import XCTest
@testable import Opus

/// Palette fix round — the two pure decisions behind "Cmd+Shift+P made the
/// Quick Terminal panel disappear and inserted nothing":
///
///  * `QuickTerminalPanel.shouldAutohideOnResign` — when losing key status
///    should collapse the panel, and when it must not.
///  * `AppDelegate.insertionTarget` — which surface a picked prompt / sent
///    clipboard goes to, including when nothing at all is on screen.
///
/// The window-server half of the fix (NSApp.keyWindow being populated one
/// runloop turn after didResignKey while Opus is a background app, and nil
/// when key leaves for another application) was measured with a standalone
/// AppKit probe — see panelDidResignKey's comment and palette-fix-report.md.
final class PanelKeyFocusTests: XCTestCase {

    // MARK: shouldAutohideOnResign

    func testKeyStayingInsideOpusDoesNotCollapseThePanel() {
        // THE bug: opening the Cmd+Shift+P palette (or the Cmd+K switcher,
        // Settings, an NSAlert) takes key status away from the panel. Keyboard
        // focus never left the app, so that is an in-app focus move, not the
        // user leaving — the panel has to stay on screen, or the palette's
        // commit handler has no visible surface left to resolve and the pick
        // is silently dropped. Covers the panel taking key straight back, too.
        XCTAssertFalse(QuickTerminalPanel.shouldAutohideOnResign(
            visible: true, pinned: false, spaceSwitchInFlight: false, keyStillWithinOpus: true))
    }

    func testKeyMovingToAnotherApplicationStillCollapsesThePanel() {
        // The regression guard on the fix above: clicking a different app must
        // still autohide, exactly as it always did.
        XCTAssertTrue(QuickTerminalPanel.shouldAutohideOnResign(
            visible: true, pinned: false, spaceSwitchInFlight: false, keyStillWithinOpus: false))
    }

    func testPinnedPanelNeverAutohides() {
        XCTAssertFalse(QuickTerminalPanel.shouldAutohideOnResign(
            visible: true, pinned: true, spaceSwitchInFlight: false, keyStillWithinOpus: false))
        XCTAssertFalse(QuickTerminalPanel.shouldAutohideOnResign(
            visible: true, pinned: true, spaceSwitchInFlight: false, keyStillWithinOpus: true))
    }

    func testSpaceSwitchGracePeriodSuppressesTheAutohide() {
        // A macOS Space transition briefly resigns key; the panel belongs on
        // the new Space, not gone.
        XCTAssertFalse(QuickTerminalPanel.shouldAutohideOnResign(
            visible: true, pinned: false, spaceSwitchInFlight: true, keyStillWithinOpus: false))
    }

    func testQuickLookPreviewSuppressesTheAutohide() {
        // Space opens a QuickLook preview, which takes key status. The panel
        // then folded and took the drawer with it, and the preview died with
        // the window that held its data source, so the preview appeared to
        // flash open and vanish.
        //
        // keyStillWithinOpus is false here on purpose: that is the value the
        // deferred check actually observes, because QLPreviewPanel takes key
        // more than one runloop turn later and NSApp.keyWindow is still nil
        // when the decision is made. Suppressing on the preview being up is
        // what makes this independent of that timing.
        XCTAssertFalse(QuickTerminalPanel.shouldAutohideOnResign(
            visible: true, pinned: false, spaceSwitchInFlight: false,
            keyStillWithinOpus: false, quickLookVisible: true))
    }

    func testQuickLookNotUpLeavesTheAutohideAlone() {
        // Regression guard: the new term must not become a blanket excuse.
        XCTAssertTrue(QuickTerminalPanel.shouldAutohideOnResign(
            visible: true, pinned: false, spaceSwitchInFlight: false,
            keyStillWithinOpus: false, quickLookVisible: false))
    }

    func testAnAlreadyHiddenPanelIsNeverHiddenAgain() {
        XCTAssertFalse(QuickTerminalPanel.shouldAutohideOnResign(
            visible: false, pinned: false, spaceSwitchInFlight: false, keyStillWithinOpus: false))
    }

    // MARK: insertionTarget

    func testAResolvedSurfaceIsUsedAsIsAndNothingIsRevealed() {
        XCTAssertEqual(AppDelegate.insertionTarget(resolved: true, hasPanel: true), .resolvedSurface)
        XCTAssertEqual(AppDelegate.insertionTarget(resolved: true, hasPanel: false), .resolvedSurface)
    }

    func testNothingVisibleFallsBackToTheHiddenPanelRatherThanDroppingTheText() {
        // The palette's old behaviour here was `return` — the picked prompt
        // went nowhere, with no feedback at all.
        XCTAssertEqual(AppDelegate.insertionTarget(resolved: false, hasPanel: true), .hiddenPanel)
    }

    func testMainOnlyModeFallsBackToTheHiddenMainWindow() {
        // Finding F8: `.mainOnly` is the one mode with no panel object at all
        // (OpusDisplayMode.includesPanel), so the main window is the only
        // surface that can take the text.
        XCTAssertEqual(AppDelegate.insertionTarget(resolved: false, hasPanel: false), .hiddenMainWindow)
    }
}
