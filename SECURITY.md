# Security Policy

## Reporting a Vulnerability

If you believe you've found a security issue in Opus, **please do not open a public issue**.

Email Andy Garcia at <andy@cblindspot.ai> with:

- A description of the issue and the impact you observed.
- Steps to reproduce (a minimal repro is ideal).
- Your suggested severity assessment (low / medium / high).
- Whether you'd like attribution in the fix commit / release notes.

Expected response time: best-effort within 7 days. Opus is a personal project; there's no SLA, but security reports take priority over feature work.

## Scope

In scope:

- The `Opus.app` GUI (Swift, embedded SwiftTerm).
- The `opus-attach` CLI client.
- The Unix domain socket protocol on `/tmp/opus.sock`.
- Build / install scripts.

Out of scope:

- Vulnerabilities in upstream dependencies (SwiftTerm, Apple frameworks) — please report those upstream and let me know so I can pin a patched version.
- Issues that require an attacker with local code execution as the same user (Opus already trusts the local user fully).
- Anything in Claude Code itself (report at https://github.com/anthropics/claude-code).

## Known Surface

- **`/tmp/opus.sock`** is a Unix domain socket with default umask-derived permissions. Any process running as the same user can connect to it and read/write the shared session. This is intentional for the multiplexer feature; if you want isolation, run Opus under a different user or switch to standalone pairing mode in Settings (which doesn't create the socket).
- **Custom command execution.** Opus shells out to `/bin/zsh -i -c "<command>"` where `<command>` is constructed from the user-configured initial command + working directory. The custom-command field in Settings is *executed*, not sandboxed. Any process with write access to the Opus preferences plist (`~/Library/Preferences/com.andygarcia.opus.plist`) can cause Opus to run arbitrary commands at next launch.
- **AppleScript automation.** `launchTerminalSession` uses AppleScript to control Terminal.app and to query its window size. The macOS Automation permission grants this.
- **No network exposure.** Opus does not listen on any TCP/UDP port. The Unix socket is local-filesystem only.
- **No telemetry.** No outbound network connections except whatever the user's spawned process itself initiates.

## Hardening Roadmap

- [ ] Per-user socket path with explicit `chmod 0700` after bind.
- [ ] Optional App Sandbox profile — currently disabled because the `/tmp` socket + AppleScript automation make it non-trivial.
- [ ] Signed releases with Apple notarization (currently ad-hoc signed for local install only).
- [ ] Optional plist file permission lockdown (`chmod 0600`) to mitigate the custom-command attack vector.
