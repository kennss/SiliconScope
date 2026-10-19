//go:build linux || windows

//
//  File:      gpu_procs.go
//  Created:   2026-10-18
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Which GPU each compute process is on. `nvidia-smi --query-compute-apps` lists one row
//             per process per GPU, tagged with that GPU's UUID; the rows are matched to the GPUs of
//             `--query-gpu` by the same UUID, so a box with several GPUs shows each process under
//             the GPU it actually uses.
//  Notes:     The parsing and matching are pure functions (tested with a two-GPU fixture); the
//             sampler in collector.go runs nvidia-smi and fills in each process's details.
//             A process on two GPUs is two rows and is listed under both, each with the memory it
//             holds on that GPU. On a single-GPU box every row belongs to that GPU whatever its
//             UUID says. With several GPUs, a row whose UUID matches none of them is left out
//             rather than credited to a GPU it may not be on.
//
package collect

import "strings"

// computeAppsQuery is the field list for `nvidia-smi --query-compute-apps`, in parse order.
const computeAppsQuery = "gpu_uuid,pid,process_name,used_memory"

// computeApp is one row of `nvidia-smi --query-compute-apps`: one process's memory on ONE GPU.
type computeApp struct {
	GPUUUID   string
	PID       int
	Name      string // argv[0] as nvidia-smi reports it
	VRAMBytes int64
}

// parseComputeApps reads the CSV rows of computeAppsQuery. The process name sits between the
// fixed leading fields and the trailing memory, so a name containing a comma is joined back
// together instead of shifting the memory column.
func parseComputeApps(out string) []computeApp {
	apps := []computeApp{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		f := splitCSV(line)
		if len(f) < 4 {
			continue
		}
		apps = append(apps, computeApp{
			GPUUUID:   f[0],
			PID:       atoi(f[1]),
			Name:      strings.Join(f[2:len(f)-1], ","),
			VRAMBytes: mibToBytes(f[len(f)-1]),
		})
	}
	return apps
}

// attachProcs puts each compute app under its GPU. describe turns a row into the GPUProc sent on
// the wire (path, script, container, user); it is called once per row that is kept.
func attachProcs(gpus []GPU, apps []computeApp, describe func(computeApp) GPUProc) {
	if len(gpus) == 0 {
		return
	}
	if len(gpus) == 1 {
		for _, a := range apps {
			gpus[0].Processes = append(gpus[0].Processes, describe(a))
		}
		return
	}
	byUUID := make(map[string]int, len(gpus))
	for i, g := range gpus {
		if g.UUID != "" {
			byUUID[g.UUID] = i
		}
	}
	for _, a := range apps {
		if i, ok := byUUID[a.GPUUUID]; ok {
			gpus[i].Processes = append(gpus[i].Processes, describe(a))
		}
	}
}
