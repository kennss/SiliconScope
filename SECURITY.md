# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's **"Report a vulnerability"** button
(this repository → **Security** → **Advisories**). For non-sensitive concerns, a regular issue
is fine. I aim to acknowledge reports within a few days.

## Security posture

SiliconScope is a **read-only system monitor**, designed to be low-trust by default:

- **No `sudo`, no privilege escalation.** It runs entirely as your user.
- **Nothing leaves your Mac.** No telemetry, no analytics, no outbound network calls. The only
  network it touches is *local* (`127.0.0.1`) and *opt-in*: reading the loaded model / tokens
  per second from an AI runtime you are already running. Off by default.
- **No execution of remote content.** Auto-updates are delivered by **Sparkle** and verified
  with an **EdDSA signature** before install; release DMGs are **Developer-ID signed and
  Apple-notarized**.
- It reads Apple **private frameworks** (IOReport / SMC / IOHID) to gather metrics — read-only —
  which is why it ships outside the Mac App Store. That private-API surface is isolated in a
  single C target (`CIOReport`) behind safe Swift wrappers.

## Supported versions

The latest release receives fixes. Building from source (`main`) is always supported.

## Verifying a build

You can build from source instead of trusting the binary:

```bash
xcrun swift build
```

Or verify a downloaded release:

```bash
spctl -a -vvv /Applications/SiliconScope.app   # expect: source=Notarized Developer ID
```
