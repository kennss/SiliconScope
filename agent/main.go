//
//  File:      main.go
//  Created:   2026-07-21
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  SiliconScope fleet agent (v0.1, Linux). Samples CPU / memory / NVIDIA GPU /
//             Ollama and prints ONE MachineMetrics JSON to stdout. This is the source-agnostic
//             boundary the Mac aggregator consumes — a headless Mac agent will emit the same
//             shape (Apple GPU/ANE in `gpus`, E/P split in `cpu`). Pure stdlib, no CGO, so it
//             cross-compiles to a static single binary: CGO_ENABLED=0 GOOS=linux go build.
//  Notes:     GPU comes from shelling out to `nvidia-smi --format=csv,noheader,nounits`
//             (keeps the binary pure-Go/static; NVML via go-nvml would need CGO). VRAM is MiB
//             from nvidia-smi (×1MiB → bytes). Memory is kB from /proc/meminfo (×1024). CPU
//             usage is a 200ms delta of /proc/stat. Ollama is optional (nil when unreachable).
//             Compute processes are matched to their GPU by UUID (gpu_procs.go), so a box with
//             several GPUs lists each process under the GPU it is on.
//
package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/grandcat/zeroconf"
)

const agentVersion = "1.4.0"

// MachineMetrics is the wire schema (source-agnostic): Linux-NVML and Mac-headless both fill it.
type MachineMetrics struct {
	MachineID    string `json:"machineId"`
	Hostname     string `json:"hostname"`
	OS           string `json:"os"`
	Kind         string `json:"kind"` // "linux" | "mac"
	AgentVersion string `json:"agentVersion"`
	TS           int64  `json:"ts"` // unix ms
	CPU          CPU    `json:"cpu"`
	Memory       Memory `json:"memory"`
	GPUs         []GPU  `json:"gpus"`
	Disks        []Disk `json:"disks"`
	LLM          *LLM   `json:"llm,omitempty"`
	// Running Docker containers. Absent = Docker isn't readable here; [] = it is, and runs nothing.
	Containers *[]Container `json:"containers,omitempty"`
	// A ComfyUI server seen on the host, and its queue. Absent when none is running.
	ComfyUI *ComfyUI `json:"comfyui,omitempty"`
}

// Container is one running Docker container. RestartCount is what makes a crash loop visible:
// a container Docker keeps restarting still reads "running".
type Container struct {
	Name         string `json:"name"`
	Image        string `json:"image"`
	State        string `json:"state"`
	Status       string `json:"status"`
	RestartCount *int   `json:"restartCount,omitempty"`
}

// ComfyUI is a ComfyUI server's queue: prompts executing and waiting.
type ComfyUI struct {
	Version string `json:"version,omitempty"`
	Port    int    `json:"port"`
	Running int    `json:"running"`
	Pending int    `json:"pending"`
}

type CPU struct {
	Cores        int     `json:"cores"`
	UsagePercent float64 `json:"usagePercent"`
	LoadAvg1     float64 `json:"loadAvg1"`
	// Model name, e.g. "AMD Ryzen 9 5950X". Omitted when /proc/cpuinfo does not say, rather than
	// guessed — the viewer renders no name at all instead of asserting one it was not given.
	Model string `json:"model,omitempty"`
}

type Memory struct {
	TotalBytes     int64 `json:"totalBytes"`
	UsedBytes      int64 `json:"usedBytes"`
	AvailableBytes int64 `json:"availableBytes"`
}

type GPUProc struct {
	PID       int    `json:"pid"`
	Name      string `json:"name"`
	VRAMBytes int64  `json:"vramBytes"`
	// The Docker container holding this VRAM, when it runs in one. Empty for the host.
	Container string `json:"container,omitempty"`
	// The Python script it runs (e.g. "halluc_bench.py"), so two jobs in one environment differ.
	Script string `json:"script,omitempty"`
	// The account it runs as: the real uid of /proc/<pid>/status, by name from the system's user
	// database, else the uid as a number. Empty when it can't be read (and on Windows).
	User string `json:"user,omitempty"`
}

type GPU struct {
	Index int `json:"index"`
	// The driver's identifier for this card ("GPU-d5a8caa7-…"). Unlike the index it stays with the
	// card when another one is added or removed, so a viewer can key a GPU's history on it.
	UUID               string    `json:"uuid,omitempty"`
	Name               string    `json:"name"`
	Driver             string    `json:"driver"`
	VRAMTotalBytes     int64     `json:"vramTotalBytes"`
	VRAMUsedBytes      int64     `json:"vramUsedBytes"`
	UtilizationPercent float64   `json:"utilizationPercent"`
	TemperatureC       float64   `json:"temperatureC"`
	PowerDrawW         float64   `json:"powerDrawW"`
	PowerLimitW        float64   `json:"powerLimitW"`
	Processes          []GPUProc `json:"processes"`

	// Extended fields (gpu_extended.go). Omitted when the driver doesn't report them — never 0.
	MemUtilPercent *float64 `json:"memUtilPercent,omitempty"` // memory controller busy: the bandwidth signal
	SMClockMHz     *float64 `json:"smClockMHz,omitempty"`
	SMClockMaxMHz  *float64 `json:"smClockMaxMHz,omitempty"`
	MemClockMHz    *float64 `json:"memClockMHz,omitempty"`
	MemClockMaxMHz *float64 `json:"memClockMaxMHz,omitempty"`
	PState         *string  `json:"pstate,omitempty"`
	FanPercent     *float64 `json:"fanPercent,omitempty"`
	EncoderPercent *float64 `json:"encoderPercent,omitempty"` // NVENC
	DecoderPercent *float64 `json:"decoderPercent,omitempty"` // NVDEC
	// Why the clocks are held down right now. nil = the card doesn't say; [] = nothing is.
	ThrottleReasons *[]string `json:"throttleReasons,omitempty"`
}

// Disk is one mounted local filesystem's capacity. The viewer derives used as total - free, so no
// third number is sent. FSType is omitempty (not every platform exposes it cheaply). Always
// emitted as a real array, never nil — a nil slice marshals to `null`, which broke the viewer's
// decode for GPU-less machines (#33).
type Disk struct {
	Mount      string `json:"mount"`
	TotalBytes int64  `json:"totalBytes"`
	FreeBytes  int64  `json:"freeBytes"`
	FSType     string `json:"fsType,omitempty"`
}

type LLMModel struct {
	Name      string `json:"name"`
	SizeBytes int64  `json:"sizeBytes"`
}

type Ollama struct {
	Running bool       `json:"running"`
	Models  []LLMModel `json:"models"`
	Loaded  []LLMModel `json:"loaded"`
}

type LLM struct {
	Ollama *Ollama `json:"ollama,omitempty"`
	// The runtime's own count of its own decode rate, when it publishes one. Absent rather than
	// zero when no runtime exposes it — a missing measurement and a measured 0 tok/s are different
	// facts, and Ollama genuinely exposes nothing server-side. See tokenrate.go.
	Rate *TokenRate `json:"rate,omitempty"`
}

func main() {
	serve := flag.String("serve", "", "run an HTTPS server on this addr (e.g. :7799) exposing GET /metrics (token-protected), instead of printing one snapshot and exiting")
	showVersion := flag.Bool("version", false, "print the agent version and exit")
	printToken := flag.Bool("print-token", false, "print the agent's bearer token (creating it on first run) and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(agentVersion)
		return
	}
	if *printToken {
		tok, err := loadOrCreateToken()
		if err != nil {
			fmt.Fprintln(os.Stderr, "token error:", err)
			os.Exit(1)
		}
		fmt.Println(tok)
		return
	}
	if *serve != "" {
		runServer(*serve)
		return
	}
	out, err := json.MarshalIndent(sample(), "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "encode error:", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}

// sample gathers one full MachineMetrics snapshot.
func sample() MachineMetrics {
	return MachineMetrics{
		MachineID:    machineID(),
		Hostname:     hostname(),
		OS:           osPrettyName(),
		Kind:         machineKind,
		AgentVersion: agentVersion,
		TS:           time.Now().UnixMilli(),
		CPU:          readCPU(),
		Memory:       readMemory(),
		Containers:   readContainers(), // before GPUs: GPU processes are named after their containers
		GPUs:         readGPUs(),
		Disks:        readDisks(),
		LLM:          readLLM(),
		ComfyUI:      readComfyUI(),
	}
}

// runServer exposes GET /metrics (token-protected, a fresh sample per request) + GET /healthz
// (open, for discovery/liveness) over TLS. The Mac aggregator connects here directly, TOFU-pinning
// the self-signed cert (fingerprint advertised via mDNS) and sending the bearer token.
func runServer(addr string) {
	// Only in serve mode: LM Studio reports a rate when a prediction FINISHES, so a one-shot
	// snapshot would exit long before anything could be observed.
	watchLMStudio()

	token, err := loadOrCreateToken()
	if err != nil {
		fmt.Fprintln(os.Stderr, "token init failed:", err)
		os.Exit(1)
	}
	cert, fingerprint, err := loadOrCreateTLS()
	if err != nil {
		fmt.Fprintln(os.Stderr, "TLS init failed:", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", requireToken(token, func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, r, sample())
	}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})

	// Advertise on the LAN (with the cert fingerprint) so the Mac auto-discovers + TOFU-pins.
	if server := registerMDNS(portFromAddr(addr), fingerprint); server != nil {
		defer server.Shutdown()
	}

	fmt.Fprintf(os.Stderr, "sscope-agent %s serving TLS on %s (GET /metrics, token required)\n", agentVersion, addr)
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		// A viewer keeps its connection open between polls (every 3 s); one that stops watching
		// leaves it idle, and this closes it rather than holding it forever (#71).
		IdleTimeout: 30 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
	}
	if err := srv.ListenAndServeTLS("", ""); err != nil {
		fmt.Fprintln(os.Stderr, "serve error:", err)
		os.Exit(1)
	}
}

// registerMDNS advertises "_sscope-agent._tcp" so the Mac aggregator discovers this machine via
// Bonjour/mDNS — no hardcoded IP/port. TXT records carry a summary (host/gpu/os/id/ver) plus the
// TLS fingerprint (fp) + secure=1 so a discovered-but-unpaired card can render and the Mac can
// TOFU-pin the cert before any authenticated fetch. Returns nil on failure (advertise skipped).
func registerMDNS(port int, fingerprint string) *zeroconf.Server {
	if port <= 0 {
		return nil
	}
	s := sample()
	gpu := "-"
	if len(s.GPUs) > 0 {
		gpu = s.GPUs[0].Name
	}
	txt := []string{
		"host=" + s.Hostname, "gpu=" + gpu, "os=" + s.OS,
		"id=" + s.MachineID, "ver=" + agentVersion,
		"secure=1", "fp=" + fingerprint,
	}
	server, err := zeroconf.Register(s.Hostname, "_sscope-agent._tcp", "local.", port, txt, nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, "mDNS register failed:", err)
		return nil
	}
	fmt.Fprintf(os.Stderr, "sscope-agent advertising via mDNS (_sscope-agent._tcp on :%d)\n", port)
	return server
}

// portFromAddr extracts the numeric port from a listen addr like ":7799" or "0.0.0.0:7799".
func portFromAddr(addr string) int {
	if i := strings.LastIndex(addr, ":"); i >= 0 {
		if p, err := strconv.Atoi(addr[i+1:]); err == nil {
			return p
		}
	}
	return 0
}

// MARK: - GPU (nvidia-smi)

// baseGPUQuery is the fields every supported driver answers; readGPUs never gives them up.
// uuid is what compute processes are matched on (gpu_procs.go).
const baseGPUQuery = "index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw,power.limit,uuid"

// baseGPUFields is how many leading columns baseGPUQuery yields; extended fields follow them.
const baseGPUFields = 10

func readGPUs() []GPU {
	extra := extendedGPUQuery()
	query := baseGPUQuery
	for _, f := range extra {
		query += "," + f.name
	}
	out, err := exec.Command("nvidia-smi", "--query-gpu="+query, "--format=csv,noheader,nounits").Output()
	if err != nil && len(extra) > 0 {
		// The extras cost the whole query on a driver that rejects one of them. Keep the GPU.
		disableExtendedGPUQuery()
		extra = nil
		out, err = exec.Command("nvidia-smi", "--query-gpu="+baseGPUQuery, "--format=csv,noheader,nounits").Output()
	}
	if err != nil {
		// No NVIDIA GPU / driver — a Raspberry Pi, CPU-only server or VM lands here. Return an
		// EMPTY slice, never nil: encoding/json marshals a nil slice as `null`, which broke the
		// viewer's decode for every GPU-less machine (issue #33).
		return []GPU{}
	}
	gpus := parseGPUs(string(out), extra)
	attachProcs(gpus, readComputeApps(), describeComputeApp())
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

func readComputeApps() []computeApp {
	out, err := exec.Command("nvidia-smi", "--query-compute-apps="+computeAppsQuery,
		"--format=csv,noheader,nounits").Output()
	if err != nil {
		return nil // no processes listed; every GPU keeps its empty (never nil) Processes
	}
	return parseComputeApps(string(out))
}

// describeComputeApp returns the per-sample describer: a process on several GPUs is several rows,
// and its /proc details are read once.
func describeComputeApp() func(computeApp) GPUProc {
	type details struct{ path, script, container, user string }
	seen := map[int]details{}
	return func(a computeApp) GPUProc {
		d, ok := seen[a.PID]
		if !ok {
			d.path, d.script = describeProc(a.PID, a.Name)
			d.container = containerOf(a.PID)
			d.user = processUser(a.PID)
			seen[a.PID] = d
		}
		return GPUProc{PID: a.PID, Name: d.path, VRAMBytes: a.VRAMBytes, Container: d.container,
			Script: d.script, User: d.user}
	}
}

// MARK: - LLM (Ollama)

func readLLM() *LLM {
	rate := readTokenRate()
	models, ok := ollamaModels("/api/tags")
	if !ok {
		// No Ollama — but another runtime may still be reporting a rate (LM Studio, llama.cpp),
		// and dropping the whole block here is what would hide it.
		if rate == nil {
			return nil
		}
		return &LLM{Rate: rate}
	}
	loaded, ok := ollamaModels("/api/ps")
	if !ok || loaded == nil {
		loaded = []LLMModel{} // never emit `null` — same nil-slice trap as gpus (#33)
	}
	return &LLM{Ollama: &Ollama{Running: true, Models: models, Loaded: loaded}, Rate: rate}
}

func ollamaModels(path string) ([]LLMModel, bool) {
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://localhost:11434" + path)
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

func atoi(s string) int       { v, _ := strconv.Atoi(strings.TrimSpace(s)); return v }
func atof(s string) float64   { v, _ := strconv.ParseFloat(strings.TrimSpace(s), 64); return v }
func mibToBytes(s string) int64 { return int64(atof(s)) * 1024 * 1024 }
func round1(f float64) float64 { return float64(int64(f*10+0.5)) / 10 }
