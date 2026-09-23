package main

// The local half: `attach` runs inside a termling in place of a shell. It owns
// the local tty, speaks frames to the remote daemon over `ssh -tt host
// cove-remote bridge`, and reconnects forever: output resumes from the exact
// byte it stopped at, unacknowledged input is resent, and in between typing is
// predicted locally so the link's latency isn't felt.

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/term"
)

var capReply = regexp.MustCompile(`\x1b\[\?7766;(\d)\$y`)

type client struct {
	host      string
	remoteBin string
	h         hello
	logf      *os.File
	coveDir   string // local Cove dir to mirror, "" outside the Cove
	metaPath  string

	outMu  sync.Mutex // guards stdout, pred, outOff
	pred   predictor
	outOff int64

	inMu   sync.Mutex
	inBuf  []byte
	inBase int64 // offset of inBuf[0]
	inNext int64
	inSent int64 // how far this connection has sent

	connMu    sync.Mutex
	fw        *frameWriter
	connected bool
	everUp    bool
	downSince time.Time
	meta      meta
	rtt       time.Duration
	lastRecv  time.Time
	proto     int           // the daemon's protocol version (from welcome)
	wasUp     bool          // connectVia got as far as a welcome (don't fail over)
	route     string        // the ssh destination in use
	ssh       *exec.Cmd     // the current link, killed to force a reconnect
	wake      chan struct{} // skip the reconnect backoff
	waking    bool          // the host's wake command is running
	wokeAt    time.Time     // when it last ran

	exitCode chan int
}

func shellQuote(s string) string {
	if s != "" && !strings.ContainsAny(s, " \t\n'\"\\$`!*?[]{}()<>|&;#~") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func runAttach(args []string) error {
	fs := flag.NewFlagSet("attach", flag.ExitOnError)
	session := fs.String("session", "", "remote session name (default: this termling's $COVE_SESSION)")
	cwd := fs.String("cwd", "", "remote working directory (default: the same path as here, else ~)")
	predictMode := fs.String("predict", "auto", "local echo prediction: auto (on slow links), on, off")
	replay := fs.Int64("replay", 1<<20, "bytes of history to replay into a fresh terminal")
	remoteBin := fs.String("remote-bin", os.Getenv("COVE_REMOTE_BIN"), "cove-remote path on the remote (default: same path as this binary)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: cove-remote attach [flags] HOST [-- command...]")
		fs.PrintDefaults()
	}
	var cmdArgs []string
	for i, a := range args {
		if a == "--" {
			cmdArgs = args[i+1:]
			args = args[:i]
			break
		}
	}
	fs.Parse(args)
	if fs.NArg() != 1 {
		fs.Usage()
		os.Exit(2)
	}
	c := &client{host: fs.Arg(0), outOff: -1, exitCode: make(chan int, 1), wake: make(chan struct{}, 1)}
	if c.remoteBin = *remoteBin; c.remoteBin == "" {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		c.remoteBin, _ = filepath.EvalSymlinks(exe)
	}
	sess := *session
	if sess == "" {
		sess = os.Getenv("COVE_SESSION")
	}
	if sess == "" {
		host, _ := os.Hostname()
		sess = fmt.Sprintf("adhoc-%s-%d", strings.Split(host, ".")[0], os.Getpid())
	}
	if !sessionRe.MatchString(sess) {
		return fmt.Errorf("bad session name %q", sess)
	}
	dir := *cwd
	if dir == "" {
		dir, _ = os.Getwd()
	}
	var cmd string
	if len(cmdArgs) == 1 {
		cmd = cmdArgs[0] // one word may be a whole shell line: -- 'cd x && make'
	} else {
		q := make([]string, len(cmdArgs))
		for i, a := range cmdArgs {
			q[i] = shellQuote(a)
		}
		cmd = strings.Join(q, " ")
	}
	env := map[string]string{"COVE_REMOTE_FROM": shortHost()}
	for _, k := range []string{"TERM", "LANG", "LC_ALL", "LC_CTYPE", "COLORTERM", "COVE",
		"COVE_SESSION", "COVE_PARENT", "KITTY_WINDOW_ID"} {
		if v := os.Getenv(k); v != "" {
			env[k] = v
		}
	}
	// A hot upgrade (SIGUSR2) re-execs us with the byte we'd reached, so the
	// new binary resumes the stream instead of replaying history.
	if v := os.Getenv("COVE_REMOTE_RESUME"); v != "" {
		fmt.Sscan(v, &c.outOff)
		os.Unsetenv("COVE_REMOTE_RESUME")
	}
	c.h = hello{Session: sess, Client: fmt.Sprintf("%s-%d-%d", shortHost(), os.Getpid(), time.Now().UnixNano()), Resume: -1, Cwd: dir, Cmd: cmd, Env: env, Replay: *replay}

	if os.Getenv("COVE_SESSION") != "" {
		c.coveDir = os.Getenv("KITTY_COVE_DIR")
		if c.coveDir == "" {
			c.coveDir = "/tmp/cove"
		}
		os.MkdirAll(filepath.Join(c.coveDir, "remote"), 0o755)
		c.metaPath = filepath.Join(c.coveDir, "remote", os.Getenv("COVE_SESSION")+".json")
	}
	logDir := filepath.Join(os.TempDir(), "cove-remote")
	os.MkdirAll(logDir, 0o700)
	c.logf, _ = os.OpenFile(filepath.Join(logDir, sess+".log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)

	var oldTTY *term.State
	if term.IsTerminal(0) {
		var err error
		if oldTTY, err = term.MakeRaw(0); err != nil {
			return err
		}
	}
	stdinTTY := oldTTY != nil
	c.updateSize()
	c.pred.always = *predictMode == "on"
	// Ask kitty whether it has the prediction overlay (private mode 7766).
	// Asked again on every resize: a kitty warm reload reattaches us (with a
	// resize) to a kitty that may have gained it.
	probe := func() {
		if *predictMode != "off" && stdinTTY && strings.HasPrefix(os.Getenv("TERM"), "xterm-kitty") {
			os.Stdout.WriteString("\x1b[?7766$p")
		}
	}
	probe()

	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGWINCH, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGUSR2)
	go func() {
		for s := range sigs {
			if s == syscall.SIGWINCH {
				c.updateSize()
				c.outMu.Lock()
				os.Stdout.Write(c.pred.clear())
				c.pred.pend = c.pred.pend[:0]
				probe()
				c.outMu.Unlock()
				c.send(func(fw *frameWriter) { fw.json(fResize, map[string]int{"cols": c.h.Cols, "rows": c.h.Rows}) })
				continue
			}
			if s == syscall.SIGUSR2 {
				c.upgrade(oldTTY)
				continue
			}
			// The termling closed: detach. The remote session keeps running.
			c.outMu.Lock()
			os.Stdout.Write(c.pred.clear())
			c.outMu.Unlock()
			c.finish(0)
		}
	}()
	go c.readStdin()
	go c.ticker()
	go c.mirrorLoop()
	go c.connectLoop()
	code := <-c.exitCode
	c.dropLink() // don't leave an orphaned ssh behind
	c.outMu.Lock()
	os.Stdout.Write(c.pred.clear())
	c.outMu.Unlock()
	c.removeMeta()
	if oldTTY != nil {
		term.Restore(0, oldTTY)
	}
	os.Exit(code)
	return nil
}

// upgrade re-execs the (possibly rebuilt) binary in place, keeping the
// session and output position. The remote side is untouched.
func (c *client) upgrade(oldTTY *term.State) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	c.outMu.Lock() // no more output writes; exec keeps the lock moot
	os.Stdout.Write(c.pred.clear())
	env := append(os.Environ(), fmt.Sprintf("COVE_REMOTE_RESUME=%d", c.outOff))
	c.connMu.Lock()
	if c.ssh != nil && c.ssh.Process != nil {
		c.ssh.Process.Kill()
	}
	c.connMu.Unlock()
	if oldTTY != nil {
		term.Restore(0, oldTTY)
	}
	c.logln("upgrading in place at output offset %d", c.outOff)
	err = syscall.Exec(exe, os.Args, env)
	c.logln("upgrade failed: %v", err) // still running the old code
	if oldTTY != nil {
		term.MakeRaw(0)
	}
	c.outMu.Unlock()
}

func (c *client) finish(code int) {
	select {
	case c.exitCode <- code:
	default:
	}
}

func shortHost() string {
	h, _ := os.Hostname()
	return strings.Split(h, ".")[0]
}

func (c *client) logln(format string, a ...any) {
	if c.logf != nil {
		fmt.Fprintf(c.logf, time.Now().Format("15:04:05.000 ")+format+"\n", a...)
	}
}

func (c *client) updateSize() {
	if w, h, err := term.GetSize(1); err == nil {
		c.h.Cols, c.h.Rows = w, h
	}
}

func (c *client) send(f func(fw *frameWriter)) {
	c.connMu.Lock()
	fw := c.fw
	c.connMu.Unlock()
	if fw != nil {
		f(fw)
	}
}

func (c *client) readStdin() {
	buf := make([]byte, 32<<10)
	for {
		n, err := os.Stdin.Read(buf)
		if n > 0 {
			data := append([]byte(nil), buf[:n]...)
			if m := capReply.FindSubmatchIndex(data); m != nil {
				v := data[m[2]]
				c.outMu.Lock()
				c.pred.enabled = v == '1' || v == '3'
				c.outMu.Unlock()
				c.logln("kitty prediction overlay: %v", v == '1' || v == '3')
				data = append(data[:m[0]], data[m[1]:]...)
			}
			if len(data) > 0 {
				c.input(data)
			}
		}
		if err != nil {
			if err == io.EOF {
				c.finish(0)
			}
			return
		}
	}
}

func (c *client) input(data []byte) {
	c.outMu.Lock()
	c.pred.onInput(data)
	os.Stdout.Write(c.pred.refresh(false))
	c.outMu.Unlock()

	c.inMu.Lock()
	c.inBuf = append(c.inBuf, data...)
	c.inNext += int64(len(data))
	c.inMu.Unlock()
	c.connMu.Lock()
	fw := c.fw
	c.connMu.Unlock()
	if fw != nil {
		c.flushInput(fw)
	}
}

// flushInput sends the input this connection hasn't sent yet, in order.
func (c *client) flushInput(fw *frameWriter) {
	c.inMu.Lock()
	defer c.inMu.Unlock()
	if c.inSent < c.inBase {
		c.inSent = c.inBase
	}
	if c.inSent >= c.inNext {
		return
	}
	if fw.offset(fInput, c.inSent, c.inBuf[c.inSent-c.inBase:]) == nil {
		c.inSent = c.inNext
	}
}

// dropLink kills the current ssh; connectLoop then reconnects at once.
func (c *client) dropLink() {
	c.connMu.Lock()
	cmd := c.ssh
	c.connMu.Unlock()
	if cmd != nil && cmd.Process != nil {
		cmd.Process.Kill()
	}
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

func (c *client) ticker() {
	t := time.NewTicker(100 * time.Millisecond)
	n := 0
	last := time.Now().Round(0) // wall clock: it jumps across a sleep, the monotonic one doesn't
	for range t.C {
		n++
		if now := time.Now().Round(0); now.Sub(last) > 2*time.Second {
			// The Mac just woke up. The old TCP connection is almost certainly
			// dead, so don't wait for timeouts to prove it.
			c.logln("woke after %v, reconnecting", now.Sub(last).Round(time.Second))
			c.dropLink()
			last = now
		} else {
			last = now
		}
		c.outMu.Lock()
		c.pred.expire()
		c.connMu.Lock()
		down := !c.connected && c.everUp && time.Since(c.downSince) > 1500*time.Millisecond
		waking := c.waking
		c.connMu.Unlock()
		if waking {
			c.pred.status = "⟳ waking " + c.host
		} else if down {
			c.pred.status = "⟳ " + c.host
		} else {
			c.pred.status = ""
		}
		os.Stdout.Write(c.pred.refresh(false))
		c.outMu.Unlock()
		if n%20 == 0 {
			now := make([]byte, 8)
			binary.BigEndian.PutUint64(now, uint64(time.Now().UnixNano()))
			c.send(func(fw *frameWriter) { fw.write(fPing, now) })
		}
	}
}

func (c *client) connectLoop() {
	backoff := 250 * time.Millisecond
	for {
		began := time.Now()
		err := c.connectOnce()
		c.connMu.Lock()
		if c.connected {
			c.downSince = time.Now()
		}
		c.connected, c.fw = false, nil
		c.connMu.Unlock()
		c.writeMeta()
		c.logln("disconnected: %v", err)
		if time.Since(began) > 10*time.Second {
			backoff = 250 * time.Millisecond
		}
		select {
		case <-time.After(backoff):
			backoff = min(backoff*2, 4*time.Second)
		case <-c.wake: // woke up or asked to: retry now
			backoff = 250 * time.Millisecond
		}
	}
}

// routes lists the ssh destinations to try for host, best first. It reads
// ~/.config/cove-remote/routes on every connect, lines like
//
//	kirans-macbook-pro  Kirans-MacBook-Pro.local  kirans-macbook-pro
//
// so a same-LAN route can go ahead of Tailscale (which may be relayed through
// a far-off DERP server) and live clients pick up edits on their next reconnect.
func routes(host string) []string {
	b, err := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".config", "cove-remote", "routes"))
	if err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			f := strings.Fields(line)
			if len(f) >= 2 && !strings.HasPrefix(f[0], "#") && strings.EqualFold(f[0], host) {
				return f[1:]
			}
		}
	}
	return []string{host}
}

func (c *client) connectOnce() error {
	err := c.tryRoutes()
	var ue unreachableError
	if err != nil && !c.wasUp && errors.As(err, &ue) && c.wakeHost() {
		err = c.tryRoutes()
	}
	return err
}

// wakeHost runs the host's wake command (from ~/.config/cove-remote/hosts),
// at most once a minute, and says whether it's worth retrying now.
func (c *client) wakeHost() bool {
	if wakeCommand(c.host) == "" || time.Since(c.wokeAt) < time.Minute {
		return false
	}
	c.connMu.Lock()
	c.waking = true
	first := !c.everUp
	c.connMu.Unlock()
	c.writeMeta()
	if first {
		c.outMu.Lock()
		fmt.Fprintf(os.Stdout, "\x1b[2m[cove-remote: waking %s]\x1b[0m\r\n", c.host)
		c.outMu.Unlock()
	}
	c.logln("%s unreachable, running its wake command", c.host)
	began := time.Now()
	err := runWake(c.host, c.logf)
	c.logln("wake finished after %v: %v", time.Since(began).Round(time.Second), err)
	c.connMu.Lock()
	c.waking = false
	c.connMu.Unlock()
	c.wokeAt = time.Now()
	c.writeMeta()
	return err == nil
}

func (c *client) tryRoutes() error {
	var err error
	rs := routes(c.host)
	for i, dest := range rs {
		// Every route but the last gets a short leash: a LAN name that doesn't
		// resolve or answer (we're elsewhere) should fail over fast.
		timeout := 20
		if i < len(rs)-1 {
			timeout = 4
		}
		if err = c.connectVia(dest, timeout); err == nil || c.wasUp {
			return err
		}
		c.logln("route %s failed: %v", dest, err)
	}
	return err
}

func (c *client) connectVia(dest string, timeout int) error {
	c.wasUp = false
	cmd := exec.Command("ssh", "-tt", "-e", "none",
		// IPv4 only: a .local name resolves to an IPv6 link-local address
		// first, which can hang for half a minute before falling back.
		"-o", "AddressFamily=inet",
		"-o", "BatchMode=yes", "-o", fmt.Sprintf("ConnectTimeout=%d", timeout), "-o", "LogLevel=ERROR",
		"-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=4",
		dest, shellQuote(c.remoteBin)+" bridge")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = c.logf
	if err := cmd.Start(); err != nil {
		return err
	}
	c.connMu.Lock()
	c.ssh = cmd
	c.connMu.Unlock()
	var exited chan error // set once something is already waiting on ssh
	defer func() {
		cmd.Process.Kill()
		if exited != nil {
			<-exited
		} else {
			cmd.Wait()
		}
		c.connMu.Lock()
		if c.ssh == cmd {
			c.ssh = nil
		}
		c.connMu.Unlock()
	}()
	// Anything silent for too long is dead (a sleeping peer, a changed network).
	// Connecting gets longer: over a Tailscale relay the ssh handshake alone
	// can take well over 7s, and killing it then just starts it over.
	c.connMu.Lock()
	c.lastRecv = time.Now()
	c.connMu.Unlock()
	up := false
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				c.connMu.Lock()
				idle := time.Since(c.lastRecv)
				rtt := c.rtt
				up = c.connected
				c.connMu.Unlock()
				// Pings go every 2s, so a live link is never silent for long;
				// allow for a slow one (3 round trips) before calling it dead.
				// A lossy relay can stall a live TCP link for several seconds;
				// tearing it down then costs a slow reconnect. Sleep is caught
				// separately (the wall-clock jump in ticker).
				limit := max(15*time.Second, 2*time.Second+4*rtt)
				if !up {
					limit = 45 * time.Second
				}
				if idle > limit {
					c.logln("no traffic for %v, dropping the link", idle)
					cmd.Process.Kill()
					return
				}
			}
		}
	}()

	r := bufio.NewReaderSize(stdout, 256<<10)
	if err := waitMarker(r); err != nil {
		// ssh closed its stdout, so it's exiting: see whether it never got
		// as far as the host.
		exited = make(chan error, 1)
		go func() { exited <- cmd.Wait() }()
		select {
		case werr := <-exited:
			exited <- werr // for the deferred cleanup
			if sshFailed(werr) {
				return unreachableError{dest, err}
			}
		case <-time.After(2 * time.Second):
		}
		return err
	}
	fw := &frameWriter{w: stdin}
	c.outMu.Lock()
	c.h.Resume = c.outOff
	c.outMu.Unlock()
	if err := fw.json(fHello, c.h); err != nil {
		return err
	}
	f, err := readFrame(r)
	if err != nil {
		return err
	}
	if f.t != fWelcome {
		return errors.New("expected welcome")
	}
	var w welcome
	if err := json.Unmarshal(f.p, &w); err != nil {
		return err
	}
	c.logln("connected via %s: %+v", dest, w)
	c.onWelcome(w)

	// Resend whatever input the daemon hasn't got yet.
	c.inMu.Lock()
	if w.InAck > c.inBase {
		drop := min(w.InAck-c.inBase, int64(len(c.inBuf)))
		c.inBuf = c.inBuf[drop:]
		c.inBase += drop
	}
	c.inSent = c.inBase
	c.inMu.Unlock()
	c.connMu.Lock()
	c.fw, c.connected, c.everUp, c.proto, c.route = fw, true, true, w.Proto, dest
	c.connMu.Unlock()
	c.wasUp = true
	c.flushInput(fw)
	c.writeMeta()
	c.resetMirror()

	for {
		f, err := readFrame(r)
		if err != nil {
			return err
		}
		c.connMu.Lock()
		c.lastRecv = time.Now()
		c.connMu.Unlock()
		switch f.t {
		case fOutput:
			off, data := u64(f.p)
			c.output(off, data)
		case fInputAck:
			ack, _ := u64(f.p)
			c.inMu.Lock()
			if ack > c.inBase {
				drop := min(ack-c.inBase, int64(len(c.inBuf)))
				c.inBuf = c.inBuf[drop:]
				c.inBase += drop
			}
			c.inMu.Unlock()
		case fPong:
			sent, _ := u64(f.p)
			rtt := time.Since(time.Unix(0, sent))
			c.connMu.Lock()
			if c.rtt == 0 {
				c.rtt = rtt
			} else {
				c.rtt = (7*c.rtt + rtt) / 8
			}
			srtt := c.rtt
			c.connMu.Unlock()
			c.outMu.Lock()
			c.pred.srtt = srtt
			c.outMu.Unlock()
			c.writeMeta()
		case fMeta:
			var m meta
			if json.Unmarshal(f.p, &m) == nil {
				c.connMu.Lock()
				c.meta = m
				c.connMu.Unlock()
				c.writeMeta()
			}
		case fAppend:
			var m fileMsg
			if json.Unmarshal(f.p, &m) == nil {
				c.appendLocal(m)
			}
		case fExit:
			var e struct{ Code int }
			json.Unmarshal(f.p, &e)
			c.finish(e.Code)
			select {} // main exits the process
		}
	}
}

func waitMarker(r *bufio.Reader) error {
	var seen []byte
	for {
		b, err := r.ReadByte()
		if err != nil {
			return fmt.Errorf("ssh closed before the bridge was ready: %w (%q)", err, seen)
		}
		seen = append(seen, b)
		if bytes.HasSuffix(seen, []byte(readyMarker)) {
			return nil
		}
		if len(seen) > 64<<10 {
			return errors.New("no ready marker from the bridge")
		}
	}
}

func (c *client) onWelcome(w welcome) {
	c.outMu.Lock()
	defer c.outMu.Unlock()
	var note string
	switch {
	case c.outOff > 0 && w.Created:
		note = "the remote session was gone (did the remote restart?); this is a new one"
		c.inMu.Lock()
		c.inBuf, c.inBase, c.inNext, c.inSent = nil, 0, 0, 0
		c.inMu.Unlock()
	case c.outOff >= 0 && w.From > c.outOff:
		note = fmt.Sprintf("%d bytes of output were lost while disconnected", w.From-c.outOff)
	}
	if note != "" {
		os.Stdout.Write(c.pred.clear())
		fmt.Fprintf(os.Stdout, "\r\n\x1b[2m[cove-remote: %s]\x1b[0m\r\n", note)
	}
	c.outOff = w.From
}

func (c *client) output(off int64, data []byte) {
	c.outMu.Lock()
	defer c.outMu.Unlock()
	end := off + int64(len(data))
	if end <= c.outOff {
		return
	}
	if off < c.outOff {
		data = data[c.outOff-off:]
	}
	os.Stdout.Write(c.pred.wrap(data))
	c.outOff = end
}

// --- Cove integration ---------------------------------------------------------

// writeMeta tells the local Cove what's really running in this termling.
func (c *client) writeMeta() {
	if c.metaPath == "" {
		return
	}
	c.connMu.Lock()
	m := map[string]any{
		"host": c.host, "route": c.route, "session": c.h.Session, "connected": c.connected,
		"rtt_ms": c.rtt.Milliseconds(), "agent": c.meta.Agent, "busy": c.meta.Busy,
		"idle": c.meta.Idle, "cwd": c.meta.Cwd, "pid": c.meta.Pid, "client_pid": os.Getpid(),
	}
	if !c.connected && c.everUp {
		m["down_since"] = c.downSince.Unix()
	}
	if c.waking {
		m["waking"] = true
	}
	c.connMu.Unlock()
	c.outMu.Lock()
	m["predict"] = c.pred.enabled
	c.outMu.Unlock()
	b, _ := json.Marshal(m)
	tmp := c.metaPath + ".tmp"
	if os.WriteFile(tmp, b, 0o644) == nil {
		os.Rename(tmp, c.metaPath)
	}
}

func (c *client) removeMeta() {
	if c.metaPath != "" {
		os.Remove(c.metaPath)
	}
}

var appendRe = regexp.MustCompile(`^(notify\.jsonl|commands\.jsonl|(events|mail)/[A-Za-z0-9._-]+\.jsonl)$`)

func (c *client) appendLocal(m fileMsg) {
	if c.coveDir == "" || !appendRe.MatchString(m.Path) {
		return
	}
	p := filepath.Join(c.coveDir, m.Path)
	os.MkdirAll(filepath.Dir(p), 0o755)
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	f.Write(m.Data)
	f.Close()
}

type mirrorState struct {
	mu      sync.Mutex
	stamp   map[string]string
	sentAt  map[string]time.Time
	replies int64
}

var mirror = mirrorState{stamp: map[string]string{}, sentAt: map[string]time.Time{}}

func (c *client) resetMirror() {
	mirror.mu.Lock()
	mirror.stamp = map[string]string{}
	mirror.sentAt = map[string]time.Time{}
	mirror.replies = -1
	mirror.mu.Unlock()
}

// The world files change every second (termlings walk), so they're sent at
// most this often, gzipped: they must never crowd out keystrokes on a thin link.
const worldEvery = 5 * time.Second

func gz(b []byte) []byte {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write(b)
	zw.Close()
	return buf.Bytes()
}

// mirrorLoop ships the Cove's world (state.json, board.json) and its command
// replies to the remote, so the remote agent's cove MCP sees the live board.
func (c *client) mirrorLoop() {
	if c.coveDir == "" {
		return
	}
	for {
		time.Sleep(150 * time.Millisecond)
		c.connMu.Lock()
		fw := c.fw
		c.connMu.Unlock()
		if fw == nil {
			continue
		}
		for _, name := range []string{"state.json", "board.json"} {
			p := filepath.Join(c.coveDir, name)
			st, err := os.Stat(p)
			if err != nil {
				continue
			}
			stamp := fmt.Sprint(st.ModTime().UnixNano(), st.Size())
			mirror.mu.Lock()
			skip := mirror.stamp[name] == stamp || time.Since(mirror.sentAt[name]) < worldEvery
			mirror.mu.Unlock()
			if skip {
				continue
			}
			data, err := os.ReadFile(p)
			if err != nil {
				continue
			}
			msg := fileMsg{Path: name, Data: data}
			c.connMu.Lock()
			proto := c.proto
			c.connMu.Unlock()
			if proto >= 2 {
				msg.Data, msg.Gz = gz(data), true
			}
			if fw.json(fPut, msg) != nil {
				continue
			}
			mirror.mu.Lock()
			mirror.stamp[name] = stamp
			mirror.sentAt[name] = time.Now()
			mirror.mu.Unlock()
		}
		p := filepath.Join(c.coveDir, "replies.jsonl")
		st, err := os.Stat(p)
		if err != nil {
			continue
		}
		mirror.mu.Lock()
		off := mirror.replies
		mirror.mu.Unlock()
		size := st.Size()
		if off == size {
			continue
		}
		replace := off < 0 || size < off
		if replace {
			off = max(0, size-(64<<10)) // recent replies are all anyone waits on
		}
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		data := make([]byte, size-off)
		n, _ := f.ReadAt(data, off)
		f.Close()
		if fw.json(fPut, fileMsg{Path: "replies.jsonl", Data: data[:n], Append: !replace}) == nil {
			mirror.mu.Lock()
			mirror.replies = off + int64(n)
			mirror.mu.Unlock()
		}
	}
}
