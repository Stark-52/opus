// BridgeServer — Opus's end of the bridge (`opus-attach ask` / `reply`, see
// OpusBridgeKit). It listens on a socket of its own, apart from
// /tmp/opus.sock (raw bytes for the shared session) and /tmp/opus-events.sock
// (hooks): one request per connection, one JSON line in, JSON lines out.
//
// BridgeCoordinator does the work on the main thread: it opens a tab in the
// background with the task as claude's first prompt (or types a follow-up
// into an idle bridge session), then follows that session's hook events until
// the turn ends, and sends back the final answer read off the transcript.

import Foundation
import Darwin
import OpusBridgeKit

final class BridgeServer {
    typealias Reply = (BridgeMessage) -> Void
    typealias Handler = (BridgeRequest, @escaping Reply) -> Void

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "opus.bridge-server", qos: .userInitiated)

    /// `handler` runs on the main queue. Its `Reply` may be called from any
    /// queue, once per message; the connection closes after the first final one.
    init(path: String = BridgeProtocol.socketPath,
         handler: @escaping Handler = { BridgeCoordinator.shared.handle($0, reply: $1) }) {
        self.path = path
        self.handler = handler
    }

    func start() {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("Opus BridgeServer: socket() failed errno=\(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                strncpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, dest.count - 1)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else {
            NSLog("Opus BridgeServer: bind() failed errno=\(errno)")
            close(listenFD); listenFD = -1
            return
        }
        // Whoever can connect can start a Claude session: owner only.
        chmod(path, 0o600)
        guard listen(listenFD, 8) == 0 else {
            NSLog("Opus BridgeServer: listen() failed errno=\(errno)")
            close(listenFD); listenFD = -1
            return
        }
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        NSLog("Opus BridgeServer: listening on \(path)")
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connection = BridgeConnection(fd: fd)
        guard let line = Self.readLine(fd),
              let request = BridgeWire.decode(BridgeRequest.self, from: line) else {
            connection.send(BridgeMessage(kind: .error, message: "Requête illisible."))
            return
        }
        let handler = handler
        DispatchQueue.main.async { handler(request) { connection.send($0) } }
    }

    /// The bytes up to the first newline, or to the end when the client closes
    /// its side without one. Nil past `BridgeProtocol.maxRequestBytes`.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= BridgeProtocol.maxRequestBytes {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return data.isEmpty ? nil : data }
            if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<n])
        }
        return nil
    }

    /// Every byte, or as many as the client still takes: a client that gave up
    /// waiting is not an error.
    static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, pointer, left)
                if n <= 0 { return }
                pointer = pointer.advanced(by: n)
                left -= n
            }
        }
    }
}

/// One client: messages go out in order, and the first final one closes it.
private final class BridgeConnection {
    private let fd: Int32
    private let queue = DispatchQueue(label: "opus.bridge-connection")
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    func send(_ message: BridgeMessage) {
        queue.async { [self] in
            guard !closed else { return }
            BridgeServer.writeAll(BridgeWire.line(message), to: fd)
            if message.isFinal {
                closed = true
                close(fd)
            }
        }
    }
}

/// What the bridge does inside Opus. Main thread only.
final class BridgeCoordinator {
    static let shared = BridgeCoordinator()

    private struct Waiter {
        let session: String
        var watch: TurnWatch
        var transcript: String
        let reply: BridgeServer.Reply
    }

    private var waiters: [Waiter] = []

    private init() {
        NotificationCenter.default.addObserver(forName: .opusClaudeEvent, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?["event"] as? OpusClaudeEvent else { return }
            self?.observe(event)
        }
    }

    func handle(_ request: BridgeRequest, reply: @escaping BridgeServer.Reply) {
        switch request.op {
        case .ask: ask(request, reply: reply)
        case .reply: readBack(request, reply: reply)
        }
    }

    private func ask(_ request: BridgeRequest, reply: @escaping BridgeServer.Reply) {
        let task = (request.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return reply(BridgeMessage(kind: .error, message: "Tâche vide.")) }

        guard let session = request.session else {
            // A new tab, in the background, with the task as claude's first prompt.
            guard let container = AppDelegate.shared?.bridgeContainer(),
                  let session = container.spawnNewTab(codeMode: request.codeMode, prompt: task, activate: false) else {
                return reply(BridgeMessage(kind: .error, message: "Opus n'a aucune fenêtre où ouvrir l'onglet."))
            }
            reply(BridgeMessage(kind: .accepted, session: session))
            waiters.append(Waiter(session: session, watch: TurnWatch(awaitingPrompt: false), transcript: "", reply: reply))
            return
        }

        // A follow-up, typed into the tab of an earlier delegated session.
        guard let (container, pane) = locate(session) else {
            return reply(BridgeMessage(kind: .error, session: session,
                                       message: "Aucun onglet privé d'Opus ne porte la session \(session)."))
        }
        switch ClaudeStateStore.shared.state(forSessionId: session) {
        case .working:
            return reply(BridgeMessage(kind: .error, session: session,
                                       message: "La session travaille encore : attends sa réponse (opus-attach reply \(session))."))
        case .needsInput:
            return reply(BridgeMessage(kind: .error, session: session,
                                       message: "La session attend une réponse dans son onglet."))
        case .idle, .done:
            break
        }
        guard !container.paneHasKeyboardFocus(pane) else {
            return reply(BridgeMessage(kind: .error, session: session,
                                       message: "Cet onglet a le clavier : rien n'y est tapé pendant qu'on s'en sert."))
        }
        container.submitPrompt(task, to: pane)
        reply(BridgeMessage(kind: .accepted, session: session))
        waiters.append(Waiter(session: session, watch: TurnWatch(awaitingPrompt: true), transcript: "", reply: reply))
    }

    /// The claude behind a delegated session stopped (tab closed, process
    /// ended, restart): whoever waits on it hears so now rather than at its
    /// timeout.
    func sessionEnded(_ session: String) {
        let ended = waiters.filter { $0.session == session }
        guard !ended.isEmpty else { return }
        waiters.removeAll { $0.session == session }
        for waiter in ended {
            waiter.reply(BridgeMessage(kind: .error, session: session,
                                       message: "La session s'est arrêtée avant la fin de son tour (onglet fermé ou claude arrêté)."))
        }
    }

    private func readBack(_ request: BridgeRequest, reply: @escaping BridgeServer.Reply) {
        guard let session = request.session, !session.isEmpty else {
            return reply(BridgeMessage(kind: .error, message: "Session manquante."))
        }
        switch ClaudeStateStore.shared.state(forSessionId: session) {
        case .working:
            guard request.wait else {
                return reply(BridgeMessage(kind: .working, session: session, message: "La session travaille encore."))
            }
            reply(BridgeMessage(kind: .accepted, session: session))
            waiters.append(Waiter(session: session, watch: TurnWatch(awaitingPrompt: false), transcript: "", reply: reply))
        case .needsInput:
            Self.finish(session: session, transcript: nil,
                        outcome: .needsInput(message: "La session attend une réponse dans son onglet."), reply: reply)
        case .idle, .done:
            Self.finish(session: session, transcript: nil, outcome: .done, reply: reply)
        }
    }

    private func observe(_ event: OpusClaudeEvent) {
        guard waiters.contains(where: { $0.session == event.sessionId }) else { return }
        let mapped: TurnWatch.Event
        switch event.kind {
        case .promptSubmitted: mapped = .promptSubmitted
        case .turnEnded: mapped = .turnEnded
        case .needsAttention(let kind, let message): mapped = .attention(kind: kind, message: message)
        default: mapped = .other
        }
        var remaining: [Waiter] = []
        for var waiter in waiters {
            guard waiter.session == event.sessionId else {
                remaining.append(waiter)
                continue
            }
            if !event.transcriptPath.isEmpty { waiter.transcript = event.transcriptPath }
            if let outcome = waiter.watch.observe(mapped) {
                Self.finish(session: waiter.session, transcript: waiter.transcript, outcome: outcome, reply: waiter.reply)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    /// Reads the answer off the transcript, away from the main thread, and
    /// sends the final message. The Stop hook can run a hair before the last
    /// record is on disk, hence the short wait and the few tries.
    private static func finish(session: String, transcript: String?, outcome: TurnWatch.Outcome,
                               reply: @escaping BridgeServer.Reply) {
        DispatchQueue.global(qos: .userInitiated).async {
            let reported = transcript.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            var url = reported ?? CodeModeSessions.shared.transcript(for: session)
            var text: String?
            for attempt in 0..<5 {
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.4 : 0.5)
                if url == nil { url = CodeModeSessions.shared.transcript(for: session) }
                if let url, let found = readReply(url) {
                    text = found
                    break
                }
            }
            switch outcome {
            case .done:
                if let text {
                    reply(BridgeMessage(kind: .done, session: session, reply: text))
                } else if url == nil {
                    reply(BridgeMessage(kind: .error, session: session, message: "Aucune transcription pour cette session."))
                } else {
                    reply(BridgeMessage(kind: .done, session: session, reply: "", message: "Le tour s'est fini sans réponse écrite."))
                }
            case .needsInput(let message):
                reply(BridgeMessage(kind: .needsInput, session: session, reply: text,
                                    message: message.isEmpty ? "La session attend une réponse dans son onglet." : message))
            }
        }
    }

    static func readReply(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return ReplyReader.lastReply { budget in
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(budget) ? size - UInt64(budget) : 0)
            return try? handle.readToEnd()
        }
    }

    private func locate(_ session: String) -> (TerminalContainerView, TabPane)? {
        for container in AppDelegate.shared?.bridgeContainers() ?? [] {
            if let pane = container.privatePane(forSession: session) { return (container, pane) }
        }
        return nil
    }
}
