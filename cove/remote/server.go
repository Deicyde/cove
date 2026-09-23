package main

// The remote half: `bridge` (run by ssh, one per connection) and `serve` (the
// session daemon, one per session, outlives every connection).
//
// The daemon owns the pty and keeps the last ringCap bytes of its output with
// absolute offsets. It is a plain byte pipe (no screen model, unlike tmux), so
// the local kitty renders the program exactly as if it ran locally and keeps
// its own native scrollback.

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

const ringCap = 8 << 20

var sessionRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

func baseDir() string {
	return filepath.Join(os.Getenv("HOME"), ".cache", "cove-remote")
}

func sessionDir(s string) string { return filepath.Join(baseDir(), s) }

// --- bridge ------------------------------------------------------------------

func runBridge() error {
	if term.IsTerminal(0) {
		// ssh -tt gives us a pty (so sshd sets TCP_NODELAY: no Nagle delay on
		// keystrokes); make it a clean 8-bit pipe before any frame crosses it.
		if _, err := term.MakeRaw(0); err != nil {
			return err
		}
	}
	os.Stdout.WriteString(readyMarker)
	in := bufio.NewReaderSize(os.Stdin, 64<<10)
	f, err := readFrame(in)
	if err != nil {
		return err
	}
	if f.t != fHello {
		return errors.New("expected hello")
	}
	var h hello
	if err := json.Unmarshal(f.p, &h); err != nil {
		return err
	}
	if !sessionRe.MatchString(h.Session) {
		return fmt.Errorf("bad session name %q", h.Session)
	}
	conn, err := dialOrStart(h)
	if err != nil {
		return err
	}
	fw := &frameWriter{w: conn}
	if err := fw.write(fHello, f.p); err != nil {
		return err
	}
	done := make(chan struct{}, 2)
	go func() { io.Copy(os.Stdout, conn); done <- struct{}{} }()
	go func() { io.Copy(conn, in); done <- struct{}{} }()
	<-done
	return nil
}

func dialOrStart(h hello) (net.Conn, error) {
	sock := filepath.Join(sessionDir(h.Session), "sock")
	if c, err := net.Dial("unix", sock); err == nil {
		return c, nil
	}
	if err := os.MkdirAll(sessionDir(h.Session), 0o700); err != nil {
		return nil, err
	}
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	b, _ := json.Marshal(h)
	logf, err := os.OpenFile(filepath.Join(sessionDir(h.Session), "log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	defer logf.Close()
	cmd := exec.Command(self, "serve", base64.StdEncoding.EncodeToString(b))
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go cmd.Wait()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if c, err := net.Dial("unix", sock); err == nil {
			return c, nil
		}
		time.Sleep(30 * time.Millisecond)
	}
	return nil, errors.New("session daemon did not start (see " + sessionDir(h.Session) + "/log)")
}

// --- daemon ------------------------------------------------------------------

type daemon struct {
	mu    sync.Mutex
	cond  *sync.Cond
	ring  []byte
	start int64 // offset of ring[0]
	head  int64 // offset of the next output byte

	inRecv   int64
	inClient string // whose input stream inRecv counts

	ptmx     *os.File
	cmd      *exec.Cmd
	exited   bool
	exitCode int

	cur       *dconn
	clients   int
	delivered bool // a client got the EXIT frame

	dir, coveDir string
	meta         []byte
}

type dconn struct {
	c     net.Conn
	fw    *frameWriter
	alive bool
}

func runServe(arg string) error {
	raw, err := base64.StdEncoding.DecodeString(arg)
	if err != nil {
		return err
	}
	var h hello
	if err := json.Unmarshal(raw, &h); err != nil {
		return err
	}
	d := &daemon{dir: sessionDir(h.Session)}
	d.cond = sync.NewCond(&d.mu)
	d.coveDir = filepath.Join(d.dir, "cove")
	for _, sub := range []string{"events", "mail", "prompts", "shots"} {
		os.MkdirAll(filepath.Join(d.coveDir, sub), 0o700)
	}
	sock := filepath.Join(d.dir, "sock")
	if c, err := net.Dial("unix", sock); err == nil {
		c.Close()
		return errors.New("session already running")
	}
	os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		return err
	}
	defer os.Remove(sock)
	if err := d.startChild(h); err != nil {
		return err
	}
	log.Printf("session %s: pid %d, cmd %q, cwd %q", h.Session, d.cmd.Process.Pid, h.Cmd, h.Cwd)
	info, _ := json.Marshal(map[string]any{"session": h.Session, "cmd": h.Cmd, "cwd": h.Cwd,
		"pid": d.cmd.Process.Pid, "daemon": os.Getpid(), "created": time.Now().Unix()})
	os.WriteFile(filepath.Join(d.dir, "info.json"), info, 0o600)
	if os.Getenv("COVE_REMOTE_NO_CAFFEINATE") == "" {
		// Keep the machine awake while the session lives (the point of running
		// something remotely is that it keeps going).
		cf := exec.Command("/usr/bin/caffeinate", "-ims", "-w", fmt.Sprint(os.Getpid()))
		if cf.Start() == nil {
			go cf.Wait()
		}
	}
	go d.readPty()
	go d.watchMeta()
	go d.pumpCoveDir()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go d.serveConn(c)
		}
	}()
	// Linger after the program ends until a client has seen the exit, but no
	// longer than an hour with nobody attached.
	for {
		time.Sleep(time.Second)
		d.mu.Lock()
		done := d.exited && (d.delivered || (d.cur == nil && time.Since(lastDetach) > time.Hour))
		d.mu.Unlock()
		if done {
			time.Sleep(500 * time.Millisecond)
			ln.Close()
			os.RemoveAll(d.dir)
			return nil
		}
	}
}

var lastDetach = time.Now()

func (d *daemon) startChild(h hello) error {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	var argv []string
	if strings.TrimSpace(h.Cmd) == "" {
		argv = []string{shell, "-l"}
	} else {
		// Run the command in an interactive login shell (so PATH and rc files
		// apply), then stay in a shell: the termling doesn't vanish with its
		// output when the command ends.
		argv = []string{shell, "-l", "-i", "-c", h.Cmd + "\nexec " + shell + " -l"}
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cwd := h.Cwd
	if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
		cwd = os.Getenv("HOME")
	}
	cmd.Dir = cwd
	cmd.Env = d.childEnv(h)
	rows, cols := h.Rows, h.Cols
	if rows <= 0 || cols <= 0 {
		rows, cols = 32, 110
	}
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: uint16(rows), Cols: uint16(cols)})
	if err != nil {
		return err
	}
	d.ptmx, d.cmd = ptmx, cmd
	return nil
}

func (d *daemon) childEnv(h hello) []string {
	env := map[string]string{}
	for _, kv := range os.Environ() {
		k, v, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "CLAUDE") || strings.HasPrefix(k, "SSH_") || k == "COVE_REMOTE_NO_CAFFEINATE" {
			continue
		}
		env[k] = v
	}
	for k, v := range h.Env {
		env[k] = v
	}
	// xterm-kitty needs kitty's terminfo, which the pro doesn't have installed;
	// the kitty checkout next to this binary does.
	if exe, err := os.Executable(); err == nil {
		ti := filepath.Join(filepath.Dir(exe), "..", "..", "terminfo")
		if _, err := os.Stat(filepath.Join(ti, "78", "xterm-kitty")); err == nil {
			env["TERMINFO_DIRS"] = ti + ":/usr/share/terminfo"
		} else if env["TERM"] == "xterm-kitty" {
			env["TERM"] = "xterm-256color"
		}
	}
	if env["TERM"] == "" {
		env["TERM"] = "xterm-256color"
	}
	if env["COLORTERM"] == "" {
		env["COLORTERM"] = "truecolor"
	}
	// The Cove integration (hooks + cove MCP) reads and writes this directory;
	// the daemon mirrors it to and from the viewing Mac's /tmp/cove.
	env["KITTY_COVE_DIR"] = d.coveDir
	env["COVE_REMOTE"] = "1"
	out := make([]string, 0, len(env))
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	return out
}

func (d *daemon) readPty() {
	buf := make([]byte, 64<<10)
	waited := make(chan int, 1)
	go func() {
		err := d.cmd.Wait()
		code := 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
		waited <- code
	}()
	eof := make(chan struct{})
	go func() {
		for {
			n, err := d.ptmx.Read(buf)
			if n > 0 {
				d.mu.Lock()
				d.ring = append(d.ring, buf[:n]...)
				d.head += int64(n)
				if len(d.ring) > 2*ringCap {
					cut := len(d.ring) - ringCap
					d.ring = append([]byte(nil), d.ring[cut:]...)
					d.start += int64(cut)
				}
				d.cond.Broadcast()
				d.mu.Unlock()
			}
			if err != nil {
				close(eof)
				return
			}
		}
	}()
	code := <-waited
	select {
	case <-eof:
	case <-time.After(300 * time.Millisecond): // a background job still holds the tty
	}
	d.mu.Lock()
	d.exited, d.exitCode = true, code
	d.cond.Broadcast()
	d.mu.Unlock()
	log.Printf("program exited %d", code)
}

func (d *daemon) serveConn(c net.Conn) {
	defer c.Close()
	r := bufio.NewReaderSize(c, 64<<10)
	f, err := readFrame(r)
	if err != nil || f.t != fHello {
		return
	}
	var h hello
	if err := json.Unmarshal(f.p, &h); err != nil {
		return
	}
	dc := &dconn{c: c, fw: &frameWriter{w: c}, alive: true}

	d.mu.Lock()
	if d.cur != nil { // newest client wins
		d.cur.alive = false
		d.cur.c.Close()
	}
	d.cur = dc
	first := d.clients == 0
	d.clients++
	if h.Client != d.inClient {
		d.inClient, d.inRecv = h.Client, 0
	}
	from := h.Resume
	fresh := from < 0 || from > d.head
	if fresh {
		back := h.Replay
		if back <= 0 {
			back = 1 << 20
		}
		from = max(d.start, d.head-back)
		// Start the replay on a line boundary rather than mid escape sequence.
		if from > d.start {
			if i := bytes.IndexByte(d.ring[from-d.start:], '\n'); i >= 0 {
				from += int64(i) + 1
			}
		}
	} else if from < d.start {
		from = d.start
	}
	w := welcome{InAck: d.inRecv, OutStart: d.start, Head: d.head, From: from,
		Created: first, Pid: d.cmd.Process.Pid, Exited: d.exited, Proto: 2}
	metaNow := d.meta
	d.mu.Unlock()
	log.Printf("client attached (resume %d, from %d, head %d)", h.Resume, from, w.Head)

	if err := dc.fw.json(fWelcome, w); err != nil {
		return
	}
	if metaNow != nil {
		dc.fw.write(fMeta, metaNow)
	}
	if h.Cols > 0 && h.Rows > 0 {
		pty.Setsize(d.ptmx, &pty.Winsize{Rows: uint16(h.Rows), Cols: uint16(h.Cols)})
		if fresh && !first {
			// A brand-new viewer: nudge full-screen programs into a redraw.
			go func() {
				time.Sleep(150 * time.Millisecond)
				pty.Setsize(d.ptmx, &pty.Winsize{Rows: uint16(h.Rows), Cols: uint16(max(h.Cols-1, 1))})
				time.Sleep(50 * time.Millisecond)
				pty.Setsize(d.ptmx, &pty.Winsize{Rows: uint16(h.Rows), Cols: uint16(h.Cols)})
			}()
		}
	}
	go d.sendOutput(dc, from)

	for {
		f, err := readFrame(r)
		if err != nil {
			break
		}
		switch f.t {
		case fInput:
			off, data := u64(f.p)
			d.mu.Lock()
			if off > d.inRecv { // a gap: the client resends from our ack on reconnect
				data = nil
			} else if skip := d.inRecv - off; skip > 0 {
				if skip >= int64(len(data)) {
					data = nil
				} else {
					data = data[skip:]
				}
			}
			d.inRecv += int64(len(data))
			ack := d.inRecv
			d.mu.Unlock()
			if len(data) > 0 {
				d.ptmx.Write(data)
			}
			dc.fw.offset(fInputAck, ack, nil)
		case fResize:
			var sz struct{ Cols, Rows int }
			if json.Unmarshal(f.p, &sz) == nil && sz.Cols > 0 && sz.Rows > 0 {
				pty.Setsize(d.ptmx, &pty.Winsize{Rows: uint16(sz.Rows), Cols: uint16(sz.Cols)})
			}
		case fPing:
			dc.fw.write(fPong, f.p)
		case fPut:
			var m fileMsg
			if json.Unmarshal(f.p, &m) == nil {
				d.putFile(m)
			}
		case fKill:
			if d.cmd.Process != nil {
				syscall.Kill(-d.cmd.Process.Pid, syscall.SIGHUP)
			}
		}
	}
	d.mu.Lock()
	dc.alive = false
	if d.cur == dc {
		d.cur = nil
		lastDetach = time.Now()
	}
	d.cond.Broadcast()
	d.mu.Unlock()
	log.Printf("client detached")
}

func (d *daemon) sendOutput(dc *dconn, pos int64) {
	for {
		d.mu.Lock()
		for dc.alive && pos >= d.head && !d.exited {
			d.cond.Wait()
		}
		if !dc.alive {
			d.mu.Unlock()
			return
		}
		if pos < d.start {
			pos = d.start
		}
		end := min(d.head, pos+(64<<10))
		chunk := append([]byte(nil), d.ring[pos-d.start:end-d.start]...)
		final := d.exited && end == d.head
		code := d.exitCode
		d.mu.Unlock()
		if len(chunk) > 0 {
			if dc.fw.offset(fOutput, pos, chunk) != nil {
				return
			}
			pos = end
		}
		if final {
			if dc.fw.json(fExit, map[string]int{"code": code}) == nil {
				d.mu.Lock()
				d.delivered = true
				d.mu.Unlock()
			}
			return
		}
	}
}

// --- session metadata (what's running, where) ---------------------------------

func (d *daemon) watchMeta() {
	var last []byte
	cwdPid, cwd, cwdAt := -1, "", time.Time{}
	for {
		time.Sleep(time.Second)
		d.mu.Lock()
		exited := d.exited
		d.mu.Unlock()
		if exited {
			return
		}
		m := scanTree(d.cmd.Process.Pid)
		if m.Pid != cwdPid || time.Since(cwdAt) > 3*time.Second {
			cwdPid, cwd, cwdAt = m.Pid, cwdOf(m.Pid), time.Now()
		}
		m.Cwd = cwd
		if t, err := unix.IoctlGetTermios(int(d.ptmx.Fd()), unix.TIOCGETA); err == nil {
			m.Echo = t.Lflag&unix.ECHO != 0 && t.Lflag&unix.ICANON != 0
		}
		b, _ := json.Marshal(m)
		if bytes.Equal(b, last) {
			continue
		}
		last = b
		d.mu.Lock()
		d.meta = b
		cur := d.cur
		d.mu.Unlock()
		if cur != nil {
			cur.fw.write(fMeta, b)
		}
	}
}

// --- cove dir mirror ------------------------------------------------------------
//
// The remote agent's hooks and cove MCP write notify.jsonl / commands.jsonl /
// events / mail into $KITTY_COVE_DIR here; each is taken whole (the same
// rename trick Cove.gd uses) and shipped to the viewer, which appends it to
// the real Cove's /tmp/cove. The viewer ships state.json, board.json and
// replies.jsonl back, so whoami/board/replies read the live Cove.

var putAllowed = map[string]bool{"state.json": true, "board.json": true, "replies.jsonl": true}

func (d *daemon) putFile(m fileMsg) {
	if !putAllowed[m.Path] {
		return
	}
	if m.Gz {
		zr, err := gzip.NewReader(bytes.NewReader(m.Data))
		if err != nil {
			return
		}
		data, err := io.ReadAll(zr)
		if err != nil {
			return
		}
		m.Data = data
	}
	p := filepath.Join(d.coveDir, m.Path)
	if m.Append {
		f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err == nil {
			f.Write(m.Data)
			f.Close()
		}
		return
	}
	tmp := p + ".tmp"
	if os.WriteFile(tmp, m.Data, 0o600) == nil {
		os.Rename(tmp, p)
	}
}

func (d *daemon) takeList() []string {
	names := []string{"notify.jsonl", "commands.jsonl"}
	seen := map[string]bool{}
	for _, sub := range []string{"events", "mail"} {
		ents, _ := os.ReadDir(filepath.Join(d.coveDir, sub))
		for _, e := range ents {
			// a .taking left behind by a failed send is retried too
			if n := strings.TrimSuffix(e.Name(), ".taking"); strings.HasSuffix(n, ".jsonl") && !seen[sub+"/"+n] {
				seen[sub+"/"+n] = true
				names = append(names, sub+"/"+n)
			}
		}
	}
	sort.Strings(names)
	return names
}

func (d *daemon) pumpCoveDir() {
	for {
		time.Sleep(100 * time.Millisecond)
		d.mu.Lock()
		cur := d.cur
		d.mu.Unlock()
		if cur == nil {
			continue // hold it until someone can deliver it
		}
		for _, rel := range d.takeList() {
			p := filepath.Join(d.coveDir, rel)
			taken := p + ".taking"
			if _, err := os.Stat(taken); err != nil {
				if os.Rename(p, taken) != nil {
					continue
				}
			}
			data, err := os.ReadFile(taken)
			if err != nil {
				continue
			}
			if len(data) == 0 || cur.fw.json(fAppend, fileMsg{Path: rel, Data: data, Append: true}) == nil {
				os.Remove(taken)
			}
		}
	}
}
