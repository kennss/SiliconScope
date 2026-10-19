//go:build linux || windows

//
//  File:      gpu_extended_test.go
//  Created:   2026-09-29
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for choosing and reading the extended NVIDIA fields.
//  Notes:     The help excerpt and values follow `nvidia-smi` on driver 595 with an RTX 3090
//             (kennt-Ubuntu). The package builds only for Linux/Windows: from a Mac, run
//             `GOOS=linux go test -c` and execute the binary on a Linux box.
//
package collect

import (
	"reflect"
	"testing"
)

const helpExcerpt = `List of valid properties to query for the switch "--query-gpu":

"fan.speed"
The fan speed value is the percent of maximum speed.

"pstate"
The current performance state for the GPU.

"clocks_event_reasons.sw_power_cap" or "clocks_throttle_reasons.sw_power_cap"
SW Power Scaling algorithm is reducing the clocks below requested clocks.

"utilization.memory"
Percent of time over the past sample period during which global (device) memory was being read or written.

"clocks.current.sm" or "clocks.sm"
Current frequency of SM (Streaming Multiprocessor) clock.
`

func TestHelpParsingFindsEveryAlias(t *testing.T) {
	got := supportedGPUFields(helpExcerpt)
	for _, want := range []string{"fan.speed", "pstate", "clocks_event_reasons.sw_power_cap",
		"clocks_throttle_reasons.sw_power_cap", "utilization.memory", "clocks.current.sm", "clocks.sm"} {
		if !got[want] {
			t.Errorf("missing %q", want)
		}
	}
	if got["switch"] || got["--query-gpu"] {
		t.Error("prose picked up as a field name")
	}
}

// A driver older than 530 knows only the throttle_reasons spelling. It must be chosen, not dropped.
func TestResolvePrefersNewNamesAndFallsBackToOld(t *testing.T) {
	newDriver := resolveGPUFields(map[string]bool{"clocks_event_reasons.sw_power_cap": true, "clocks_throttle_reasons.sw_power_cap": true})
	oldDriver := resolveGPUFields(map[string]bool{"clocks_throttle_reasons.sw_power_cap": true})
	if len(newDriver) != 1 || newDriver[0].name != "clocks_event_reasons.sw_power_cap" {
		t.Errorf("new driver: %+v", newDriver)
	}
	if len(oldDriver) != 1 || oldDriver[0].name != "clocks_throttle_reasons.sw_power_cap" {
		t.Errorf("old driver: %+v", oldDriver)
	}
	if got := resolveGPUFields(map[string]bool{}); got != nil {
		t.Errorf("nothing supported should resolve to nothing, got %+v", got)
	}
}

func TestApplyExtendedReadsValuesAndLeavesUnreportedOut(t *testing.T) {
	fields := []resolvedField{
		{"memUtil", "utilization.memory"}, {"smClock", "clocks.sm"}, {"smClockMax", "clocks.max.sm"},
		{"pstate", "pstate"}, {"fan", "fan.speed"}, {"enc", "utilization.encoder"},
		{"throttle.powerCap", "clocks_event_reasons.sw_power_cap"},
		{"throttle.hwThermal", "clocks_event_reasons.hw_thermal_slowdown"},
	}
	var g GPU
	applyExtended(&g, fields, []string{"9", "1830", "2130", "P2", "[N/A]", "0", "Active", "Not Active"})
	if g.MemUtilPercent == nil || *g.MemUtilPercent != 9 {
		t.Errorf("memUtil = %v", g.MemUtilPercent)
	}
	if g.SMClockMHz == nil || *g.SMClockMHz != 1830 || g.SMClockMaxMHz == nil || *g.SMClockMaxMHz != 2130 {
		t.Error("clocks")
	}
	if g.PState == nil || *g.PState != "P2" {
		t.Errorf("pstate = %v", g.PState)
	}
	if g.FanPercent != nil {
		t.Error("[N/A] fan must be omitted, not 0")
	}
	if g.EncoderPercent == nil || *g.EncoderPercent != 0 {
		t.Error("a real 0 % encoder must be kept")
	}
	if g.ThrottleReasons == nil || !reflect.DeepEqual(*g.ThrottleReasons, []string{"power cap"}) {
		t.Errorf("throttle = %v", g.ThrottleReasons)
	}
}

// Nothing active is a fact ([]); no throttle field answered is not knowing (nil).
func TestThrottleNoneVersusUnknown(t *testing.T) {
	f := []resolvedField{{"throttle.powerCap", "x"}}
	var none, unknown GPU
	applyExtended(&none, f, []string{"Not Active"})
	applyExtended(&unknown, f, []string{"[N/A]"})
	if none.ThrottleReasons == nil || len(*none.ThrottleReasons) != 0 {
		t.Error("nothing active should be an empty, present list")
	}
	if unknown.ThrottleReasons != nil {
		t.Error("an unanswered reason must leave the list absent")
	}
}

// The umbrella "hardware slowdown" is dropped when its specific cause is named.
func TestHardwareSlowdownUmbrellaYieldsToItsCause(t *testing.T) {
	f := []resolvedField{{"throttle.hwThermal", "a"}, {"throttle.hw", "b"}}
	var g GPU
	applyExtended(&g, f, []string{"Active", "Active"})
	if !reflect.DeepEqual(*g.ThrottleReasons, []string{"thermal (hardware)"}) {
		t.Errorf("got %v", *g.ThrottleReasons)
	}
}
