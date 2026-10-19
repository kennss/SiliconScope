//go:build linux || windows

//
//  File:      gpu_procs_test.go
//  Created:   2026-10-18
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for reading nvidia-smi's GPU and compute-app rows and putting each process
//             under the GPU it is on.
//  Notes:     GPU 0's rows are real output of driver 595 on an RTX 3090 (kennt-Ubuntu); GPU 1 and
//             its processes are a fixture in the same format, as no two-GPU box was at hand. The
//             package builds only for Linux/Windows: from a Mac, run `GOOS=linux go test -c` and
//             execute the binary on a Linux box.
//
package collect

import (
	"reflect"
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
