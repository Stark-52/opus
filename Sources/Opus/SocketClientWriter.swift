// SocketClientWriter — per-client outbound pipe for SocketServer.
//
// Why: ClaudeBackend broadcasts subscriber callbacks on the MAIN queue. The
// old code did a raw blocking write(2) right there, so one stuck opus-attach
// client froze the whole app, and a vanished client raised SIGPIPE (fatal by
// default, never ignored anywhere). All writes now happen on a per-client
// serial queue, failures surface through onFailure exactly once, and a
// pending-bytes cap drops pathological clients instead of buffering forever.
//
// Non-blocking writes, the hard way: O_NONBLOCK is a file-STATUS flag shared
// by every fd pointing at the same open file description (dup() doesn't
// help either — a dup'd fd shares status flags with the original). This fd
// is also used by SocketServer's read loop, so setting O_NONBLOCK here
// would silently turn the read side non-blocking too, and its
// `if n <= 0 { break }` would start misreading EAGAIN as EOF (a real client
// "disconnects" on its first idle gap). We never touch O_NONBLOCK on `fd`.
//
// send(2) with MSG_DONTWAIT was tried next (per-call, no shared side
// effect, the obvious fix) — but empirically, on this platform, MSG_DONTWAIT
// does NOT reliably prevent send(2)/write(2) from blocking on an AF_UNIX
// SOCK_STREAM socket once the requested length exceeds currently available
// buffer room: a probe writing to a socketpair half with no reader blocked
// indefinitely on send(..., MSG_DONTWAIT) past the point the kernel buffer
// filled, both for large and modest (8 KB) request sizes. So this writer
// keeps the fd fully blocking (read side gets true blocking semantics, no
// leakage at all) and instead bounds each blocking write(2) call with a
// WATCHDOG: shutdown(fd, SHUT_WR), called from a different thread, reliably
// interrupts an in-flight blocked write(2) on this fd, returning it with a
// clean EPIPE (verified empirically — ~sub-ms latency, no crash given
// SO_NOSIGPIPE/SIG_IGN). Each write(2) attempt is capped to a modest chunk
// (`writeChunkSize`) and armed with a fresh per-attempt watchdog timer; the
// timer is cancelled the instant that attempt returns. A genuinely
// slow-but-alive peer keeps making per-chunk progress and never trips it; a
// peer that stops draining entirely gets its blocked write interrupted and
// dropped within stallTimeout, exactly like a hard write error. SHUT_WR
// only tears down OUR send capability — it does not touch the read side, so
// the read loop's own read(2) is unaffected by a write-side watchdog firing.
//
// Backlog accounting: pendingBytes is updated synchronously inside
// enqueue(), under `lock`, BEFORE the data is handed to the serial write
// queue — not inside the (later, async) write closure. That's what lets the
// cap see the true queued backlog of a slow-but-draining client, not just
// whichever single chunk happens to be mid-write at the time. `lock` also
// guards `failed`, so enqueue-side cap trips, write failures, and stalls
// all share one onFailure-once guarantee. The enqueue-side cap trip calls
// fail() directly (not via the writer's serial queue): dispatching it onto
// `queue` would park it behind whatever chunk is currently mid-write, which
// can itself take up to stallTimeout to resolve — direct-and-synchronous is
// what makes the cap trip actually synchronous, matching its contract.
// fail() itself only ever touches the lock-guarded `failed` flag and,
// outside the lock, invokes onFailure — safe to call from any thread.

import Foundation
import Darwin

final class SocketClientWriter {
    private let fd: Int32
    private let queue: DispatchQueue
    private let onFailure: () -> Void
    private let stallTimeout: TimeInterval
    private let lock = NSLock()
    private var failed = false
    private var closed = false
    private var pendingBytes = 0
    /// Beyond this many queued-but-unwritten bytes the client is considered
    /// dead (claude can emit MBs during a paste; 4 MB is far above normal).
    static let pendingCap = 4 * 1024 * 1024
    /// Cap on a single write(2) attempt. Keeps each blocking call's worst
    /// case bounded and gives a slow-but-alive peer periodic progress
    /// checkpoints (each of which re-arms the watchdog with a fresh
    /// stallTimeout window) instead of one huge all-or-nothing call.
    private static let writeChunkSize = 16 * 1024

    init(fd: Int32, stallTimeout: TimeInterval = 5.0, onFailure: @escaping () -> Void) {
        self.fd = fd
        self.queue = DispatchQueue(label: "opus.socket-client.\(fd)", qos: .userInitiated)
        self.onFailure = onFailure
        self.stallTimeout = stallTimeout
        // Belt and braces next to the app-wide SIG_IGN: never SIGPIPE this fd.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func enqueue(_ data: Data) {
        lock.lock()
        if failed {
            lock.unlock()
            return
        }
        pendingBytes += data.count
        if pendingBytes > Self.pendingCap {
            // Backlog already exceeds the cap — drop this chunk unwritten
            // and report failure synchronously (see class doc: dispatching
            // this onto `queue` would park it behind an in-flight write).
            lock.unlock()
            fail()
            return
        }
        lock.unlock()

        queue.async { [self] in performWrite(data) }
    }

    private func performWrite(_ data: Data) {
        lock.lock()
        if failed {
            // Queued before a prior chunk tripped the cap/stall/error path —
            // still owns (and must release) its own pendingBytes share.
            pendingBytes -= data.count
            lock.unlock()
            return
        }
        lock.unlock()

        var written = 0
        let total = data.count
        var hitFailure = false

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            while written < total {
                let attemptLen = min(total - written, Self.writeChunkSize)

                // Arm a watchdog for this one blocking write(2) attempt.
                // Cancelled the instant the call returns; if it fires first,
                // it forcibly unblocks the write via shutdown(SHUT_WR).
                let watchdog = DispatchWorkItem { [fd] in
                    _ = Darwin.shutdown(fd, SHUT_WR)
                }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + stallTimeout, execute: watchdog)

                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: written), attemptLen)
                let writeErrno = errno
                watchdog.cancel()

                if n <= 0 {
                    if n < 0 && writeErrno == EINTR { continue }
                    hitFailure = true
                    return
                }
                written += n
            }
        }

        lock.lock()
        pendingBytes -= total
        lock.unlock()

        if hitFailure { fail() }
    }

    /// Test-and-set `failed`, then report at most once. Never calls
    /// onFailure while holding the lock. Safe to call from any thread.
    private func fail() {
        lock.lock()
        let alreadyFailed = failed
        failed = true
        lock.unlock()
        guard !alreadyFailed else { return }
        onFailure()
    }

    func shutdown() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        failed = true
        lock.unlock()
        // Interrupt any in-flight blocked write right away rather than
        // waiting up to stallTimeout for its own watchdog to fire — same
        // mechanism as the per-write watchdog, just triggered immediately.
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        queue.async { [self] in
            close(fd)
        }
    }
}
