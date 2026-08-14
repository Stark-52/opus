import AppKit

/// A text field on a rounded plate — the one input look in Opus.
///
/// Before this, every panel styled its own. Three font sizes across four
/// panels, some fields with the system bezel and some without, one with the
/// blue system focus ring and the rest with none. Two failure modes were
/// shared by all of them:
///
///  - `drawsBackground = true` paints the field's own rectangle, which has no
///    corner radius. A hard-cornered box sat inside a 14pt-rounded panel.
///  - a bezel-less NSTextField does NOT vertically centre its text in a frame
///    taller than the text. The bezel is what normally does that, so removing
///    it left every placeholder riding high in its box.
///
/// This view owns the plate and positions the field inside it at the field's
/// own natural height, which fixes both. Panels set the plate's frame and
/// nothing else; `layout()` places the rest.
final class FieldPlate: NSView {
    /// Every input in the app is this tall, so a panel that stacks a name and
    /// a value field gets an even rhythm without each caller picking a number.
    static let height: CGFloat = 30
    /// One size for every field. 13pt is the smallest that stays comfortable
    /// for a value you are checking character by character, which is what the
    /// secrets panel's fields are for.
    static let fontSize: CGFloat = 13

    let field: NSTextField
    private let icon: NSImageView?
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat

    /// - Parameters:
    ///   - field: the caller supplies it, because it may be an NSTextField, an
    ///     NSSecureTextField or an NSSearchField and the plate does not care.
    ///   - iconSymbol: drawn at the leading edge. Supplied here rather than
    ///     left to NSSearchField's own magnifier: without a bezel that button
    ///     is not given any space, so it renders on top of the first two
    ///     characters.
    ///   - trailingInset: room for a control the panel puts on top of the
    ///     plate, e.g. the secrets panel's reveal eye.
    init(field: NSTextField, placeholder: String, iconSymbol: String? = nil,
         trailingInset: CGFloat = 10) {
        self.field = field
        self.trailingInset = trailingInset

        if let iconSymbol {
            let view = NSImageView()
            let image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)
            image?.isTemplate = true
            view.image = image
            view.contentTintColor = OpusTheme.cream(0.35)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.refusesFirstResponder = true
            self.icon = view
            self.leadingInset = 10 + 13 + 8      // inset + glyph + gap
        } else {
            self.icon = nil
            self.leadingInset = 10
        }

        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = OpusTheme.fieldBackground.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = OpusTheme.radiusControl
        layer?.borderWidth = 1
        layer?.borderColor = OpusTheme.cream(0.07).cgColor

        field.font = NSFont.systemFont(ofSize: Self.fontSize)
        field.textColor = OpusTheme.cream(0.95)
        field.isBezeled = false
        // The PLATE draws the background. Leaving this on would paint the
        // field's square rectangle over the plate's rounded one.
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: OpusTheme.cream(0.4),
                         .font: NSFont.systemFont(ofSize: Self.fontSize)]
        )
        // A search field's own magnifier has no reserved space without a
        // bezel; the plate's icon replaces it. The cancel button is kept —
        // it lives at the trailing edge, where nothing collides with it.
        (field as? NSSearchField).map { ($0.cell as? NSSearchFieldCell)?.searchButtonCell = nil }

        if let icon { addSubview(icon) }
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        let glyph: CGFloat = 13
        icon?.frame = NSRect(x: 10, y: bounds.midY - glyph / 2, width: glyph, height: glyph)
        // The field takes its own natural height, centred. Stretching it to
        // the plate's full height is what pushes the text off the midline.
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: leadingInset,
                             y: bounds.midY - fieldHeight / 2,
                             width: max(0, bounds.width - leadingInset - trailingInset),
                             height: fieldHeight)
    }
}
