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
- **Per-conversation dangerous mode** — a shield button (top-right of the panel and main window) relaunches the shared Claude session with `--dangerously-skip-permissions` and resumes the exact same conversation (`--resume <session-id>`, using the session id Opus already knows it's running; falls back to scanning `~/.claude/projects/` only after a `--continue`-launched session, whose id claude picked, not Opus). Click again to restore permission prompts, same conversation. Orange = armed. Also in the App/Dock menus.
- **Restart Claude Session** (`Cmd+Ctrl+R`) — kill + respawn the session in the focused pane, without quitting Opus (private tabs restart in place; the shared pane restarts the shared session, and all its surfaces stay attached). Asks for confirmation by default ("Don't ask again" checkbox in the alert, re-enable in Settings → General).
- **Switch Project** — App/Dock menu of your 8 most recent working directories; picking one restarts the session in that project.
- **Settings** (`Cmd+,`) — three tabs:
  - **General** — initial command (Claude / shell / custom), skip-permissions default, resume-last-conversation (`--continue`), working directory, launch at login.
  - **Appearance** — default blur / transparent / custom tint color / background image, terminal font family + size (live).
  - **Display** — choose between the four display modes above.
- **First-launch onboarding** — bundles macOS permission prompts upfront so they don't surprise you mid-session.
- **Session-ended overlay** — when Claude exits and there are no other live panes, you get a centered "Start new session" / "Close Opus" prompt instead of a frozen dead terminal.
- **Event-driven resize** — `opus-attach` reports SIGWINCH via a self-pipe; the broadcaster ioctls the master PTY and SIGWINCHes the child on focus change. No polling.
- **Cursor stays visible in Claude's TUI** — DECTCEM hide/show sequences (`\e[?25l` / `\e[?25h`) are filtered out before reaching SwiftTerm so the caret doesn't disappear inside the panel.
- **Find in scrollback** (`Cmd+F`) — a find bar over SwiftTerm's built-in search engine. Enter = next match, Shift+Enter = previous, Esc = close. `Cmd+G` / `Cmd+Shift+G` step to the next/previous match without refocusing the bar.
- **"Claude needs you" notifications** — a terminal bell fires a Dock badge + bounce and a native notification when Opus is backgrounded, debounced so a bell storm collapses to one signal.
- **Pin button** (top-right of the panel) — disables panel autohide so it stays visible while you work in another app, for monitoring long-running sessions.
- **`opus-attach send`** — push a one-shot prompt into the live shared session from scripts, cron, git hooks, or Raycast, without attaching a terminal.
- **Font zoom** (`Cmd+=` / `Cmd+-` / `Cmd+0`) — live font size adjustment, plus a configurable scrollback ceiling in Settings.
- **Permission-mode picker** — right-click the shield button to pick a `--permission-mode` preset (default / plan / auto-accept edits) independent of the dangerous-mode toggle.
- **Activity dots** — each tab shows an amber (working) / red (needs input) / green (done) dot, driven live by Claude Code's own hooks (`opus-hooks.json` injected into every spawned session, relayed over a Unix socket) — no polling, no scraping the TUI.
- **Cmd+K conversation switcher** — fuzzy-search every Claude Code conversation on this machine (any project, any working directory), Enter resumes it into the shared session.
- **Context usage bar** — a thin bar above the tab bar showing how full the active tab's session's context window is, parsed live from the transcript.
- **Cmd+click file:line** — click a file path (with optional `:line`) anywhere in the terminal to open it in your editor. Defaults to `code -g {target}`; there's no Settings UI for this yet, so change it with `defaults write com.stark52.opus opus.editorCommand "your-editor {target}"`.
- **Broadcast input** (`Cmd+Shift+I`) — type once, land in every pane of the active tab; armed panes get a lit border so you can't forget it's on.
- **Prompt jump** (`Cmd+Up` / `Cmd+Down`) — jump the scrollback straight to the previous/next submitted prompt.

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

Optional: add a `claude-join()` function to your `~/.zshrc` so you can voluntarily attach a Terminal.app tab to the panel's shared session whenever you want, instead of starting a fresh `claude`:

```zsh
claude-join() {
    if [ -S /tmp/opus.sock ]; then
        exec opus-attach
    else
        command claude "$@"
    fi
}
```

Run `claude-join` when you want this tab mirroring the shared session; run plain `claude` for an independent one. It's a voluntary attach, not an override of `claude` itself.

### Push a prompt from anywhere

    opus-attach send "run the test suite and fix failures"   # submits
    opus-attach send -n "half-typed thought"                  # types without submitting

Works from scripts, cron, git hooks, Raycast: anything that can run a binary
can drive the live Claude session.

The socket now runs in every display mode (not just when Terminal.app is
part of the mix), so `claude-join`/`opus-attach` mirroring and `send` both
work regardless of which display mode Opus is set to.

Quote your text, especially with apostrophes: `opus-attach send "don't forget"`.

## Architecture

```
Opus.app
├── ClaudeBackend (singleton, owns child PTY via SwiftTerm LocalProcess)
│     └── multi-subscriber broadcast — same bytes to every client
├── OpusPreferences (UserDefaults singleton)
├── ClaudeSessionLocator (session-ID lookup for --resume)
├── QuickTerminalPanel (NSPanel) → embeds TerminalContainerView
├── MainTerminalWindow (NSWindow) → embeds TerminalContainerView
├── TerminalContainerView (shared NSView — tabs + panes + splits + tab bar)
│     ├── tab 0 → ClaudeBackend subscriber (shared with every other live surface)
│     ├── private panes (Cmd+T tabs, splits) → FilteredClaudeTab, own PTY
│     └── splits via NSSplitView (nested, axis-mixed)
├── SettingsWindowController (General / Appearance / Display tabs)
├── OnboardingWindowController (first-launch TCC prompts)
├── SocketServer (/tmp/opus.sock, always running regardless of displayMode)
│     └── opus-attach clients — Terminal.app windows
└── EventSocketServer (/tmp/opus-events.sock) — Claude Code hook bus
      ├── HookSettingsWriter injects opus-hooks.json into every spawned claude
      ├── ClaudeStateStore — live per-session activity, feeds tab-bar dots + notifications
      └── SessionIndex / ContextMeter — Cmd+K switcher + context usage bar read transcripts directly
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

## Changelog

- v1.4.2 (2026-08-12): clickable Cmd+K rows, arrow-key search navigation with a match counter, a visible context readout.
- v1.4.1 (2026-08-11): live-smoke fixes — visible status dot in single-tab mode, context bar placement, pin button z-order, legible Cmd+K palette, Cmd+F searches up through the full scrollback.
- v1.4 (2026-08-11): the Claude cockpit — hook-driven state bus, activity dots, Cmd+K switcher, context meter, Cmd+click paths, broadcast input, prompt jump, deterministic session ids.
- v1.3 (2026-08-11): Cmd+F search, attention notifications, panel pin, opus-attach send, font zoom + scrollback setting, permission-mode picker, transcript-marker env fix.
- v1.2.2 (2026-08-10): 12 bugfixes from the multi-agent review — restart targets the focused pane, SIGPIPE hardening, Caps Lock shortcuts, panel toggle race, and more.

## License

MIT — see [LICENSE](LICENSE).
