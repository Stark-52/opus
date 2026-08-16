// ProcessParentLookup — the one hop `ProcessAncestry` cannot do for itself.
//
// Lives in the app target rather than the kit because `sysctl` is the whole
// implementation, and keeping it out of the kit is what lets the ancestry
// walk be tested against a constructed tree instead of against whatever
// happens to be running on the machine.

import Foundation
import Darwin

enum ProcessParentLookup {
    /// The parent pid of `pid`, or nil when the process is gone, is not ours
    /// to inspect, or the call fails. Callers treat nil as "stop walking",
    /// which is the safe reading: a hook we cannot attribute is dropped
    /// rather than attributed to the wrong pane.
    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        // A zero size means the pid exists in the table but nothing was
        // written, which is indistinguishable from "gone" for our purposes.
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
