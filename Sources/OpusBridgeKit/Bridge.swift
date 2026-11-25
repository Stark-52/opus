// OpusBridgeKit — the bridge that lets one Claude session hand a task to
// another one running in Opus (`opus-attach ask`): the messages both sides
// exchange, and the rule that says when the delegated turn is over.
//
// One connection per request. The client writes one JSON object on one line;
// Opus answers with one JSON object per line: `accepted` (with the session id)
// as soon as the task is in, then one final message.

import Foundation

public enum BridgeProtocol {
    /// Where Opus listens. OPUS_BRIDGE_SOCKET overrides it, for tests.
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["OPUS_BRIDGE_SOCKET"] ?? "/tmp/opus-bridge.sock"
    }

    /// A request longer than this is refused: a brief, not a file dump.
    public static let maxRequestBytes = 1 << 20
}

public struct BridgeRequest: Codable, Equatable {
    public enum Op: String, Codable {
        case ask, reply
    }

    public var op: Op
    /// ask: the task.
    public var task: String?
    /// ask: go on in this session instead of opening a tab. reply: the session to read.
    public var session: String?
    /// ask, new tab: open it in code mode (the default) or as a plain tab.
    public var codeMode: Bool
    /// reply: wait for the session's turn to end before answering.
    public var wait: Bool

    public init(op: Op, task: String? = nil, session: String? = nil, codeMode: Bool = true, wait: Bool = false) {
        self.op = op
        self.task = task
        self.session = session
        self.codeMode = codeMode
        self.wait = wait
    }

    /// Missing flags take their defaults, so a client that leaves one out is still understood.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(Op.self, forKey: .op)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        codeMode = try c.decodeIfPresent(Bool.self, forKey: .codeMode) ?? true
        wait = try c.decodeIfPresent(Bool.self, forKey: .wait) ?? false
    }
}

public struct BridgeMessage: Codable, Equatable {
    public enum Kind: String, Codable {
        /// The task is in; `session` names the conversation.
        case accepted
        /// The turn ended; `reply` is its final answer.
        case done
        /// The session waits for a person (a permission, a question); `message` says what.
        case needsInput
        /// Still at work (a reply asked for without waiting).
        case working
        /// Nothing was done; `message` says why.
        case error
    }

    public var kind: Kind
    public var session: String?
    public var reply: String?
    public var message: String?

    public init(kind: Kind, session: String? = nil, reply: String? = nil, message: String? = nil) {
        self.kind = kind
        self.session = session
        self.reply = reply
        self.message = message
    }

    /// Every message but `accepted` ends the exchange.
    public var isFinal: Bool { kind != .accepted }
}

public enum BridgeWire {
    /// One JSON object and a newline. JSON escapes the newlines inside strings,
    /// so a message is always exactly one line.
    public static func line<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }
}

/// Follows one session's hook events and says when the delegated turn is over.
public struct TurnWatch: Equatable {
    public enum Event: Equatable {
        case promptSubmitted
        case turnEnded
        case attention(kind: String, message: String)
        case other
    }

    public enum Outcome: Equatable {
        case done
        case needsInput(message: String)
    }

    /// Notifications that mean the session waits for a person. `idle_prompt`
    /// is not one: it only comes once a turn has ended.
    public static let waitingKinds: Set<String> = ["permission_prompt", "elicitation_dialog", "agent_needs_input"]

    private var promptSeen: Bool

    /// A new tab's task is its first turn: nothing to wait for before it. A
    /// follow-up must see its own prompt go in first, or the end of an earlier
    /// turn would be taken for its own.
    public init(awaitingPrompt: Bool) {
        promptSeen = !awaitingPrompt
    }

    public mutating func observe(_ event: Event) -> Outcome? {
        switch event {
        case .promptSubmitted:
            promptSeen = true
            return nil
        case .turnEnded:
            return promptSeen ? .done : nil
        case .attention(let kind, let message):
            return promptSeen && Self.waitingKinds.contains(kind) ? .needsInput(message: message) : nil
        case .other:
            return nil
        }
    }
}
