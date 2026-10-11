package main

// Relayed cove MCP calls. A remote agent's cove MCP can't drive the Mac's
// kitty (spawn / send / read / wait / kill ...), so it writes the call into
// commands.jsonl as {"cmd": "rpc", "req", "tool", "args"}. The daemon ships
// commands.jsonl here like any other; appendLocal takes the rpc lines out
// (Godot never sees them) and runs each through the local cove_mcp.py
// --call, as this termling's COVE_SESSION: whatever session the remote side
// claims, it can only act as the termling it's attached in, so the MCP's own
// ownership rules (only your descendants) hold. The answer goes back as a
// line appended to the remote replies.jsonl, where the MCP is waiting on req.

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

type rpcCall struct {
	Cmd  string          `json:"cmd"`
	Req  string          `json:"req"`
	Tool string          `json:"tool"`
	Args json.RawMessage `json:"args"`
}

type rpcReply struct {
	line []byte
	at   time.Time
}

// Answers sent in the last few minutes: a reconnect replaces the remote
// replies.jsonl with the local one's tail, so these are sent again after it.
const rpcKeep = 10 * time.Minute

var rpcs = struct {
	mu     sync.Mutex
	seen   map[string]bool
	recent []rpcReply
}{seen: map[string]bool{}}

// takeRPC splits the rpc calls out of a chunk of commands.jsonl and returns
// the rest for Godot.
func (c *client) takeRPC(data []byte) []byte {
	var rest []byte
	for _, line := range bytes.SplitAfter(data, []byte("\n")) {
		var call rpcCall
		if bytes.Contains(line, []byte(`"rpc"`)) && json.Unmarshal(line, &call) == nil && call.Cmd == "rpc" {
			if call.Req != "" {
				c.runRPC(call)
			}
			continue
		}
		rest = append(rest, line...)
	}
	return rest
}

func coveMCP() string {
	if p := os.Getenv("COVE_MCP"); p != "" {
		return p
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return filepath.Join(filepath.Dir(exe), "..", "mcp", "cove_mcp.py")
}

func (c *client) runRPC(call rpcCall) {
	rpcs.mu.Lock()
	dup := rpcs.seen[call.Req]
	rpcs.seen[call.Req] = true
	rpcs.mu.Unlock()
	if dup { // a chunk the daemon resent after a failed send
		return
	}
	c.logln("relay: %s (req %s)", call.Tool, call.Req)
	go func() {
		out := map[string]any{"req": call.Req, "rpc": true}
		res, err := c.execRPC(call)
		if err != nil {
			out["ok"], out["error"] = false, err.Error()
		} else {
			for k, v := range res {
				out[k] = v
			}
		}
		line, _ := json.Marshal(out)
		line = append(line, '\n')
		c.logln("relay: %s done (req %s, %d bytes)", call.Tool, call.Req, len(line))
		rpcs.mu.Lock()
		rpcs.recent = append(rpcs.recent, rpcReply{line, time.Now()})
		rpcs.mu.Unlock()
		for !c.putReply(line) {
			time.Sleep(500 * time.Millisecond)
		}
	}()
}

func (c *client) execRPC(call rpcCall) (map[string]any, error) {
	py, err := exec.LookPath("python3")
	if err != nil {
		py = "/usr/bin/python3"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3700*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, py, coveMCP(), "--call")
	in, _ := json.Marshal(map[string]any{"tool": call.Tool, "args": call.Args})
	cmd.Stdin = bytes.NewReader(in)
	// This termling's own env: its COVE_SESSION is the caller's identity.
	cmd.Env = append(os.Environ(), "COVE_RELAY_HOST="+c.host, "COVE_REMOTE=")
	if c.coveDir != "" {
		cmd.Env = append(cmd.Env, "KITTY_COVE_DIR="+c.coveDir)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.Output()
	var res map[string]any
	if jerr := json.Unmarshal(stdout, &res); jerr != nil {
		if err == nil {
			err = jerr
		}
		c.logln("relay: %s failed: %v %s", call.Tool, err, stderr.String())
		return nil, err
	}
	return res, nil
}

// putReply appends one answer to the remote replies.jsonl.
func (c *client) putReply(line []byte) bool {
	c.connMu.Lock()
	fw, proto := c.fw, c.proto
	c.connMu.Unlock()
	if fw == nil {
		return false
	}
	msg := fileMsg{Path: "replies.jsonl", Data: line, Append: true}
	if proto >= 2 {
		msg.Data, msg.Gz = gz(line), true
	}
	return fw.json(fPut, msg) == nil
}

// resendRPC runs after the remote replies.jsonl was replaced wholesale.
func (c *client) resendRPC() {
	rpcs.mu.Lock()
	keep := rpcs.recent[:0]
	for _, r := range rpcs.recent {
		if time.Since(r.at) < rpcKeep {
			keep = append(keep, r)
		}
	}
	rpcs.recent = keep
	lines := append([]rpcReply(nil), keep...)
	rpcs.mu.Unlock()
	for _, r := range lines {
		c.putReply(r.line)
	}
}
