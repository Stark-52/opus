# Architecture

How Opus is wired internally. Aimed at contributors and curious readers.

## Components

```
Opus.app
├── AppDelegate
│     ├── installAppMenu()           — minimal menu bar (Settings…, Quit)
│     ├── registerHotkey()           — Carbon RegisterEventHotKey for Cmd+Ctrl+T / Cmd+Ctrl+M / Cmd+Ctrl+R
│     ├── SocketServer               — Unix domain socket at /tmp/opus.sock (mirror mode only)
│     ├── QuickTerminalPanel?        — slide-down NSPanel host (panel/both modes)
│     ├── MainTerminalWindow?        — standalone NSWindow host (main/both modes)
│     ├── SettingsWindowController   — NSTabView with General / Appearance / Display
│     ├── OnboardingWindowController — first-launch TCC prompts
│     └── launchTerminalSession()    — AppleScript spawns Terminal.app + opus-attach (only when displayMode includes the native surface)
│
├── ClaudeBackend (singleton)
│     ├── owns a single LocalProcess (SwiftTerm) running the configured command
│     ├── broadcasts incoming bytes to all subscribers (panel pane, socket clients)
│     ├── setPrimarySize(cols, rows) → ioctl(TIOCSWINSZ) on master FD via Mirror reflection on .childfd
│     ├── send(data:) — forwards stdin bytes from any client into the PTY
│     └── restart(resume:) — SIGTERM child (SIGKILL after 1.5 s), respawn with optional --resume / --dangerously-skip-permissions
│
├── ClaudeSessionLocator — session-ID lookup for --resume
│     └── encodes cwd → project-dir name, takes most-recently-modified UUID *.jsonl in ~/.claude/projects/<encoded>/
│
├── TerminalContainerView (NSView)
│     ├── tabs[] / tabPanes[][] / tabActivePaneIndex[] / tabTitles[]
│     ├── OpusTabBar at the bottom (hidden when single tab)
│     ├── OpusSplitView for nested Cmd+D / Cmd+Shift+D splits
│     ├── TabPane abstraction
│     │     ├── shared  → ClaudeBackend subscriber, no own process (mirrors Terminal.app)
│     │     └── private → own FilteredClaudeTab wrapping LocalProcess
│     ├── TerminalViewDelegate impl (send/sizeChanged/setTerminalTitle/clipboardCopy/…)
│     └── copySelectionToPasteboard() / pasteFromPasteboard()
│
└── OpusPreferences (singleton)
      ├── UserDefaults-backed key/value store
      ├── posts opusPreferencesDidChange on every write
      └── resolvedSpawnCommand() → assembles the `/bin/zsh -c` payload

Tests/OpusTests/          — first test target (22 unit tests)
      ├── spawn-command flag assembly
      ├── ClaudeSessionLocator (cwd encoding, UUID selection, --continue fallback)
      └── MRU recent-projects list
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
permission mode. `ClaudeSessionLocator` resolves the ID: encode the cwd into
Claude Code's project-dir name (every non-alphanumeric → `-`; older
dot-keeping encoding as fallback), then take the most recently modified
UUID-named `*.jsonl` in `~/.claude/projects/<encoded>/`. No session found → `--continue` fallback →
worst case the existing "Session ended" overlay.

## PTY ownership

`SwiftTerm.LocalProcess` is the canonical PTY owner. Opus extends it with a `Mirror`-based reflection trick to access the master FD (`.childfd`), enabling out-of-band resize via `ioctl(TIOCSWINSZ)` + `kill(pid, SIGWINCH)`. This is fragile across SwiftTerm versions — if a release breaks `.childfd`, look for the equivalent property and update both `ClaudeBackend.setPrimarySize` and `FilteredClaudeTab.sizeChanged`.

## Socket protocol

Unix domain socket at `/tmp/opus.sock`. Client (`opus-attach`) flow:

1. Connect.
2. Send the 9-byte control prefix `ESC O p u s <colsHi> <colsLo> <rowsHi> <rowsLo>`.
3. Stream raw stdin bytes; receive raw stdout bytes. No framing on the data plane.
4. On every local `SIGWINCH` (via self-pipe), re-send the 9-byte control prefix with new dimensions.

Server scans the leading bytes of every chunk for the magic prefix; matched chunks drive a `setPrimarySize` instead of being forwarded to the child PTY.

## Cursor visibility filter

Claude Code's TUI emits `\e[?25l` to hide the cursor while it owns the screen. Inside the SwiftTerm panel that makes the input caret disappear, which Andy hated. We strip both `\e[?25l` and `\e[?25h` from every incoming byte stream (`QuickTerminalPanel.stripCursorVisibilityToggles`). The Terminal.app side gets the raw stream — its native terminal handles cursor visibility correctly.

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
| `opus.resumeLastConversation` | Bool | `false` |
| `opus.confirmRestart` | Bool | `true` (absent key = ask) |
| `opus.fontName` | String | "" (system default) |
| `opus.fontSize` | Double | `14` |
| `opus.recentProjects` | `[String]` | `[]` |

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
