// ChromeButtonBar: the toolbar's buttons, the way a macOS toolbar draws
// them: one weight, one size, monochrome, a rounded fill under the pointer.
// The open drawer's button is drawn brighter rather than in a colour.
//
// Copy and Artifacts open their drawers, Keychain the secrets panel, and
// "⋯" a menu for what is set once per session (pin, bypass permissions).

import AppKit
import OpusArtifactsKit

final class ChromeButtonBar: NSView {
    var activeDrawer: DrawerGeometry.Occupant = .none { didSet { restyle() } }
    /// A hairline before the first button, for a bar where the buttons
    /// follow other content (one bottom bar).
    var showsLeadingSeparator = false { didSet { leadingSeparator.isHidden = !showsLeadingSeparator } }
    var onCopy: (() -> Void)?
    var onArtifacts: (() -> Void)?
    var onKeychain: (() -> Void)?
    /// Built on each click, so its check marks are always current.
    var moreMenu: (() -> NSMenu)?

    private let copyButton = ChromeIconButton(symbol: "doc.on.clipboard", label: "Copier",
                                              toolTip: "Copier la dernière réponse, bloc par bloc (Cmd+Shift+C)")
    private let artifactsButton = ChromeIconButton(symbol: "sidebar.trailing", label: "Artifacts",
                                                   toolTip: "Fichiers et images de la session (Cmd+Shift+A)")
    private let keychainButton = ChromeIconButton(symbol: "key", label: "Trousseau",
                                                  toolTip: "Trousseau des secrets (Cmd+Ctrl+K)")
    private let moreButton = ChromeIconButton(symbol: "ellipsis.circle", label: "Plus",
                                              toolTip: "Épingler, permissions…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        copyButton.onPress = { [weak self] _ in self?.onCopy?() }
        artifactsButton.onPress = { [weak self] _ in self?.onArtifacts?() }
        keychainButton.onPress = { [weak self] _ in self?.onKeychain?() }
        moreButton.onPress = { [weak self] button in
            guard let menu = self?.moreMenu?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
        }

        let separator = Self.makeSeparator()
        leadingSeparator.isHidden = true

        let stack = NSStackView(views: [leadingSeparator, copyButton, artifactsButton, keychainButton, separator, moreButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.setCustomSpacing(10, after: leadingSeparator)
        stack.setCustomSpacing(6, after: keychainButton)
        stack.setCustomSpacing(6, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor),
        ])
        // As wide as its buttons, which never give way: the tabs or the
        // figures beside them take the slack.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        self.stack = stack
        restyle()
    }

    private weak var stack: NSStackView?
    private let leadingSeparator = ChromeButtonBar.makeSeparator()

    private static func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = OpusTheme.cream(0.1)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return separator
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: stack?.fittingSize.width ?? NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func restyle() {
        copyButton.isActive = activeDrawer == .reply
        artifactsButton.isActive = activeDrawer == .artifacts
    }
}

/// One toolbar icon: 26 by 22, a rounded fill under the pointer.
final class ChromeIconButton: NSView {
    var onPress: ((ChromeIconButton) -> Void)?
    var isActive = false { didSet { restyle() } }

    private let imageView = NSImageView()
    private var isHovered = false { didSet { restyle() } }

    init(symbol: String, label: String, toolTip: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        self.toolTip = toolTip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 22),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onPress?(self) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        imageView.contentTintColor = isActive || isHovered ? OpusTheme.cream(0.95) : OpusTheme.cream(0.55)
        layer?.backgroundColor = (isHovered ? OpusTheme.cream(0.08) : isActive ? OpusTheme.cream(0.05) : .clear).cgColor
    }
}
