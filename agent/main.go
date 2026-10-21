//
//  File:      main.go
//  Created:   2026-07-21
//  Updated:   2026-10-21
//  Developer: Kennt Kim / Calida Lab
//  Overview:  SiliconScope fleet agent (Linux, Windows). Prints ONE MachineMetrics JSON to stdout,
//             or with --serve answers GET /metrics over TLS with a bearer token and advertises
//             itself over mDNS. This is the source-agnostic boundary the Mac aggregator consumes;
//             the Mac agent (sscope-agent-mac) emits the same shape. No cgo, so it cross-compiles
//             to a static single binary: CGO_ENABLED=0 GOOS=linux go build.
//  Notes:     What a sample contains is package collect's (agent/collect), which SiliconDesk's
//             host also links. This file is only the program around it: flags, the server, mDNS.
//             The serving side — token, TLS, the config dir — is security.go; gzip is compress.go.
//             DOCKER_HOST is read here and passed to the collector, so the service can point it at
//             a read-only socket proxy.
//
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/grandcat/zeroconf"

	"github.com/kennss/SiliconScope/agent/collect"
)

const agentVersion = "1.5.3"

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
	// Only in serve mode is LM Studio watched: it reports a rate when a prediction FINISHES, so a
	// one-shot snapshot would exit long before anything could be observed.
	collector, err := collect.New(collect.Options{
		Version:       agentVersion,
		DockerHost:    os.Getenv("DOCKER_HOST"),
		WatchLMStudio: *serve != "",
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if *serve != "" {
		runServer(*serve, collector)
		return
	}
	out, err := json.MarshalIndent(collector.Collect(context.Background()), "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "encode error:", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}

// runServer exposes GET /metrics (token-protected, a fresh sample per request) + GET /healthz
// (open, for discovery/liveness) over TLS. The Mac aggregator connects here directly, TOFU-pinning
// the self-signed cert (fingerprint advertised via mDNS) and sending the bearer token.
func runServer(addr string, collector *collect.Collector) {
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
		writeJSON(w, r, collector.Collect(r.Context()))
	}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})

	// Advertise on the LAN (with the cert fingerprint) so the Mac auto-discovers + TOFU-pins.
	if server := registerMDNS(portFromAddr(addr), fingerprint, collector); server != nil {
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
func registerMDNS(port int, fingerprint string, collector *collect.Collector) *zeroconf.Server {
	if port <= 0 {
		return nil
	}
	s := collector.Collect(context.Background())
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
