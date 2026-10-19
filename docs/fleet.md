# Fleet — user manual

Fleet shows your other machines in the same app as This Mac: a headless Mac mini, a Linux GPU box,
a cloud server. Each machine runs a small **agent** that the viewer reads over an encrypted, paired
connection. The agent is read-only: it reports what the machine is doing and cannot be told to do
anything.

- [What each machine shows](#what-each-machine-shows)
- [How the connection is protected](#how-the-connection-is-protected)
- [When it uses the network](#when-it-uses-the-network)
- [Adding a machine](#adding-a-machine)
  - [A Mac you sit at](#a-mac-you-sit-at)
  - [Any other machine: the installer](#any-other-machine-the-installer)
  - [A headless Mac](#a-headless-mac)
  - [A Linux GPU box](#a-linux-gpu-box)
  - [A cloud server (VPS)](#a-cloud-server-vps)
  - [An Intel Mac](#an-intel-mac)
  - [A Windows machine](#a-windows-machine)
- [Machines off your LAN](#machines-off-your-lan)
- [Managing machines](#managing-machines)
- [Installer options](#installer-options)
- [Troubleshooting](#troubleshooting)

## What each machine shows

| Machine | What you see |
|---|---|
| **Apple Silicon Mac** | The same dashboard as This Mac: E/P cores, GPU, **Neural Engine**, Media Engine, memory bandwidth, power, fans, temperatures. |
| **Linux with an NVIDIA card** | The card first: utilisation and VRAM, power against its limit, clocks, and why it is being held back (thermal, power cap). A box with several cards shows each one, and you pick the card the page below describes. Then what runs on it: which processes hold VRAM on that card (with the account they run as and their container), the AI runtime (Ollama models, LM Studio / llama.cpp decode rate, ComfyUI queue), and the containers. Then the host: CPU, memory, disks. |
| **Linux without a GPU** | Containers (with restart counts), AI runtime if one runs, CPU, memory, disks. |
| **Intel Mac** | CPU, memory, fans and temperatures. |
| **Windows** | CPU, memory, and an NVIDIA card through the same path Linux uses. |

A reading the machine doesn't have is left out, never shown as zero. A Pi has no GPU card on its
page; a fanless Mac says *fanless* instead of 0 rpm.

## How the connection is protected

- **TLS.** The agent makes its own certificate on first start. The viewer **pins** it the first time
  it connects, so a re-keyed or impersonated agent is refused instead of trusted.
- **A pairing token.** Every request carries it. Treat it like a password: anyone who has it can
  read that machine's metrics. The installer prints it inside the pairing link; don't paste that
  link anywhere public.
- **Nothing is exposed but metrics.** The agent answers `GET /metrics` (token required) and
  `GET /healthz`. It has no endpoint that changes anything.

## When it uses the network

**Only while fleet data is on screen.** Machines are polled when the SiliconScope window is visible
*and* it is showing them — the Devices sidebar is open (each row carries a machine's live summary),
or the Fleet overview or a machine's page is selected:

- **On screen:** every machine is polled every 3 seconds, over one connection per machine that
  stays open between polls, with the reply gzipped.
- **Not on screen** — the window closed, minimised or covered, or the sidebar collapsed while you
  look at This Mac: no machine is polled and every connection is closed. A machine you check once a
  day costs nothing the rest of the day. Finding machines on your LAN (mDNS) keeps running; it
  stays on your local network.
- **Back on screen:** polling resumes at once. The charts show a break where nothing was measured, so
  a reading from before and one from now are not drawn as if they were seconds apart.

Measured against a cloud agent, one minute each: 106 KB with the window open in 4.5.0 and earlier,
29 KB since (with the agent not yet sending gzip), nothing with the window closed. Update the
agents too: compression needs agent 1.4.0 or later on both platforms, and so does keeping the
connection open to a Mac agent (the Linux agent always kept it).

## Adding a machine

### A Mac you sit at

No install. On that Mac, open **SiliconScope → Settings → Share this Mac to Fleet**. It appears on
your other Macs on the same network; click it and enter the token shown under the toggle.

### Any other machine: the installer

One command, the same on Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh
```

- **Linux:** installs a systemd service (asks for `sudo`). Starts on boot.
- **macOS:** installs a LaunchAgent. No `sudo`, so it finishes unattended over `ssh`.

It ends by printing a **pairing link**:

```
sscope://pair?name=…&host=…&port=7799&token=…
```

In the app, click **Add machine…** at the bottom of the sidebar and paste the **whole link** into
the Host field. Name, address, port and token fill in, and the machine is added and paired in one
step. Copy the full line: double-clicking in a terminal selects only one word of it.

On your LAN, the machine also appears by itself (mDNS) with a lock; the link just pairs it.

### A headless Mac

Turn on **System Settings → General → Sharing → Remote Login** first, so you can `ssh` in. Then run
the installer over `ssh`.

### A Linux GPU box

Run the installer as the user who runs your AI tools; it asks for `sudo` itself. The service runs
as that user, so it can see an Ollama or ComfyUI you started yourself. `nvidia-smi` must be installed; without it the box shows as a machine with no GPU.

To see containers too, the agent needs to read Docker. See the next section for the safe way.

### A cloud server (VPS)

A droplet or VPS running a few services in Docker. Two things differ from a machine on your desk:

1. **Reach it over Tailscale.** Don't open the agent's port to the internet. Put the server and
   your Mac on the same [Tailscale](https://tailscale.com) network.
2. **Don't give the agent root.** Anyone who can read the Docker socket can start a container that
   mounts the host's disk, so the `docker` group is root in all but name. The agent only needs the
   container list, so give it exactly that through a read-only proxy.

```sh
# 1. A read-only Docker proxy that answers container listings and refuses everything else.
#    Bind it to 127.0.0.1: a port Docker publishes skips ufw, so 0.0.0.0 would put it on the internet.
docker run -d --name sscope-docker-proxy --restart unless-stopped \
  -e CONTAINERS=1 -e POST=0 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -p 127.0.0.1:2375:2375 tecnativa/docker-socket-proxy

# 2. The agent, as its own no-login user (created if missing), reading Docker through the proxy.
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh \
  | SSCOPE_USER=sscope SSCOPE_DOCKER_HOST=tcp://127.0.0.1:2375 sh

# 3. Open the agent's port to your tailnet only.
ufw allow in on tailscale0 to any port 7799 proto tcp
```

When the server is on a tailnet, the installer prints a **second** pairing link carrying its
Tailscale address. Paste that one: the first carries the public address, which step 3 keeps closed.

Skip step 1 on a server without Docker. Without step 2's variables the agent runs as the user who
ran the installer, which on a fresh droplet is root.

In the Tailscale admin console, consider **Disable key expiry** for the server, or it drops off
the tailnet (and out of your fleet) when its key expires.

### An Intel Mac

The installer works as on Apple Silicon. The agent reports CPU, memory, fans and temperatures. Neural
Engine, Media Engine, memory bandwidth and per-domain power are absent because the hardware doesn't
have them. The SiliconScope **app** itself remains Apple Silicon only.

### A Windows machine

No one-line installer yet. Build the agent with `GOOS=windows go build ./agent` and run it as a
scheduled task with `--serve :7799`. Print its token with `--print-token`, then add it in the app by
address. Windows has no load average, so that field stays empty rather than showing an invented
number, and disk capacity is not collected yet.

## Machines off your LAN

mDNS only reaches your local subnet. For anything else (Tailscale, a VPN, a cloud server), add the
machine by address in **Add machine…**: paste its pairing link, or type the address. Over Tailscale
that is its `100.x` address or MagicDNS name.

Prefer Tailscale or an SSH tunnel to opening port 7799 to the internet. The connection is encrypted
and token-protected either way, but a closed port can't be probed.

## Managing machines

Right-click a machine in the sidebar:

- **Rename…** — changes the label on this Mac only. The pairing is untouched.
- **Forget pairing** — deletes the token on this Mac. The machine stays listed as *pairing
  required*.
- **Remove machine** — removes it, its token and its pinned certificate. A machine that was found
  on the LAN keeps advertising itself, so it goes into **N removed** at the bottom of the sidebar,
  from where you can bring it back.

**Change a machine's token** (for example after it was pasted somewhere it shouldn't have been):

```sh
# Linux
sudo rm /var/lib/sscope-agent/token && sudo systemctl restart sscope-agent
sudo cat /var/lib/sscope-agent/token

# macOS agent
rm ~/Library/Application\ Support/SiliconScope/agent/token
launchctl kickstart -k gui/$(id -u)/ai.calidalab.sscope-agent
~/.local/bin/sscope-agent-mac --print-token
```

The machine turns *pairing required* in the app; click **Pair…** and enter the new token.

**Remove an agent** — run the installer with `--uninstall` on that machine. It stops the service
and deletes the binary, token, certificate and keychain. Then remove the machine in the app.

```sh
curl -fsSL https://raw.githubusercontent.com/kennss/SiliconScope/main/scripts/install-agent.sh | sh -s -- --uninstall
```

## Installer options

Set these in front of `sh`, e.g. `curl … | SSCOPE_PORT=7800 sh`.

| Variable | Default | What it does |
|---|---|---|
| `SSCOPE_PORT` | `7799` | Port the agent listens on. |
| `SSCOPE_USER` | the user running the installer | Linux: run the service as this user, created as a no-login system account if it doesn't exist. |
| `SSCOPE_DOCKER_HOST` | local socket | Linux: where the agent reads Docker, e.g. `tcp://127.0.0.1:2375` for a read-only proxy. |
| `SSCOPE_LOCAL_BIN` | download | Install this agent binary instead of downloading the latest release (offline installs). |
| `SSCOPE_REPO` | `kennss/SiliconScope` | Where releases are downloaded from. |

## Troubleshooting

**A machine on my LAN doesn't appear.**
- It must be on the **same subnet**; mDNS doesn't cross routers. Otherwise add it by address.
- On the viewer Mac: **System Settings → Privacy & Security → Local Network** must allow SiliconScope.
- On a Mac running the agent: **Lockdown Mode**, or a firewall set to **Block all incoming
  connections**, keeps the viewer out. Open **System Settings → Network → Firewall → Options**, turn
  that off, check that SiliconScope (or `sscope-agent-mac`) is allowed, and restart SiliconScope.
  Worked out by [@progenitor-amborella](https://github.com/progenitor-amborella) in
  [#63](https://github.com/kennss/SiliconScope/issues/63).

**Red dot, "An SSL error has occurred" (-1200 / -9802), on a Tailscale or VPN address.**
Update SiliconScope. Versions up to 4.4.0 applied macOS's certificate rules to non-local addresses
before checking the agent's pinned certificate, so any machine added by a `100.x` or VPN address
failed this way. LAN machines were unaffected.

**Red dot, "A server with the specified hostname could not be found".**
The Host field holds something that isn't an address. Most often only the token was pasted instead
of the whole `sscope://pair…` line. Remove the machine and paste the full link.

**It worked, and now it's refused after I reinstalled the agent.**
Reinstalling makes a new certificate, and the viewer refuses a certificate it didn't pin. That is
the protection working. Remove the machine, bring it back (or add it again), and pair.

**The machine shows *pairing required*.**
Its token changed or this Mac forgot it. Click **Pair…** and enter the current token (see *Change a
machine's token* above for how to read it).

**A GPU box shows no GPU.**
Check that `nvidia-smi` runs for the service's user: `sudo -u <user> nvidia-smi`.

**Containers don't show.**
The agent can't read Docker, and it says nothing about it: a machine it can't ask shows no
containers card. Check what it can reach as the service's user:

```sh
# Through the read-only proxy
curl -s http://127.0.0.1:2375/containers/json | head -c 200
# Through the socket (needs the docker group; see the VPS section for why the proxy is better)
sudo -u <user> curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json | head -c 200
```

A JSON list means Docker answers. Then check that the service was installed with the matching
`SSCOPE_DOCKER_HOST` (see [A cloud server (VPS)](#a-cloud-server-vps)).
