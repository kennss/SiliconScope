//go:build linux

//
//  File:      netmounts_linux_test.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for reporting network filesystems: which /proc/mounts entries count, the
//             automount timeout over each, and the probes — a slow or dead server never holds a
//             sample, is asked once at a time, and reads as unresponsive rather than empty.
//  Notes:     The autofs + cifs pair is kennt-Ubuntu's NAS share (a systemd automount, timeout=0);
//             the indirect NFS map is a fixture. statfs and the clock are stood in, so no share is
//             touched. Run on Linux (`GOOS=linux go test -c`).
//
package collect

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

var boxMounts = []mountEntry{
	{"/dev/nvme0n1p2", "/", "ext4", "rw,relatime"},
	{"systemd-1", "/proc/sys/fs/binfmt_misc", "autofs", "rw,relatime,fd=32,pgrp=1,timeout=0,direct"},
	{"systemd-1", "/mnt/nas-home", "autofs", "rw,relatime,fd=105,pgrp=1,timeout=0,minproto=5,maxproto=5,direct"},
	{"//192.168.68.105/home", "/mnt/nas-home", "cifs", "rw,relatime,vers=3.0,soft"},
	{"auto.data", "/data", "autofs", "rw,relatime,fd=7,pgrp=900,timeout=300,indirect"},
	{"nas:/export/datasets", "/data/datasets", "nfs4", "rw,relatime,hard"},
	{"tmpfs", "/run", "tmpfs", "rw"},
}

func TestNetworkMountsPicksMountedSharesOnly(t *testing.T) {
	got := networkMounts(boxMounts)
	if len(got) != 2 {
		t.Fatalf("got %d network mounts, want the cifs and nfs4 ones: %+v", len(got), got)
	}
	if got[0].mount != "/mnt/nas-home" || got[0].fsType != "cifs" || got[0].idleTimeout != 0 {
		t.Fatalf("the NAS share = %+v, want cifs under a never-expiring automount", got[0])
	}
	if got[1].mount != "/data/datasets" || got[1].idleTimeout != 300*time.Second {
		t.Fatalf("the indirect NFS share = %+v, want its map's 300 s timeout", got[1])
	}
	if probeInterval(got[1]) <= 300*time.Second {
		t.Fatalf("a share under a 300 s automount is probed every %v; must be past the timeout", probeInterval(got[1]))
	}
	// An automount alone — nothing mounted under it — is not a filesystem to ask.
	if len(networkMounts(boxMounts[:3])) != 0 {
		t.Fatal("an unmounted automount point must not be reported (stat'ing it would mount the share)")
	}
}

// fakeServer stands in statfs: it answers with the given result, or never until released.
type fakeServer struct {
	mu      sync.Mutex
	calls   int
	err     error
	block   chan struct{} // nil = answer at once
	clock   time.Time
	release sync.Once
}

func (f *fakeServer) statfs(string) (int64, int64, error) {
	f.mu.Lock()
	f.calls++
	block, err := f.block, f.err
	f.mu.Unlock()
	if block != nil {
		<-block
	}
	return 4 << 40, 1 << 40, err
}

func (f *fakeServer) now() time.Time { f.mu.Lock(); defer f.mu.Unlock(); return f.clock }
func (f *fakeServer) advance(d time.Duration) {
	f.mu.Lock()
	f.clock = f.clock.Add(d)
	f.mu.Unlock()
}
func (f *fakeServer) callCount() int { f.mu.Lock(); defer f.mu.Unlock(); return f.calls }

func newFake(t *testing.T, blocking bool, err error) (*platformState, *fakeServer) {
	f := &fakeServer{err: err, clock: time.Unix(1_800_000_000, 0)}
	if blocking {
		f.block = make(chan struct{})
		t.Cleanup(func() { f.release.Do(func() { close(f.block) }) })
	}
	p := &platformState{net: newNetMountState()}
	p.net.statfs, p.net.now = f.statfs, f.now
	return p, f
}

var nas = []netMount{{device: "//192.168.68.105/home", mount: "/mnt/nas-home", fsType: "cifs"}}

func TestAnsweringShareIsReportedAndNotAskedAgainTooSoon(t *testing.T) {
	p, f := newFake(t, false, nil)
	d := p.networkDisks(context.Background(), nas)
	if len(d) != 1 || !d[0].Network || d[0].Unresponsive || d[0].TotalBytes != 4<<40 || d[0].FreeBytes != 1<<40 {
		t.Fatalf("got %+v, want the share with its size", d)
	}
	f.advance(30 * time.Second)
	p.networkDisks(context.Background(), nas)
	if f.callCount() != 1 {
		t.Fatalf("asked %d times within a minute, want 1", f.callCount())
	}
	f.advance(31 * time.Second)
	p.networkDisks(context.Background(), nas)
	if f.callCount() != 2 {
		t.Fatalf("asked %d times after a minute, want 2", f.callCount())
	}
}

func TestDeadServerNeverHoldsASampleAndIsAskedOnce(t *testing.T) {
	p, f := newFake(t, true, nil)
	start := time.Now()
	if d := p.networkDisks(context.Background(), nas); len(d) != 0 {
		t.Fatalf("a share that hasn't answered yet must be left out, got %+v", d)
	}
	if waited := time.Since(start); waited > 2*netProbeWait {
		t.Fatalf("the sample waited %v for a dead server", waited)
	}
	f.advance(netProbeStuck)
	d := p.networkDisks(context.Background(), nas)
	if len(d) != 1 || !d[0].Unresponsive || d[0].TotalBytes != 0 {
		t.Fatalf("got %+v, want the share unresponsive with unknown size", d)
	}
	f.advance(10 * time.Minute)
	p.networkDisks(context.Background(), nas)
	if f.callCount() != 1 {
		t.Fatalf("a stuck probe was joined by %d more", f.callCount()-1)
	}
}

func TestServerErrorIsUnresponsive(t *testing.T) {
	p, _ := newFake(t, false, errors.New("host is down"))
	d := p.networkDisks(context.Background(), nas)
	if len(d) != 1 || !d[0].Unresponsive {
		t.Fatalf("got %+v, want unresponsive", d)
	}
}

func TestOffByDefault(t *testing.T) {
	c, _ := New(Options{})
	if d := c.readNetworkDisks(context.Background()); d != nil {
		t.Fatalf("network mounts were read without being asked for: %+v", d)
	}
}
