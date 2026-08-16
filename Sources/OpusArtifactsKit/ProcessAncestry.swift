// ProcessAncestry — which pane does this hook belong to?
//
// A Claude Code hook payload names the conversation (`session_id`) and the
// working directory. Neither identifies a PANE, and after a `/resume` the
// session id is no longer the one Opus spawned the pane with, so a pane can
// sit bound to an id whose transcript will never exist. Everything that
// resolves a session off that binding - the context meter, the tasks drawer,
// the artifacts drawer - then reads the wrong file for the rest of the
// pane's life.
//
// What does still tell the truth is the process tree: the hook runs
// `opus-attach` as a descendant of the `claude` process Opus started inside
// that pane's PTY. Walking up from the hook's own pid until we meet a shell
// pid Opus knows about identifies the pane exactly, no matter how many tabs
// and splits are open and no matter what the session id has become.
//
// The parent lookup is injected rather than called directly, so the walk can
// be tested against a constructed tree. The real lookup lives in the app
// target, where `sysctl` belongs.

import Foundation

public enum ProcessAncestry {
    /// How many hops up the tree to try before giving up. A hook is three or
    /// four levels below its pane at most; the bound exists so a malformed
    /// or cyclic tree cannot hang a handler that runs on every tool call.
    public static let maximumDepth = 24

    /// The shell pid, among `known`, that `pid` descends from. `nil` when the
    /// process belongs to no known pane, which is the correct answer for a
    /// hook fired by a claude session Opus did not start.
    public static func owner(
        of pid: Int32,
        among known: Set<Int32>,
        parentOf: (Int32) -> Int32?
    ) -> Int32? {
        guard !known.isEmpty else { return nil }
        var current = pid
        var seen = Set<Int32>()
        for _ in 0..<maximumDepth {
            if known.contains(current) { return current }
            // A repeat means the tree lied to us. Stop rather than loop.
            guard seen.insert(current).inserted else { return nil }
            guard let parent = parentOf(current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// Convenience for the common call shape, where panes are held as an
    /// array rather than a set.
    public static func owner(
        of pid: Int32,
        among known: [Int32],
        parentOf: (Int32) -> Int32?
    ) -> Int32? {
        owner(of: pid, among: Set(known), parentOf: parentOf)
    }
}
