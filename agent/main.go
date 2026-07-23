//
//  File:      main.go
//  Created:   2026-07-21
//  Updated:   2026-07-22
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
//             v0.1 attaches all compute-apps to GPU 0 (single-GPU box); multi-GPU needs
//             gpu_uuid matching — TODO.
//
package main

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/grandcat/zeroconf"
)

const agentVersion = "0.1.0"

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
	LLM          *LLM   `json:"llm,omitempty"`
}

type CPU struct {
	Cores        int     `json:"cores"`
	UsagePercent float64 `json:"usagePercent"`
	LoadAvg1     float64 `json:"loadAvg1"`
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
}

type GPU struct {
	Index              int       `json:"index"`
	Name               string    `json:"name"`
	Driver             string    `json:"driver"`
	VRAMTotalBytes     int64     `json:"vramTotalBytes"`
	VRAMUsedBytes      int64     `json:"vramUsedBytes"`
	UtilizationPercent float64   `json:"utilizationPercent"`
	TemperatureC       float64   `json:"temperatureC"`
	PowerDrawW         float64   `json:"powerDrawW"`
	PowerLimitW        float64   `json:"powerLimitW"`
	Processes          []GPUProc `json:"processes"`
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
		Hostname:     firstLine("/etc/hostname"),
		OS:           osPrettyName(),
		Kind:         "linux",
		AgentVersion: agentVersion,
		TS:           time.Now().UnixMilli(),
		CPU:          readCPU(),
		Memory:       readMemory(),
		GPUs:         readGPUs(),
		LLM:          readLLM(),
	}
}

// runServer exposes GET /metrics (token-protected, a fresh sample per request) + GET /healthz
// (open, for discovery/liveness) over TLS. The Mac aggregator connects here directly, TOFU-pinning
// the self-signed cert (fingerprint advertised via mDNS) and sending the bearer token.
func runServer(addr string) {
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
	mux.HandleFunc("/metrics", requireToken(token, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(sample())
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

// MARK: - CPU

func readCPU() CPU {
	c := CPU{Cores: runtime.NumCPU(), LoadAvg1: loadAvg1()}
	t1, i1 := procStatTotals()
	time.Sleep(200 * time.Millisecond)
	t2, i2 := procStatTotals()
	if dt := t2 - t1; dt > 0 {
		busy := (t2 - t1) - (i2 - i1) // total delta minus idle delta
		c.UsagePercent = round1(100 * float64(busy) / float64(dt))
	}
	return c
}

func procStatTotals() (total, idle uint64) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := s.Text()
		if strings.HasPrefix(line, "cpu ") {
			for i, fld := range strings.Fields(line)[1:] {
				v, _ := strconv.ParseUint(fld, 10, 64)
				total += v
				if i == 3 || i == 4 { // idle + iowait
					idle += v
				}
			}
			return
		}
	}
	return
}

func loadAvg1() float64 {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0
	}
	if f := strings.Fields(string(b)); len(f) > 0 {
		v, _ := strconv.ParseFloat(f[0], 64)
		return v
	}
	return 0
}

// MARK: - Memory

func readMemory() Memory {
	var m Memory
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return m
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		parts := strings.Fields(s.Text())
		if len(parts) < 2 {
			continue
		}
		kb, _ := strconv.ParseInt(parts[1], 10, 64)
		switch parts[0] {
		case "MemTotal:":
			m.TotalBytes = kb * 1024
		case "MemAvailable:":
			m.AvailableBytes = kb * 1024
		}
	}
	m.UsedBytes = m.TotalBytes - m.AvailableBytes
	return m
}

// MARK: - GPU (nvidia-smi)

func readGPUs() []GPU {
	out, err := exec.Command("nvidia-smi",
		"--query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw,power.limit",
		"--format=csv,noheader,nounits").Output()
	if err != nil {
		// No NVIDIA GPU / driver — a Raspberry Pi, CPU-only server or VM lands here. Return an
		// EMPTY slice, never nil: encoding/json marshals a nil slice as `null`, which broke the
		// viewer's decode for every GPU-less machine (issue #33).
		return []GPU{}
	}
	procs := readGPUProcs()
	gpus := []GPU{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := splitCSV(line)
		if len(f) < 9 {
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
		gpus = append(gpus, g)
	}
	// v0.1: single-GPU box — attach all compute-apps to GPU 0. (Multi-GPU: match gpu_uuid.)
	if len(gpus) > 0 && len(procs) > 0 {
		gpus[0].Processes = procs
	}
	return gpus
}

func readGPUProcs() []GPUProc {
	out, err := exec.Command("nvidia-smi",
		"--query-compute-apps=pid,process_name,used_memory",
		"--format=csv,noheader,nounits").Output()
	if err != nil {
		return []GPUProc{} // never nil — see readGPUs (#33)
	}
	var procs []GPUProc
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		f := splitCSV(line)
		if len(f) < 3 {
			continue
		}
		procs = append(procs, GPUProc{PID: atoi(f[0]), Name: f[1], VRAMBytes: mibToBytes(f[2])})
	}
	return procs
}

// MARK: - LLM (Ollama)

func readLLM() *LLM {
	models, ok := ollamaModels("/api/tags")
	if !ok {
		return nil // Ollama not reachable → omit
	}
	loaded, ok := ollamaModels("/api/ps")
	if !ok || loaded == nil {
		loaded = []LLMModel{} // never emit `null` — same nil-slice trap as gpus (#33)
	}
	return &LLM{Ollama: &Ollama{Running: true, Models: models, Loaded: loaded}}
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

func firstLine(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		h, _ := os.Hostname()
		return h
	}
	return strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0])
}

func machineID() string {
	if id := strings.TrimSpace(readFile("/etc/machine-id")); id != "" {
		return id
	}
	h, _ := os.Hostname()
	return h
}

func osPrettyName() string {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return runtime.GOOS
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if v, ok := strings.CutPrefix(s.Text(), "PRETTY_NAME="); ok {
			return strings.Trim(v, `"`)
		}
	}
	return runtime.GOOS
}

func readFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}
