//go:build windows

//
//  File:      deathsig_windows.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Windows side of dieWithParent: nothing is set.
//  Notes:     Windows has no parent-death signal; the analogue is a job object with
//             KILL_ON_JOB_CLOSE. LM Studio's CLI is the only long-lived child, and the stream is
//             stopped by Close (the command's context) — a killed caller can leave it running.
//
package collect

import "os/exec"

// dieWithParent is a no-op on Windows (see the file notes).
func dieWithParent(*exec.Cmd) {}
