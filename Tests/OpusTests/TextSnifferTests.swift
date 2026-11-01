import XCTest
@testable import OpusArtifactsKit

/// Cmd+click sends text to the editor and everything else to its own app,
/// which is decided from the first bytes, not the extension: `.ts` is
/// TypeScript as often as it is an MPEG transport stream.
final class TextSnifferTests: XCTestCase {
    func testUtf8ProseAndCodeAreText() {
        XCTAssertTrue(TextSniffer.looksLikeText(Data("Facture n° 12, réglée à réception.\n".utf8)))
        XCTAssertTrue(TextSniffer.looksLikeText(Data("export const a: number = 1;\n".utf8)))
        XCTAssertTrue(TextSniffer.looksLikeText(Data()))
    }

    func testACharacterCutAtTheEndOfTheSampleIsStillText() {
        let sample = Data("prix : 12 €".utf8).dropLast(1)
        XCTAssertTrue(TextSniffer.looksLikeText(Data(sample)))
    }

    func testPdfAndImageHeadersAreNotText() {
        // A PDF's second line is a comment of high bytes, there to say so.
        XCTAssertFalse(TextSniffer.looksLikeText(Data("%PDF-1.7\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])))
        XCTAssertFalse(TextSniffer.looksLikeText(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])))
    }

    func testFilesOnDisk() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let script = dir.appendingPathComponent("main.ts")
        try Data("const x = 1\n".utf8).write(to: script)
        let pdf = dir.appendingPathComponent("brouillon.pdf")
        try (Data("%PDF-1.4\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3]) + Data(count: 9000)).write(to: pdf)

        XCTAssertTrue(TextSniffer.isTextFile(atPath: script.path))
        XCTAssertFalse(TextSniffer.isTextFile(atPath: pdf.path))
        XCTAssertFalse(TextSniffer.isTextFile(atPath: dir.appendingPathComponent("absent.txt").path))
    }
}
