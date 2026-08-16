// FindBarView — thin search bar pinned to the top of the container.
// Enter/↑ = search UP through scrollback, Shift+Enter/↓ = search down,
// Esc = close (and clearSearch).
//
// Fix 5b (v1.4.1): from a bottom viewport (the terminal's normal resting
// position), a plain "search forward" default covers almost nothing — there
// is rarely anything BELOW the current position. Terminal-app convention
// (and what a user typing a search term from the bottom actually wants) is
// Enter = search backward/up through history; the callback names below were
// renamed from onNext/onPrevious to onSearchUp/onSearchDown to say that
// directly instead of via SwiftTerm's forward/backward-in-buffer framing.
//
// Fix 2 (v1.4.2): arrow keys now do the same thing as Enter/Shift+Enter —
// see control(_:textView:doCommandBy:) — plus a right-aligned "n / total"
// match counter (updateMatchCounter, driven by TerminalContainerView after
// every navigation).

import AppKit

final class FindBarView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    /// Fix 2 (v1.4.2) — "n / total" / "no match" readout at the bar's
    /// trailing end. Empty string (its initial/idle value) takes ~0 width,
    /// so `field` gets the bar's full space until there's something to show.
    private let counterLabel = NSTextField(labelWithString: "")
    var onSearchUp: ((String) -> Void)?
    var onSearchDown: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        layer?.cornerRadius = OpusTheme.radiusControl

        // Fix (v1.5.1, Cmd+F readability): the field read as grey on white
        // in macOS Light mode. Root cause: this view never forced an
        // appearance, so the embedded NSSearchField drew its bezel using the
        // SYSTEM appearance — a white rounded bezel painted INSIDE this dark
        // bar — and the cream(0.95) text set below then sat on white.
        // Same one-line pattern and rationale as
        // SessionSwitcherPanel.swift:144 (force darkAqua regardless of the
        // system appearance so OUR dark palette below draws correctly no
        // matter what mode macOS is in). NOT sufficient alone — see the
        // isBezeled/drawsBackground block below, which stops the field from
        // drawing a system bezel at all.
        self.appearance = NSAppearance(named: .darkAqua)

        field.translatesAutoresizingMaskIntoConstraints = false
        // Fix 2 (v1.4.2): mention both arrow directions now that they work,
        // not just Enter.
        //
        // Fix (v1.5.1) — verified against the new `fieldBackground`
        // (calibratedWhite 0.16): cream(0.45)/cream(0.95) are a light warm
        // off-white at 45%/95% opacity over a dark grey, i.e. still a light-
        // on-dark pairing, not the light-on-light bezel bug this fix
        // removes — legible same as before.
        field.placeholderAttributedString = NSAttributedString(
            string: "Find (↑ older, ↓ newer)",
            attributes: [.foregroundColor: OpusTheme.cream(0.45)]
        )
        field.textColor = OpusTheme.cream(0.95)
        // Fix (v1.5.1, Cmd+F readability): forcing darkAqua above fixes the
        // system bezel's TINT, but NSSearchField still synthesizes its own
        // bezel — a rounded control background AppKit draws itself, not
        // something `layer?.backgroundColor` above ever touched. Killing
        // that bezel and painting the field's own background ourselves
        // (`OpusTheme.fieldBackground`, lighter than the bar so it stays
        // visually distinct — see that token's doc comment) is what
        // actually removes the white rect. `focusRingType` is
        // deliberately left untouched: the focus ring must stay visible.
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = OpusTheme.fieldBackground
        field.delegate = self
        field.sendsSearchStringImmediately = false
        addSubview(field)

        // Fix 2 (v1.4.2): monospaced digits so "3 / 17" → "12 / 17" doesn't
        // jitter width as the digits change while output streams in. Cream,
        // same base color as the rest of the app's text (see e.g.
        // SessionSwitcherPanel's title/subtitle labels).
        counterLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counterLabel.textColor = OpusTheme.cream(0.55)
        counterLabel.alignment = .right
        counterLabel.lineBreakMode = .byClipping
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(counterLabel)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: counterLabel.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),

            counterLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            counterLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onSearchDown?(field.stringValue)
            } else {
                onSearchUp?(field.stringValue)
            }
            return true
        // Fix 2 (v1.4.2): arrow-key navigation — same targets as Enter/
        // Shift+Enter, same up/down framing as the placeholder above.
        case #selector(NSResponder.moveUp(_:)):
            onSearchUp?(field.stringValue)
            return true
        case #selector(NSResponder.moveDown(_:)):
            onSearchDown?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }

    /// Fix 2 (v1.4.2) — called by TerminalContainerView.navigateFind after
    /// EVERY search navigation (Enter, arrow, or Cmd+G/Cmd+Shift+G — the
    /// latter two route through here too even though they don't touch this
    /// view's own field). Never called per keystroke.
    func updateMatchCounter(_ text: String) {
        counterLabel.stringValue = text
    }
}
