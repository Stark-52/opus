# Opus

Native macOS quick-terminal multiplexer built for **Claude Code** — but happy to host any command you throw at it.

Opus opens as a slide-down panel from the top of the active screen (or as a full main window, your choice), backed by a custom Unix-socket multiplexer that mirrors a shared session between the panel and a Terminal.app window. Multi-tab, nested splits, event-driven resize, optional custom appearance. No tmux, no dtach, no Hammerspoon — ~3MB bundle, 100% native Swift + SwiftTerm.

## Features

- **Slide-down panel** (`Cmd+Ctrl+T`) — non-activating NSPanel, native blur, follows the active macOS Space, persists its size per display.
- **Optional main window** (`Cmd+Ctrl+M`) — full NSWindow with the same tabs/splits, for users who prefer a permanent tiling workspace. Mix both modes if you want.
- **Shared session** — typing in the panel mirrors live in Terminal.app (and vice versa), per-client size negotiation via a 9-byte control protocol over a Unix domain socket. Main window runs its own private session.
- **Multi-tab** — `Cmd+T` new tab, `Cmd+W` close current pane/tab, `Cmd+1..9` switch tab. New tabs spawn their own private session.
- **Splits** — `Cmd+D` side-by-side, `Cmd+Shift+D` top/bottom. Nested via `NSSplitView` (iTerm2 conventions).
- **Settings** (`Cmd+,`) — pick initial command (Claude / shell / custom), working directory, Terminal.app pairing (mirror or standalone), background (default blur / transparent / custom tint / background image), and window mode.
- **First-launch onboarding** — bundles macOS permission prompts upfront so they don't surprise you mid-session.
- **Event-driven resize** — `opus-attach` reports SIGWINCH via a self-pipe; the panel ioctls the master PTY and SIGWINCHes the child on focus change. No polling.
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
│     ├── shared pane → subscribes to ClaudeBackend (panel only)
│     ├── private panes → FilteredClaudeTab wrappers, own PTY
│     └── splits via NSSplitView (nested, axis-mixed)
├── SettingsWindowController (General / Appearance / Window tabs)
├── OnboardingWindowController (first-launch TCC prompts)
└── SocketServer (/tmp/opus.sock, mirror mode only)
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
