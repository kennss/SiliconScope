//
//  File:      types.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The MachineMetrics wire schema: what one sample says about a machine. SiliconScope's
//             viewer decodes this JSON (MachineMetrics.swift); the Mac agent emits the same shape.
//  Notes:     Moved here from the agent's main.go unchanged — field names and JSON tags are the
//             wire, so renaming one breaks every viewer in the field. Absence is part of the
//             schema: a pointer or omitempty field that is missing means "not reported", never 0,
//             and every slice is sent as [] rather than nil (a nil slice marshals to `null`,
//             which made GPU-less machines vanish from the viewer, #33). TemperatureC and the
//             watts on GPU are plain numbers: nvidia-smi's unsupported values arrive as 0 there.
//
package collect

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

// CPU is the whole processor: its usage over a 200 ms window and the 1-minute load average.
type CPU struct {
	Cores        int     `json:"cores"`
	UsagePercent float64 `json:"usagePercent"`
	LoadAvg1     float64 `json:"loadAvg1"`
	// Model name, e.g. "AMD Ryzen 9 5950X". Omitted when /proc/cpuinfo does not say, rather than
	// guessed — the viewer renders no name at all instead of asserting one it was not given.
	Model string `json:"model,omitempty"`
}

// Memory is physical memory in bytes.
type Memory struct {
	TotalBytes     int64 `json:"totalBytes"`
	UsedBytes      int64 `json:"usedBytes"`
	AvailableBytes int64 `json:"availableBytes"`
}

// GPUProc is one process's memory on one GPU.
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

// GPU is one NVIDIA card as nvidia-smi reports it.
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

	// The card's own temperature limits, as its driver states them (gpu_limits.go): it shuts down
	// at ShutdownTempC, halves its clocks at SlowdownTempC, and is specified up to
	// MaxOperatingTempC; TargetTempC is what its fan curve aims for. Omitted when not reported.
	ShutdownTempC     *float64 `json:"shutdownTempC,omitempty"`
	SlowdownTempC     *float64 `json:"slowdownTempC,omitempty"`
	MaxOperatingTempC *float64 `json:"maxOperatingTempC,omitempty"`
	TargetTempC       *float64 `json:"targetTempC,omitempty"`
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
	// Network is true for a filesystem served by another machine (NFS, SMB, sshfs), reported only
	// when Options.NetworkMounts asks for them (netmounts_linux.go). Its sizes are from the last
	// time its server answered, at most a minute or so ago.
	Network bool `json:"network,omitempty"`
	// Unresponsive is true when a network filesystem's server hasn't answered (it is down, or the
	// link is): TotalBytes and FreeBytes are then 0 and mean unknown, not empty.
	Unresponsive bool `json:"unresponsive,omitempty"`
}

// LLMModel is one model a runtime has, by name and size on disk.
type LLMModel struct {
	Name      string `json:"name"`
	SizeBytes int64  `json:"sizeBytes"`
}

// Ollama is an Ollama server's models: those it has, and those loaded now.
type Ollama struct {
	Running bool       `json:"running"`
	Models  []LLMModel `json:"models"`
	Loaded  []LLMModel `json:"loaded"`
}

// LLM is what the local LLM runtimes report.
type LLM struct {
	Ollama *Ollama `json:"ollama,omitempty"`
	// The runtime's own count of its own decode rate, when it publishes one. Absent rather than
	// zero when no runtime exposes it — a missing measurement and a measured 0 tok/s are different
	// facts, and Ollama genuinely exposes nothing server-side. See tokenrate.go.
	Rate *TokenRate `json:"rate,omitempty"`
}

// TokenRate is one runtime's most recent decode rate.
type TokenRate struct {
	TokensPerSec float64 `json:"tokensPerSec"`
	Source       string  `json:"source"`            // "llama.cpp" | "lmstudio"
	Model        string  `json:"model,omitempty"`   // which model produced it, when known
	MeasuredAt   int64   `json:"measuredAt"`        // unix ms — how stale the number is
	TTFTSec      float64 `json:"ttftSec,omitempty"` // time to first token (LM Studio reports it)
}
