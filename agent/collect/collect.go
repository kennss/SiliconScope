//
//  File:      collect.go
//  Created:   2026-10-19
//  Updated:   2026-10-19
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Package collect reads one machine's metrics — CPU, memory, disks, NVIDIA GPUs and the
//             processes on each card, Docker containers, the local LLM runtime and a ComfyUI queue —
//             as the MachineMetrics wire schema. sscope-agent (package main beside this one) serves
//             it to SiliconScope's Fleet; SiliconDesk's host links it and samples in process.
//  Notes:     This file and types.go build everywhere, so a caller on an unsupported platform (a Mac
//             running its tests) still compiles: there New returns ErrUnsupported. The readers
//             themselves exist for Linux and Windows only (collector.go and the *_linux/_windows
//             files). Nothing here knows about tokens, TLS, mDNS or HTTP serving — that is the
//             agent's — and nothing reads the environment: the caller passes what it wants in
//             Options. A Collector is safe for concurrent Collect calls (the agent serves several
//             viewers at once).
//
package collect

import "errors"

// ErrUnsupported is returned by New on a platform the readers don't cover (anything but Linux and
// Windows). The Mac's own collector is Swift (sscope-agent-mac), not this package.
var ErrUnsupported = errors.New("collect: metrics are not collected on this platform")

// Options is what a caller decides about a Collector.
type Options struct {
	// Version is reported as MachineMetrics.AgentVersion: the version of the program collecting.
	Version string
	// DockerHost addresses the Docker Engine API the way DOCKER_HOST does: "unix:///path" for a
	// socket, "tcp://host:port" for an endpoint such as a read-only socket proxy. Empty means
	// /var/run/docker.sock, which needs the docker group.
	DockerHost string
	// WatchLMStudio keeps `lms log stream` running so LM Studio's decode rate can be reported. LM
	// Studio only reports a rate when a prediction finishes, so this is for a long-lived caller; a
	// one-shot sample would exit before anything is seen. Close stops it.
	WatchLMStudio bool
}
