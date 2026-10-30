// RenderProbeTests — real captures of the chrome, for a person (or an agent)
// to look at. Unit tests check what the views are told; these check what
// they draw, which static review of this codebase has missed before.
//
// Skipped unless OPUS_RENDER_PROBE names an existing folder, where each test
// writes its PNG. Needs a logged-in session with the display awake.

import XCTest
import AppKit
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
            bar.heightAnchor.constraint(equalToConstant: TerminalContainerView.toolbarHeight),
        ])
        try RenderProbe.capture(host, size: NSSize(width: 900, height: 60),
                                to: (out as NSString).appendingPathComponent("toolbar.png"))
    }
}
