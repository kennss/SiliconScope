//go:build linux

//
//  File:      netmounts_linux.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Network filesystems mounted now — NFS, SMB, sshfs — with their size, for a caller
//             that asks (Options.NetworkMounts): a NAS share on a GPU box is where datasets and
//             outputs live. Never touches a share that isn't mounted, and never lets a server that
//             doesn't answer hold up a sample.
//  Notes:     Only entries of /proc/mounts whose type is a network filesystem are asked, so an
//             automount point that isn't mounted (an `autofs` entry alone) is never stat'd — doing
//             so would mount the share. Its size comes from statfs, which on a dead server can block
//             for good (a `hard` NFS mount) and can't be cancelled; so it runs off the sample, at
//             most once at a time per mount: a sample waits briefly for a probe it started, else
//             reports the last answer, and a probe running past netProbeStuck makes the mount
//             Unresponsive. A stuck probe holds one goroutine and its thread until the server
//             answers. Probes repeat every netProbeEvery; under an automount with an idle timeout,
//             less often than that timeout, so this reader's own visits can't keep the share
//             mounted (a path walk through autofs counts as use). On kennt-Ubuntu the NAS share is a
//             systemd automount (x-systemd.automount, timeout=0: never expires).
//
package collect

import (
	"bufio"
	"context"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	// netProbeEvery is how often a network filesystem's size is asked for.
	netProbeEvery = 60 * time.Second
	// netProbeWait is how long a sample waits for a probe it started before reporting what it has.
	netProbeWait = 300 * time.Millisecond
	// netProbeStuck is how long a probe may run before its server counts as not answering.
	netProbeStuck = 5 * time.Second
	// netDiskLimit caps the network filesystems reported, largest first, as topDisks does for local.
	netDiskLimit = 8
)

// networkFSTypes are the /proc/mounts types served by another machine.
var networkFSTypes = map[string]bool{
	"nfs": true, "nfs4": true, "cifs": true, "smb3": true, "fuse.sshfs": true,
}

// mountEntry is one line of /proc/mounts.
type mountEntry struct {
	device, mount, fsType, options string
}

// netMount is a mounted network filesystem and the idle timeout of the automount over it, if any.
type netMount struct {
	device, mount, fsType string
	idleTimeout           time.Duration // 0 = not automounted, or its automount never expires
}

// netProbe is what is known of one mount's size.
type netProbe struct {
	running  bool
	started  time.Time
	finished time.Time // when the last probe returned; zero = none has
	done     chan struct{}
	ok       bool
	total    int64
	free     int64
}

// netMountState is the probes, by mount path, behind platformState.netMu.
type netMountState struct {
	probes map[string]*netProbe
	// statfs reads a filesystem's total and free bytes (Bavail, as readDisks), and now is the
	// clock. Fields so tests can stand in a server that never answers, and time that passes.
	statfs func(path string) (total, free int64, err error)
	now    func() time.Time
}

func newNetMountState() netMountState {
	return netMountState{probes: map[string]*netProbe{}, statfs: statfsBytes, now: time.Now}
}

func statfsBytes(path string) (int64, int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	bsize := int64(st.Bsize)
	return int64(st.Blocks) * bsize, int64(st.Bavail) * bsize, nil
}

// readMountEntries parses /proc/mounts.
func readMountEntries() []mountEntry {
	f, err := os.Open("/proc/mounts")
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []mountEntry
	s := bufio.NewScanner(f)
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) < 4 {
			continue
		}
		out = append(out, mountEntry{fields[0], unescapeMount(fields[1]), fields[2], fields[3]})
	}
	return out
}

// networkMounts picks the mounted network filesystems, one per mount path, each with the idle
// timeout of the closest automount at or above it. Pure, for testing.
func networkMounts(entries []mountEntry) []netMount {
	automounts := map[string]time.Duration{} // autofs mount path -> its idle timeout
	for _, e := range entries {
		if e.fsType == "autofs" {
			automounts[e.mount] = autofsTimeout(e.options)
		}
	}
	seen := map[string]bool{}
	var out []netMount
	for _, e := range entries {
		if !networkFSTypes[e.fsType] || seen[e.mount] {
			continue
		}
		seen[e.mount] = true
		m := netMount{device: e.device, mount: e.mount, fsType: e.fsType}
		best := -1
		for path, timeout := range automounts {
			if (e.mount == path || strings.HasPrefix(e.mount, strings.TrimSuffix(path, "/")+"/")) && len(path) > best {
				best, m.idleTimeout = len(path), timeout
			}
		}
		out = append(out, m)
	}
	return out
}

// autofsTimeout reads an autofs entry's "timeout=N" (seconds); 0 when absent or 0.
func autofsTimeout(options string) time.Duration {
	for _, o := range strings.Split(options, ",") {
		if v, ok := strings.CutPrefix(o, "timeout="); ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				return time.Duration(n) * time.Second
			}
		}
	}
	return 0
}

// probeInterval is how often m is asked: netProbeEvery, or past its automount's idle timeout.
func probeInterval(m netMount) time.Duration {
	if m.idleTimeout > 0 {
		return m.idleTimeout + netProbeEvery
	}
	return netProbeEvery
}

// readNetworkDisks reports the mounted network filesystems, when Options.NetworkMounts asks.
func (c *Collector) readNetworkDisks(ctx context.Context) []Disk {
	if !c.opts.NetworkMounts {
		return nil
	}
	return c.platform.networkDisks(ctx, networkMounts(readMountEntries()))
}

// networkDisks probes each mount as due and reports what is known. A mount not answered yet (its
// first probe still within netProbeStuck) is left out rather than shown empty.
func (p *platformState) networkDisks(ctx context.Context, mounts []netMount) []Disk {
	now := p.net.now
	var waits []chan struct{}
	p.netMu.Lock()
	present := map[string]bool{}
	for _, m := range mounts {
		present[m.mount] = true
		pr := p.net.probes[m.mount]
		if pr == nil {
			pr = &netProbe{}
			p.net.probes[m.mount] = pr
		}
		if pr.running || (!pr.finished.IsZero() && now().Sub(pr.finished) < probeInterval(m)) {
			continue
		}
		pr.running, pr.started, pr.done = true, now(), make(chan struct{})
		waits = append(waits, pr.done)
		go p.probe(m.mount, pr)
	}
	for path, pr := range p.net.probes {
		if !present[path] && !pr.running {
			delete(p.net.probes, path) // unmounted; one still probing is removed on a later sample
		}
	}
	p.netMu.Unlock()

	if len(waits) > 0 {
		t := time.NewTimer(netProbeWait)
		defer t.Stop()
	wait:
		for _, w := range waits {
			select {
			case <-w:
			case <-t.C:
				break wait
			case <-ctx.Done():
				break wait
			}
		}
	}

	p.netMu.Lock()
	defer p.netMu.Unlock()
	disks := []Disk{}
	for _, m := range mounts {
		pr := p.net.probes[m.mount]
		d := Disk{Mount: m.mount, FSType: m.fsType, Network: true}
		switch {
		case pr.running && now().Sub(pr.started) >= netProbeStuck:
			d.Unresponsive = true
		case pr.finished.IsZero():
			continue // first answer still coming
		case pr.ok:
			d.TotalBytes, d.FreeBytes = pr.total, pr.free
		default:
			d.Unresponsive = true // the server answered with an error (a soft mount timing out)
		}
		disks = append(disks, d)
	}
	sort.SliceStable(disks, func(i, j int) bool { return disks[i].TotalBytes > disks[j].TotalBytes })
	if len(disks) > netDiskLimit {
		disks = disks[:netDiskLimit]
	}
	return disks
}

// probe asks one mount its size, off the sample, and records the answer.
func (p *platformState) probe(path string, pr *netProbe) {
	total, free, err := p.net.statfs(path)
	p.netMu.Lock()
	pr.running, pr.finished = false, p.net.now()
	pr.ok, pr.total, pr.free = err == nil, total, free
	close(pr.done)
	p.netMu.Unlock()
}
