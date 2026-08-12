# Architecture

How Opus is wired internally. Aimed at contributors and curious readers.

## Components

```
Opus.app
├── AppDelegate
│     ├── installAppMenu()           — minimal menu bar (Settings…, Quit)
│     ├── registerHotkey()           — Carbon RegisterEventHotKey for Cmd+Ctrl+T / Cmd+Ctrl+M / Cmd+Ctrl+R
│     ├── SocketServer               — Unix domain socket at /tmp/opus.sock, always running regardless of displayMode; also serves `opus-attach send` one-shot prompt injection
│     ├── EventSocketServer          — Unix domain socket at /tmp/opus-events.sock, the read side of the Claude Code hook bus (Task 1); feeds ClaudeStateStore
│     ├── QuickTerminalPanel?        — slide-down NSPanel host (panel/both modes)
│     ├── MainTerminalWindow?        — standalone NSWindow host (main/both modes)
│     ├── SettingsWindowController   — NSTabView with General / Appearance / Display
│     ├── OnboardingWindowController — first-launch TCC prompts
│     └── launchTerminalSession()    — AppleScript spawns Terminal.app + opus-attach (only when displayMode includes the native surface)
│
├── ClaudeBackend (singleton)
│     ├── owns a single LocalProcess (SwiftTerm) running the configured command
│     ├── broadcasts incoming bytes to all subscribers (panel pane, socket clients)
│     ├── currentSessionId — the id Opus itself minted (--session-id) or was told (--resume); primary source of "what session is this", nil only after a --continue launch (Task 6)
│     ├── setPrimarySize(cols, rows) → ioctl(TIOCSWINSZ) on master FD via Mirror reflection on .childfd
│     ├── send(data:) — forwards stdin bytes from any client into the PTY
│     └── restart(resume:) — SIGTERM child (SIGKILL after 1.5 s), respawn with optional --resume / --dangerously-skip-permissions
│
├── ClaudeSessionLocator — --resume ID fallback for the one case ClaudeBackend.currentSessionId can't cover: a --continue-launched session
│     └── encodes cwd → project-dir name, takes most-recently-modified UUID *.jsonl in ~/.claude/projects/<encoded>/
│
├── HookSettingsWriter — generates opus-hooks.json (--settings), injected into every spawned claude; lives at ~/Library/Application Support/Opus/opus-hooks.json
│     └── six pure-observer hooks (UserPromptSubmit/PreToolUse/PostToolUse/Notification/Stop/SessionStart), each firing `opus-attach event <Name>` → EventSocketServer
│
├── ClaudeStateStore (singleton) — live per-session PaneActivity, built from the hook bus
│     ├── idle/working/needsInput/done, drives the tab-bar dot color and ClaudeAttention's precision
│     └── owns pane↔session binding (paneSessionIds/pendingSpawns) — see its own doc comments for the direct-bind vs spawn-order-FIFO split
│
├── SessionIndex / SessionSwitcherPanel — Cmd+K conversation switcher
│     ├── SessionIndex scans ~/.claude/projects/*/*.jsonl (bounded 16KB head read per file, plus a 40KB tail read to catch a fresher ai-title record) across every project on this machine
│     └── SessionSwitcherPanel fuzzy-filters by title/cwd, resumes the pick into the shared session (tab 0)
│
├── ContextMeter / ContextMeterBar — context-window usage bar above the tab bar
│     └── parses the ACTIVE tab's session's live transcript tail for `message.usage` token counts, refreshed on a timer
│
├── PathDetector — pure token-scan for Cmd+click file[:line] detection in terminal text
│     └── TerminalContainerView resolves the result against cwd and opens it via `OpusPreferences.editorCommand`
│
├── TerminalContainerView (NSView)
│     ├── tabs[] / tabPanes[][] / tabActivePaneIndex[] / tabTitles[]
│     ├── OpusTabBar at the bottom (hidden when single tab), dots sourced from ClaudeStateStore
│     ├── OpusSplitView for nested Cmd+D / Cmd+Shift+D splits
│     ├── TabPane abstraction
│     │     ├── shared  → ClaudeBackend subscriber, no own process (mirrors Terminal.app)
│     │     └── private → own FilteredClaudeTab wrapping LocalProcess
│     ├── TerminalViewDelegate impl (send/sizeChanged/setTerminalTitle/clipboardCopy/…)
│     ├── FindBarView — Cmd+F find bar over SwiftTerm's built-in scrollback search (Enter/Shift+Enter/Esc); also backs Cmd+Up/Down prompt jump (searches "❯ ")
│     ├── broadcastArmed — Cmd+Shift+I fans keystrokes out to every pane of the active tab, lit border while armed
│     └── copySelectionToPasteboard() / pasteFromPasteboard()
│
├── ClaudeAttention (singleton)
│     └── turns terminal BELs into a Dock badge + notification ("Claude needs you") when Opus is backgrounded, debounced 3s
│
└── OpusPreferences (singleton)
      ├── UserDefaults-backed key/value store
      ├── posts opusPreferencesDidChange on every write
      ├── permissionMode → shield's right-click `--permission-mode` preset (default/plan/acceptEdits)
      ├── editorCommand → Cmd+click target for PathDetector hits (default `code -g {target}`)
      └── resolvedSpawnCommand() → assembles the `/bin/zsh -c` payload, including `--session-id <id>` (fresh spawns) and `--settings <opus-hooks.json path>` (every `.claude`-preset spawn)

Tests/OpusTests/          — 170 unit tests
      ├── spawn-command flag assembly
      ├── ClaudeSessionLocator (cwd encoding, UUID selection, --continue fallback)
      ├── MRU recent-projects list
      └── cockpit: ClaudeStateStore transitions/binding, SessionIndex parsing, ContextMeter parsing, PathDetector token-scan, HookSettingsWriter, EventSocketServer parsing, prompt-marker-selection predicate
```

## Hosting model

Two hosts can embed a `TerminalContainerView`:

- **QuickTerminalPanel** — borderless NSPanel slide-down. Wraps the container in a `NSVisualEffectView` + tint `NSView` + optional `NSImageView` (appearance). Owns the show/hide animation, the hotkey monitor, the appearance applier, and the ↗ button.
- **MainTerminalWindow** — standard NSWindow, frame auto-saved across launches via `setFrameAutosaveName`, fullscreen-capable. No appearance wrapping (uses default macOS chrome).

Each host implements `TerminalContainerHost` (provides `hostWindow: NSWindow?` and `openInTerminalRequested()`).

Both hosts create their container with `useSharedTab0: true`, so each surface's tab 0 subscribes to the same `ClaudeBackend` broadcast. With `displayMode == .panelAndMain`, the panel and the main window mirror each other live (and the panel mirrors Terminal.app via `opus-attach` in `nativeAndPanel`). `Cmd+T` always spawns a private tab — those keep their own `LocalProcess` and don't sync between surfaces.

## Display modes

`OpusPreferences.displayMode` picks which surfaces are alive at launch:

| Mode | Panel | Main Window | Terminal.app + socket |
|---|---|---|---|
| `nativeAndPanel` (default) | ✓ | — | ✓ |
| `panelAndMain` | ✓ | ✓ | — |
| `panelOnly` | ✓ | — | — |
| `mainOnly` | — | ✓ | — |

`AppDelegate.applicationDidFinishLaunching` reads the mode once and gates: socket server startup, `launchTerminalSession()`, `nativePanel = QuickTerminalPanel()`, and `MainTerminalWindow.shared.show()`. Cmd+Ctrl+M is only registered as a global hotkey when the mode includes the main window. Changing the mode in Settings requires a restart to apply.

## Session restart & dangerous mode (v1.2)

`ClaudeBackend.restart(resume:)` SIGTERMs the child (SIGKILL escalation after
1.5 s), then `processTerminated` — seeing the `isRestarting` flag — broadcasts
a full terminal reset (`ESC c`) to all subscribers and respawns instead of
posting the dead-session notification. Subscribers (panel, main window,
opus-attach clients) never detach.

`skipPermissionsActive` is per-app-run state on `ClaudeBackend`, seeded from
the `opus.skipPermissions` default. The shield button in
`TerminalContainerView` flips it via `toggleSkipPermissions()`, which restarts
with `--resume <session-id>` so the same conversation reopens with the new
permission mode. The id comes primarily from `ClaudeBackend.currentSessionId`
(Lot 3, Task 6): Opus mints it itself as `--session-id` on a fresh spawn, or
records it as-is for an explicit `.resume(sessionId:)` — either way Opus
already KNOWS the id, since it's either the one it chose or the one it was
told, no disk lookup needed. `ClaudeSessionLocator` only runs as a fallback,
for the single case where Opus doesn't know the id up front: a
`--continue`-launched session (`currentSessionId == nil`, since claude, not
Opus, picked the id). There it encodes the cwd into Claude Code's
project-dir name (every non-alphanumeric → `-`; older dot-keeping encoding
as fallback), then takes the most recently modified UUID-named `*.jsonl` in
`~/.claude/projects/<encoded>/`. No session found → `--continue` fallback →
worst case the existing "Session ended" overlay.

Right-clicking the shield opens a menu of `OpusPermissionMode` presets (`--permission-mode` values, e.g. `plan`/`acceptEdits`); the shield's own `--dangerously-skip-permissions` toggle always wins when both are active.

## Spawn environment

`SpawnEnvironment.make` builds the child process env: forces `TERM`/`COLORTERM`/`LANG`, guarantees `/usr/bin:/bin:/usr/sbin:/sbin` are on `PATH` (SwiftTerm's default env omits it), and strips inherited Claude Code session markers (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, etc.) so a spawned `claude` isn't mistaken for a nested child session, which would silently disable transcript persistence and break `--resume`.

## PTY ownership

`SwiftTerm.LocalProcess` is the canonical PTY owner. Opus extends it with a `Mirror`-based reflection trick to access the master FD (`.childfd`), enabling out-of-band resize via `ioctl(TIOCSWINSZ)` + `kill(pid, SIGWINCH)`. This is fragile across SwiftTerm versions — if a release breaks `.childfd`, look for the equivalent property and update both `ClaudeBackend.setPrimarySize` and `FilteredClaudeTab.sizeChanged`.

## Socket protocol

Unix domain socket at `/tmp/opus.sock`. Client (`opus-attach`) flow:

1. Connect.
2. Send the 9-byte control prefix `ESC O p u s <colsHi> <colsLo> <rowsHi> <rowsLo>`.
3. Stream raw stdin bytes; receive raw stdout bytes. No framing on the data plane.
4. On every local `SIGWINCH` (via self-pipe), re-send the 9-byte control prefix with new dimensions.

Server scans the leading bytes of every chunk for the magic prefix; matched chunks drive a `setPrimarySize` instead of being forwarded to the child PTY.

## Events socket (Claude Code hook bus)

Separate Unix domain socket at `/tmp/opus-events.sock`, one-directional and connection-per-line (not a persistent duplex pipe like the data socket above). `HookSettingsWriter` injects six pure-observer hooks into every spawned `claude` via `--settings opus-hooks.json`; each fires `opus-attach event <Name>`, which forwards claude's own hook stdin JSON (newline-compacted to one line) to the socket and exits. `EventSocketServer` reads each connection to EOF, splits on `0x0A`, and hands each line to `OpusClaudeEvent.parse` — a line that doesn't decode into a known event/shape is dropped silently, never crashes Opus. Parsed events post `.opusClaudeEvent` on the main queue, which `ClaudeStateStore` consumes to drive tab-bar dots and `ClaudeAttention`'s notification precision.

## Cursor visibility filter

Claude Code's TUI emits `\e[?25l` to hide the cursor while it owns the screen. Inside the SwiftTerm panel that makes the input caret disappear, which the owner hated. We strip both `\e[?25l` and `\e[?25h` from every incoming byte stream (`QuickTerminalPanel.stripCursorVisibilityToggles`). The Terminal.app side gets the raw stream — its native terminal handles cursor visibility correctly.

## Appearance pipeline

`QuickTerminalPanel` builds a layered visual stack:

```
NSPanel.contentView
└── NSVisualEffectView (blur)
    ├── NSImageView (background image, hidden unless mode == image)
    ├── NSView (tint, layer.backgroundColor depends on mode)
    └── TerminalContainerView
```

`applyAppearance()` reads `OpusPreferences.appearanceMode` (default / transparent / tint / image) and toggles:

- Blur `state` (`.active` for default + tint, `.inactive` for transparent + image).
- Tint layer color (default RGBA `(0.04, 0.05, 0.07, 0.55)`; custom user RGBA for tint mode; floor `(0, 0, 0, 0.25)` for image mode to keep terminal text readable).
- Image view visibility + content.

Observed via `Notification.Name.opusPreferencesDidChange` so changes apply live without restart.

## Settings persistence

`OpusPreferences` exposes typed accessors backed by `UserDefaults.standard`. Keys are namespaced under `opus.*`:

| Key | Type | Default |
|---|---|---|
| `opus.initialCommandPreset` | `OpusInitialCommandPreset` (claude/shell/custom) | `claude` |
| `opus.customCommand` | String | "" |
| `opus.workingDirectory` | String | `~/Documents/GitHub/ClaudeUltra` |
| `opus.displayMode` | `OpusDisplayMode` (nativeAndPanel/panelAndMain/panelOnly/mainOnly) | `nativeAndPanel` |
| `opus.onboardingShown` | Bool | `false` |
| `opus.appearanceMode` | String (default/transparent/tint/image) | `default` |
| `opus.appearanceTintRGBA` | `[Double]` (4 components) | `[0.04, 0.05, 0.07, 0.55]` |
| `opus.appearanceImagePath` | String? | `nil` |
| `opus.panelGeometry.display<DisplayID>` | `["width": Double, "height": Double]` | — |
| `opus.skipPermissions` | Bool | `false` |
| `opus.permissionMode` | `OpusPermissionMode` (default/plan/acceptEdits) | `default` |
| `opus.resumeLastConversation` | Bool | `false` |
| `opus.confirmRestart` | Bool | `true` (absent key = ask) |
| `opus.fontName` | String | "" (system default) |
| `opus.fontSize` | Double | `14` |
| `opus.recentProjects` | `[String]` | `[]` |
| `opus.notifyOnBell` | Bool | `true` (absent key = on) |
| `opus.panelPinned` | Bool | `false` |
| `opus.scrollbackLines` | Int | `10_000` (clamped 1,000–200,000) |
| `opus.editorCommand` | String | `code -g {target}` (`{target}` → `path` or `path:line`) |
| `opus.contextLimitTokens` | Int | `1_000_000` (clamped 10,000–2,000,000) — the transcript carries no context-window metadata, so ContextMeter's limit is this pref, not a derived value (see `ContextMeter.resolveLimit`) |

Panel size is keyed by `CGDirectDisplayID` (via `NSScreen.deviceDescription["NSScreenNumber"]`) so two physically distinct monitors with identical pixel dimensions don't share one entry.

## macOS 14+ NSPanel gotchas

- `[.canJoinAllSpaces, .moveToActiveSpace]` together **deadlocks** the panel init. Use `.canJoinAllSpaces + .stationary + .transient + .fullScreenAuxiliary`.
- `animationBehavior` must be `.none` — macOS otherwise overrides the custom CA slide animation.
- `tabbingMode = .disallowed` — prevents the macOS automatic window-tab UI from appearing on terminal titles.
- Show via `orderFrontRegardless() + makeKey()` (not `makeKeyAndOrderFront`) to avoid switching Spaces.

## NSSplitView pitfalls

- Negative `cols`/`rows` arrive in `sizeChanged` during the first layout pass on a freshly-inserted pane. Guard `newCols > 0, newRows > 0` and skip — the next pass produces valid values.
- `arrangedSubviews` mutations don't auto-redistribute. Call `adjustSubviews()` after any insert/remove/replace.
- Removing order: `removeArrangedSubview(view)` → `view.removeFromSuperview()` → `adjustSubviews()`.

## AZERTY keyboard support

Letter shortcuts (`T`, `W`, `D`, `C`, `V`) match by `charactersIgnoringModifiers` (letters are layout-stable). Digit shortcuts (`Cmd+1..9`) match by `event.keyCode` because AZERTY puts digits behind Shift — character matching fails there.

## Hotkeys

Global hotkeys are registered via Carbon `RegisterEventHotKey`:

| Hotkey | ID | Action |
|---|---|---|
| Cmd+Ctrl+T | 1 | Toggle quick-terminal panel (when displayMode includes panel) |
| Cmd+Ctrl+M | 2 | Toggle main window (only registered when displayMode includes main) |
| Cmd+Ctrl+R | 3 | Restart Claude session (kill + respawn, all surfaces stay attached) |

The dispatcher in `hotkeyCallback` reads the `EventHotKeyID.id` and routes accordingly.

## Footprint

| | Idle | With Claude running |
|---|---|---|
| Opus.app RSS | ~98 MB | n/a (child is its own process) |
| opus-attach RSS | ~6 MB | per Terminal.app session |
| Bundle size | ~3.2 MB | — |
