// EditorCommandTests — which command Cmd+click runs when none is set.
//
// `code -g {target}` only works once VS Code's "Install 'code' command in
// PATH" has been run. Without it the command exits 127, Opus falls back to
// opening the file with its default app (Xcode for .swift, .md, .json),
// which loses the line and can raise an error dialog. The CLI ships inside
// the app bundle either way, so the default points there when it exists.

import XCTest
@testable import Opus

final class EditorCommandTests: XCTestCase {
    private let bundled = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"

    func testTheDefaultUsesTheCLIInsideVSCodeWhenTheAppIsInstalled() {
        let command = OpusPreferences.defaultEditorCommand(home: "/Users/me") { $0 == self.bundled }

        XCTAssertEqual(command, "'\(bundled)' -g {target}")
    }

    func testAVSCodeInstalledForTheUserAloneIsFoundToo() {
        let userBundled = "/Users/me/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        let command = OpusPreferences.defaultEditorCommand(home: "/Users/me") { $0 == userBundled }

        XCTAssertEqual(command, "'\(userBundled)' -g {target}")
    }

    func testWithoutVSCodeTheDefaultStaysTheCodeCommand() {
        XCTAssertEqual(OpusPreferences.defaultEditorCommand(home: "/Users/me") { _ in false }, "code -g {target}")
    }
}
