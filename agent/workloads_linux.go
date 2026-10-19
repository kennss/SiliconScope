//go:build linux

//
//  File:      workloads_linux.go
//  Created:   2026-09-29
//  Updated:   2026-10-18
//  Developer: Kennt Kim / Calida Lab
//  Overview:  What is running on a Linux GPU box besides the model server: Docker containers
//             (read from the Engine API over its unix socket, restart counts included), which
//             container a GPU process belongs to, the account it runs as, and a ComfyUI
//             server's queue.
//  Notes:     Docker is read through its Engine API, not by running the CLI: the service is
//             hardened, and the API is what the CLI itself uses. By default that is
//             /var/run/docker.sock, which needs the `docker` group — root in all but name, since it
//             can start a container that mounts the host. DOCKER_HOST=tcp://127.0.0.1:PORT points
//             the agent at a read-only socket proxy instead, so it runs as an unprivileged user.
//             Unreachable either way, containers are reported as unknown (nil), never as none.
//             ComfyUI is asked only when a ComfyUI process is SEEN on the host, on the port in its
//             own argv (#53: observe the process, don't poll the neighbourhood). A ComfyUI inside a
//             container is skipped: asking localhost for it would reach whatever the host serves on
//             that port and credit the answer to the wrong server.
//
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// dockerEndpoint reads DOCKER_HOST the way the Docker CLI does: unix:///path for a socket,
// tcp://host:port for an HTTP endpoint (a read-only socket proxy, so the agent needs neither root
// nor the docker group, which is root in all but name). Unset means the local socket. Pure, for
// testing.
func dockerEndpoint(dockerHost string) (network, address string) {
	switch {
	case strings.HasPrefix(dockerHost, "tcp://"):
		return "tcp", strings.TrimPrefix(dockerHost, "tcp://")
	case strings.HasPrefix(dockerHost, "unix://"):
		return "unix", strings.TrimPrefix(dockerHost, "unix://")
	default:
		return "unix", "/var/run/docker.sock"
	}
}

var dockerClient = func() *http.Client {
	network, address := dockerEndpoint(os.Getenv("DOCKER_HOST"))
	return &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, address)
		}},
	}
}()

var (
	containersMu     sync.Mutex
	containersAt     time.Time
	containersCached *[]Container
	containerIDs     map[string]string // full container id -> name, for GPU process attribution
)

// readContainers lists running containers, refreshed every 10 s (each refresh inspects every
// container for its restart count). nil = Docker isn't reachable; [] = it is, and runs nothing.
func readContainers() *[]Container {
	containersMu.Lock()
	defer containersMu.Unlock()
	if time.Since(containersAt) < 10*time.Second {
		return containersCached
	}
	containersAt = time.Now()
	containersCached, containerIDs = nil, map[string]string{}

	var list []struct {
		ID     string   `json:"Id"`
		Names  []string `json:"Names"`
		Image  string   `json:"Image"`
		State  string   `json:"State"`
		Status string   `json:"Status"`
	}
	if !dockerGet("/containers/json", &list) {
		return nil
	}
	out := []Container{}
	for _, c := range list {
		name := c.ID[:min(12, len(c.ID))]
		if len(c.Names) > 0 {
			name = strings.TrimPrefix(c.Names[0], "/")
		}
		ct := Container{Name: name, Image: c.Image, State: c.State, Status: c.Status}
		var inspect struct {
			RestartCount *int `json:"RestartCount"`
		}
		if dockerGet("/containers/"+c.ID+"/json", &inspect) {
			ct.RestartCount = inspect.RestartCount
		}
		out = append(out, ct)
		containerIDs[c.ID] = name
	}
	containersCached = &out
	return containersCached
}

func dockerGet(path string, into any) bool {
	resp, err := dockerClient.Get("http://docker" + path)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	return json.NewDecoder(resp.Body).Decode(into) == nil
}

var containerIDInCgroup = regexp.MustCompile(`[0-9a-f]{64}`)

// containerID is the container a process runs in, from its cgroup path, or "" for the host.
func containerID(pid int) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cgroup", pid))
	if err != nil {
		return ""
	}
	return containerIDInCgroup.FindString(string(b))
}

// containerOf names the container a GPU process belongs to, "" when it runs on the host or in a
// container Docker didn't list.
func containerOf(pid int) string {
	id := containerID(pid)
	if id == "" {
		return ""
	}
	containersMu.Lock()
	defer containersMu.Unlock()
	return containerIDs[id]
}

// describeProc turns nvidia-smi's process name into something a person can tell apart. nvidia-smi
// reports argv[0] as launched, so `bin/python halluc_bench.py` run from ~/whisper-bench arrives as
// "bin/python" — no project in it. A relative name is resolved against the process's working
// directory, and the script it runs (the first *.py argument) is reported alongside.
func describeProc(pid int, name string) (path, script string) {
	path = name
	if !strings.HasPrefix(name, "/") {
		if cwd := readlink(fmt.Sprintf("/proc/%d/cwd", pid)); cwd != "" {
			path = filepath.Join(cwd, name)
		}
	}
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err == nil {
		script = scriptOf(strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00"))
	}
	return path, script
}

// scriptOf is the Python script an interpreter's argv runs, by file name; "" when there is none
// (`python -m module`, or not Python at all). Pure, for testing.
func scriptOf(args []string) string {
	if len(args) < 2 || !strings.HasPrefix(filepath.Base(args[0]), "python") {
		return ""
	}
	for _, a := range args[1:] {
		if strings.HasPrefix(a, "-") {
			if a == "-m" || a == "-c" {
				return "" // a module or inline code: no script file to name
			}
			continue
		}
		if strings.HasSuffix(a, ".py") {
			return filepath.Base(a)
		}
		return ""
	}
	return ""
}

// MARK: - Process owner

var (
	userNamesMu sync.Mutex
	userNames   = map[string]string{} // uid → name, only for uids that resolved
)

// processUser is the account a process runs as: the real uid in /proc/<pid>/status, by name when
// the system's user database knows it (os/user reads /etc/passwd in this cgo-free build, so a
// directory-only account such as LDAP stays a number), else the uid itself. "" when the status
// file can't be read — the process has exited, or /proc hides it (hidepid).
func processUser(pid int) string {
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return ""
	}
	uid, ok := realUID(string(raw))
	if !ok {
		return ""
	}
	userNamesMu.Lock()
	defer userNamesMu.Unlock()
	if name, ok := userNames[uid]; ok {
		return name
	}
	if u, err := user.LookupId(uid); err == nil && u.Username != "" {
		userNames[uid] = u.Username
		return u.Username
	}
	return uid // not cached: an account added later is named on a later sample
}

// realUID is the first (real) uid of the "Uid:" line of a /proc/<pid>/status file. Pure, for
// testing.
func realUID(status string) (string, bool) {
	for _, line := range strings.Split(status, "\n") {
		rest, ok := strings.CutPrefix(line, "Uid:")
		if !ok {
			continue
		}
		f := strings.Fields(rest)
		if len(f) == 0 {
			return "", false
		}
		if _, err := strconv.Atoi(f[0]); err != nil {
			return "", false
		}
		return f[0], true
	}
	return "", false
}

// MARK: - ComfyUI

var (
	comfyMu   sync.Mutex
	comfyAt   time.Time
	comfyPort int // 0 = no host ComfyUI seen at the last scan
)

// findComfyUIPort scans the process table (every 10 s) for a ComfyUI server on the host and
// returns the port from its argv (--port N), or its default 8188. 0 when none is running.
func findComfyUIPort() int {
	comfyMu.Lock()
	defer comfyMu.Unlock()
	if time.Since(comfyAt) < 10*time.Second {
		return comfyPort
	}
	comfyAt, comfyPort = time.Now(), 0
	dirs, _ := filepath.Glob("/proc/[0-9]*")
	for _, d := range dirs {
		raw, err := os.ReadFile(d + "/cmdline")
		if err != nil || len(raw) == 0 {
			continue
		}
		args := strings.Split(strings.TrimRight(string(raw), "\x00"), "\x00")
		if port, ok := comfyUIPort(args, readlink(d+"/cwd")); ok {
			pid, _ := strconv.Atoi(filepath.Base(d))
			if containerID(pid) != "" {
				continue // inside a container: localhost would not reach it
			}
			comfyPort = port
			break
		}
	}
	return comfyPort
}

func readlink(p string) string { s, _ := os.Readlink(p); return s }

// comfyUIPort decides whether argv is a ComfyUI server — a `main.py` run from, or naming, a ComfyUI
// directory — and which port it serves on. Pure, for testing.
func comfyUIPort(args []string, cwd string) (int, bool) {
	hasMain := false
	for _, a := range args {
		if a == "main.py" || strings.HasSuffix(a, "/main.py") {
			hasMain = true
		}
	}
	if !hasMain {
		return 0, false
	}
	joined := strings.ToLower(strings.Join(args, " ") + " " + cwd)
	if !strings.Contains(joined, "comfyui") {
		return 0, false
	}
	port := 8188
	for i, a := range args {
		if a == "--port" && i+1 < len(args) {
			if p, err := strconv.Atoi(args[i+1]); err == nil {
				port = p
			}
		} else if strings.HasPrefix(a, "--port=") {
			if p, err := strconv.Atoi(strings.TrimPrefix(a, "--port=")); err == nil {
				port = p
			}
		}
	}
	return port, true
}

var comfyHTTP = &http.Client{Timeout: 2 * time.Second}

// readComfyUI asks a seen ComfyUI for its queue. nil when none is running or it doesn't answer.
func readComfyUI() *ComfyUI {
	port := findComfyUIPort()
	if port == 0 {
		return nil
	}
	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	var q struct {
		Running []json.RawMessage `json:"queue_running"`
		Pending []json.RawMessage `json:"queue_pending"`
	}
	if !httpGetJSON(base+"/queue", &q) {
		return nil
	}
	c := &ComfyUI{Port: port, Running: len(q.Running), Pending: len(q.Pending)}
	var st struct {
		System struct {
			Version string `json:"comfyui_version"`
		} `json:"system"`
	}
	if httpGetJSON(base+"/system_stats", &st) {
		c.Version = st.System.Version
	}
	return c
}

func httpGetJSON(url string, into any) bool {
	resp, err := comfyHTTP.Get(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	return json.NewDecoder(resp.Body).Decode(into) == nil
}
