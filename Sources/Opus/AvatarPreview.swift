// AvatarPreview: `Opus --avatar-preview` opens one window that runs the
// avatar's real views (tab strip, standalone avatars, menu bar, Dock tile)
// on made-up states that change every few seconds, and nothing else: no
// Claude, no sockets, no dtach, no hotkeys, no preferences written. It can
// therefore run beside an Opus in use, so the avatar can be watched on
// screen without restarting that one.
// `--snapshot <dir>` also writes the window, the menu bar image and the Dock
// tile as PNGs every half second for eight seconds, then quits: frames an
// agent can look at when the screen is locked or asleep.

import AppKit

enum AvatarPreview {
    static let flag = "--avatar-preview"

    /// One row per step, one state per tab. Each step turns at least one
    /// working tab to done, so the burst of joy shows every cycle.
    static let script: [[PaneActivity]] = [
        [.working, .needsInput, .done, .idle, .working],
        [.done, .needsInput, .done, .idle, .working],
        [.needsInput, .working, .idle, .idle, .working],
        [.working, .done, .idle, .idle, .done],
    ]

    static func run(_ app: NSApplication) -> Never {
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 330),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Opus avatar preview"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        window.isReleasedWhenClosed = false
        let root = Backdrop(frame: NSRect(x: 0, y: 0, width: 760, height: 330))
        window.contentView = root

        let titles = ["Travaille", "T'attend", "A fini", "Au repos", "Longue tâche"]
        let strip = makeStrip(titles: titles, y: 280, in: root)
        let tired = makeStrip(titles: titles, y: 240, in: root)
        tired.weekPercent = 99
        label("semaine 99 %, paupières lourdes", x: 560, y: 248, in: root)

        let moods: [(String, NSColor, Bool, (Double) -> ClaudeAvatar.Pose?)] = [
            ("travaille", OpusTheme.cyan, false, { ClaudeAvatar.pose(.working, time: $0) }),
            ("t'attend", OpusTheme.red, false, { ClaudeAvatar.pose(.needsInput, time: $0) }),
            ("a fini", OpusTheme.green, false, { ClaudeAvatar.pose(.done, time: $0) }),
            ("dort", OpusTheme.cream(0.75), true, { ClaudeAvatar.sleeping(time: $0) }),
            ("cherche", OpusTheme.cream(0.35), false, { ClaudeAvatar.lookingAround(time: $0) }),
            ("transpire", OpusTheme.cyan, false, { t in
                var pose = ClaudeAvatar.pose(.working, time: t)
                pose?.sweat = true
                return pose
            }),
        ]
        for (index, mood) in moods.enumerated() {
            let view = ClaudeAvatarView(frame: NSRect(x: 24 + CGFloat(index) * 120, y: 70, width: 96, height: 96))
            view.color = mood.1
            view.snoreRoom = mood.2
            view.pose = mood.3
            root.addSubview(view)
            label(mood.0, x: 24 + CGFloat(index) * 120, y: 40, width: 96, in: root)
        }

        MenuBarAvatar.shared.install(onClick: {}, reveal: {})
        DockAvatar.shared.show(.needsInput)
        var step = 0
        let advance = {
            let states = script[step % script.count]
            strip.states = states
            tired.states = states
            MenuBarAvatar.shared.report(states, from: strip) { _ in }
            step += 1
        }
        advance()
        let timer = Timer(timeInterval: 4, repeats: true) { _ in advance() }
        RunLoop.main.add(timer, forMode: .common)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in app.terminate(nil) }
        // Bottom left, in front, without taking the focus from the app in use.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
        }
        window.orderFrontRegardless()
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            snapshot(window: window, into: URL(fileURLWithPath: CommandLine.arguments[index + 1]), app: app)
        }
        print("AVATAR_PREVIEW window=\(window.windowNumber)")
        fflush(stdout)
        app.run()
        exit(0)
    }

    private static func snapshot(window: NSWindow, into dir: URL, app: NSApplication) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var frame = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { timer in
            frame += 1
            let name = String(format: "%02d", frame)
            if let view = window.contentView { write(view, to: dir.appendingPathComponent("window-\(name).png")) }
            if let image = MenuBarAvatar.shared.currentImage { write(image, size: 72, to: dir.appendingPathComponent("menubar-\(name).png")) }
            if let tile = NSApp.dockTile.contentView { write(tile, to: dir.appendingPathComponent("dock-\(name).png")) }
            if frame >= 16 {
                timer.invalidate()
                app.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func write(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func write(_ image: NSImage, size: CGFloat, to url: URL) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func makeStrip(titles: [String], y: CGFloat, in root: NSView) -> ChromeTabStrip {
        let strip = ChromeTabStrip(frame: .zero)
        strip.translatesAutoresizingMaskIntoConstraints = true
        strip.frame = NSRect(x: 16, y: y, width: 540, height: 32)
        strip.titles = titles
        root.addSubview(strip)
        return strip
    }

    private static func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 190, in root: NSView) {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = OpusTheme.cream(0.55)
        field.alignment = width < 190 ? .center : .left
        field.frame = NSRect(x: x, y: y, width: width, height: 16)
        root.addSubview(field)
    }
}

/// The preview's dark ground, drawn by the view so snapshots carry it too.
private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        dirtyRect.fill()
    }
}
