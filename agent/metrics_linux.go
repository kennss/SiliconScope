//go:build linux

//
//  File:      metrics_linux.go
//  Created:   2026-09-11
//  Updated:   2026-09-11
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Linux CPU, memory, and machine identity readers for the fleet agent.
//  Notes:     CPU usage is a 200ms delta of /proc/stat. Memory comes from
//             /proc/meminfo in kB converted to bytes. Identity comes from /etc.
//
package main

import (
	"bufio"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const machineKind = "linux"

func hostname() string { return firstLine("/etc/hostname") }

// MARK: - CPU

func readCPU() CPU {
	c := CPU{Cores: runtime.NumCPU(), LoadAvg1: loadAvg1(), Model: cpuModel()}
	t1, i1 := procStatTotals()
	time.Sleep(200 * time.Millisecond)
	t2, i2 := procStatTotals()
	if dt := t2 - t1; dt > 0 {
		busy := (t2 - t1) - (i2 - i1) // total delta minus idle delta
		c.UsagePercent = round1(100 * float64(busy) / float64(dt))
	}
	return c
}

func procStatTotals() (total, idle uint64) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := s.Text()
		if strings.HasPrefix(line, "cpu ") {
			for i, fld := range strings.Fields(line)[1:] {
				v, _ := strconv.ParseUint(fld, 10, 64)
				total += v
				if i == 3 || i == 4 { // idle + iowait
					idle += v
				}
			}
			return
		}
	}
	return
}

// cpuModel returns the "model name" line from /proc/cpuinfo, or "" when it is absent. Empty is a
// real answer here: the viewer shows no name rather than inventing one.
func cpuModel() string {
	b, err := os.ReadFile("/proc/cpuinfo")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "model name", "Model": // x86 and arm64 spell it differently
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func loadAvg1() float64 {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0
	}
	if f := strings.Fields(string(b)); len(f) > 0 {
		v, _ := strconv.ParseFloat(f[0], 64)
		return v
	}
	return 0
}

// MARK: - Memory

func readMemory() Memory {
	var m Memory
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return m
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		parts := strings.Fields(s.Text())
		if len(parts) < 2 {
			continue
		}
		kb, _ := strconv.ParseInt(parts[1], 10, 64)
		switch parts[0] {
		case "MemTotal:":
			m.TotalBytes = kb * 1024
		case "MemAvailable:":
			m.AvailableBytes = kb * 1024
		}
	}
	m.UsedBytes = m.TotalBytes - m.AvailableBytes
	return m
}

// MARK: - small helpers

func firstLine(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		h, _ := os.Hostname()
		return h
	}
	return strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0])
}

func machineID() string {
	if id := strings.TrimSpace(readFile("/etc/machine-id")); id != "" {
		return id
	}
	h, _ := os.Hostname()
	return h
}

func osPrettyName() string {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return runtime.GOOS
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if v, ok := strings.CutPrefix(s.Text(), "PRETTY_NAME="); ok {
			return strings.Trim(v, `"`)
		}
	}
	return runtime.GOOS
}

func readFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

// topDisks caps the list at the 8 largest by capacity (largest first) so a host with many mounts
// can't bloat the payload, and guarantees a non-nil slice (never `null`, #33).
func topDisks(disks []Disk) []Disk {
	sort.Slice(disks, func(i, j int) bool { return disks[i].TotalBytes > disks[j].TotalBytes })
	if len(disks) > 8 {
		disks = disks[:8]
	}
	if disks == nil {
		return []Disk{}
	}
	return disks
}

// localFSTypes are the real on-disk filesystems worth reporting. Everything else in /proc/mounts is
// pseudo/virtual (proc, sysfs, tmpfs, devtmpfs, squashfs, cgroup*, fuse*, devpts): it either reports
// RAM-backed or zero capacity, or re-exposes storage already counted elsewhere.
var localFSTypes = map[string]bool{
	"ext4": true, "ext3": true, "xfs": true, "btrfs": true, "zfs": true, "f2fs": true,
}

// readDisks parses /proc/mounts, keeps real local filesystems, dedupes by backing device so bind
// mounts don't double-count, and statfs's each. Free uses Bavail*Bsize, NOT Bfree*Bsize: Bfree
// includes root-reserved blocks an unprivileged process can't use, so it overstates free space.
func readDisks() []Disk {
	f, err := os.Open("/proc/mounts")
	if err != nil {
		return []Disk{} // never nil — a nil slice marshals to `null` and breaks the viewer (#33)
	}
	defer f.Close()

	byDevice := map[string]int{} // backing device -> index into disks
	disks := []Disk{}
	s := bufio.NewScanner(f)
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) < 3 {
			continue
		}
		device, mount, fsType := fields[0], unescapeMount(fields[1]), fields[2]
		// A container's root is an overlay, and it is that machine's real disk from the inside, so
		// accept overlay at "/" even though it is otherwise a stacking filesystem worth skipping.
		if !localFSTypes[fsType] && !(fsType == "overlay" && mount == "/") {
			continue
		}
		// Bind mounts of a single file (a container's /etc/hosts) carry the whole backing device's
		// statfs numbers while naming a file. Only a directory is a filesystem.
		if fi, err := os.Stat(mount); err != nil || !fi.IsDir() {
			continue
		}
		var st syscall.Statfs_t
		if syscall.Statfs(mount, &st) != nil {
			continue
		}
		bsize := int64(st.Bsize)
		d := Disk{
			Mount:      mount,
			TotalBytes: int64(st.Blocks) * bsize,
			FreeBytes:  int64(st.Bavail) * bsize,
			FSType:     fsType,
		}
		// One device appears once per bind mount, so keep the shortest mount path: that is the
		// filesystem's own root rather than a bind of some file inside it.
		if i, ok := byDevice[device]; ok {
			if len(mount) < len(disks[i].Mount) {
				disks[i] = d
			}
			continue
		}
		byDevice[device] = len(disks)
		disks = append(disks, d)
	}
	return topDisks(disks)
}

// unescapeMount decodes the octal escapes /proc/mounts uses for space (\040), tab (\011), newline
// (\012), and backslash (\134) in a mount path, so a path with a space reads correctly.
func unescapeMount(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	return strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(s)
}
