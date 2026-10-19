//go:build linux || windows

//
//  File:      gpu_limits.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Each NVIDIA card's own temperature limits — shutdown, slowdown, maximum operating and
//             target — so a viewer can judge a temperature against the card instead of a fixed
//             guess (sdmon used 80/90 °C; an RTX 3090 slows at 95 °C and aims for 83 °C).
//  Notes:     --query-gpu has none of them (`temperature.gpu.tlimit` is a different, live reading,
//             and N/A on an RTX 3090), and `-q -d TEMPERATURE` can't be combined with -x. So the
//             full `nvidia-smi -q -x` (≈47 KB, ≈0.2 s on kennt-Ubuntu) is read, and only once: the
//             limits are fixed by the card and its VBIOS. It is read again when a card appears whose
//             UUID it hasn't seen, and a failed read is retried after a minute, not every sample.
//             "N/A" leaves a limit out; it is never sent as 0.
//
package collect

import (
	"context"
	"encoding/xml"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// gpuLimits is one card's temperature limits in °C; nil = not reported.
type gpuLimits struct {
	shutdown, slowdown, maxOperating, target *float64
}

// gpuLimitState is what a Collector knows of its cards' limits, by UUID.
type gpuLimitState struct {
	mu       sync.Mutex
	byUUID   map[string]gpuLimits
	failedAt time.Time // the last read that failed; the next waits a minute
}

// gpuLimitsRetry is how long after a failed read the limits are asked for again.
const gpuLimitsRetry = time.Minute

// apply fills each GPU's limits, reading them first when a card is new.
func (s *gpuLimitState) apply(ctx context.Context, gpus []GPU) {
	s.mu.Lock()
	defer s.mu.Unlock()
	missing := false
	for _, g := range gpus {
		if _, ok := s.byUUID[g.UUID]; g.UUID != "" && !ok {
			missing = true
		}
	}
	if missing && time.Since(s.failedAt) >= gpuLimitsRetry {
		out, err := exec.CommandContext(ctx, "nvidia-smi", "-q", "-x").Output()
		var limits map[string]gpuLimits
		if err == nil {
			limits, err = parseGPULimits(out)
		}
		if err != nil {
			if ctx.Err() == nil {
				s.failedAt = time.Now()
			}
		} else {
			s.byUUID = limits
		}
	}
	for i := range gpus {
		if l, ok := s.byUUID[gpus[i].UUID]; ok {
			gpus[i].ShutdownTempC, gpus[i].SlowdownTempC = l.shutdown, l.slowdown
			gpus[i].MaxOperatingTempC, gpus[i].TargetTempC = l.maxOperating, l.target
		}
	}
}

// parseGPULimits reads the temperature block of each <gpu> in `nvidia-smi -q -x`. Pure, for
// testing.
func parseGPULimits(xmlOut []byte) (map[string]gpuLimits, error) {
	var log struct {
		GPUs []struct {
			UUID        string `xml:"uuid"`
			Temperature struct {
				Shutdown     string `xml:"gpu_temp_max_threshold"`
				Slowdown     string `xml:"gpu_temp_slow_threshold"`
				MaxOperating string `xml:"gpu_temp_max_gpu_threshold"`
				Target       string `xml:"gpu_target_temperature"`
			} `xml:"temperature"`
		} `xml:"gpu"`
	}
	if err := xml.Unmarshal(xmlOut, &log); err != nil {
		return nil, err
	}
	out := make(map[string]gpuLimits, len(log.GPUs))
	for _, g := range log.GPUs {
		t := g.Temperature
		out[strings.TrimSpace(g.UUID)] = gpuLimits{
			shutdown: celsius(t.Shutdown), slowdown: celsius(t.Slowdown),
			maxOperating: celsius(t.MaxOperating), target: celsius(t.Target),
		}
	}
	return out, nil
}

// celsius reads "95 C"; nil for "N/A" or anything that isn't a number of degrees.
func celsius(s string) *float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(s), "C")), 64)
	if err != nil {
		return nil
	}
	return &v
}
