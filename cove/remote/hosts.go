package main

// Per-host settings, read from ~/.config/cove-remote/hosts on every use, one
// setting per line:
//
//	# host   setting  value
//	aws-dev  wake     ~/Documents/code/aws-devbox/bin/aws-dev-wake
//
// A host's wake command runs (through sh) when ssh can't reach the host at
// all, then the connection is retried. It should start the machine and return
// once `ssh HOST true` works; a non-zero exit means it couldn't. It gets
// COVE_REMOTE_HOST in its environment. Routes stay in their own file (see
// routes in client.go).

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// wakeTimeout bounds a wake command: booting a stopped instance and waiting
// for Tailscale and sshd takes a minute or two.
const wakeTimeout = 10 * time.Minute

func hostSetting(host, key string) string {
	b, err := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".config", "cove-remote", "hosts"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) >= 3 && !strings.HasPrefix(f[0], "#") && strings.EqualFold(f[0], host) && f[1] == key {
			// the value is the rest of the line, spaces and all
			rest := strings.TrimSpace(line)
			for _, w := range f[:2] {
				rest = strings.TrimSpace(strings.TrimPrefix(rest, w))
			}
			return rest
		}
	}
	return ""
}

func wakeCommand(host string) string { return hostSetting(host, "wake") }

// runWake runs host's wake command, its output going to out.
func runWake(host string, out io.Writer) error {
	w := wakeCommand(host)
	if w == "" {
		return errors.New("no wake command for " + host)
	}
	ctx, cancel := context.WithTimeout(context.Background(), wakeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", w)
	cmd.Env = append(os.Environ(), "COVE_REMOTE_HOST="+host)
	cmd.Stdout, cmd.Stderr = out, out
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("wake %s: %w", host, err)
	}
	return nil
}

// unreachableError is ssh failing before the remote command ran (ssh's own
// exit status 255): the host is down, asleep, or not on the network.
type unreachableError struct {
	dest string
	err  error
}

func (e unreachableError) Error() string { return e.dest + " unreachable: " + e.err.Error() }
func (e unreachableError) Unwrap() error { return e.err }

// sshFailed says whether a finished ssh exited with its own connection error.
func sshFailed(err error) bool {
	var ee *exec.ExitError
	return errors.As(err, &ee) && ee.ExitCode() == 255
}
