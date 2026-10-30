// ArtifactMoment: the drawer's time groups, newest first.
//
// Fixed slices rather than clusters, so a person can predict where a file
// lands: the last hour, the rest of today, yesterday, then one group per
// day. An artifact is dated by its timestamp, which the store keeps at the
// latest mention: a file Claude cites again comes back up, as it is current
// again. A missing timestamp goes to a last group of its own rather than
// passing for recent.

import Foundation

public enum ArtifactMoment: Hashable, Sendable {
    case lastHour, today, yesterday
    /// The start of that day, in the calendar the moment was computed with.
    case day(Date)
    case undated

    public static func of(_ timestamp: Date?, now: Date, calendar: Calendar) -> ArtifactMoment {
        guard let timestamp else { return .undated }
        // A timestamp slightly ahead of `now` (clocks of two machines, a
        // transcript written a moment after the read) is still the last hour.
        if now.timeIntervalSince(timestamp) < 3600 { return .lastHour }
        if calendar.isDate(timestamp, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(timestamp, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .day(calendar.startOfDay(for: timestamp))
    }

    public func title(calendar: Calendar) -> String {
        switch self {
        case .lastHour: return "Dernière heure"
        case .today: return "Aujourd'hui"
        case .yesterday: return "Hier"
        case .undated: return "Plus tôt"
        case .day(let start):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEEE d MMMM"
            return formatter.string(from: start)
        }
    }
}

public struct ArtifactSection: Equatable {
    public let moment: ArtifactMoment
    /// Kind `.image`, newest first.
    public let images: [Artifact]
    /// Everything else, newest first.
    public let others: [Artifact]
}

public enum ArtifactSections {
    public static func build(_ artifacts: [Artifact], now: Date, calendar: Calendar) -> [ArtifactSection] {
        // Stable sort: equal timestamps (and undated ones) keep their order.
        let newestFirst = artifacts.enumerated().sorted { lhs, rhs in
            let l = lhs.element.timestamp ?? .distantPast
            let r = rhs.element.timestamp ?? .distantPast
            return l != r ? l > r : lhs.offset < rhs.offset
        }.map(\.element)

        var order: [ArtifactMoment] = []
        var grouped: [ArtifactMoment: [Artifact]] = [:]
        for artifact in newestFirst {
            let moment = ArtifactMoment.of(artifact.timestamp, now: now, calendar: calendar)
            if grouped[moment] == nil { order.append(moment) }
            grouped[moment, default: []].append(artifact)
        }

        // Moments only ever get older as timestamps do, and undated ones sort
        // last, so first-seen order is already newest first.
        return order.map { moment in
            let members = grouped[moment] ?? []
            return ArtifactSection(moment: moment,
                                   images: members.filter { $0.kind == .image },
                                   others: members.filter { $0.kind != .image })
        }
    }
}
