import XCTest
@testable import OpusArtifactsKit

/// Every JSON shape below was copied from a real transcript under
/// ~/.claude/projects on 15 August 2026, then reduced to the fields the
/// extractor reads. `cwd` is present on every assistant and user line.
final class TranscriptArtifactExtractorTests: XCTestCase {

    private func run(_ json: String) -> [ArtifactCandidate] {
        TranscriptArtifactExtractor.candidates(fromLine: Data(json.utf8))
    }

    private let cwd = "/Users/a/proj"

    func testWriteToolYieldsItsFilePath() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_use","name":"Write","input":{"file_path":"/tmp/report.md","content":"x"}}
        ]}}
        """)
        XCTAssertEqual(out, [ArtifactCandidate(payload: .path("/tmp/report.md"), cwd: cwd)])
    }

    func testEditToolYieldsItsFilePath() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_use","name":"Edit","input":{"file_path":"src/a.swift","old_string":"a","new_string":"b"}}
        ]}}
        """)
        XCTAssertEqual(out, [ArtifactCandidate(payload: .path("src/a.swift"), cwd: cwd)])
    }

    func testNavigateToolYieldsItsUrl() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_use","name":"mcp__claude-in-chrome__navigate","input":{"url":"https://a.dev/x","tabId":3}}
        ]}}
        """)
        XCTAssertEqual(out, [ArtifactCandidate(payload: .url("https://a.dev/x"), cwd: cwd)])
    }

    func testArrayValuedPathKeyYieldsEveryEntry() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_use","name":"mcp__claude-in-chrome__file_upload","input":{"paths":["/tmp/a.png","/tmp/b.png"]}}
        ]}}
        """)
        XCTAssertEqual(out, [
            ArtifactCandidate(payload: .path("/tmp/a.png"), cwd: cwd),
            ArtifactCandidate(payload: .path("/tmp/b.png"), cwd: cwd)
        ])
    }

    func testBashCommandIsTextScanned() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_use","name":"Bash","input":{"command":"cp out/hero.png ~/Desktop/","description":"copy"}}
        ]}}
        """)
        XCTAssertEqual(out, [
            ArtifactCandidate(payload: .path("out/hero.png"), cwd: cwd),
            ArtifactCandidate(payload: .path("~/Desktop/"), cwd: cwd)
        ])
    }

    func testUnknownMcpToolFollowingTheConventionIsCovered() {
        // The fallback rule is what keeps a newly added MCP tool working
        // without a code change, as long as it names its key conventionally.
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_use","name":"mcp__someone__brand_new","input":{"output_path":"/tmp/z.pdf"}}
        ]}}
        """)
        XCTAssertEqual(out, [ArtifactCandidate(payload: .path("/tmp/z.pdf"), cwd: cwd)])
    }

    func testDeniedToolYieldsNothing() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_use","name":"Read","input":{"file_path":"/tmp/read-only.md"}}
        ]}}
        """)
        XCTAssertEqual(out, [])
    }

    func testAssistantTextIsScanned() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"text","text":"c'est dans ~/Desktop/kit/ et en ligne sur https://a.dev"}
        ]}}
        """)
        XCTAssertEqual(out, [
            ArtifactCandidate(payload: .url("https://a.dev"), cwd: cwd),
            ArtifactCandidate(payload: .path("~/Desktop/kit/"), cwd: cwd)
        ])
    }

    func testThinkingBlocksAreIgnored() {
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":[
          {"type":"thinking","thinking":"maybe I should write /tmp/considered.md"}
        ]}}
        """)
        XCTAssertEqual(out, [])
    }

    func testToolResultBlocksAreIgnored() {
        let out = run("""
        {"type":"user","cwd":"/Users/a/proj","message":{"content":[
          {"type":"tool_result","content":"1\\t/etc/passwd\\n2\\t/tmp/leak.md"}
        ]}}
        """)
        XCTAssertEqual(out, [])
    }

    func testUserTextIsIgnored() {
        let out = run("""
        {"type":"user","cwd":"/Users/a/proj","message":{"content":[
          {"type":"text","text":"regarde /tmp/mine.md"}
        ]}}
        """)
        XCTAssertEqual(out, [])
    }

    func testStringContentInsteadOfBlocksIsHandled() {
        // SessionIndex.parseSummary documents that message.content is either
        // a String or an array of blocks. A String on an assistant line is
        // still assistant prose, so it is scanned.
        let out = run("""
        {"type":"assistant","cwd":"/Users/a/proj","message":{"content":"see /tmp/plain.md"}}
        """)
        XCTAssertEqual(out, [ArtifactCandidate(payload: .path("/tmp/plain.md"), cwd: cwd)])
    }

    func testNonMessageLinesYieldNothing() {
        XCTAssertEqual(run(#"{"type":"file-history-snapshot","snapshot":{}}"#), [])
        XCTAssertEqual(run(#"{"type":"ai-title","aiTitle":"x"}"#), [])
    }

    func testMalformedJsonYieldsNothingRatherThanThrowing() {
        XCTAssertEqual(run("{not json at all"), [])
        XCTAssertEqual(run(""), [])
    }

    func testLineWithoutCwdYieldsNothing() {
        // Without a cwd a relative path cannot be resolved, and guessing
        // would point the drawer at a file in the wrong project.
        let out = run("""
        {"type":"assistant","message":{"content":[
          {"type":"tool_use","name":"Write","input":{"file_path":"a.md"}}
        ]}}
        """)
        XCTAssertEqual(out, [])
    }
}
