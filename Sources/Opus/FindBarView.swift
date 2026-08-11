// FindBarView — thin search bar pinned to the top of the container.
// Enter = search UP through scrollback, Shift+Enter = search down,
// Esc = close (and clearSearch).
//
// Fix 5b (v1.4.1): from a bottom viewport (the terminal's normal resting
// position), a plain "search forward" default covers almost nothing — there
// is rarely anything BELOW the current position. Terminal-app convention
// (and what a user typing a search term from the bottom actually wants) is
// Enter = search backward/up through history; the callback names below were
// renamed from onNext/onPrevious to onSearchUp/onSearchDown to say that
// directly instead of via SwiftTerm's forward/backward-in-buffer framing.

import AppKit

final class FindBarView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    var onSearchUp: ((String) -> Void)?
    var onSearchDown: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = 8
        field.translatesAutoresizingMaskIntoConstraints = false
        // Fix 5b (v1.4.1): tell the user the direction up front instead of
        // leaving Enter's behavior to guesswork.
        field.placeholderString = "Find (Enter searches up)"
        field.delegate = self
        field.sendsSearchStringImmediately = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }
}
