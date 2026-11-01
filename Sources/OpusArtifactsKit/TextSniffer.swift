// TextSniffer: whether a file is text, from its first bytes. Cmd+click sends
// text to the editor and any other file (a PDF, an image, a video) to its own
// app. The extension cannot decide it: `.ts` is TypeScript as often as it is
// an MPEG transport stream, and many text files have no extension at all.

import Foundation

public enum TextSniffer {
    /// How much of a file is read to decide.
    static let sampleSize = 8192

    /// UTF-8 with no NUL byte. A character cut off at the end of the sample
    /// does not count against it.
    public static func looksLikeText(_ sample: Data) -> Bool {
        if sample.contains(0) { return false }
        for cut in 0...min(3, sample.count) {
            if String(data: sample.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// False for a file that cannot be read: the editor could not open it
    /// either, and its own app at least says why.
    public static func isTextFile(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: sampleSize) else { return false }
        return looksLikeText(sample)
    }
}
