//go:build linux || windows

//
//  File:      gpu_limits_test.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Tests for reading each card's temperature limits from `nvidia-smi -q -x`.
//  Notes:     GPU 0's block is real output of driver 595.84 on an RTX 3090 (kennt-Ubuntu), cut to
//             the elements read; GPU 1 is a fixture that reports none of them. Run on Linux
//             (`GOOS=linux go test -c`).
//
package collect

import "testing"

const limitsXML = `<?xml version="1.0" ?>
<!DOCTYPE nvidia_smi_log SYSTEM "nvsmi_device_v12.dtd">
<nvidia_smi_log>
	<driver_version>595.84</driver_version>
	<attached_gpus>2</attached_gpus>
	<gpu id="00000000:01:00.0">
		<product_name>NVIDIA GeForce RTX 3090</product_name>
		<uuid>GPU-d5a8caa7-b8c9-a066-415f-550d411855cb</uuid>
		<temperature>
			<gpu_temp>45 C</gpu_temp>
			<gpu_temp_tlimit>N/A</gpu_temp_tlimit>
			<gpu_temp_max_threshold>98 C</gpu_temp_max_threshold>
			<gpu_temp_slow_threshold>95 C</gpu_temp_slow_threshold>
			<gpu_temp_max_gpu_threshold>93 C</gpu_temp_max_gpu_threshold>
			<gpu_target_temperature>83 C</gpu_target_temperature>
			<memory_temp>N/A</memory_temp>
			<gpu_temp_max_mem_threshold>N/A</gpu_temp_max_mem_threshold>
		</temperature>
	</gpu>
	<gpu id="00000000:02:00.0">
		<uuid>GPU-0f6a1c2e-1111-2222-3333-444455556666</uuid>
		<temperature>
			<gpu_temp>41 C</gpu_temp>
			<gpu_temp_max_threshold>N/A</gpu_temp_max_threshold>
			<gpu_temp_slow_threshold>N/A</gpu_temp_slow_threshold>
		</temperature>
	</gpu>
</nvidia_smi_log>`

func TestParseGPULimitsByUUID(t *testing.T) {
	limits, err := parseGPULimits([]byte(limitsXML))
	if err != nil {
		t.Fatal(err)
	}
	l := limits["GPU-d5a8caa7-b8c9-a066-415f-550d411855cb"]
	for name, got := range map[string]*float64{"shutdown": l.shutdown, "slowdown": l.slowdown,
		"maxOperating": l.maxOperating, "target": l.target} {
		want := map[string]float64{"shutdown": 98, "slowdown": 95, "maxOperating": 93, "target": 83}[name]
		if got == nil || *got != want {
			t.Fatalf("%s = %v, want %v", name, got, want)
		}
	}
	none := limits["GPU-0f6a1c2e-1111-2222-3333-444455556666"]
	if none.shutdown != nil || none.slowdown != nil || none.maxOperating != nil || none.target != nil {
		t.Fatalf("a card that reports no limits must have none, got %+v", none)
	}
}

func TestApplyLeavesAnUnknownCardWithoutLimits(t *testing.T) {
	s := gpuLimitState{byUUID: map[string]gpuLimits{"GPU-a": {slowdown: celsius("95 C")}}}
	gpus := []GPU{{UUID: "GPU-a"}, {UUID: ""}}
	s.apply(t.Context(), gpus)
	if gpus[0].SlowdownTempC == nil || *gpus[0].SlowdownTempC != 95 {
		t.Fatalf("GPU-a slowdown = %v, want 95", gpus[0].SlowdownTempC)
	}
	if gpus[1].SlowdownTempC != nil {
		t.Fatal("a card without a UUID can't be matched and gets no limits")
	}
}

func TestCelsius(t *testing.T) {
	for in, want := range map[string]float64{"95 C": 95, " 83 C ": 83, "98": 98} {
		if got := celsius(in); got == nil || *got != want {
			t.Fatalf("celsius(%q) = %v, want %v", in, got, want)
		}
	}
	for _, in := range []string{"N/A", "", "Not Supported"} {
		if celsius(in) != nil {
			t.Fatalf("celsius(%q) must be nil", in)
		}
	}
}
