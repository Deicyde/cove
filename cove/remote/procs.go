package main

import "strings"

// scanTree mirrors Cove.gd's _scan_sessions: the agent is the first
// claude/codex/opencode below the session's shell. The process table and
// command lines come from the kernel (procs_darwin.go, procs_linux.go).
func scanTree(root int) meta {
	m := meta{Agent: "shell", Pid: root}
	kids, comm, ok := procTable()
	if !ok {
		return m
	}
	queue := append([]int(nil), kids[root]...)
	agentPid := -1
	for guard := 0; len(queue) > 0 && guard < 256; guard++ {
		cur := queue[0]
		queue = queue[1:]
		lc := strings.ToLower(argv(cur, comm[cur]))
		switch {
		case strings.Contains(lc, "opencode"):
			m.Agent, agentPid = "opencode", cur
		case strings.Contains(lc, "codex") && m.Agent == "shell":
			m.Agent, agentPid = "codex", cur
		case strings.Contains(lc, "claude") && m.Agent == "shell":
			m.Agent, agentPid = "claude", cur
		}
		queue = append(queue, kids[cur]...)
	}
	if agentPid != -1 {
		m.Pid = agentPid
	}
	m.Busy = m.Agent != "shell"
	// The root is the login shell (a `-c cmd; exec shell` wrapper execs into
	// one), so a bare prompt is "no children".
	m.Idle = m.Agent == "shell" && len(kids[root]) == 0
	return m
}
