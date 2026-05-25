# Opus

Native macOS quick-terminal multiplexer built for **Claude Code** — but happy to host any command you throw at it.

Opus opens as a slide-down panel from the top of the active screen (or as a full main window, your choice), backed by a custom Unix-socket multiplexer that mirrors a shared session between the panel and a Terminal.app window. Multi-tab, nested splits, event-driven resize, optional custom appearance. No tmux, no dtach, no Hammerspoon — ~3MB bundle, 100% native Swift + SwiftTerm.

## Features

- **Four display modes** — pick how Opus shows up:
  - **Terminal.app + Quick Terminal** (default) — native Terminal window + slide-down panel, mirrored live.
  - **Quick Terminal + Main Window** — slide-down panel + a permanent NSWindow, mirrored live, no Terminal.app.
  - **Quick Terminal only** — just the slide-down panel.
  - **Main Window only** — just the standalone NSWindow.

  In every mode, all visible surfaces share the same Claude session (tab 0 of each subscribes to one `ClaudeBackend` broadcaster). Type in any surface — output appears everywhere.
- **Slide-down panel** (`Cmd+Ctrl+T`) — non-activating NSPanel, native blur, follows the active macOS Space, persists its size per display.
- **Main window** (`Cmd+Ctrl+M`) — standard NSWindow, fullscreen-capable, frame auto-saved across launches.
- **Multi-tab** — `Cmd+T` new private tab (own session), `Cmd+W` close current pane/tab, `Cmd+1..9` switch tab.
- **Splits** — `Cmd+D` side-by-side, `Cmd+Shift+D` top/bottom. Nested via `NSSplitView` (iTerm2 conventions).
- **Settings** (`Cmd+,`) — three tabs:
  - **General** — initial command (Claude / shell / custom), working directory.
  - **Appearance** — default blur / transparent / custom tint color / background image.
  - **Display** — choose between the four display modes above.
- **First-launch onboarding** — bundles macOS permission prompts upfront so they don't surprise you mid-session.
- **Session-ended overlay** — when Claude exits and there are no other live panes, you get a centered "Start new session" / "Close Opus" prompt instead of a frozen dead terminal.
- **Event-driven resize** — `opus-attach` reports SIGWINCH via a self-pipe; the broadcaster ioctls the master PTY and SIGWINCHes the child on focus change. No polling.
- **Cursor stays visible in Claude's TUI** — DECTCEM hide/show sequences (`\e[?25l` / `\e[?25h`) are filtered out before reaching SwiftTerm so the caret doesn't disappear inside the panel.

## Build

```bash
./build.sh
```

Produces `Opus.app` next to the script and installs `opus-attach` to `~/.local/bin/`. Move `Opus.app` to `~/Applications/` and run.

```bash
cp -R Opus.app ~/Applications/
codesign --force --sign - --deep ~/Applications/Opus.app
open ~/Applications/Opus.app
```

Pin to the Dock once it's running.

## Wire-up in your shell

Add to your `~/.zshrc` so `claude` in Terminal.app auto-attaches to the panel's session when Opus is running:

```zsh
claude() {
    if [ -S /tmp/opus.sock ]; then
        exec opus-attach
    else
        command claude "$@"
    fi
}
```

## Architecture

```
Opus.app
├── ClaudeBackend (singleton, owns child PTY via SwiftTerm LocalProcess)
│     └── multi-subscriber broadcast — same bytes to every client
├── OpusPreferences (UserDefaults singleton)
├── QuickTerminalPanel (NSPanel) → embeds TerminalContainerView
├── MainTerminalWindow (NSWindow) → embeds TerminalContainerView
├── TerminalContainerView (shared NSView — tabs + panes + splits + tab bar)
│     ├── tab 0 → ClaudeBackend subscriber (shared with every other live surface)
│     ├── private panes (Cmd+T tabs, splits) → FilteredClaudeTab, own PTY
│     └── splits via NSSplitView (nested, axis-mixed)
├── SettingsWindowController (General / Appearance / Display tabs)
├── OnboardingWindowController (first-launch TCC prompts)
└── SocketServer (/tmp/opus.sock, only when displayMode includes Terminal.app)
      └── opus-attach clients — Terminal.app windows
```

The 9-byte control protocol prefix: `ESC O p u s + cols(2 BE) + rows(2 BE)`. Sent client → server on initial connect and every SIGWINCH.

For deeper internals (PTY ownership model, NSPanel macOS 14+ quirks, NSSplitView pitfalls, AZERTY keyboard handling), see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requirements

- macOS 13+
- Swift 5.9+ (Xcode 15+)
- `claude` CLI in `$PATH` (only if you keep the default Claude preset; pick "Interactive shell" or a custom command in Settings if you want Opus as a general drop-down terminal)
- A Nerd Font (`MesloLGS NF` recommended) for proper rendering, falls back to SF Mono / Menlo

## Status

Personal project shipped by [@Stark-52](https://github.com/Stark-52). Battle-tested on macOS Tahoe (26.x) with French AZERTY layout. Pull requests welcome but not actively solicited. Bug reports via GitHub Issues are read.

## License

MIT — see [LICENSE](LICENSE).
