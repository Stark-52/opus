// opus-attach — Terminal.app's counterpart to the Opus QT panel.
//
// Connects to Opus's Unix socket and bridges this terminal's stdin/stdout to
// the shared claude session owned by Opus.app.
//
// Wire protocol:
//   - Normal stdin bytes  → forwarded to socket as raw (claude input)
//   - Socket bytes        → forwarded to stdout (claude output)
//   - Control prefix (9 bytes): ESC + "Opus" + 2 bytes cols (BE) + 2 bytes rows (BE)
//     Sent client→server only, on initial connect and on every SIGWINCH.
//     Server uses it to resize claude's PTY to match this terminal's actual size.
//
// Usage:    opus-attach                     (uses /tmp/opus.sock)
//           opus-attach <path>              (custom socket path)
//           opus-attach send [-n] <text...> (one-shot prompt injection, then exit;
//                                             -n = don't submit, just type it)
//           opus-attach ask [--normal] [--to <session>] [--wait <s>] [task...]
//                                            (hand a task to a new code mode tab
//                                             in Opus and print its final answer;
//                                             the task is read on stdin if absent)
//           opus-attach reply <session> [--wait <s>]
//                                            (the answer of a delegated session)
//           opus-attach event <EventName>   (Claude Code hook command, see
//                                             HookSettingsWriter — relays hook
//                                             stdin to /tmp/opus-events.sock)

import Foundation
import Darwin
import OpusBridgeKit

/// `opus-attach event <EventName>` — invoked as a Claude Code hook command
/// (registered by HookSettingsWriter). Forwards the hook's own stdin JSON —
/// newline-compacted to a single line — to /tmp/opus-events.sock, then
/// returns. `<EventName>` is accepted only for operator visibility (`ps`,
/// debugging); it is never parsed here — `hook_event_name` already rides
/// inside the JSON payload itself, and that's what EventSocketServer.parse
/// reads on the other end.
///
/// MUST be a pure, silent observer: on UserPromptSubmit, claude parses this
/// process's STDOUT as context-injection JSON when it exits 0 — writing
/// anything there would inject garbage into every prompt the user submits.
/// stderr also stays silent in normal operation (a missing/refused Opus
/// socket is not an error worth surfacing to claude's transcript). The
/// caller (event subcommand's caller below) always exits 0 unconditionally
/// afterward — claude must never be slowed or blocked by Opus being absent,
/// broken, or slow to accept the connection.
func runEventSubcommand() {
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()

    // Raw newlines only ever occur BETWEEN JSON tokens (pretty-printed hook
    // stdin); in-string newlines are already escaped `\n` two-char
    // sequences, so blanking 0x0A/0x0D is safe and guarantees the socket
    // protocol's one-line-per-event framing regardless of how claude
    // formatted the payload.
    var compacted = stdinData
    for i in compacted.indices where compacted[i] == 0x0A || compacted[i] == 0x0D {
        compacted[i] = 0x20
    }

    // Stamp this process's own pid into the payload, so the receiving side
    // can work out WHICH pane the event belongs to by walking up from here
    // to the pane's shell. Nothing else in a hook payload identifies a pane:
    // session_id names the conversation, and after a `/resume` that is no
    // longer the id Opus spawned the pane with, which is exactly how a pane
    // ends up reading a transcript that does not exist.
    //
    // Injected at the byte level, immediately after the opening brace,
    // rather than by decoding and re-encoding: this subcommand's whole
    // contract is that it forwards the payload verbatim, and a round trip
    // through JSONSerialization would silently reorder keys and could drop
    // anything Foundation cannot represent.
    if let brace = compacted.firstIndex(of: 0x7B) {   // '{'
        let field = Data("\"opus_pid\":\(getpid()),".utf8)
        compacted.insert(contentsOf: field, at: compacted.index(after: brace))
    }

    compacted.append(0x0A)

    let eventSock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard eventSock >= 0 else { return }
    defer { close(eventSock) }

    var eaddr = sockaddr_un()
    eaddr.sun_family = sa_family_t(AF_UNIX)
    "/tmp/opus-events.sock".withCString { cstr in
        withUnsafeMutableBytes(of: &eaddr.sun_path) { dest in
            _ = strncpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, dest.count - 1)
        }
    }
    let connected = withUnsafePointer(to: &eaddr) { ptr -> Bool in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(eventSock, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard connected else { return }   // Opus not running — silent no-op, never fail the hook

    compacted.withUnsafeBytes { buf in
        _ = write(eventSock, buf.baseAddress, buf.count)
    }
}

// Subcommand: `opus-attach send [-n] <text...>` — one-shot prompt injection
// into the live shared session, then exit. No TTY dance, no mirror.
var args = Array(CommandLine.arguments.dropFirst())

if args.first == "event" {
    // A write into a half-closed Opus socket must never signal-kill this
    // hook process — that would surface as a non-zero/signal exit status
    // instead of the guaranteed exit(0) below.
    signal(SIGPIPE, SIG_IGN)
    runEventSubcommand()
    exit(0)
}

if args.first == "ask" || args.first == "reply" {
    runBridgeSubcommand(args)
}

var sendMode = false
var sendNoNewline = false
if args.first == "send" {
    sendMode = true
    args.removeFirst()
    if args.first == "-n" { sendNoNewline = true; args.removeFirst() }
}
let socketPath = (!sendMode && args.count >= 1) ? args[0] : "/tmp/opus.sock"
let OPUS_MAGIC: [UInt8] = [0x1B, 0x4F, 0x70, 0x75, 0x73]   // "ESC O p u s"

// MARK: connect

let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else {
    FileHandle.standardError.write("opus-attach: socket() failed\n".data(using: .utf8)!)
    exit(1)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
socketPath.withCString { cstr in
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
        _ = strncpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, dest.count - 1)
    }
}

let connectOK = withUnsafePointer(to: &addr) { ptr -> Bool in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
    }
}
guard connectOK else {
    FileHandle.standardError.write("opus-attach: cannot connect to \(socketPath); is Opus running?\n".data(using: .utf8)!)
    exit(1)
}

if sendMode {
    let text = args.joined(separator: " ")
    guard !text.isEmpty else {
        FileHandle.standardError.write("usage: opus-attach send [-n] <text>\n".data(using: .utf8)!)
        exit(1)
    }
    var payload = Array(text.utf8)
    if !sendNoNewline { payload.append(0x0D) }   // CR submits the prompt
    payload.withUnsafeBufferPointer { buf in
        _ = write(sock, buf.baseAddress, buf.count)
    }
    // No flush delay needed: on AF_UNIX stream sockets a successful write()
    // has already handed the bytes to the kernel, and close() does not
    // discard data still buffered for the peer.
    close(sock)
    exit(0)
}

// MARK: TTY raw mode + restore on exit/signal

var oldTermios = termios()
let isTTY = isatty(0) != 0
if isTTY {
    tcgetattr(0, &oldTermios)
    var raw = oldTermios
    cfmakeraw(&raw)
    tcsetattr(0, TCSADRAIN, &raw)
}

var oldTermiosCopy = oldTermios   // captured by atexit/signal handlers
atexit {
    var t = oldTermiosCopy
    tcsetattr(0, TCSADRAIN, &t)
}
let restoreTermios: @convention(c) (Int32) -> Void = { _ in
    var t = oldTermiosCopy
    tcsetattr(0, TCSADRAIN, &t)
    _ = write(1, "\n", 1)
    _exit(0)
}
signal(SIGINT,  restoreTermios)
signal(SIGTERM, restoreTermios)
signal(SIGHUP,  restoreTermios)
signal(SIGPIPE, SIG_IGN)   // dead socket must not kill us mid-write

/// Restore the TTY and exit — used when the socket write side dies.
func exitDisconnected() -> Never {
    if isTTY {
        var t = oldTermiosCopy
        tcsetattr(0, TCSADRAIN, &t)
    }
    FileHandle.standardError.write("\nopus-attach: connection closed\n".data(using: .utf8)!)
    exit(0)
}

// MARK: window-size reporting (initial + on SIGWINCH)

// Self-pipe so the SIGWINCH handler (signal-safe) just writes a byte; the main
// flow reads it and does the actual ioctl/socket write off the handler.
var winchPipe: [Int32] = [0, 0]
_ = pipe(&winchPipe)

let winchHandler: @convention(c) (Int32) -> Void = { _ in
    var b: UInt8 = 1
    _ = write(winchPipeWriteFD, &b, 1)
}
var winchPipeWriteFD = winchPipe[1]   // captured by the C-style signal handler
signal(SIGWINCH, winchHandler)

func sendCurrentSize() {
    var ws = winsize()
    if ioctl(0, TIOCGWINSZ, &ws) != 0 { return }
    var msg: [UInt8] = OPUS_MAGIC + [
        UInt8(ws.ws_col >> 8), UInt8(ws.ws_col & 0xff),
        UInt8(ws.ws_row >> 8), UInt8(ws.ws_row & 0xff)
    ]
    if write(sock, &msg, msg.count) < 0 && errno == EPIPE { exitDisconnected() }
}

sendCurrentSize()   // initial size at connect

// Background thread that drains the self-pipe and sends size updates.
let winchQueue = DispatchQueue(label: "opus-attach.winch")
winchQueue.async {
    var b: UInt8 = 0
    while true {
        let n = read(winchPipe[0], &b, 1)
        if n <= 0 { break }
        sendCurrentSize()
    }
}

// MARK: data relay

let recvQueue = DispatchQueue(label: "opus-attach.recv")
recvQueue.async {
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(sock, &buf, buf.count)
        if n <= 0 {
            if isTTY {
                var t = oldTermiosCopy
                tcsetattr(0, TCSADRAIN, &t)
            }
            FileHandle.standardError.write("\nopus-attach: connection closed\n".data(using: .utf8)!)
            exit(0)
        }
        _ = write(1, &buf, n)
    }
}

var buf = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(0, &buf, buf.count)
    if n <= 0 { break }
    if write(sock, &buf, n) < 0 { exitDisconnected() }
}

if isTTY {
    var t = oldTermios
    tcsetattr(0, TCSADRAIN, &t)
}

// MARK: bridge (ask / reply)

/// `opus-attach ask` / `opus-attach reply`: the bridge's command line (see
/// OpusBridgeKit). stdout carries the answer alone, so a caller can capture
/// it; everything else goes to stderr. Exit codes: 0 the answer, 1 an error,
/// 2 the session waits for a person in its tab, 3 still at work (stdout then
/// holds the session id, for `opus-attach reply`).
func runBridgeSubcommand(_ arguments: [String]) -> Never {
    signal(SIGPIPE, SIG_IGN)
    let usage = """
        usage: opus-attach ask [--normal] [--to <session>] [--wait <secondes>] [tâche...]
               opus-attach reply <session> [--wait <secondes>]
        """
    func say(_ text: String) { FileHandle.standardError.write(Data(("opus-attach: " + text + "\n").utf8)) }
    func fail(_ text: String) -> Never { say(text); exit(1) }

    var rest = Array(arguments.dropFirst())
    let isAsk = arguments.first == "ask"
    var waitSeconds = 540.0
    var codeMode = true
    var target: String?
    var words: [String] = []
    while !rest.isEmpty {
        let arg = rest.removeFirst()
        switch arg {
        case "--wait":
            guard let value = rest.first.flatMap(Double.init), value >= 0 else { fail(usage) }
            waitSeconds = value
            rest.removeFirst()
        case "--normal":
            codeMode = false
        case "--to":
            guard let value = rest.first, !value.isEmpty else { fail(usage) }
            target = value
            rest.removeFirst()
        case "--":
            words += rest
            rest = []
        default:
            words.append(arg)
        }
    }

    let request: BridgeRequest
    if isAsk {
        var task = words.joined(separator: " ")
        if task.isEmpty, isatty(0) == 0 {
            task = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail(usage) }
        request = BridgeRequest(op: .ask, task: task, session: target, codeMode: codeMode)
    } else {
        guard let session = words.first ?? target else { fail(usage) }
        request = BridgeRequest(op: .reply, session: session, wait: waitSeconds > 0)
    }

    let path = BridgeProtocol.socketPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket() a échoué") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { cstr in
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            _ = strncpy(dest.baseAddress!.assumingMemoryBound(to: CChar.self), cstr, dest.count - 1)
        }
    }
    let connected = withUnsafePointer(to: &addr) { ptr -> Bool in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard connected else { fail("aucun pont Opus sur \(path) : Opus est-il lancé, dans une version qui a le pont ?") }

    let out = BridgeWire.line(request)
    let sent = out.withUnsafeBytes { raw -> Bool in
        var pointer = raw.baseAddress!
        var left = raw.count
        while left > 0 {
            let n = write(fd, pointer, left)
            if n <= 0 { return false }
            pointer = pointer.advanced(by: n)
            left -= n
        }
        return true
    }
    guard sent else { fail("la demande n'a pas pu être envoyée à Opus") }

    var session = target ?? (isAsk ? nil : words.first)
    func stillWorking(_ text: String) -> Never {
        say(text)
        if let session { print(session) }
        exit(3)
    }
    // The first message comes at once (the tab is open, or the reply is
    // there); the final one may take as long as `--wait` allows.
    let start = Date()
    var gotFirst = false
    var pending = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let message = BridgeWire.decode(BridgeMessage.self, from: Data(line)) else { continue }
            gotFirst = true
            if let id = message.session { session = id }
            let id = session ?? "?"
            switch message.kind {
            case .accepted:
                if isAsk {
                    say(target == nil
                        ? "session \(id) : onglet \(codeMode ? "Code Mode" : "normal") ouvert dans Opus, en arrière-plan"
                        : "session \(id) : suite envoyée dans son onglet")
                }
                if waitSeconds == 0 { stillWorking("réponse plus tard : opus-attach reply \(id) --wait 540") }
            case .done:
                if let note = message.message { say(note) }
                print(message.reply ?? "")
                exit(0)
            case .needsInput:
                say("la session \(id) attend une réponse dans son onglet Opus : \(message.message ?? "")")
                if let partial = message.reply, !partial.isEmpty { say("dernier texte : " + partial) }
                print(id)
                exit(2)
            case .working:
                stillWorking("la session \(id) travaille encore. Plus tard : opus-attach reply \(id) --wait 540")
            case .error:
                fail(message.message ?? "erreur inconnue")
            }
        }
        let limit = gotFirst ? waitSeconds : max(waitSeconds, 15)
        let left = limit - Date().timeIntervalSince(start)
        if left <= 0 {
            guard gotFirst else { fail("Opus n'a pas répondu") }
            stillWorking("la session \(session ?? "?") travaille encore après \(Int(waitSeconds)) s. Pour la réponse : opus-attach reply \(session ?? "?") --wait 540")
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(min(left, 1) * 1000))
        if ready <= 0 { continue }
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { fail("Opus a fermé la connexion sans réponse finale") }
        pending.append(contentsOf: chunk[0..<n])
    }
}
