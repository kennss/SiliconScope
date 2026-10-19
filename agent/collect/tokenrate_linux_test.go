//go:build linux

//
//  File:      tokenrate_linux_test.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The LM Studio stream's child ends with the Collector: Close stops `lms log stream`
//             and waits for it, so a caller that closes never leaves an `lms` running.
//  Notes:     A fake `lms` on PATH records its pid and sleeps. A child does not die with its
//             parent by itself (see deathsig_linux.go for the kill -9 case). Run on Linux
//             (`GOOS=linux go test -c`).
//
package collect

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCloseStopsTheLMStudioChild(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := "#!/bin/sh\necho $$ > " + pidFile + "\nexec sleep 600\n"
	if err := os.WriteFile(filepath.Join(dir, "lms"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	c, err := New(Options{WatchLMStudio: true})
	if err != nil {
		t.Fatal(err)
	}
	var pid int
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if b, err := os.ReadFile(pidFile); err == nil {
			if pid, err = strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				break
			}
		}
	}
	if pid == 0 {
		c.Close()
		t.Fatal("the fake lms never started")
	}

	done := make(chan struct{})
	go func() { c.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not return")
	}
	if err := syscall.Kill(pid, 0); err == nil {
		t.Fatalf("lms (pid %d) still running after Close", pid)
	}
}
