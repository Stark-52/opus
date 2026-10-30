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
- **Per-conversation dangerous mode**: « Passer les permissions (bypass) » in the toolbar's ⋯ menu relaunches the shared Claude session with `--dangerously-skip-permissions` into the same conversation; Claude Code's own footer says when it is on.
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
- **Find in scrollback** (`Cmd+F`) — a find bar over SwiftTerm's built-in search engine. Enter = previous match (searches up, toward older lines), Shift+Enter = next match (down, toward the bottom), Esc = close. `Cmd+G` / `Cmd+Shift+G` repeat the previous/next match without refocusing the bar.
- **"Claude needs you" notifications** — a terminal bell fires a Dock badge + bounce and a native notification when Opus is backgrounded, debounced so a bell storm collapses to one signal.
- **Pin** (⋯ menu of the panel's toolbar): disables panel autohide so it stays visible while you work in another app.
- **`opus-attach send`** — push a one-shot prompt into the live shared session from scripts, cron, git hooks, or Raycast, without attaching a terminal.
- **Font zoom** (`Cmd+=` / `Cmd+-` / `Cmd+0`) — live font size adjustment, plus a configurable scrollback ceiling in Settings.
- **Permission-mode picker**: the ⋯ menu's « Mode de permission » submenu picks a `--permission-mode` preset (default / plan / auto-accept edits), independent of bypass.
- **Activity dots** — each tab shows a cyan (working) / red (needs input) / green (done) dot, driven live by Claude Code's own hooks (`opus-hooks.json` injected into every spawned session, relayed over a Unix socket) — no polling, no scraping the TUI.
- **Cmd+K conversation switcher** — fuzzy-search every Claude Code conversation on this machine (any project, any working directory), Enter resumes it into the shared session.
- **Toolbar and status bar**: tabs (compact, with their activity dot, `+` for a new one) and the Copier, Artifacts, Trousseau and ⋯ buttons sit in a toolbar of their own, monochrome and lit under the pointer; the status bar below names the memory the session carries and gives the context and the plan's usage as words and numbers (`contexte 36 % · semaine 23 % · 5h 2 %`), amber then red when they need attention, resets and token counts in the tooltip. Nothing floats over the terminal's text.
- **Where the figures come from**: the context percentage is parsed live from the transcript; Claude Code never says which context window a session runs with, so the ceiling is a Settings → Appearance preference (`opus.contextLimitTokens`, default 1,000,000), bumped automatically if usage ever exceeds it. The 5-hour and 7-day figures come from `~/Library/Application Support/Opus/usage.json`, which your Claude Code status line command keeps from its `rate_limits` input (newest reset per window, highest figure within one); sessions Opus spawns get `OPUS_PANE=1`, so that command can print nothing inside Opus. The memory comes from `~/Library/Application Support/Opus/memory/<session id>.json`, written by the memory-router mod.
- **Disposition** (Settings, Appearance): the toolbar on top with the status bar below, or everything in one bottom bar.
- **Click to place the cursor**: a plain click inside Claude Code's input (between its two `────` rules) sends the arrow keys that bring the cursor under it, one press per character, a wide character counting once. A click on another row of the input goes up or down first, then reads where the cursor landed. Ignored while scrolled back through history, and outside the input.
- **Cmd+click file:line** (a folder opens in the Finder): click a file path (with optional `:line`) anywhere in the terminal to open it in your editor, even one with spaces in its name or wrapped onto the next row. A web address written without `https://` opens in the browser. Defaults to VS Code's own `code` CLI inside the app bundle when VS Code is installed (no need for its "Install 'code' command in PATH"), `code -g {target}` otherwise; there's no Settings UI for this yet, so change it with `defaults write com.stark52.opus opus.editorCommand "your-editor {target}"`.
- **Broadcast input** (`Cmd+Shift+I`) — type once, land in every pane of the active tab; armed panes get a lit border so you can't forget it's on.
- **Prompt jump** (`Cmd+Up` / `Cmd+Down`) — jump the scrollback straight to the previous/next submitted prompt.
- **Prompt history palette** (`Cmd+Shift+P`, v1.6) — fuzzy-search every prompt you've ever typed into Claude Code on this machine, any project or session, not just the active pane's scrollback. Enter inserts the picked prompt into the active pane without submitting it — you review and hit Return yourself, same feel as a paste.
- **Send to Claude** (`Cmd+Ctrl+S`, v1.6) — global hotkey, works from anywhere: sends the clipboard (or Finder-selected file paths, same handling as `Cmd+V`) straight into the active Claude session without submitting it. The payload template is configurable in Settings (`opus.sendToClaudeTemplate`, default `{clipboard}`).
- **Copy drawer** (`Cmd+Shift+C`, the Copier button, or a two-finger swipe to the right): Claude's latest answer, read off the transcript and drawn formatted, with a copy button per block. A copy keeps the formatting (headings, bold, lists, links, code, tables) where you paste it, in Notes, Mail, Google Docs, Notion or Slack, and stays plain text in a terminal or a field that takes only text; a code block copies as its code alone. It opens from the left.
- **Drawers on both edges, opened by swipe**: Copy on the left, Artifacts on the right; a two-finger swipe pulls one in and the drawer follows the fingers, settling open past a third of its width or on a fling, and the reverse swipe closes it. A drawer lies over the text and the terminal keeps its width, so Claude Code never redraws for it (on a new width it reprints its live region without clearing the scrollback, which repeated or dropped text at the seam).
- **Artifacts drawer** (`Cmd+Shift+A`, the Artifacts button, or a swipe to the left): what the session produced, newest first and grouped by moment (dernière heure, aujourd'hui, hier, then the day); images as large thumbnails, documents and folders with a magnifying glass on hover that shows them in the Finder; source and configuration files have their own Code tab and stay out of All.

Note: multi-line pastes, drag-dropped Finder paths, and text delivered by the palette/hotkey above are now wrapped in bracketed-paste markers before reaching claude, so embedded newlines land as data instead of triggering an early submit (fixed in v1.6 — see Changelog).

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

- 2026-10-30: SwiftTerm 2.0 line (1.99.x): a row Claude Code rewrites no longer keeps the soft wrap of the text it replaced, which used to scatter the scrollback on a diagonal after a resize. Drawers lie over the terminal instead of resizing it. Integrated chrome: a toolbar and a status bar in place of the floating buttons, the gauge and the bottom tab bar (or one bottom bar, in Settings); the memory the session carries in the status bar; Copy drawer on the left, Artifacts on the right, both opened by a two-finger swipe; Artifacts grouped by moment with a Code tab. Clicks on the bottom rows land on their row, and move the cursor on the press. The tab bar is no longer cut along its bottom edge.
- v1.6 (2026-08-12): prompt history palette, global send-to-Claude hotkey, task drawer, bracketed paste for multi-line input.
- v1.5 (2026-08-12): visual harmonization — bottom status rail, one color per meaning, shared theme tokens.
- v1.4.2 (2026-08-12): clickable Cmd+K rows, arrow-key search navigation with a match counter, a visible context readout.
- v1.4.1 (2026-08-11): live-smoke fixes — visible status dot in single-tab mode, context bar placement, pin button z-order, legible Cmd+K palette, Cmd+F searches up through the full scrollback.
- v1.4 (2026-08-11): the Claude cockpit — hook-driven state bus, activity dots, Cmd+K switcher, context meter, Cmd+click paths, broadcast input, prompt jump, deterministic session ids.
- v1.3 (2026-08-11): Cmd+F search, attention notifications, panel pin, opus-attach send, font zoom + scrollback setting, permission-mode picker, transcript-marker env fix.
- v1.2.2 (2026-08-10): 12 bugfixes from the multi-agent review — restart targets the focused pane, SIGPIPE hardening, Caps Lock shortcuts, panel toggle race, and more.

## License

MIT — see [LICENSE](LICENSE).
