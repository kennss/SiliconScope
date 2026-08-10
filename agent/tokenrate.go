//
//  File:      tokenrate.go
//  Created:   2026-08-10
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads the decode rate (tokens/sec) of whatever local LLM runtime is serving on this
//             machine, so a Fleet view can show how fast a remote box is actually generating —
//             not an estimate derived from bandwidth, but the runtime's own count of its own work.
//  Notes:     Two sources, because the runtimes disagree about how to expose it:
//               - llama.cpp server (and anything wearing its API) publishes
//                 `llamacpp:predicted_tokens_seconds` on /metrics when started with `--metrics`.
//                 A plain HTTP poll; works in one-shot mode.
//               - LM Studio publishes nothing over HTTP, but `lms log stream --json --stats` emits
//                 a `stats` object per completed prediction carrying `tokensPerSecond`. That is a
//                 PUSH stream, so it needs a long-lived reader — only available under `--serve`.
//             ⚠️ Both are measurements of REAL traffic, so both are stale between requests. The
//             wire carries `measuredAt` for exactly that reason: a rate with no timestamp invites
//             the reader to believe it is current. Ollama exposes no server-side rate at all (its
//             embedded llama-server is built without --metrics), so it is absent here by fact,
//             not by omission.
//
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// TokenRate is one runtime's most recent decode rate.
type TokenRate struct {
	TokensPerSec float64 `json:"tokensPerSec"`
	Source       string  `json:"source"`            // "llama.cpp" | "lmstudio"
	Model        string  `json:"model,omitempty"`   // which model produced it, when known
	MeasuredAt   int64   `json:"measuredAt"`        // unix ms — how stale the number is
	TTFTSec      float64 `json:"ttftSec,omitempty"` // time to first token (LM Studio reports it)
}

// MARK: - llama.cpp server — Prometheus /metrics

// llamaCppPorts are the ports a llama.cpp-compatible server is conventionally reachable on.
// 8080 is llama-server's default; 8081 is the usual second instance.
var llamaCppPorts = []int{8080, 8081}

// readLlamaCppRate polls /metrics for the decode-rate gauge. Returns nil unless a server answers
// AND was started with `--metrics` — without that flag the endpoint 501s, which is not an error
// worth reporting, just an absence.
func readLlamaCppRate() *TokenRate {
	client := http.Client{Timeout: 2 * time.Second}
	for _, port := range llamaCppPorts {
		resp, err := client.Get(fmt.Sprintf("http://localhost:%d/metrics", port))
		if err != nil {
			continue
		}
		body := make([]byte, 64*1024)
		n, _ := resp.Body.Read(body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			continue
		}
		if v, ok := parsePrometheus(string(body[:n]), "llamacpp:predicted_tokens_seconds"); ok {
			return &TokenRate{
				TokensPerSec: v,
				Source:       "llama.cpp",
				MeasuredAt:   time.Now().UnixMilli(),
			}
		}
	}
	return nil
}

// parsePrometheus pulls one gauge out of a Prometheus text exposition. Comment lines (# HELP /
// # TYPE) carry the same key and must not be read as samples.
func parsePrometheus(text, key string) (float64, bool) {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || !strings.HasPrefix(line, key) {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if v, err := strconv.ParseFloat(fields[len(fields)-1], 64); err == nil {
			return v, true
		}
	}
	return 0, false
}

// MARK: - LM Studio — `lms log stream --json --stats`

// lmStudioWatcher holds the most recent prediction stats seen on the log stream.
//
// LM Studio reports a rate only when a prediction FINISHES, so this is inherently a "last known"
// value rather than a live gauge. Keeping it behind a mutex lets the sampler read it at any moment
// without blocking the stream, and the timestamp lets the UI decide when it has gone stale.
type lmStudioWatcher struct {
	mu    sync.RWMutex
	rate  *TokenRate
	start sync.Once
}

var lmStudio = &lmStudioWatcher{}

// latest returns a copy of the last observed rate, or nil if nothing has been seen yet.
func (w *lmStudioWatcher) latest() *TokenRate {
	w.mu.RLock()
	defer w.mu.RUnlock()
	if w.rate == nil {
		return nil
	}
	r := *w.rate
	return &r
}

// lmsBinary locates the LM Studio CLI. It is not on PATH by default — the installer drops it in
// ~/.lmstudio/bin — so check both rather than requiring the user to have fixed their shell.
func lmsBinary() string {
	if p, err := exec.LookPath("lms"); err == nil {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	p := filepath.Join(home, ".lmstudio", "bin", "lms")
	if st, err := os.Stat(p); err == nil && !st.IsDir() {
		return p
	}
	return ""
}

// watchLMStudio starts the log stream and keeps it running for the life of the process.
//
// Only meaningful under `--serve`: a one-shot snapshot exits before any prediction could complete,
// and starting a child process just to kill it would be pure cost. The stream is restarted with a
// backoff if LM Studio quits, so an agent that outlives the app still recovers when it returns.
func watchLMStudio() {
	lmStudio.start.Do(func() {
		bin := lmsBinary()
		if bin == "" {
			return
		}
		go func() {
			for {
				runLMStudioStream(bin)
				time.Sleep(15 * time.Second) // LM Studio not running (or it died) — retry, quietly
			}
		}()
	})
}

func runLMStudioStream(bin string) {
	cmd := exec.Command(bin, "log", "stream", "--json", "--stats")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if cmd.Start() != nil {
		return
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024) // a prediction line carries the full output
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "{") {
			continue // the stream opens with a human-readable banner
		}
		var ev struct {
			Timestamp int64 `json:"timestamp"`
			Data      struct {
				Type            string `json:"type"`
				ModelIdentifier string `json:"modelIdentifier"`
				Stats           *struct {
					TokensPerSecond     float64 `json:"tokensPerSecond"`
					TimeToFirstTokenSec float64 `json:"timeToFirstTokenSec"`
				} `json:"stats"`
			} `json:"data"`
		}
		if json.Unmarshal([]byte(line), &ev) != nil || ev.Data.Stats == nil {
			continue
		}
		if ev.Data.Stats.TokensPerSecond <= 0 {
			continue // a cancelled prediction reports zero; that is not a measurement
		}
		at := ev.Timestamp
		if at == 0 {
			at = time.Now().UnixMilli()
		}
		lmStudio.mu.Lock()
		lmStudio.rate = &TokenRate{
			TokensPerSec: ev.Data.Stats.TokensPerSecond,
			Source:       "lmstudio",
			Model:        ev.Data.ModelIdentifier,
			MeasuredAt:   at,
			TTFTSec:      ev.Data.Stats.TimeToFirstTokenSec,
		}
		lmStudio.mu.Unlock()
	}
}

// MARK: - Selection

// readTokenRate returns the rate to publish this sample, preferring the live HTTP source over the
// remembered stream one: llama.cpp's gauge is current by construction, whereas LM Studio's is the
// last prediction, which may be hours old.
func readTokenRate() *TokenRate {
	if r := readLlamaCppRate(); r != nil {
		return r
	}
	return lmStudio.latest()
}
