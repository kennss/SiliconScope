//go:build linux || windows

//
//  File:      gpu_procs_test.go
//  Created:   2026-10-18
//  Updated:   2026-10-21
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for reading nvidia-smi's GPU, compute-app and pmon rows, putting each process
//             under the GPU it is on, and adding each one's use of the card.
//  Notes:     GPU 0's rows are real output of driver 595 on an RTX 3090 (kennt-Ubuntu), the pmon
//             tables too (one idle, one with a matrix-multiply load on PID 2762421, 2026-10-21);
//             GPU 1 and its processes, and the older pmon layout, are fixtures in the same format,
//             as no two-GPU box or older driver was at hand. The
//             package builds only for Linux/Windows: from a Mac, run `GOOS=linux go test -c` and
//             execute the binary on a Linux box.
//
package collect

import (
	"reflect"
	"strconv"
	"testing"
)

const (
	uuid0 = "GPU-d5a8caa7-b8c9-a066-415f-550d411855cb"
	uuid1 = "GPU-0f6a1c2e-1111-2222-3333-444455556666"
)

const twoGPUs = `0, NVIDIA GeForce RTX 3090, 595.84, 24576, 6012, 37, 48, 112.40, 350.00, ` + uuid0 + `
1, NVIDIA GeForce RTX 3090, 595.84, 24576, 20480, 98, 71, 341.20, 350.00, ` + uuid1

const twoGPUApps = uuid0 + `, 2724, /home/kennt/whisper-bench/bin/python, 5408
` + uuid0 + `, 2720, /home/kennt/ComfyUI/venv/bin/python, 256
` + uuid1 + `, 4100, /opt/train/bin/python, 18432
` + uuid1 + `, 2724, /home/kennt/whisper-bench/bin/python, 1024
GPU-ffffffff-0000-0000-0000-000000000000, 5000, /usr/bin/ghost, 64`

// byPID describes a row with only what the matching decides: its PID and memory.
func byPID(a computeApp) GPUProc { return GPUProc{PID: a.PID, VRAMBytes: a.VRAMBytes} }

func procs(g GPU) map[int]int64 {
	m := map[int]int64{}
	for _, p := range g.Processes {
		m[p.PID] = p.VRAMBytes
	}
	return m
}

func TestParseGPUsReadsTheUUID(t *testing.T) {
	gpus := parseGPUs(twoGPUs, nil)
	if len(gpus) != 2 {
		t.Fatalf("got %d GPUs, want 2", len(gpus))
	}
	if gpus[0].UUID != uuid0 || gpus[1].UUID != uuid1 {
		t.Fatalf("UUIDs = %q, %q", gpus[0].UUID, gpus[1].UUID)
	}
	if gpus[1].Index != 1 || gpus[1].VRAMUsedBytes != 20480*1024*1024 || gpus[1].UtilizationPercent != 98 {
		t.Fatalf("GPU 1 = %+v", gpus[1])
	}
	if gpus[0].Processes == nil || len(gpus[0].Processes) != 0 {
		t.Fatalf("a GPU starts with an empty, non-nil process list (#33)")
	}
}

func TestParseGPUsAppliesExtendedFieldsAfterTheUUID(t *testing.T) {
	extra := []resolvedField{{key: "pstate", name: "pstate"}, {key: "fan", name: "fan.speed"}}
	gpus := parseGPUs(`0, NVIDIA GeForce RTX 3090, 595.84, 24576, 6012, 37, 48, 112.40, 350.00, `+uuid0+`, P2, 54`, extra)
	if len(gpus) != 1 || gpus[0].PState == nil || *gpus[0].PState != "P2" ||
		gpus[0].FanPercent == nil || *gpus[0].FanPercent != 54 {
		t.Fatalf("extended fields misread: %+v", gpus)
	}
}

func TestParseGPUsLeavesAnUnreportedUUIDEmpty(t *testing.T) {
	gpus := parseGPUs(`0, Some GPU, 595.84, 24576, 6012, 37, 48, 112.40, 350.00, [N/A]`, nil)
	if len(gpus) != 1 || gpus[0].UUID != "" {
		t.Fatalf("UUID = %q, want empty", gpus[0].UUID)
	}
}

func TestParseComputeApps(t *testing.T) {
	got := parseComputeApps(uuid0 + ", 2724, /home/kennt/whisper-bench/bin/python, 5408\n" +
		uuid0 + ", 31, /srv/odd,name/run, 128\n\n")
	want := []computeApp{
		{GPUUUID: uuid0, PID: 2724, Name: "/home/kennt/whisper-bench/bin/python", VRAMBytes: 5408 * 1024 * 1024},
		{GPUUUID: uuid0, PID: 31, Name: "/srv/odd,name/run", VRAMBytes: 128 * 1024 * 1024},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
	if apps := parseComputeApps(""); apps == nil || len(apps) != 0 {
		t.Fatalf("no rows = %v, want an empty list", apps)
	}
}

func TestAttachProcsPutsEachProcessUnderItsGPU(t *testing.T) {
	gpus := parseGPUs(twoGPUs, nil)
	attachProcs(gpus, parseComputeApps(twoGPUApps), byPID)
	const mib = 1024 * 1024
	if got, want := procs(gpus[0]), map[int]int64{2724: 5408 * mib, 2720: 256 * mib}; !reflect.DeepEqual(got, want) {
		t.Errorf("GPU 0 = %v, want %v", got, want)
	}
	// 2724 runs on both GPUs: listed under each with the memory it holds there. The row whose UUID
	// matches no GPU (5000) is left out, not credited to GPU 0.
	if got, want := procs(gpus[1]), map[int]int64{4100: 18432 * mib, 2724: 1024 * mib}; !reflect.DeepEqual(got, want) {
		t.Errorf("GPU 1 = %v, want %v", got, want)
	}
}

func TestAttachProcsOnOneGPUKeepsEveryRow(t *testing.T) {
	gpus := parseGPUs(`0, NVIDIA GeForce RTX 3090, 595.84, 24576, 6012, 37, 48, 112.40, 350.00, [N/A]`, nil)
	attachProcs(gpus, parseComputeApps(twoGPUApps), byPID)
	if len(gpus[0].Processes) != 5 {
		t.Fatalf("one GPU holds every process whatever its UUID: got %d of 5", len(gpus[0].Processes))
	}
}

func TestAttachProcsWithoutGPUsOrApps(t *testing.T) {
	attachProcs(nil, parseComputeApps(twoGPUApps), byPID) // must not panic
	gpus := parseGPUs(twoGPUs, nil)
	attachProcs(gpus, nil, byPID)
	for _, g := range gpus {
		if g.Processes == nil || len(g.Processes) != 0 {
			t.Fatalf("GPU %d processes = %v, want empty and non-nil", g.Index, g.Processes)
		}
	}
}

func TestDescribeComputeAppReadsAProcessOnce(t *testing.T) {
	c, _ := New(Options{})
	describe := c.describeComputeApp()
	a := describe(computeApp{GPUUUID: uuid0, PID: 999999, Name: "/bin/x", VRAMBytes: 1})
	b := describe(computeApp{GPUUUID: uuid1, PID: 999999, Name: "/bin/x", VRAMBytes: 2})
	if a.Name != b.Name || a.VRAMBytes != 1 || b.VRAMBytes != 2 {
		t.Fatalf("rows of one process share its details but keep their own memory: %+v %+v", a, b)
	}
}

// pmonIdle is `nvidia-smi pmon -c 1 -s um` on kennt-Ubuntu with nothing running on the card.
const pmonIdle = `# gpu         pid   type     sm    mem    enc    dec    jpg    ofa     fb   ccpm    command 
# Idx           #    C/G      %      %      %      %      %      %     MB     MB    name 
    0       2724     C      -      -      -      -      -      -   5408      0    python         
    0       2764     G      -      -      -      -      -      -    171      0    Xorg           
    0       3127     G      -      -      -      -      -      -     14      0    gnome-shell    
    0    1881466     C      -      -      -      -      -      -    402      0    python         
`

// pmonLoaded is the same box with PID 2762421 multiplying matrices (the card read 99 % / 12 %).
const pmonLoaded = `# gpu         pid   type     sm    mem    enc    dec    jpg    ofa     fb   ccpm    command 
# Idx           #    C/G      %      %      %      %      %      %     MB     MB    name 
    0       2724     C      -      -      -      -      -      -   5408      0    python         
    0       2764     G      -      -      -      -      -      -    171      0    Xorg           
    0       3127     G      -      -      -      -      -      -     14      0    gnome-shell    
    0    1881466     C      -      -      -      -      -      -    402      0    python         
    0    2762421     C     99     12      -      -      -      -    480      0    python         
`

func ptr(v float64) *float64 { return &v }

func use(p *float64) string {
	if p == nil {
		return "absent"
	}
	return strconv.FormatFloat(*p, 'f', -1, 64)
}

func TestParsePmonReadsTheDriversTable(t *testing.T) {
	rows := parsePmon(pmonLoaded)
	if len(rows) != 5 {
		t.Fatalf("got %d rows, want 5: %+v", len(rows), rows)
	}
	busy := rows[4]
	if busy.GPUIndex != 0 || busy.PID != 2762421 || busy.Kind != "compute" || use(busy.SM) != "99" ||
		use(busy.Mem) != "12" || busy.VRAMBytes != 480*1024*1024 || busy.Command != "python" {
		t.Fatalf("busy row = %+v", busy)
	}
	xorg := rows[1]
	if xorg.PID != 2764 || xorg.Kind != "graphics" || xorg.SM != nil || xorg.Mem != nil || xorg.Command != "Xorg" {
		t.Fatalf("Xorg row = %+v", xorg)
	}
}

func TestParsePmonFindsColumnsByTheHeader(t *testing.T) {
	// An older driver: no jpg, ofa or ccpm columns, so fb and the command sit further left.
	old := `# gpu        pid  type    sm   mem   enc   dec    fb   command
# Idx          #   C/G     %     %     %     %    MB   name
    0       4100     C    63    20     -     -  18432   train run
    0       4200   C+G     5     1     -     -   900   blender
`
	rows := parsePmon(old)
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2: %+v", len(rows), rows)
	}
	if rows[0].VRAMBytes != 18432*1024*1024 || rows[0].Command != "train run" || use(rows[0].SM) != "63" {
		t.Fatalf("row 0 = %+v", rows[0])
	}
	if rows[1].Kind != "compute+graphics" {
		t.Fatalf("C+G kind = %q", rows[1].Kind)
	}
}

func TestParsePmonSkipsAGPUWithNothingOnIt(t *testing.T) {
	out := `# gpu         pid   type     sm    mem    enc    dec    jpg    ofa     fb   ccpm    command 
# Idx           #    C/G      %      %      %      %      %      %     MB     MB    name 
    0          -     -      -      -      -      -      -      -      -      -    -              
`
	if rows := parsePmon(out); len(rows) != 0 {
		t.Fatalf("an empty GPU's row was read as a process: %+v", rows)
	}
	if rows := parsePmon("NVIDIA-SMI has failed\n"); len(rows) != 0 {
		t.Fatalf("output without a header gave rows: %+v", rows)
	}
}

func TestPmonGroupsAskFourGPUsAtATime(t *testing.T) {
	got := pmonGroups([]int{0, 1, 2, 3, 4, 5})
	if want := [][]int{{0, 1, 2, 3}, {4, 5}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	if got := pmonGroups([]int{0}); !reflect.DeepEqual(got, [][]int{{0}}) {
		t.Fatalf("one GPU: %v", got)
	}
	if got := pmonGroups(nil); len(got) != 0 {
		t.Fatalf("no GPUs: %v", got)
	}
}

// oneGPU is kennt-Ubuntu's card at the given load, with its compute processes as compute-apps
// lists them (compute-apps lists no graphics process).
func oneGPU(util float64) []GPU {
	gpus := []GPU{{Index: 0, UUID: uuid0, UtilizationPercent: util, Processes: []GPUProc{}}}
	attachProcs(gpus, []computeApp{
		{GPUUUID: uuid0, PID: 2724, VRAMBytes: 5408 * 1024 * 1024},
		{GPUUUID: uuid0, PID: 1881466, VRAMBytes: 402 * 1024 * 1024},
		{GPUUUID: uuid0, PID: 2762421, VRAMBytes: 480 * 1024 * 1024},
	}, func(a computeApp) GPUProc { return GPUProc{PID: a.PID, VRAMBytes: a.VRAMBytes, Kind: "compute"} })
	return gpus
}

func byPmonPID(r pmonRow) GPUProc { return GPUProc{PID: r.PID, Name: r.Command, VRAMBytes: r.VRAMBytes} }

func procByPID(g GPU, pid int) *GPUProc {
	for i := range g.Processes {
		if g.Processes[i].PID == pid {
			return &g.Processes[i]
		}
	}
	return nil
}

func TestApplyPmonGivesEachProcessItsShare(t *testing.T) {
	gpus := oneGPU(99)
	applyPmon(gpus, parsePmon(pmonLoaded), byPmonPID)
	g := gpus[0]
	if p := procByPID(g, 2762421); p == nil || use(p.UtilizationPercent) != "99" || use(p.MemUtilPercent) != "12" {
		t.Fatalf("the busy process = %+v", p)
	}
	// The driver attributed the card's use, so "-" means idle.
	if p := procByPID(g, 2724); p == nil || use(p.UtilizationPercent) != "0" || use(p.MemUtilPercent) != "0" ||
		p.VRAMBytes != 5408*1024*1024 {
		t.Fatalf("an idle compute process = %+v", p)
	}
	// Graphics processes are added, with pmon's memory and kind.
	xorg := procByPID(g, 2764)
	if xorg == nil || xorg.Kind != "graphics" || xorg.Name != "Xorg" || xorg.VRAMBytes != 171*1024*1024 ||
		use(xorg.UtilizationPercent) != "0" {
		t.Fatalf("Xorg = %+v", xorg)
	}
	if len(g.Processes) != 5 {
		t.Fatalf("got %d processes, want 3 compute + 2 graphics", len(g.Processes))
	}
}

func TestApplyPmonOnAnIdleCardReadsEveryProcessIdle(t *testing.T) {
	gpus := oneGPU(0)
	applyPmon(gpus, parsePmon(pmonIdle), byPmonPID)
	for _, p := range gpus[0].Processes {
		if p.PID == 2762421 {
			continue // not in the idle table: compute-apps listed it, pmon did not
		}
		if use(p.UtilizationPercent) != "0" {
			t.Errorf("PID %d on a 0 %% card = %s, want 0", p.PID, use(p.UtilizationPercent))
		}
	}
	if p := procByPID(gpus[0], 2762421); p == nil || p.UtilizationPercent != nil {
		t.Errorf("a process pmon didn't list keeps its use absent: %+v", p)
	}
}

func TestApplyPmonClaimsNoIdleProcessOnABusyCard(t *testing.T) {
	// The card is 99 % busy but every process reads "-" (MIG, or the busy one exited in the
	// window): who kept it busy is unknown, so no process is said to be idle.
	gpus := oneGPU(99)
	applyPmon(gpus, parsePmon(pmonIdle), byPmonPID)
	for _, p := range gpus[0].Processes {
		if p.UtilizationPercent != nil || p.MemUtilPercent != nil {
			t.Errorf("PID %d = %s / %s, want absent", p.PID, use(p.UtilizationPercent), use(p.MemUtilPercent))
		}
	}
}

func TestApplyPmonMatchesGPUsByIndex(t *testing.T) {
	gpus := parseGPUs(twoGPUs, nil)
	attachProcs(gpus, parseComputeApps(twoGPUApps), byPID)
	// 2724 runs on both cards: busy on GPU 1, idle on GPU 0.
	applyPmon(gpus, []pmonRow{
		{GPUIndex: 0, PID: 2724, Kind: "compute"},
		{GPUIndex: 0, PID: 2720, Kind: "compute", SM: ptr(30), Mem: ptr(4)},
		{GPUIndex: 1, PID: 2724, Kind: "compute", SM: ptr(70), Mem: ptr(9)},
		{GPUIndex: 1, PID: 4100, Kind: "compute", SM: ptr(28), Mem: ptr(40)},
	}, byPmonPID)
	if p := procByPID(gpus[0], 2724); p == nil || use(p.UtilizationPercent) != "0" {
		t.Errorf("2724 on GPU 0 = %+v", p)
	}
	if p := procByPID(gpus[1], 2724); p == nil || use(p.UtilizationPercent) != "70" {
		t.Errorf("2724 on GPU 1 = %+v", p)
	}
	if len(gpus[0].Processes) != 2 || len(gpus[1].Processes) != 2 {
		t.Errorf("no process moved between cards: %d, %d", len(gpus[0].Processes), len(gpus[1].Processes))
	}
}

func TestApplyPmonWithoutRowsChangesNothing(t *testing.T) {
	gpus := oneGPU(99)
	applyPmon(gpus, nil, byPmonPID)
	for _, p := range gpus[0].Processes {
		if p.UtilizationPercent != nil || p.Kind != "compute" {
			t.Errorf("PID %d = %+v", p.PID, p)
		}
	}
}
