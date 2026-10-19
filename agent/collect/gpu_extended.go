//go:build linux || windows

//
//  File:      gpu_extended.go
//  Created:   2026-09-29
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  The NVIDIA fields beyond the basic nine: memory-controller utilisation (the
//             bandwidth signal), SM and memory clocks against their maxima, P-state, fan, NVENC /
//             NVDEC, and why the clocks are being held down. They answer on a GPU box the questions
//             SiliconScope asks of Apple Silicon: bandwidth-bound? boosting? throttled, and by what?
//  Notes:     nvidia-smi rejects the WHOLE query when one field is unknown, and field names change
//             across drivers (clocks_throttle_reasons.* became clocks_event_reasons.* in 530). So
//             the fields are chosen once from `nvidia-smi --help-query-gpu`, and a query that still
//             fails drops back to the basic nine for good. Losing the extras must never lose the
//             GPU (#33 was a whole machine vanishing over one field). "[N/A]" / "[Not Supported]"
//             mean the card doesn't report it: the field is omitted, never sent as 0. What was
//             chosen is kept per Collector (gpuFieldState), not per process.
//
package collect

import (
	"context"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// gpuField is one metric and the names drivers have used for it, newest first.
type gpuField struct {
	key   string
	names []string
}

var extendedGPUFields = []gpuField{
	{"memUtil", []string{"utilization.memory"}},
	{"smClock", []string{"clocks.current.sm", "clocks.sm"}},
	{"smClockMax", []string{"clocks.max.sm"}},
	{"memClock", []string{"clocks.current.memory", "clocks.mem"}},
	{"memClockMax", []string{"clocks.max.memory", "clocks.max.mem"}},
	{"pstate", []string{"pstate"}},
	{"fan", []string{"fan.speed"}},
	{"enc", []string{"utilization.encoder"}},
	{"dec", []string{"utilization.decoder"}},
	{"throttle.powerCap", []string{"clocks_event_reasons.sw_power_cap", "clocks_throttle_reasons.sw_power_cap"}},
	{"throttle.swThermal", []string{"clocks_event_reasons.sw_thermal_slowdown", "clocks_throttle_reasons.sw_thermal_slowdown"}},
	{"throttle.hwThermal", []string{"clocks_event_reasons.hw_thermal_slowdown", "clocks_throttle_reasons.hw_thermal_slowdown"}},
	{"throttle.powerBrake", []string{"clocks_event_reasons.hw_power_brake_slowdown", "clocks_throttle_reasons.hw_power_brake_slowdown"}},
	{"throttle.hw", []string{"clocks_event_reasons.hw_slowdown", "clocks_throttle_reasons.hw_slowdown"}},
}

// throttleNames are the reasons as the viewer shows them. "gpu_idle" is deliberately absent:
// an idle GPU running slow is not being held back.
var throttleNames = map[string]string{
	"throttle.powerCap":   "power cap",
	"throttle.swThermal":  "thermal (driver)",
	"throttle.hwThermal":  "thermal (hardware)",
	"throttle.powerBrake": "power brake",
	"throttle.hw":         "hardware slowdown",
}

type resolvedField struct{ key, name string }

// gpuFieldState is which extended fields this driver answers: chosen once from
// `--help-query-gpu`, and given up for good when a query with them fails.
type gpuFieldState struct {
	once     sync.Once
	fields   []resolvedField
	mu       sync.Mutex
	disabled bool
}

var quotedName = regexp.MustCompile(`"([a-z0-9_.]+)"`)

// supportedGPUFields parses `nvidia-smi --help-query-gpu`: every line naming a field starts with
// the quoted name, and aliases follow on the same line ("a" or "b").
func supportedGPUFields(help string) map[string]bool {
	out := map[string]bool{}
	for _, line := range strings.Split(help, "\n") {
		if !strings.HasPrefix(line, `"`) {
			continue
		}
		for _, m := range quotedName.FindAllStringSubmatch(line, -1) {
			out[m[1]] = true
		}
	}
	return out
}

// resolveGPUFields picks, for each metric, the first name this driver knows.
func resolveGPUFields(supported map[string]bool) []resolvedField {
	var out []resolvedField
	for _, f := range extendedGPUFields {
		for _, n := range f.names {
			if supported[n] {
				out = append(out, resolvedField{f.key, n})
				break
			}
		}
	}
	return out
}

// query is the extended fields to ask for this sample.
func (s *gpuFieldState) query(ctx context.Context) []resolvedField {
	s.once.Do(func() {
		help, err := exec.CommandContext(ctx, "nvidia-smi", "--help-query-gpu").Output()
		if err == nil {
			s.fields = resolveGPUFields(supportedGPUFields(string(help)))
		}
	})
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.disabled {
		return nil
	}
	return s.fields
}

// disable is called when a query with the extra fields fails: from then on only the basic nine
// are asked for, so a driver that chokes on one of them still reports its GPU.
func (s *gpuFieldState) disable() {
	s.mu.Lock()
	s.disabled = true
	s.mu.Unlock()
}

// optFloat reads a value nvidia-smi may decline to give. nil means "not reported", never 0.
func optFloat(s string) *float64 {
	s = strings.TrimSpace(s)
	if s == "" || strings.Contains(s, "N/A") || strings.Contains(s, "Not Supported") || strings.Contains(s, "Unknown") {
		return nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	return &v
}

func optString(s string) *string {
	s = strings.TrimSpace(s)
	if s == "" || strings.Contains(s, "N/A") || strings.Contains(s, "Not Supported") {
		return nil
	}
	return &s
}

// applyExtended fills a GPU from the values of the resolved fields, in query order.
func applyExtended(g *GPU, fields []resolvedField, values []string) {
	var reasons []string
	throttleKnown := false
	hwSub := false
	for i, f := range fields {
		if i >= len(values) {
			break
		}
		v := values[i]
		switch f.key {
		case "memUtil":
			g.MemUtilPercent = optFloat(v)
		case "smClock":
			g.SMClockMHz = optFloat(v)
		case "smClockMax":
			g.SMClockMaxMHz = optFloat(v)
		case "memClock":
			g.MemClockMHz = optFloat(v)
		case "memClockMax":
			g.MemClockMaxMHz = optFloat(v)
		case "pstate":
			g.PState = optString(v)
		case "fan":
			g.FanPercent = optFloat(v)
		case "enc":
			g.EncoderPercent = optFloat(v)
		case "dec":
			g.DecoderPercent = optFloat(v)
		default:
			name, ok := throttleNames[f.key]
			if !ok {
				continue
			}
			state := strings.TrimSpace(v)
			if state != "Active" && state != "Not Active" {
				continue // N/A: this reason isn't reported on this card
			}
			throttleKnown = true
			if state == "Active" {
				if f.key == "throttle.hwThermal" || f.key == "throttle.powerBrake" {
					hwSub = true
				}
				reasons = append(reasons, name)
			}
		}
	}
	if throttleKnown {
		// "hardware slowdown" is the umbrella for the thermal and power-brake cases; when one of
		// those is named, the umbrella adds nothing.
		if hwSub {
			kept := reasons[:0]
			for _, r := range reasons {
				if r != "hardware slowdown" {
					kept = append(kept, r)
				}
			}
			reasons = kept
		}
		if reasons == nil {
			reasons = []string{} // known and none active: [] on the wire, not omitted
		}
		g.ThrottleReasons = &reasons
	}
}
