//go:build linux

//
//  File:      deathsig_linux.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  A long-lived child (`lms log stream`) dies with the process that started it.
//  Notes:     A child does not follow its parent: killed with SIGKILL, or crashed, the caller never
//             runs Close, and the child would keep running under init. PR_SET_PDEATHSIG makes the
//             kernel send it SIGKILL instead. The signal is tied to the THREAD that forked it, and
//             Go only retires a thread whose goroutine locked it and exited without unlocking —
//             nothing here locks one — so in practice it fires when the process dies.
//
package collect

import (
	"os/exec"
	"syscall"
)

// dieWithParent asks the kernel to kill cmd's process when this one dies.
func dieWithParent(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}
