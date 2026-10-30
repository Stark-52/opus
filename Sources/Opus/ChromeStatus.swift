// ChromeStatus — the status bar's words: the context as a percentage, the
// week's usage, the five-hour window's. Token counts and reset moments go
// in the tooltip; the bar says only what is read at a glance.

import CoreGraphics
import Foundation

enum ChromeStatus {
    /// "contexte 36 %", with the no-break space French puts before "%".
    static func context(fraction: CGFloat?) -> String? {
        fraction.map { "contexte \(percent(Double($0) * 100))" }
    }

    static func week(_ windows: [UsageWindow]) -> String? {
        windows.first { $0.kind == .sevenDay }.map { "semaine \(percent($0.percent))" }
    }

    static func fiveHour(_ windows: [UsageWindow]) -> String? {
        windows.first { $0.kind == .fiveHour }.map { "5h \(percent($0.percent))" }
    }

    /// The token count against the window's limit, then each usage window
    /// with its full reset moment.
    static func tooltip(tokens: Int?, limit: Int?, windows: [UsageWindow]) -> String {
        var lines: [String] = []
        if let tokens, let limit, limit > 0 {
            let k = { (value: Int) in Int((Double(value) / 1000).rounded()) }
            lines.append("\(k(tokens))k / \(k(limit))k tokens (\(percent(Double(tokens) / Double(limit) * 100)))")
        }
        lines += windows.map { UsageLimits.tooltip($0) }
        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))\u{00A0}%"
    }
}
