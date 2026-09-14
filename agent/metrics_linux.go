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
	"strconv"
	"strings"
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
