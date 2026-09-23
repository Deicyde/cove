---
name: cove-remote
description: Run a live terminal, shell or Claude agent on another machine (the MacBook Pro, kirans-macbook-pro, or a Linux box such as aws-dev) as a Cove termling that feels local. It has native kitty scrollback, CLI apps work, typing is predicted locally, it survives dropped links and this laptop sleeping, and it reattaches. Use when asked to run something on the pro/MBP or a Linux devbox, offload a build or agent, work "remotely" in a termling, or to list, reattach or kill remote sessions. Replaces the tmux route in mbp-offload.
---
# cove-remote: termlings that run on another machine

`cove/bin/cove-remote` (Go source in `cove/remote/`) works like Eternal
Terminal plus mosh, built for the Cove:

- **A byte pipe, not tmux.** The remote program's output streams straight into
  the local kitty, so scrollback, mouse wheel, selection, colours, kitty
  graphics and TUIs behave exactly as they do locally. Scrolling is local and
  instant.
- **Resumable.** A daemon on the remote (`~/.cache/cove-remote/<session>/`)
  owns the pty and keeps 8 MB of output with byte offsets. When the link drops
  (sleep, wifi change, Tailscale relay), `attach` reconnects on its own. It
  notices a wake from sleep by the wall clock jumping and reconnects about 1s
  later, and it drops a link that's been silent for 7s. It replays exactly the bytes it missed and resends unacked keystrokes.
  Nothing is duplicated and there are no gaps. While it's down, the nameplate
  reads `@ host, reconnecting` and the cursor shows `⟳ host`.
- **Predicted typing.** Keystrokes appear at once, underlined, through kitty's
  IME overlay (our kitty's OSC 7766). They're replaced when the real echo
  arrives. A wrong guess (a password prompt, vim normal mode) disappears and
  never lands in the screen or scrollback. The overlay is only shown after
  three confirmed echoes and when the RTT is over 20 ms (`--predict on` always
  shows it, `off` disables it). It needs the rebuilt kitty. Older kitties answer
  the DECRQM probe with 0, and prediction then stays off.
- **Cove-integrated.** The remote shell gets `COVE=1`, this termling's
  `COVE_SESSION` and a `KITTY_COVE_DIR` that the daemon mirrors to the local
  `/tmp/cove`. So a remote Claude's Stop/Notification hooks badge the termling,
  and its cove MCP `status` / `rename` / `add_note` / `report` / `whoami` /
  `board` work. `spawn` / `send` / `read` from a remote agent don't work (they
  drive the local kitty). The local Cove reads `/tmp/cove/remote/<session>.json`
  for the real agent/cwd and shows `name @ host` on the nameplate.
- **Transport.** `ssh -tt host cove-remote bridge` (the `-tt` makes sshd set
  TCP_NODELAY, so keystrokes aren't Nagle-delayed). It uses the usual key auth
  and needs no new ports. The remote binary is the same path: via Syncthing
  on the pro, installed by `cove/remote/install-linux.sh HOST` on Linux.
- **Linux remotes.** The server side (`bridge`, `serve`, `ls`, `kill`) also
  runs on Linux: a static `GOOS=linux` build that reads `/proc` instead of
  sysctl/proc_pidinfo. The Mac is always the client. `install-linux.sh`
  builds `cove/bin/cove-remote-linux-<arch>` for the host's arch, installs it
  at this checkout's `bin/cove-remote` path there (the box needs that path to
  resolve, e.g. a `/Users/kirancodes` symlink) and puts kitty's terminfo in
  `~/.terminfo`. Rerun it after changing the Go source.

## Starting one

From an agent, use the cove MCP (preferred; it handles claude's trust dialog
and auto mode like a local child):

```
spawn(name: "build @ pro", host: "kirans-macbook-pro",
      cwd: "/Users/kirancodes/Documents/code/<repo>",
      command: "claude", prompt: "...")
```

By hand, or from any termling:

```
cove/bin/cove-remote attach kirans-macbook-pro                 # a login shell there
cove/bin/cove-remote attach --cwd ~/code/x kirans-macbook-pro -- claude
cove/bin/cove-remote attach kirans-macbook-pro -- 'make -j8 2>&1 | tee build.log'
```

- The cwd defaults to the same path as here, falling back to `~` if it doesn't
  exist there. Copy or push the work first (rsync to the same absolute path,
  or git; see mbp-offload §2 for the rsync gotchas).
- A command runs in an interactive login shell, then drops to a shell when it
  ends, so the output stays.
- The session name defaults to this termling's `$COVE_SESSION`. Use
  `--session NAME` (names from `ls`) to reattach a session from another
  termling. A fresh viewer gets the last 1 MB of output replayed
  (`--replay BYTES`), then full-screen apps are nudged to redraw.
- On a Mac the remote holds a `caffeinate -ims` for the session's life, so
  the pro stays awake (set `COVE_REMOTE_NO_CAFFEINATE=1` in the remote env to
  skip). Linux gets nothing: the devbox's idle-stop counts live sessions.

## Lifetimes

- Closing the termling only **detaches**. The remote session keeps running
  (that's the point: laptop lid closed, job continues). MCP `kill` on a child
  spawned with `host` also ends the remote session.
- `exit` in the remote shell ends the session and closes the termling.
- All keys go to the remote (Ctrl+C included). To leave without ending it,
  close the termling.

```
cove/bin/cove-remote ls kirans-macbook-pro          # session, state, agent, cwd, cmd
cove/bin/cove-remote kill kirans-macbook-pro SESSION
```

## Routes (LAN first)

Tailscale can end up relaying through a far-off DERP server (seen: every
byte via Miami, 4 s RTT, 40% loss) even when both Macs sit on the same LAN.
`~/.config/cove-remote/routes` lists ssh destinations to try, best first; it's
re-read on every reconnect, and all but the last get a 4 s connect timeout:

```
kirans-macbook-pro  Kirans-MacBook-Pro.local  kirans-macbook-pro
```

ssh runs with `AddressFamily=inet` (a `.local` name's IPv6 link-local address
can hang for 30 s). The meta file's `route` says which one is in use.

## Waking a stopped host

`~/.config/cove-remote/hosts` holds per-host settings, one per line, re-read
on every use. `wake` is a shell command that `attach`, `ls` and `kill` run
when ssh can't reach the host at all (ssh's exit 255), then retry:

```
# host   setting  value
aws-dev  wake     ~/Documents/code/aws-devbox/bin/aws-dev-wake
```

It should start the machine and return once `ssh HOST true` works (non-zero
means it couldn't); it gets `COVE_REMOTE_HOST`, has 10 minutes, and its
output goes to the client log (stderr for `ls`/`kill`). `attach` runs it at
most once a minute, shows `[cove-remote: waking HOST]` on first connect and
`⟳ waking HOST` at the cursor, and puts `"waking": true` in the meta file.
Routes stay in the `routes` file.

## Upgrading live clients

`kill -USR2 <client_pid>` (pids in `/tmp/cove/remote/*.json`) re-execs the
rebuilt binary in place, resuming at the exact output byte. Clients older than
this feature die on USR2 instead: `kill -HUP` them and rerun `attach` in the
termling.

## Debugging

- Client log: `$TMPDIR/cove-remote/<session>.log` (connects, drops, whether
  kitty has the prediction overlay). Daemon log:
  `~/.cache/cove-remote/<session>/log` on the remote.
- `ssh kirans-macbook-pro` must work non-interactively (`BatchMode=yes`).
  Off-LAN it goes over Tailscale. See the connect-to-pro memory.
- The remote binary must match: after `cd cove/remote && go build -o
  ../bin/cove-remote .`, wait for Syncthing (`shasum` both sides) before
  testing. Running daemons keep their old code until their session ends.
- Nameplate/agent detection needs the current `Cove.gd` (`cove/reload.sh`).
  Prediction needs the rebuilt kitty (`cove/reload-kitty.sh`).
- Remote `lsof` can hang on the pro, so the daemon uses sysctl and
  proc_pidinfo. Don't reintroduce subprocess scans.
