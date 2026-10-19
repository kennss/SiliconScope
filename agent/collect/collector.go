//go:build linux || windows

//
//  File:      collector.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The Collector: one sample of the machine, and what it remembers between samples. The
//             NVIDIA GPU readers (nvidia-smi) and the Ollama reader live here too, moved from the
//             agent's main.go unchanged.
//  Notes:     GPU comes from shelling out to `nvidia-smi --format=csv,noheader,nounits` (keeps the
//             binary pure-Go/static; NVML via go-nvml would need cgo). VRAM is MiB from nvidia-smi
//             (×1 MiB → bytes). Compute processes are matched to their GPU by UUID (gpu_procs.go).
//             Ollama is optional (nil when unreachable).
//             What a Collector remembers — the extended nvidia-smi fields this driver answers, each
//             card's temperature limits (gpu_limits.go), the Docker container list (10 s), uid →
//             name, the ComfyUI port (10 s), network filesystems' sizes (netmounts_linux.go), LM
//             Studio's last rate — sits behind its own lock, so concurrent Collect calls are safe.
//             ctx bounds the commands and HTTP requests of one sample; a cancelled one returns what
//             it has.
//
package collect

import (
	"context"
	"encoding/json"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Collector reads this machine's metrics. Make one with New, call Collect for each sample, and
// Close it when done.
type Collector struct {
	opts      Options
	gpuFields gpuFieldState
	gpuLimits gpuLimitState
	platform  *platformState // what the OS-specific readers remember (workloads_linux.go)
	lmStudio  lmStudioWatcher
	stop      context.CancelFunc
	running   sync.WaitGroup
}

// New makes a Collector. With Options.WatchLMStudio it starts reading LM Studio's log stream in
// the background until Close.
func New(opts Options) (*Collector, error) {
	c := &Collector{opts: opts, platform: newPlatformState(opts)}
	if opts.WatchLMStudio {
		ctx, cancel := context.WithCancel(context.Background())
		c.stop = cancel
		c.watchLMStudio(ctx)
	}
	return c, nil
}

// Close stops what New started and waits for it: the LM Studio log stream and its `lms` child.
func (c *Collector) Close() {
	if c.stop != nil {
		c.stop()
	}
	c.running.Wait()
}

// Collect gathers one full MachineMetrics snapshot. It takes about 200 ms (the CPU window) plus
// the nvidia-smi calls.
func (c *Collector) Collect(ctx context.Context) MachineMetrics {
	return MachineMetrics{
		MachineID:    machineID(),
		Hostname:     hostname(),
		OS:           osPrettyName(),
		Kind:         machineKind,
		AgentVersion: c.opts.Version,
		TS:           time.Now().UnixMilli(),
		CPU:          readCPU(ctx),
		Memory:       readMemory(),
		Containers:   c.readContainers(ctx), // before GPUs: GPU processes are named after their containers
		GPUs:         c.readGPUs(ctx),
		Disks:        append(readDisks(), c.readNetworkDisks(ctx)...),
		LLM:          c.readLLM(ctx),
		ComfyUI:      c.readComfyUI(ctx),
	}
}

// sleep waits d, or less when ctx ends first.
func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
	case <-ctx.Done():
	}
}

// MARK: - GPU (nvidia-smi)

// baseGPUQuery is the fields every supported driver answers; readGPUs never gives them up.
// uuid is what compute processes are matched on (gpu_procs.go).
const baseGPUQuery = "index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw,power.limit,uuid"

// baseGPUFields is how many leading columns baseGPUQuery yields; extended fields follow them.
const baseGPUFields = 10

func (c *Collector) readGPUs(ctx context.Context) []GPU {
	extra := c.gpuFields.query(ctx)
	query := baseGPUQuery
	for _, f := range extra {
		query += "," + f.name
	}
	out, err := exec.CommandContext(ctx, "nvidia-smi", "--query-gpu="+query, "--format=csv,noheader,nounits").Output()
	if err != nil && len(extra) > 0 && ctx.Err() == nil {
		// The extras cost the whole query on a driver that rejects one of them. Keep the GPU.
		c.gpuFields.disable()
		extra = nil
		out, err = exec.CommandContext(ctx, "nvidia-smi", "--query-gpu="+baseGPUQuery,
			"--format=csv,noheader,nounits").Output()
	}
	if err != nil {
		// No NVIDIA GPU / driver — a Raspberry Pi, CPU-only server or VM lands here. Return an
		// EMPTY slice, never nil: encoding/json marshals a nil slice as `null`, which broke the
		// viewer's decode for every GPU-less machine (issue #33).
		return []GPU{}
	}
	gpus := parseGPUs(string(out), extra)
	c.gpuLimits.apply(ctx, gpus)
	attachProcs(gpus, readComputeApps(ctx), c.describeComputeApp())
	return gpus
}

// parseGPUs reads the CSV rows of baseGPUQuery followed by the extended fields. Pure, for testing.
func parseGPUs(out string, extra []resolvedField) []GPU {
	gpus := []GPU{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := splitCSV(line)
		if len(f) < baseGPUFields {
			continue
		}
		g := GPU{
			Index:              atoi(f[0]),
			Name:               f[1],
			Driver:             f[2],
			VRAMTotalBytes:     mibToBytes(f[3]),
			VRAMUsedBytes:      mibToBytes(f[4]),
			UtilizationPercent: atof(f[5]),
			TemperatureC:       atof(f[6]),
			PowerDrawW:         atof(f[7]),
			PowerLimitW:        atof(f[8]),
			Processes:          []GPUProc{},
		}
		if id := optString(f[9]); id != nil {
			g.UUID = *id
		}
		if len(f) >= baseGPUFields+len(extra) {
			applyExtended(&g, extra, f[baseGPUFields:])
		}
		gpus = append(gpus, g)
	}
	return gpus
}

func readComputeApps(ctx context.Context) []computeApp {
	out, err := exec.CommandContext(ctx, "nvidia-smi", "--query-compute-apps="+computeAppsQuery,
		"--format=csv,noheader,nounits").Output()
	if err != nil {
		return nil // no processes listed; every GPU keeps its empty (never nil) Processes
	}
	return parseComputeApps(string(out))
}

// describeComputeApp returns the per-sample describer: a process on several GPUs is several rows,
// and its /proc details are read once.
func (c *Collector) describeComputeApp() func(computeApp) GPUProc {
	type details struct{ path, script, container, user string }
	seen := map[int]details{}
	return func(a computeApp) GPUProc {
		d, ok := seen[a.PID]
		if !ok {
			d.path, d.script = describeProc(a.PID, a.Name)
			d.container = c.containerOf(a.PID)
			d.user = c.processUser(a.PID)
			seen[a.PID] = d
		}
		return GPUProc{PID: a.PID, Name: d.path, VRAMBytes: a.VRAMBytes, Container: d.container,
			Script: d.script, User: d.user}
	}
}

// MARK: - LLM (Ollama)

func (c *Collector) readLLM(ctx context.Context) *LLM {
	rate := c.readTokenRate(ctx)
	models, ok := ollamaModels(ctx, "/api/tags")
	if !ok {
		// No Ollama — but another runtime may still be reporting a rate (LM Studio, llama.cpp),
		// and dropping the whole block here is what would hide it.
		if rate == nil {
			return nil
		}
		return &LLM{Rate: rate}
	}
	loaded, ok := ollamaModels(ctx, "/api/ps")
	if !ok || loaded == nil {
		loaded = []LLMModel{} // never emit `null` — same nil-slice trap as gpus (#33)
	}
	return &LLM{Ollama: &Ollama{Running: true, Models: models, Loaded: loaded}, Rate: rate}
}

func ollamaModels(ctx context.Context, path string) ([]LLMModel, bool) {
	client := http.Client{Timeout: 3 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://localhost:11434"+path, nil)
	if err != nil {
		return nil, false
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	var r struct {
		Models []struct {
			Name string `json:"name"`
			Size int64  `json:"size"`
		} `json:"models"`
	}
	if json.NewDecoder(resp.Body).Decode(&r) != nil {
		return nil, false
	}
	out := make([]LLMModel, 0, len(r.Models))
	for _, m := range r.Models {
		out = append(out, LLMModel{Name: m.Name, SizeBytes: m.Size})
	}
	return out, true
}

// MARK: - small helpers

func splitCSV(line string) []string {
	parts := strings.Split(line, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

func atoi(s string) int         { v, _ := strconv.Atoi(strings.TrimSpace(s)); return v }
func atof(s string) float64     { v, _ := strconv.ParseFloat(strings.TrimSpace(s), 64); return v }
func mibToBytes(s string) int64 { return int64(atof(s)) * 1024 * 1024 }
func round1(f float64) float64  { return float64(int64(f*10+0.5)) / 10 }
