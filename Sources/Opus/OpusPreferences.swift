// OpusPreferences — UserDefaults-backed settings singleton. Every
// configurable surface in Opus reads through this. Values are reactive via
// the `didChange` notification so multiple views can refresh in sync.

import Foundation
import AppKit

/// Posted whenever any preference is written. Observers (e.g. the panel's
/// appearance applier, ClaudeBackend's next spawn) read the current value.
extension Notification.Name {
    static let opusPreferencesDidChange = Notification.Name("com.stark52.opus.preferencesDidChange")
}

/// How a spawned claude reattaches to past conversations.
enum OpusResumeMode: Equatable {
    case none
    case continueMostRecent            // claude --continue
    case resume(sessionId: String)     // claude --resume <id>
}

/// Initial-command presets the user picks from in Settings → General.
enum OpusInitialCommandPreset: String, CaseIterable {
    case claude = "claude"        // /bin/zsh -i -c "cd <cwd> && command claude"
    case shell  = "shell"         // /bin/zsh -i (interactive shell, no command)
    case custom = "custom"        // run the user-supplied custom command verbatim

    var displayName: String {
        switch self {
        case .claude: return "Claude (default)"
        case .shell:  return "Interactive shell"
        case .custom: return "Custom command…"
        }
    }
}

/// Claude Code's `--permission-mode` presets, offered from the shield's
/// right-click menu. `.standard` omits the flag entirely (claude's own
/// default); the shield's `--dangerously-skip-permissions` toggle always
/// wins over this when both are active (see composeSpawnCommand).
enum OpusPermissionMode: String, CaseIterable {
    case standard    = "default"
    case plan        = "plan"
    case acceptEdits = "acceptEdits"   // exact casing claude's CLI expects

    var displayName: String {
        switch self {
        case .standard:    return "Ask for permissions (default)"
        case .plan:        return "Plan mode"
        case .acceptEdits: return "Auto-accept edits"
        }
    }
}

/// Which surfaces Opus exposes the shared Claude session through. All
/// combinations keep tab 0 of every surface subscribed to the same
/// ClaudeBackend broadcast, so what you type in one shows everywhere.
enum OpusDisplayMode: String, CaseIterable {
    /// Native Terminal.app window via opus-attach + slide-down panel.
    case nativeAndPanel = "nativeAndPanel"
    /// Slide-down panel + Main window (NSWindow). No Terminal.app.
    case panelAndMain   = "panelAndMain"
    /// Slide-down panel only.
    case panelOnly      = "panelOnly"
    /// Main window only.
    case mainOnly       = "mainOnly"

    var displayName: String {
        switch self {
        case .nativeAndPanel: return "Terminal.app + Quick Terminal"
        case .panelAndMain:   return "Quick Terminal + Main Window"
        case .panelOnly:      return "Quick Terminal only"
        case .mainOnly:       return "Main Window only"
        }
    }

    var includesNativeTerminal: Bool { self == .nativeAndPanel }
    var includesPanel: Bool { self != .mainOnly }
    var includesMain:  Bool { self == .panelAndMain || self == .mainOnly }
}

final class OpusPreferences {
    static let shared = OpusPreferences()
    private let defaults = UserDefaults.standard

    // MARK: Keys (kept private to force access through the typed properties below)

    private enum K {
        static let initialCommandPreset   = "opus.initialCommandPreset"
        static let permissionMode         = "opus.permissionMode"
        static let customCommand          = "opus.customCommand"
        static let workingDirectory       = "opus.workingDirectory"
        static let displayMode            = "opus.displayMode"
        static let onboardingShown        = "opus.onboardingShown"
        static let skipPermissions        = "opus.skipPermissions"
        static let resumeLastConversation = "opus.resumeLastConversation"
        static let confirmRestart         = "opus.confirmRestart"
        static let notifyOnBell           = "opus.notifyOnBell"
        static let recentProjects         = "opus.recentProjects"
        static let panelPinned            = "opus.panelPinned"
        // Appearance (used in Phase 4)
        static let appearanceMode         = "opus.appearanceMode"
        static let appearanceTintRGBA     = "opus.appearanceTintRGBA"
        static let appearanceImagePath    = "opus.appearanceImagePath"
        static let fontName               = "opus.fontName"
        static let fontSize               = "opus.fontSize"
        static let scrollbackLines        = "opus.scrollbackLines"
        // Cockpit (Lot 3, Task 5)
        static let editorCommand          = "opus.editorCommand"
    }

    // MARK: Typed accessors

    var initialCommandPreset: OpusInitialCommandPreset {
        get {
            let raw = defaults.string(forKey: K.initialCommandPreset) ?? OpusInitialCommandPreset.claude.rawValue
            return OpusInitialCommandPreset(rawValue: raw) ?? .claude
        }
        set { write(K.initialCommandPreset, newValue.rawValue) }
    }

    var customCommand: String {
        get { defaults.string(forKey: K.customCommand) ?? "" }
        set { write(K.customCommand, newValue) }
    }

    /// Shell command template for Cmd+click-opens-file (Lot 3, Task 5).
    /// `{target}` is replaced with a shell-quoted `path` (or `path:line`
    /// when a line number was parsed) before running via `/bin/zsh -lc`.
    /// Pattern of `customCommand` above, except the default here is already
    /// a directly runnable command rather than an empty string with a
    /// fallback applied elsewhere — there's no equivalent of `.claude`'s
    /// preset system for this one setting.
    var editorCommand: String {
        get { defaults.string(forKey: K.editorCommand) ?? "code -g {target}" }
        set { write(K.editorCommand, newValue) }
    }

    /// `--permission-mode` preset applied to spawned claude processes (global,
    /// not per-project — see the shield's right-click menu). Overridden by
    /// `skipPermissions` when that's active (see composeSpawnCommand).
    var permissionMode: OpusPermissionMode {
        get {
            let raw = defaults.string(forKey: K.permissionMode) ?? OpusPermissionMode.standard.rawValue
            return OpusPermissionMode(rawValue: raw) ?? .standard
        }
        set { write(K.permissionMode, newValue.rawValue) }
    }

    /// Default for new Opus launches — ClaudeBackend seeds its runtime
    /// `skipPermissionsActive` from this. The shield button flips the runtime
    /// state without touching this default.
    var skipPermissions: Bool {
        get { defaults.bool(forKey: K.skipPermissions) }
        set { write(K.skipPermissions, newValue) }
    }

    /// Launch claude with --continue so the most recent conversation in the
    /// working directory reopens on Opus start.
    var resumeLastConversation: Bool {
        get { defaults.bool(forKey: K.resumeLastConversation) }
        set { write(K.resumeLastConversation, newValue) }
    }

    /// Ask before Restart Claude Session (hotkey/menu) nukes the current
    /// conversation. Defaults to TRUE (absent key = ask); the alert's
    /// "Don't ask again" suppression checkbox flips it off.
    var confirmRestart: Bool {
        get { defaults.object(forKey: K.confirmRestart) == nil ? true : defaults.bool(forKey: K.confirmRestart) }
        set { write(K.confirmRestart, newValue) }
    }

    /// Native notification + Dock badge when a session rings the bell while
    /// Opus is in the background. Default ON.
    var notifyOnBell: Bool {
        get { defaults.object(forKey: K.notifyOnBell) == nil ? true : defaults.bool(forKey: K.notifyOnBell) }
        set { write(K.notifyOnBell, newValue) }
    }

    /// Pin the panel so it stays visible when it loses focus. Default OFF
    /// (autohide on focus loss). When pinned, the explicit Cmd+Ctrl+T still
    /// hides the panel.
    var panelPinned: Bool {
        get { defaults.bool(forKey: K.panelPinned) }
        set { write(K.panelPinned, newValue) }
    }

    var workingDirectory: String {
        get {
            defaults.string(forKey: K.workingDirectory)
                ?? (NSHomeDirectory() + "/Documents/GitHub/ClaudeUltra")
        }
        set {
            // Two notifications fire (workingDirectory + recentProjects);
            // observers of opusPreferencesDidChange must stay idempotent.
            write(K.workingDirectory, newValue)
            recentProjects = Self.updatedRecentProjects(recentProjects, adding: newValue)
        }
    }

    /// MRU list of working directories (front = most recent, max 8). Fed by
    /// the workingDirectory setter; consumed by the Switch Project menus.
    var recentProjects: [String] {
        get { (defaults.array(forKey: K.recentProjects) as? [String]) ?? [] }
        set { write(K.recentProjects, newValue) }
    }

    /// Maximum number of paths kept in the MRU list.
    static let recentProjectsLimit = 8

    /// Pure MRU helper — static for testability.
    static func updatedRecentProjects(_ list: [String], adding path: String) -> [String] {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") && trimmed.count > 1 { trimmed = String(trimmed.dropLast()) }
        guard !trimmed.isEmpty else { return list }
        var out = list.filter { $0 != trimmed }
        out.insert(trimmed, at: 0)
        return Array(out.prefix(Self.recentProjectsLimit))
    }

    var displayMode: OpusDisplayMode {
        get {
            let raw = defaults.string(forKey: K.displayMode) ?? OpusDisplayMode.nativeAndPanel.rawValue
            return OpusDisplayMode(rawValue: raw) ?? .nativeAndPanel
        }
        set { write(K.displayMode, newValue.rawValue) }
    }

    var onboardingShown: Bool {
        get { defaults.bool(forKey: K.onboardingShown) }
        set { write(K.onboardingShown, newValue) }
    }

    // Appearance — see Phase 4 for the consumers.
    var appearanceMode: String {
        get { defaults.string(forKey: K.appearanceMode) ?? "default" }
        set { write(K.appearanceMode, newValue) }
    }
    var appearanceTintRGBA: [Double] {
        get { (defaults.array(forKey: K.appearanceTintRGBA) as? [Double]) ?? [0.04, 0.05, 0.07, 0.55] }
        set { write(K.appearanceTintRGBA, newValue) }
    }
    var appearanceImagePath: String? {
        get { defaults.string(forKey: K.appearanceImagePath) }
        set { write(K.appearanceImagePath, newValue) }
    }

    /// Terminal font family name; "" = automatic Nerd-font chain.
    var fontName: String {
        get { defaults.string(forKey: K.fontName) ?? "" }
        set { write(K.fontName, newValue) }
    }

    /// Terminal font size in points, clamped to 9…24 (default 14).
    var fontSize: Double {
        get {
            let v = defaults.double(forKey: K.fontSize)
            return (v >= 9 && v <= 24) ? v : 14
        }
        set { write(K.fontSize, min(24, max(9, newValue))) }
    }

    /// Scrollback depth per pane. Long agent runs easily blow the SwiftTerm
    /// default; clamp keeps memory sane (a line is cheap but not free).
    var scrollbackLines: Int {
        get {
            let v = defaults.integer(forKey: K.scrollbackLines)
            return v == 0 ? 10_000 : min(200_000, max(1_000, v))
        }
        set { write(K.scrollbackLines, min(200_000, max(1_000, newValue))) }
    }

    /// Bump font size by delta, clamped to 9…24 bounds.
    func bumpFontSize(_ delta: Double) { fontSize = fontSize + delta }

    /// Reset font size to default (14 points).
    func resetFontSize() { fontSize = 14 }

    /// Terminal font from prefs. The automatic chain matches the historical
    /// hardcoded fallbacks, with a guaranteed final monospaced system font.
    func resolvedTerminalFont() -> NSFont {
        let size = CGFloat(fontSize)
        if !fontName.isEmpty {
            if let f = NSFont(name: fontName, size: size) { return f }
            // Family names don't always resolve as face names (e.g. "JetBrains
            // Mono") — fall back to the family's first member via NSFontManager.
            if let face = NSFontManager.shared.availableMembers(ofFontFamily: fontName)?.first,
               let psName = face[0] as? String,
               let f = NSFont(name: psName, size: size) { return f }
        }
        return NSFont(name: "MesloLGS NF", size: size)
            ?? NSFont(name: "SF Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Computed

    /// Pure command builder — static so tests exercise it without UserDefaults.
    /// Launch flags (skip-permissions, resume) only apply to the .claude
    /// preset: .shell doesn't run claude and .custom runs the user's verbatim
    /// command (including its empty-string claude fallback).
    ///
    /// `sessionId` (Lot 3, Task 6): the UUID Opus itself minted for this spawn
    /// (see `ClaudeBackend.spawn`/`FilteredClaudeTab.sessionId`), passed
    /// straight through as `--session-id` so Opus KNOWS the exact session a
    /// pane belongs to instead of inferring it from a SessionStart hook race
    /// (ClaudeStateStore's spawn-order heuristic, now a fallback — see its
    /// doc comment). Only wired up when `resumeMode == .none`: `--resume`
    /// and `--continue` reattach an EXISTING transcript (its id is already
    /// fixed by claude, not by us) and are mutually exclusive with
    /// `--session-id` by construction — resume/continue always win, so
    /// `sessionId` is silently ignored whenever `resumeMode` isn't `.none`,
    /// same as any other resumeMode combination test below exercises.
    static func composeSpawnCommand(
        preset: OpusInitialCommandPreset,
        customCommand: String,
        workingDirectory: String,
        skipPermissions: Bool,
        resumeMode: OpusResumeMode,
        permissionMode: OpusPermissionMode = .standard,
        sessionId: String? = nil
    ) -> String {
        // zsh double quotes still expand $VAR, $(...), backticks, and honor
        // backslashes. Escape all four; backslash FIRST or it re-escapes the
        // escapes we just added.
        let cwd = workingDirectory
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        let cdPrefix = "cd \"\(cwd)\" && "
        switch preset {
        case .claude:
            var cmd = "command claude"
            if skipPermissions { cmd += " --dangerously-skip-permissions" }
            if !skipPermissions && permissionMode != .standard {
                cmd += " --permission-mode \(permissionMode.rawValue)"
            }
            switch resumeMode {
            case .none:
                // sessionId is ours (UUID().uuidString.lowercased() — see
                // ClaudeBackend.spawn/FilteredClaudeTab), never shell-unsafe.
                if let sessionId { cmd += " --session-id \(sessionId)" }
            case .continueMostRecent: cmd += " --continue"
            case .resume(let id): cmd += " --resume \(id)"  // IDs are UUID filenames from ClaudeSessionLocator — no shell metachars
            }
            // Claude cockpit event bus (Lot 3, Task 1): inject the pure-observer
            // hooks that report session state over /tmp/opus-events.sock. Only
            // the .claude preset runs claude at all, so only it gets this flag.
            cmd += " --settings \(HookSettingsWriter.escapedSettingsPathForShell)"
            return cdPrefix + cmd
        case .shell:
            return cdPrefix + "exec /bin/zsh -i"
        case .custom:
            let cmd = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return cmd.isEmpty ? cdPrefix + "command claude" : cdPrefix + cmd
        }
    }

    /// The actual shell command to run inside the spawned zsh. Private tabs
    /// (FilteredClaudeTab.start) call this passing the live skip-permissions
    /// state explicitly and always `resumeMode: .none` — they inherit the
    /// current dangerous-mode/permission-mode flags but never resume, since
    /// `--continue`/`--resume` there would attach the same transcript tab 0
    /// is already writing (two claudes on one session file). Because they're
    /// always `resumeMode: .none`, private tabs ALWAYS pass their own minted
    /// `sessionId` (Lot 3, Task 6) too — `--session-id` always applies to
    /// them, never conditionally.
    ///
    /// Every spawn path (ClaudeBackend.spawn, FilteredClaudeTab.start) goes
    /// through here, so this is also where the hooks settings file gets its
    /// pre-flight check: claude HARD-FAILS (exit 1, no session at all) when
    /// --settings points at a file that doesn't exist, so "warmed once at
    /// app launch" isn't enough — a file deleted mid-session would take down
    /// every subsequent restart/private-tab spawn. ensureSettingsFile() is
    /// idempotent and cheap (a content-compare, not an unconditional
    /// rewrite), so doing this unconditionally on every call is fine.
    /// composeSpawnCommand itself stays a pure static function — no
    /// filesystem effects there, only here.
    func resolvedSpawnCommand(
        skipPermissions: Bool = false,
        resumeMode: OpusResumeMode = .none,
        sessionId: String? = nil
    ) -> String {
        if initialCommandPreset == .claude {
            HookSettingsWriter.ensureSettingsFile()
        }
        return Self.composeSpawnCommand(
            preset: initialCommandPreset,
            customCommand: customCommand,
            workingDirectory: workingDirectory,
            skipPermissions: skipPermissions,
            resumeMode: resumeMode,
            permissionMode: permissionMode,
            sessionId: sessionId
        )
    }

    // MARK: Internal

    private func write(_ key: String, _ value: Any?) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .opusPreferencesDidChange, object: nil)
    }

    private init() {}
}
