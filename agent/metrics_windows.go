//go:build windows

//
//  File:      metrics_windows.go
//  Created:   2026-09-11
//  Updated:   2026-09-11
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Windows CPU, memory, and machine identity readers for the fleet agent.
//  Notes:     Uses kernel32 system times and memory status plus registry identity.
//             CPU usage is a 200ms delta. Windows APIs are called without CGO.
//
package main

import (
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const machineKind = "windows"

var (
	kernel32                 = windows.NewLazySystemDLL("kernel32.dll")
	procGetSystemTimes       = kernel32.NewProc("GetSystemTimes")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
)

func hostname() string {
	h, _ := os.Hostname()
	return h
}

// MARK: - CPU

func readCPU() CPU {
	c := CPU{Cores: runtime.NumCPU(), LoadAvg1: loadAvg1()}
	i1, t1, ok1 := systemTimes()
	time.Sleep(200 * time.Millisecond)
	i2, t2, ok2 := systemTimes()
	if totalDelta := t2 - t1; ok1 && ok2 && totalDelta > 0 {
		busyDelta := totalDelta - (i2 - i1)
		c.UsagePercent = round1(100 * float64(busyDelta) / float64(totalDelta))
	}
	return c
}

func systemTimes() (idle, total uint64, ok bool) {
	var idleTime, kernelTime, userTime windows.Filetime
	r, _, _ := procGetSystemTimes.Call(
		uintptr(unsafe.Pointer(&idleTime)),
		uintptr(unsafe.Pointer(&kernelTime)),
		uintptr(unsafe.Pointer(&userTime)),
	)
	if r == 0 {
		return 0, 0, false
	}
	idle = uint64(idleTime.HighDateTime)<<32 | uint64(idleTime.LowDateTime)
	kernel := uint64(kernelTime.HighDateTime)<<32 | uint64(kernelTime.LowDateTime)
	user := uint64(userTime.HighDateTime)<<32 | uint64(userTime.LowDateTime)
	return idle, kernel + user, true
}

func loadAvg1() float64 {
	// Windows has no load average. A measured zero differs from a missing measurement,
	// so keep the field's neutral zero rather than inventing a value.
	return 0
}

// MARK: - Memory

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func readMemory() Memory {
	var s memoryStatusEx
	s.Length = uint32(unsafe.Sizeof(s))
	r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&s)))
	if r == 0 {
		return Memory{}
	}
	m := Memory{TotalBytes: int64(s.TotalPhys), AvailableBytes: int64(s.AvailPhys)}
	m.UsedBytes = m.TotalBytes - m.AvailableBytes
	return m
}

// MARK: - small helpers

func machineID() string {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Cryptography`, registry.QUERY_VALUE)
	if err == nil {
		defer k.Close()
		if id, _, err := k.GetStringValue("MachineGuid"); err == nil {
			if id = strings.TrimSpace(id); id != "" {
				return id
			}
		}
	}
	h, _ := os.Hostname()
	return h
}

func osPrettyName() string {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE)
	if err != nil {
		return runtime.GOOS
	}
	defer k.Close()
	product, _, err := k.GetStringValue("ProductName")
	product = strings.TrimSpace(product)
	if err != nil || product == "" {
		return runtime.GOOS
	}
	buildString, _, err := k.GetStringValue("CurrentBuild")
	if err == nil {
		if build, err := strconv.Atoi(strings.TrimSpace(buildString)); err == nil && build >= 22000 && strings.Contains(product, "Windows 10") {
			// Microsoft froze ProductName at Windows 10 on Windows 11 hosts. Build 22000
			// is the Windows 11 threshold, keeping os honest without shelling out to WMI.
			product = strings.ReplaceAll(product, "Windows 10", "Windows 11")
		}
	}
	return product
}
