import XCTest
@testable import Opus
@testable import OpusArtifactsKit

/// Only the pure formatter is unit-tested. Layout, thumbnails and gestures
/// are verified on screen in Task 11, because static review of this file
/// has twice missed z-order and anchoring bugs that a screenshot caught.
final class ArtifactsDrawerViewTests: XCTestCase {

    private func file(_ n: Int) -> Artifact {
        Artifact(key: "/tmp/\(n)", kind: .file, resolvedPath: "/tmp/\(n)", urlString: nil)
    }

    func testHeaderCountsArtifacts() {
        XCTAssertEqual(ArtifactsDrawerView.headerText(artifacts: []), "Artifacts 0")
        XCTAssertEqual(ArtifactsDrawerView.headerText(artifacts: [file(1), file(2)]), "Artifacts 2")
    }

    func testHeaderCountsWhatAllShowsSoCodeIsLeftOut() {
        let code = Artifact(key: "/r/main.swift", kind: .file, resolvedPath: "/r/main.swift", urlString: nil)
        XCTAssertEqual(ArtifactsDrawerView.headerText(artifacts: [file(1), code]), "Artifacts 1")
    }

    func testTheDrawerShowsRowsForTheSelectedChipOnly() {
        let now = Date()
        let code = Artifact(key: "/r/main.swift", kind: .file, resolvedPath: "/r/main.swift",
                            urlString: nil, timestamp: now)
        let image = Artifact(key: "/r/shot.png", kind: .image, resolvedPath: "/r/shot.png",
                             urlString: nil, timestamp: now)
        let drawer = ArtifactsDrawerView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        drawer.update(artifacts: [code, image], hasSession: true, hasTranscript: true)

        XCTAssertFalse(drawer.displayedRows.contains(.item(code)))
        XCTAssertTrue(drawer.displayedRows.contains(.images([image])))

        drawer.select(kindFilter: .code)
        XCTAssertTrue(drawer.displayedRows.contains(.item(code)))
        XCTAssertFalse(drawer.displayedRows.contains { if case .images = $0 { return true } else { return false } })
    }

    func testClickingEmptySpaceClearsTheSelection() {
        let doc = Artifact(key: "/r/a.md", kind: .file, resolvedPath: "/r/a.md", urlString: nil, timestamp: Date())
        let drawer = ArtifactsDrawerView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        drawer.update(artifacts: [doc], hasSession: true, hasTranscript: true)
        drawer.select(key: doc.key)
        XCTAssertEqual(drawer.selectedArtifact, doc)
        drawer.tableSelectionChanged(toRow: -1)
        XCTAssertNil(drawer.selectedArtifact)
    }

    func testTheChipRowFitsTheNarrowestDrawer() {
        XCTAssertLessThanOrEqual(ArtifactsDrawerView.chipRowWidth(),
                                 DrawerGeometry.minimumWidth - 2 * OpusTheme.insetPanel)
    }
}

/// The Finder button, measured: it once sat on top of the path it reveals.
final class ArtifactCellRevealTests: XCTestCase {
    private func hover(_ cell: ArtifactCellView, entering: Bool) throws {
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: entering ? .mouseEntered : .mouseExited,
                                                          location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: 0, context: nil, eventNumber: 0,
                                                          trackingNumber: 0, userData: nil))
        entering ? cell.mouseEntered(with: event) : cell.mouseExited(with: event)
        cell.layoutSubtreeIfNeeded()
    }

    func testTheFinderButtonIsAnIconThatTheTextStopsBefore() throws {
        let cell = ArtifactCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        let folder = "/Users/someone/Movies/projet/rendus/lot0/turntable"
        cell.configure(artifact: Artifact(key: folder, kind: .folder, resolvedPath: folder, urlString: nil))
        cell.layoutSubtreeIfNeeded()
        let resting = cell.detailLabel.frame.maxX

        try hover(cell, entering: true)
        XCTAssertFalse(cell.revealButton.isHidden)
        XCTAssertEqual(cell.revealButton.imagePosition, .imageOnly, "an icon, not a pill of text")
        XCTAssertEqual(cell.revealButton.toolTip, "Afficher dans le Finder")
        XCTAssertLessThanOrEqual(cell.nameLabel.frame.maxX, cell.revealButton.frame.minX)
        XCTAssertLessThanOrEqual(cell.detailLabel.frame.maxX, cell.revealButton.frame.minX, "the path never runs under it")

        try hover(cell, entering: false)
        XCTAssertTrue(cell.revealButton.isHidden)
        XCTAssertEqual(cell.detailLabel.frame.maxX, resting, "the text takes the room back")
    }

    func testALinkHasNoFinderButton() throws {
        let cell = ArtifactCellView(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        cell.configure(artifact: Artifact(key: "https://example.com", kind: .url, resolvedPath: nil,
                                          urlString: "https://example.com"))
        try hover(cell, entering: true)
        XCTAssertTrue(cell.revealButton.isHidden)
    }
}

/// A click on the Finder button, sent through a real window as AppKit
/// delivers it. The test runner is in the background, as Opus is when the
/// click on the button is the one that brings it back (right after the Finder
/// came forward): a row's button used to lose exactly that click.
final class ArtifactRevealClickTests: XCTestCase {
    private final class Spy: NSObject {
        var hits = 0
        @objc func hit() { hits += 1 }
    }

    private func cells(in view: NSView) -> [ArtifactCellView] {
        view.subviews.flatMap { ($0 as? ArtifactCellView).map { [$0] } ?? cells(in: $0) }
    }

    func testTheFinderButtonTakesTheClickThatBringsOpusBack() throws {
        let path = "/Users/someone/Desktop/facture/brouillon.pdf"
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let drawer = ArtifactsDrawerView(frame: NSRect(x: 0, y: 0, width: 340, height: 600))
        window.contentView = drawer
        drawer.update(artifacts: [Artifact(key: path, kind: .file, resolvedPath: path, urlString: nil, timestamp: Date())],
                      hasSession: true, hasTranscript: true)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        drawer.layoutSubtreeIfNeeded()

        let cell = try XCTUnwrap(cells(in: drawer).first)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, trackingNumber: 0, userData: nil))
        cell.mouseEntered(with: enter)
        cell.layoutSubtreeIfNeeded()
        let button = cell.revealButton
        XCTAssertFalse(button.isHidden)
        // The click is what is under test, not the Finder opening.
        let spy = Spy()
        button.target = spy
        button.action = #selector(Spy.hit)

        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        window.sendEvent(try mouse(.leftMouseDown))
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        XCTAssertEqual(spy.hits, 1)
    }
}
