// SocketServer — exposes ClaudeBackend over a Unix domain socket at /tmp/opus.sock.
// Each accepted connection subscribes to claude's output and can write input.
// Bytes flow both ways, raw, with no framing. Phase 3 will add per-client size
// negotiation via a small control protocol.

import Foundation
import Darwin

final class SocketServer {
    private let path: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "opus.socket-server", qos: .userInitiated)

    init(path: String = "/tmp/opus.sock") {
        self.path = path
    }

    func start() {
        unlink(path)   // remove any stale socket file

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("Opus SocketServer: socket() failed errno=\(errno)")
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
            NSLog("Opus SocketServer: bind() failed errno=\(errno)")
            close(listenFD); listenFD = -1
            return
        }
        guard listen(listenFD, 4) == 0 else {
            NSLog("Opus SocketServer: listen() failed errno=\(errno)")
            return
        }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
        NSLog("Opus SocketServer: listening on \(path)")
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
            handleClient(fd: fd)
        }
    }

    // Control protocol: opus-attach sends a 9-byte sequence on its initial
    // connect and on every SIGWINCH:
    //   ESC O p u s <colsHi> <colsLo> <rowsHi> <rowsLo>
    // We scan the first bytes of each incoming chunk for this prefix and
    // drive a PTY resize accordingly; anything else passes through to claude.
    private static let opusMagic: [UInt8] = [0x1B, 0x4F, 0x70, 0x75, 0x73]
    private static let opusCtrlSize = 9

    private func handleClient(fd: Int32) {
        NSLog("Opus SocketServer: client connected fd=\(fd)")

        let token = ClaudeBackend.shared.subscribe { slice in
            let data = Data(slice)
            data.withUnsafeBytes { buf in
                _ = Darwin.write(fd, buf.baseAddress, buf.count)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }

                // Parse leading control sequence(s) — opus-attach may stack
                // multiple size updates if WINCH fires rapidly.
                var i = 0
                while i + Self.opusCtrlSize <= n &&
                      Array(buffer[i..<(i + 5)]) == Self.opusMagic {
                    let cols = (UInt16(buffer[i+5]) << 8) | UInt16(buffer[i+6])
                    let rows = (UInt16(buffer[i+7]) << 8) | UInt16(buffer[i+8])
                    DispatchQueue.main.async {
                        ClaudeBackend.shared.setPrimarySize(cols: cols, rows: rows)
                    }
                    i += Self.opusCtrlSize
                }
                if i < n {
                    let slice = ArraySlice(buffer[i..<n])
                    ClaudeBackend.shared.send(data: slice)
                }
            }
            ClaudeBackend.shared.unsubscribe(token)
            close(fd)
            NSLog("Opus SocketServer: client disconnected fd=\(fd)")
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
