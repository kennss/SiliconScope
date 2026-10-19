//go:build !linux && !windows

//
//  File:      unsupported.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The package on a platform it doesn't collect on (a Mac, BSD): it compiles, so a
//             caller's code and tests build there, and New says it can't collect.
//  Notes:     A Collector can't be made here, so Collect and Close are never reached on one; they
//             exist for the caller's code to compile against.
//
package collect

import "context"

// Collector reads this machine's metrics. On this platform there is none to make.
type Collector struct{}

// New returns ErrUnsupported: this platform has no readers.
func New(Options) (*Collector, error) { return nil, ErrUnsupported }

// Collect returns an empty sample. Unreachable: New never returns a Collector here.
func (c *Collector) Collect(context.Context) MachineMetrics {
	return MachineMetrics{GPUs: []GPU{}, Disks: []Disk{}}
}

// Close does nothing.
func (c *Collector) Close() {}
