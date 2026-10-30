// RenderProbeTests: real captures of the chrome, for a person (or an agent)
// to look at. Unit tests check what the views are told; these check what
// they draw, which static review of this codebase has missed before.
//
// Skipped unless OPUS_RENDER_PROBE names an existing folder, where each test
// writes its PNG. Needs a logged-in session with the display awake.

import XCTest
import AppKit
import SwiftTerm
@testable import Opus
@testable import OpusArtifactsKit

enum RenderProbe {
    static var folder: String? {
        guard let path = ProcessInfo.processInfo.environment["OPUS_RENDER_PROBE"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Shows `view` in a borderless window over a dark backdrop, lets it
    /// settle (layout, QuickLook thumbnails), then captures that window.
    static func capture(_ view: NSView, size: NSSize, to path: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 120), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        window.level = .floating
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try capture.run()
        capture.waitUntilExit()
    }

    /// A small solid-gradient PNG on disk, so QuickLook has something to draw.
    static func image(named name: String, in folder: String, hue: CGFloat) -> String {
        let path = (folder as NSString).appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1),
                       ending: NSColor(hue: hue + 0.2, saturation: 0.6, brightness: 0.5, alpha: 1))?
                .draw(in: rect, angle: 45)
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            FileManager.default.createFile(atPath: path, contents: png)
        }
        return path
    }
}

final class RenderProbeTests: XCTestCase {
    private func folderOrSkip() throws -> String {
        guard let folder = RenderProbe.folder else { throw XCTSkip("OPUS_RENDER_PROBE not set") }
        return folder
    }

    func testRenderArtifactsDrawer() throws {
        let out = try folderOrSkip()
        let files = (out as NSString).appendingPathComponent("artifacts-fixtures")
        try? FileManager.default.createDirectory(atPath: files, withIntermediateDirectories: true)
        let now = Date()
        func file(_ name: String, _ kind: ArtifactKind, minutesAgo: Double) -> Artifact {
            let path = (files as NSString).appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: Data("x".utf8)) }
            return Artifact(key: path, kind: kind, resolvedPath: path, urlString: nil,
                            timestamp: now.addingTimeInterval(-minutesAgo * 60))
        }
        func image(_ name: String, hue: CGFloat, minutesAgo: Double) -> Artifact {
            let path = RenderProbe.image(named: name, in: files, hue: hue)
            return Artifact(key: path, kind: .image, resolvedPath: path, urlString: nil,
                            timestamp: now.addingTimeInterval(-minutesAgo * 60))
        }
        let artifacts = [
            image("cover-v3.png", hue: 0.05, minutesAgo: 2),
            image("affiche.png", hue: 0.75, minutesAgo: 3),
            file("devis-client.pdf", .file, minutesAgo: 4),
            file("DrawerDock.swift", .file, minutesAgo: 5),
            image("post-ig.png", hue: 0.12, minutesAgo: 30 * 60),
            image("banner.png", hue: 0.5, minutesAgo: 30 * 60 + 5),
            file("chrome-design.md", .file, minutesAgo: 30 * 60 + 10),
        ]
        let drawer = ArtifactsDrawerView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        drawer.update(artifacts: artifacts, hasSession: true, hasTranscript: true)
        try RenderProbe.capture(drawer, size: NSSize(width: 300, height: 600),
                                to: (out as NSString).appendingPathComponent("artifacts.png"))
    }

    /// Two folder rows, the second under the pointer: its Finder button
    /// beside the path, never on it.
    func testRenderArtifactRowWithTheFinderButton() throws {
        let out = try folderOrSkip()
        let folder = (out as NSString).appendingPathComponent("Movies/projet/rendus/lot0/turntable")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 104))
        stack.wantsLayer = true
        stack.layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        for (index, hovered) in [false, true].enumerated() {
            let cell = ArtifactCellView(frame: NSRect(x: 0, y: CGFloat(1 - index) * 52, width: 300, height: 52))
            cell.configure(artifact: Artifact(key: folder, kind: .folder, resolvedPath: folder, urlString: nil))
            if hovered, let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                           timestamp: 0, windowNumber: 0, context: nil,
                                                           eventNumber: 0, trackingNumber: 0, userData: nil) {
                cell.mouseEntered(with: event)
            }
            stack.addSubview(cell)
        }
        try RenderProbe.capture(stack, size: stack.frame.size,
                                to: (out as NSString).appendingPathComponent("artifact-row-finder.png"))
    }

    /// The top bar of layout A as the container builds it: tabs on the left,
    /// buttons on the right, over the panel's dark tint.
    static func toolbar(width: CGFloat) -> NSView {
        let bar = ChromeBar(edge: .minY)
        let tabs = ChromeTabStrip(frame: .zero)
        tabs.titles = ["Fonctionnalité des mods", "Publication Instagram programmée"]
        tabs.states = [.working, .done]
        tabs.activeIndex = 0
        let buttons = ChromeButtonBar(frame: .zero)
        buttons.activeDrawer = .reply
        bar.addSubview(tabs)
        bar.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: OpusTheme.insetPanel),
            tabs.topAnchor.constraint(equalTo: bar.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            tabs.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    func testRenderToolbarWithTwoTabs() throws {
        let out = try folderOrSkip()
        let host = NSView()
        let bar = Self.toolbar(width: 900)
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: ChromeArrangement.toolbarHeight),
        ])
        try RenderProbe.capture(host, size: NSSize(width: 900, height: 60),
                                to: (out as NSString).appendingPathComponent("toolbar.png"))
    }

    /// The bottom bar of layout A: memory on the left, figures on the right.
    static func statusBar() -> NSView {
        let bar = ChromeBar(edge: .maxY)
        let status = ChromeStatusView(frame: .zero)
        let resets = Date().addingTimeInterval(3 * 86_400)
        status.memory = "mémoire : Atelier · Jeu: v.2"
        status.contextFraction = 0.357
        status.usage = [UsageWindow(kind: .fiveHour, percent: 2, resetsAt: resets),
                        UsageWindow(kind: .sevenDay, percent: 23, resetsAt: resets)]
        bar.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: OpusTheme.insetPanel),
            status.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -OpusTheme.insetPanel),
            status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    func testRenderStatusBar() throws {
        let out = try folderOrSkip()
        let host = NSView()
        let bar = Self.statusBar()
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: ChromeArrangement.statusBarHeight),
        ])
        try RenderProbe.capture(host, size: NSSize(width: 900, height: 50),
                                to: (out as NSString).appendingPathComponent("status.png"))
    }

    /// A whole window in each layout: the bars as the container arranges
    /// them around a terminal showing a Claude Code screen.
    func testRenderLayoutAAndB() throws {
        let out = try folderOrSkip()
        for (layout, name) in [(ChromeLayout.toolbarAndStatus, "layout-a.png"), (.singleBottomBar, "layout-b.png")] {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
            let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 872, height: 420))
            terminal.nativeBackgroundColor = .clear
            terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.85, alpha: 1)
            terminal.feed(text: [
                "\u{1b}[2m⏺\u{1b}[0m 680 tests passent, dont les 5 nouveaux. Je commite les deux dépôts.",
                "\u{1b}[2m  ⎿ 53101d6 Name the session's loaded memory domains on the status rail\u{1b}[0m",
                "",
                "\u{1b}[2m" + String(repeating: "─", count: 104) + "\u{1b}[0m",
                "❯ ",
                "\u{1b}[2m" + String(repeating: "─", count: 104) + "\u{1b}[0m",
                "  \u{1b}[31m▸▸ bypass permissions on\u{1b}[0m \u{1b}[2m(shift+tab to cycle)\u{1b}[0m",
            ].joined(separator: "\r\n"))
            let tabs = ChromeTabStrip(frame: .zero)
            tabs.titles = ["Fonctionnalité des mods", "Publication Instagram programmée"]
            tabs.states = [.working, .done]
            let status = ChromeStatusView(frame: .zero)
            let resets = Date().addingTimeInterval(3 * 86_400)
            status.memory = "mémoire : socle"
            status.contextFraction = 0.357
            status.usage = [UsageWindow(kind: .fiveHour, percent: 2, resetsAt: resets),
                            UsageWindow(kind: .sevenDay, percent: 23, resetsAt: resets)]
            _ = ChromeArrangement.arrange(
                ChromeViews(top: ChromeBar(edge: .minY), bottom: ChromeBar(edge: .maxY), tabs: tabs,
                            buttons: ChromeButtonBar(frame: .zero), status: status, terminal: terminal),
                in: container, layout: layout)
            try RenderProbe.capture(container, size: NSSize(width: 900, height: 500),
                                    to: (out as NSString).appendingPathComponent(name))
        }
    }

    /// A reply copied from the reply drawer, then pasted the way a Cocoa
    /// editor (Notes, Mail, TextEdit) pastes it, on a light page and a dark
    /// one. The HTML and RTF land beside the captures for a browser and
    /// Quick Look.
    func testRenderReplyCopyPastedIntoATextView() throws {
        let out = try folderOrSkip()
        let reply = """
        ## Ce qui change

        Le **scroll** reste en place, voir `ScrollFollowTests` et [la doc](https://example.com). Déjà testé.

        - premier point, *en italique*
          - un sous-point
        - second point

        1. un
        2. deux

        ```swift
        let x = 1 < 2
        ```

        | Fichier | État |
        |---|---|
        | `Opus.app` | **installé** |

        > une citation
        """
        let board = NSPasteboard(name: NSPasteboard.Name("opus-render-probe-paste"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(ReplyClipboard.write(ReplyMarkdown.blocks(reply), to: board))
        try XCTUnwrap(board.string(forType: .html)).write(toFile: (out as NSString).appendingPathComponent("reply-copy.html"),
                                                         atomically: true, encoding: .utf8)
        try XCTUnwrap(board.data(forType: .rtf)).write(to: URL(fileURLWithPath: (out as NSString).appendingPathComponent("reply-copy.rtf")))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
            text.appearance = NSAppearance(named: appearance)
            text.usesAdaptiveColorMappingForDarkAppearance = true
            text.textContainerInset = NSSize(width: 16, height: 16)
            XCTAssertTrue(text.readSelection(from: board))
            print("reply probe pasted as", text.preferredPasteboardType(from: board.types ?? [], restrictedToTypesFrom: nil) ?? "none")
            try RenderProbe.capture(text, size: NSSize(width: 520, height: 560),
                                    to: (out as NSString).appendingPathComponent("reply-pasted-\(name).png"))
        }
    }
}
