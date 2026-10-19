//go:build windows

//
//  File:      workloads_windows.go
//  Created:   2026-09-29
//  Updated:   2026-10-18
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Windows side of the workload readers: not implemented, and reported as unknown.
//  Notes:     Docker on Windows is a named pipe and processes have no /proc, so nothing is read.
//             nil means "not reported", which the viewer shows as absent — never as "no containers".
//
package main

func readContainers() *[]Container { return nil }
func containerOf(pid int) string    { return "" }
func readComfyUI() *ComfyUI         { return nil }

func describeProc(pid int, name string) (string, string) { return name, "" }
func processUser(pid int) string                         { return "" }
