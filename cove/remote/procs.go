package main

// Process-tree inspection straight from the kernel. The pro's lsof can hang
// for minutes and ps is slow, so the session daemon asks sysctl and
// proc_pidinfo instead.

/*
#include <libproc.h>
#include <sys/proc_info.h>
*/
import "C"

import (
	"bytes"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

// argv returns a process's command line, or its short name if that's hidden.
func argv(pid int, comm string) string {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil || len(raw) < 4 {
		return comm
	}
	argc := int(*(*int32)(unsafe.Pointer(&raw[0])))
	rest := raw[4:]
	// skip the exec path and its NUL padding
	i := bytes.IndexByte(rest, 0)
	if i < 0 {
		return comm
	}
	rest = rest[i:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	args := make([]string, 0, argc)
	for len(args) < argc && len(rest) > 0 {
		j := bytes.IndexByte(rest, 0)
		if j < 0 {
			j = len(rest)
		}
		args = append(args, string(rest[:j]))
		if j == len(rest) {
			break
		}
		rest = rest[j+1:]
	}
	return strings.Join(args, " ")
}

// scanTree mirrors Cove.gd's _scan_sessions: the agent is the first
// claude/codex/opencode below the session's shell.
func scanTree(root int) meta {
	m := meta{Agent: "shell", Pid: root}
	procs, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return m
	}
	kids := map[int][]int{}
	comm := map[int]string{}
	for _, p := range procs {
		pid, ppid := int(p.Proc.P_pid), int(p.Eproc.Ppid)
		kids[ppid] = append(kids[ppid], pid)
		comm[pid] = unix.ByteSliceToString(p.Proc.P_comm[:])
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

func cwdOf(pid int) string {
	var vpi C.struct_proc_vnodepathinfo
	n := C.proc_pidinfo(C.int(pid), C.PROC_PIDVNODEPATHINFO, 0, unsafe.Pointer(&vpi), C.int(unsafe.Sizeof(vpi)))
	if n <= 0 {
		return ""
	}
	return C.GoString(&vpi.pvi_cdir.vip_path[0])
}
