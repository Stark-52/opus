// EventSocketServer — the read side of the Claude Code hook bus.
//
// HookSettingsWriter injects six pure-observer hooks (UserPromptSubmit,
// PreToolUse, PostToolUse, Notification, Stop, SessionStart) into every
// spawned `claude` via --settings. Each hook fires `opus-attach event
// <Name>`, which forwards claude's own hook stdin JSON — newline-compacted
// to one line, see Sources/opus-attach/main.swift's `event` subcommand — to
// /tmp/opus-events.sock and exits. This file is the listener on the other
// end: structurally a copy of SocketServer's bind/listen/accept (same
// errno-logging shape; the listen() backlog and accept-queue QoS differ —
// see start()/acceptQueue below), but one-directional and connection-per-line
// instead of a persistent duplex pipe. Each accepted connection is read to
// EOF, split on 0x0A, and each line is handed to OpusClaudeEvent.parse — a
// line that doesn't decode into a known event is dropped silently (claude's
// hook payload shapes may gain fields or events over time; a parse miss must
// never crash Opus).
//
// Concurrency: two claude sessions (e.g. the shared tab and a private tab)
// emitting hooks at the same moment each open their OWN connection — a
// `socket()+connect()+write()+close()` per hook invocation, never shared or
// pooled. acceptLoop() hands each fd to a fresh async read task instead of
// handling it inline, so slow/concurrent hook processes don't serialize
// behind one another and never block accept() from taking the next
// connection. There is no cross-connection buffering or interleaving to
// worry about: each connection's bytes are entirely its own.

import Foundation
import Darwin

/// Posted on the main queue for every successfully parsed hook event.
/// `userInfo["event"]` holds the `OpusClaudeEvent`.
extension Notification.Name {
    static let opusClaudeEvent = Notification.Name("com.stark52.opus.claudeEvent")
}

/// One parsed Claude Code hook firing. `sessionId`/`cwd` come from the
/// common fields every hook payload carries; `kind` captures the
/// event-specific shape.
struct OpusClaudeEvent: Equatable {
    let sessionId: String
    let cwd: String
    let kind: Kind

    enum Kind: Equatable {
        case promptSubmitted
        case toolUse(name: String)
        case toolDone
        /// `kind` is the Notification payload's own `type` field
        /// (permission_prompt|idle_prompt|auth_success|elicitation_dialog|
        /// agent_needs_input|agent_completed) — named `kind` on the case to
        /// avoid colliding with the enclosing `Kind` type's own name.
        case needsAttention(kind: String, message: String)
        case turnEnded
        /// `source`: startup|resume|clear|compact|fork.
        case sessionStarted(source: String)

        /// Fix 4 (v1.4.2) — cheap one-line description for the diagnostic
        /// NSLog in `EventSocketServer.handleClient`. The state bus has
        /// never been observed end-to-end; this lets `log show` confirm
        /// hooks are actually firing without needing a GUI screenshot.
        var logDescription: String {
            switch self {
            case .promptSubmitted: return "promptSubmitted"
            case .toolUse(let name): return "toolUse(\(name))"
            case .toolDone: return "toolDone"
            case .needsAttention(let kind, _): return "needsAttention(\(kind))"
            case .turnEnded: return "turnEnded"
            case .sessionStarted(let source): return "sessionStarted(\(source))"
            }
        }
    }

    /// Parses one line of hook stdin (already newline-compacted by
    /// opus-attach — see its `event` subcommand). Pure, side-effect-free,
    /// fully unit tested. Returns nil for anything that isn't recognizable
    /// JSON with a known `hook_event_name` — malformed/future/unexpected
    /// input is dropped, never crashes the caller.
    static func parse(line: Data) -> OpusClaudeEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let eventName = obj["hook_event_name"] as? String
        else { return nil }

        let sessionId = obj["session_id"] as? String ?? ""
        let cwd = obj["cwd"] as? String ?? ""

        let kind: Kind
        switch eventName {
        case "UserPromptSubmit":
            kind = .promptSubmitted
        case "PreToolUse":
            kind = .toolUse(name: obj["tool_name"] as? String ?? "")
        case "PostToolUse":
            kind = .toolDone
        case "Notification":
            kind = .needsAttention(
                kind: obj["type"] as? String ?? "",
                message: obj["message"] as? String ?? ""
            )
        case "Stop":
            kind = .turnEnded
        case "SessionStart":
            kind = .sessionStarted(source: obj["source"] as? String ?? "")
        default:
            return nil   // unrecognized event name — not one of our six hooks
        }

        return OpusClaudeEvent(sessionId: sessionId, cwd: cwd, kind: kind)
    }
}

final class EventSocketServer {
    private let path: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "opus.event-socket-server", qos: .utility)

    init(path: String = "/tmp/opus-events.sock") {
        self.path = path
    }

    func start() {
        unlink(path)   // remove any stale socket file

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("Opus EventSocketServer: socket() failed errno=\(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                strncpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, dest.count - 1)
            }
        }

        let bindOK = withUnsafePointer(to: &addr) { addrPtr -> Bool in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bindOK else {
            NSLog("Opus EventSocketServer: bind() failed errno=\(errno)")
            close(listenFD); listenFD = -1
            return
        }
        // Same rationale as SocketServer: connect() on a UNIX socket needs
        // write permission on the socket file — don't rely on ambient umask.
        chmod(path, 0o600)
        guard listen(listenFD, 8) == 0 else {
            NSLog("Opus EventSocketServer: listen() failed errno=\(errno)")
            close(listenFD); listenFD = -1
            return
        }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
        NSLog("Opus EventSocketServer: listening on \(path)")
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &clientLen)
                }
            }
            if fd < 0 {
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            // Each hook invocation is a short-lived one-shot connection
            // (connect, write, close) — hand it to its own task so a burst
            // of concurrent hooks (two live sessions firing at once) never
            // serializes behind each other or blocks the next accept().
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(fd: fd)
            }
        }
    }

    private func handleClient(fd: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        close(fd)

        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let event = OpusClaudeEvent.parse(line: Data(line)) else { continue }
            // Fix 4 (v1.4.2): one NSLog per successfully parsed event —
            // see Kind.logDescription's doc comment above.
            NSLog("Opus EventSocketServer: %@ session=%@", event.kind.logDescription, event.sessionId)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .opusClaudeEvent, object: nil,
                    userInfo: ["event": event]
                )
            }
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }
}
