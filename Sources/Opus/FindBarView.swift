// FindBarView — thin search bar pinned to the top of the container.
// Enter = next, Shift+Enter = previous, Esc = close (and clearSearch).

import AppKit

final class FindBarView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    var onNext: ((String) -> Void)?
    var onPrevious: ((String) -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = 8
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Find in scrollback"
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
                onPrevious?(field.stringValue)
            } else {
                onNext?(field.stringValue)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }
}
