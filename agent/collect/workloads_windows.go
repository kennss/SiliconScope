//go:build windows

//
//  File:      workloads_windows.go
//  Created:   2026-09-29
//  Updated:   2026-10-21
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Windows side of the workload readers: not implemented, and reported as unknown.
//  Notes:     Docker on Windows is a named pipe and processes have no /proc, so nothing is read.
//             nil means "not reported", which the viewer shows as absent — never as "no containers".
//
package collect

import "context"

// platformState is empty on Windows: these readers remember nothing.
type platformState struct{}

func newPlatformState(Options) *platformState { return &platformState{} }

func (c *Collector) readContainers(context.Context) *[]Container { return nil }
func (c *Collector) containerOf(pid int) string                  { return "" }
func (c *Collector) readComfyUI(context.Context) *ComfyUI         { return nil }
func (c *Collector) processUser(pid int) string                  { return "" }
func (c *Collector) readNetworkDisks(context.Context) []Disk      { return nil }

func describeProc(pid int, name string) (string, string) { return name, "" }

func describeRunningProc(pid int, comm string) (string, string) { return comm, "" }
