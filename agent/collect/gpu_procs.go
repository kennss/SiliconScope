//go:build linux || windows

//
//  File:      gpu_procs.go
//  Created:   2026-10-18
//  Updated:   2026-10-21
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Which GPU each process is on, and how busy it keeps it. `nvidia-smi
//             --query-compute-apps` lists one row per compute process per GPU, tagged with that
//             GPU's UUID; the rows are matched to the GPUs of `--query-gpu` by the same UUID, so a
//             box with several GPUs shows each process under the GPU it actually uses. `nvidia-smi
//             pmon` then adds each process's share of the card (SM and memory-controller %), its
//             kind, and the graphics processes compute-apps leaves out (a display server, a desktop
//             shell).
//  Notes:     The parsing and matching are pure functions (tested with real driver-595 output and
//             a two-GPU fixture); the sampler in collector.go runs nvidia-smi and fills in each
//             process's details. A process on two GPUs is two rows and is listed under both, each
//             with the memory it holds on that GPU. On a single-GPU box every row belongs to that
//             GPU whatever its UUID says. With several GPUs, a row whose UUID matches none of them
//             is left out rather than credited to a GPU it may not be on.
//             pmon names GPUs by index, not UUID, and watches at most four at a time, so a box with
//             more is asked in groups of four (pmonGroups). Its columns differ across drivers (jpg,
//             ofa and ccpm came later), so they are found by the header line. "-" in its sm and mem
//             columns means the process did no work in the window, and reads as 0 only where the
//             driver is evidently attributing the card's use (pmonAttributes); otherwise it stays
//             absent rather than claiming an idle process on a busy card.
//
package collect

import (
	"strconv"
	"strings"
)

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

// MARK: - Per-process use (nvidia-smi pmon)

// pmonMaxGPUs is how many GPUs one `nvidia-smi pmon` watches; it ignores the rest.
const pmonMaxGPUs = 4

// pmonRow is one row of `nvidia-smi pmon -c 1 -s um`: one process on one GPU, named by the GPU's
// index.
type pmonRow struct {
	GPUIndex  int
	PID       int
	Kind      string   // "compute", "graphics" or "compute+graphics"; "" for a type pmon didn't say
	SM        *float64 // nil where pmon printed "-": the process did no work in the window
	Mem       *float64
	VRAMBytes int64  // the fb column (MiB); 0 when the driver prints none
	Command   string // the kernel's short name for it (comm, 15 characters at most)
}

// pmonKinds maps pmon's type column to GPUProc.Kind.
var pmonKinds = map[string]string{"C": "compute", "G": "graphics", "C+G": "compute+graphics"}

// pmonGroups splits a box's GPU indices into the groups of at most four that one pmon run can
// watch. Pure, for testing.
func pmonGroups(indices []int) [][]int {
	groups := [][]int{}
	for len(indices) > pmonMaxGPUs {
		groups = append(groups, indices[:pmonMaxGPUs])
		indices = indices[pmonMaxGPUs:]
	}
	if len(indices) > 0 {
		groups = append(groups, indices)
	}
	return groups
}

// parsePmon reads pmon's table. The header line that names the columns ("# gpu pid type sm …")
// says where each one is; the units line under it is skipped, and so is the row pmon prints for a
// GPU with no process (pid "-"). The command is the last column and is joined back together if it
// holds a space. Output from several runs can be concatenated: each run repeats its header.
func parsePmon(out string) []pmonRow {
	rows := []pmonRow{}
	var cols map[string]int
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if strings.HasPrefix(f[0], "#") {
			names := strings.Fields(strings.TrimPrefix(strings.Join(f, " "), "#"))
			if len(names) > 0 && names[0] == "gpu" {
				cols = map[string]int{}
				for i, n := range names {
					cols[n] = i
				}
			}
			continue
		}
		gpuCol, okGPU := cols["gpu"]
		pidCol, okPID := cols["pid"]
		if cols == nil || !okGPU || !okPID || len(f) < len(cols) {
			continue
		}
		pid, err := strconv.Atoi(f[pidCol])
		if err != nil {
			continue // "-": a GPU with nothing on it
		}
		r := pmonRow{GPUIndex: atoi(f[gpuCol]), PID: pid}
		if i, ok := cols["type"]; ok {
			r.Kind = pmonKinds[f[i]]
		}
		if i, ok := cols["sm"]; ok {
			r.SM = pmonValue(f[i])
		}
		if i, ok := cols["mem"]; ok {
			r.Mem = pmonValue(f[i])
		}
		if i, ok := cols["fb"]; ok {
			r.VRAMBytes = mibToBytes(f[i])
		}
		if i, ok := cols["command"]; ok && i < len(f) {
			r.Command = strings.Join(f[i:], " ")
		}
		rows = append(rows, r)
	}
	return rows
}

// pmonValue is a percentage column: nil for "-" (or anything else that is not a number).
func pmonValue(s string) *float64 {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	return &v
}

// pmonAttributes says whether "-" on this GPU can be read as "idle": pmon printed a number for
// some process on it, so the driver is attributing the card's use, or the card itself read 0 %
// busy, so every process on it was idle. A busy card on which every process reads "-" is the
// case left: the driver did not say who kept it busy (MIG, or a process that exited in the
// window), and no process is claimed idle.
func pmonAttributes(g GPU, rows []pmonRow) bool {
	if g.UtilizationPercent == 0 {
		return true
	}
	for _, r := range rows {
		if r.SM != nil || r.Mem != nil {
			return true
		}
	}
	return false
}

// applyPmon adds what pmon knows to the processes attachProcs listed: each one's kind and use of
// the card. A process pmon lists that compute-apps did not (a graphics process, or one that
// started between the two calls) is added, described by describe. A process compute-apps listed
// that pmon did not keeps its memory, with its use absent.
func applyPmon(gpus []GPU, rows []pmonRow, describe func(pmonRow) GPUProc) {
	for gi := range gpus {
		g := &gpus[gi]
		var mine []pmonRow
		for _, r := range rows {
			if r.GPUIndex == g.Index {
				mine = append(mine, r)
			}
		}
		attributed := pmonAttributes(*g, mine)
		use := func(v *float64) *float64 {
			if v == nil && attributed {
				zero := 0.0
				return &zero
			}
			return v
		}
		for _, r := range mine {
			p := -1
			for i := range g.Processes {
				if g.Processes[i].PID == r.PID {
					p = i
					break
				}
			}
			if p < 0 {
				g.Processes = append(g.Processes, describe(r))
				p = len(g.Processes) - 1
			}
			if r.Kind != "" {
				g.Processes[p].Kind = r.Kind
			}
			g.Processes[p].UtilizationPercent = use(r.SM)
			g.Processes[p].MemUtilPercent = use(r.Mem)
		}
	}
}
