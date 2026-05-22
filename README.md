# Opus

Native macOS launcher and terminal multiplexer dedicated to **Claude Code**.

Opus opens as a slide-down quick-terminal panel from the top of the active screen, backed by a custom Unix-socket multiplexer that mirrors a shared claude session between the panel and a Terminal.app window. Multi-tab, nested splits, event-driven resize. No tmux, no dtach, no Hammerspoon — ~1k lines of Swift + SwiftTerm.

## Features

- **Slide-down panel** (`Cmd+Ctrl+T`) — non-activating NSPanel, native blur, follows the active macOS Space.
- **Shared session** — typing in the panel mirrors live in Terminal.app (and vice versa), per-client size negotiation via a 9-byte control protocol over a Unix domain socket.
- **Multi-tab** — `Cmd+T` new tab, `Cmd+W` close current pane/tab, `Cmd+1..9` switch tab. New tabs spawn their own private `claude`.
- **Splits** — `Cmd+D` side-by-side, `Cmd+Shift+D` top/bottom. Nested via `NSSplitView` (iTerm2 conventions).
- **Event-driven resize** — `opus-attach` reports SIGWINCH via a self-pipe; the panel ioctls the master PTY and SIGWINCHes claude on focus change. No polling.
- **Cursor stays visible in claude's TUI** — DECTCEM hide/show sequences (`\e[?25l` / `\e[?25h`) are filtered out before reaching SwiftTerm so the caret doesn't disappear inside the panel.

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
├── ClaudeBackend (singleton, owns claude via SwiftTerm LocalProcess)
│     └── multi-subscriber broadcast — same bytes to every client
├── QuickTerminalPanel (NSPanel + NSVisualEffectView + tab bar)
│     ├── tab 0 = shared pane (subscribes to ClaudeBackend)
│     ├── tabs 1+ = FilteredClaudeTab wrappers (own PTY)
│     └── splits via NSSplitView (nested, axis-mixed)
└── SocketServer (/tmp/opus.sock)
      └── opus-attach clients — Terminal.app windows
```

The 9-byte control protocol prefix: `ESC O p u s + cols(2 BE) + rows(2 BE)`. Sent client → server on initial connect and every SIGWINCH.

## Requirements

- macOS 13+
- Swift 5.7+ (Xcode toolchain)
- `claude` CLI in `$PATH`
- A Nerd Font (`MesloLGS NF` recommended) for proper rendering, falls back to SF Mono / Menlo

## Status

Early personal-use project. Battle-tested on macOS Tahoe (26.x) with French AZERTY layout. Not yet packaged for distribution.

## License

Private repository. License TBD.
