// UsageLimits — the plan's 5-hour and 7-day usage windows, for the rail.
//
// Claude Code hands its status line command `rate_limits` on every refresh
// (Pro and Max plans, once a first API response has come back). The command
// merges them into Application Support/Opus/usage.json, keeping per window
// the newest reset and, within one window, the highest figure: a session
// sitting idle still holds an older reading, and the account-wide figure
// only ever grows until its reset. Opus reads that file and nothing else.

import Foundation

struct UsageWindow: Equatable {
    enum Kind: CaseIterable {
        case fiveHour, sevenDay

        /// The key the window sits under in usage.json, as Claude Code names it.
        var key: String {
            switch self {
            case .fiveHour: return "five_hour"
            case .sevenDay: return "seven_day"
            }
        }

        var shortName: String {
            switch self {
            case .fiveHour: return "5h"
            case .sevenDay: return "7j"
            }
        }
    }

    let kind: Kind
    /// Share of the window used, 0...100.
    let percent: Double
    let resetsAt: Date
}

enum UsageLimits {
    enum Level { case nominal, attention, critical }

    static var fileURL: URL {
        HookSettingsWriter.settingsDirectory.appendingPathComponent("usage.json")
    }

    /// Both windows the file holds, five-hour first; none for a missing or
    /// malformed file, and none for a window without a figure or a reset.
    static func parse(_ data: Data) -> [UsageWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }

        return UsageWindow.Kind.allCases.compactMap { kind in
            guard let window = root[kind.key] as? [String: Any],
                  let percent = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let resetsAt = (window["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }

            return UsageWindow(kind: kind, percent: percent, resetsAt: Date(timeIntervalSince1970: resetsAt))
        }
    }

    static func read(from url: URL = fileURL) -> [UsageWindow] {
        (try? Data(contentsOf: url)).map(parse) ?? []
    }

    /// The windows still running at `now`.
    static func current(_ windows: [UsageWindow], now: Date = Date()) -> [UsageWindow] {
        windows.filter { $0.resetsAt > now }
    }

    /// Same thresholds as the terminal status line: attention from half the
    /// window, critical from 80%.
    static func level(percent: Double) -> Level {
        if percent >= 80 { return .critical }
        if percent >= 50 { return .attention }
        return .nominal
    }

    /// "5h 42% ↺22:47" for the five-hour window, "7j 83% ↺dim" for the week:
    /// the hour is what matters within five hours, the day within seven.
    static func label(_ window: UsageWindow, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = timeZone
        formatter.dateFormat = window.kind == .fiveHour ? "HH:mm" : "EEE"
        let reset = formatter.string(from: window.resetsAt).replacingOccurrences(of: ".", with: "")

        return "\(window.kind.shortName) \(Int(window.percent.rounded()))% ↺\(reset)"
    }

    /// The tooltip line: the full reset moment, which the rail abbreviates.
    static func tooltip(_ window: UsageWindow, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE HH:mm"
        let name = window.kind == .fiveHour ? "5 heures" : "7 jours"

        return "\(name) : \(Int(window.percent.rounded()))% utilisés, remise à zéro \(formatter.string(from: window.resetsAt))"
    }
}
