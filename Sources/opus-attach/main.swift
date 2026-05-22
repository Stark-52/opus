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
// Usage:    opus-attach           (uses /tmp/opus.sock)
//           opus-attach <path>    (custom socket path)

import Foundation
import Darwin

let socketPath = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : "/tmp/opus.sock"
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
    FileHandle.standardError.write("opus-attach: cannot connect to \(socketPath) — is Opus running?\n".data(using: .utf8)!)
    exit(1)
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
    _ = write(sock, &msg, msg.count)
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
    _ = write(sock, &buf, n)
}

if isTTY {
    var t = oldTermios
    tcsetattr(0, TCSADRAIN, &t)
}
