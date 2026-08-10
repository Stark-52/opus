// SocketClientWriter — per-client outbound pipe for SocketServer.
//
// Why: ClaudeBackend broadcasts subscriber callbacks on the MAIN queue. The
// old code did a raw blocking write(2) right there, so one stuck opus-attach
// client froze the whole app, and a vanished client raised SIGPIPE (fatal by
// default, never ignored anywhere). All writes now happen on a per-client
// serial queue, failures surface through onFailure exactly once, and a
// pending-bytes cap drops pathological clients instead of buffering forever.
//
// Stall budget: a non-blocking write against a peer that never drains its
// kernel buffer retries EAGAIN forever — since the writer queue is serial,
// that single stuck write blocks every later enqueue() from ever running,
// so pendingBytes stops accumulating and the cap can never see it. To keep
// the "pathologically stuck client gets DROPPED" guarantee, each write
// tracks how long it has gone without making any progress; once that
// exceeds `stallTimeout` the client is treated as dead and fail() fires,
// same as a hard write error.

import Foundation
import Darwin

final class SocketClientWriter {
    private let fd: Int32
    private let queue: DispatchQueue
    private let onFailure: () -> Void
    private let stallTimeout: TimeInterval
    private var failed = false
    private var pendingBytes = 0
    /// Beyond this many queued-but-unwritten bytes the client is considered
    /// dead (claude can emit MBs during a paste; 4 MB is far above normal).
    static let pendingCap = 4 * 1024 * 1024

    init(fd: Int32, stallTimeout: TimeInterval = 5.0, onFailure: @escaping () -> Void) {
        self.fd = fd
        self.queue = DispatchQueue(label: "opus.socket-client.\(fd)", qos: .userInitiated)
        self.onFailure = onFailure
        self.stallTimeout = stallTimeout
        // Belt and braces next to the app-wide SIG_IGN: never SIGPIPE this fd.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    func enqueue(_ data: Data) {
        queue.async { [self] in
            guard !failed else { return }
            pendingBytes += data.count
            if pendingBytes > Self.pendingCap { fail(); return }
            var written = 0
            let total = data.count
            var stallStart = Date()
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                while written < total {
                    let n = Darwin.write(fd, buf.baseAddress!.advanced(by: written), total - written)
                    if n <= 0 {
                        if n < 0 && errno == EAGAIN {
                            // Kernel buffer full — park the remainder and retry
                            // on the next tick, but only for as long as the
                            // peer keeps failing to drain. A mirror client
                            // that hasn't accepted a single byte for
                            // stallTimeout seconds is dead for our purposes.
                            if Date().timeIntervalSince(stallStart) > stallTimeout {
                                fail(); return
                            }
                            usleep(2000)
                            continue
                        }
                        fail(); return
                    }
                    stallStart = Date()
                    written += n
                }
            }
            pendingBytes -= total
        }
    }

    /// Queue-only. Marks the client dead and reports once.
    private func fail() {
        guard !failed else { return }
        failed = true
        onFailure()
    }

    func shutdown() {
        queue.async { [self] in
            failed = true
            close(fd)
        }
    }
}
