import AppKit

/// How every transient panel in Opus arrives and leaves.
///
/// One implementation, not one per panel. The secrets and scripts panels each
/// grew their own copy of this and the prompt palette and session switcher
/// had none at all, so half the app faded and half of it popped. Four copies
/// of the same fifteen lines drift; this is the single place the app's
/// vocabulary of motion is defined.
///
/// The motion itself: a 3% scale-up under a fade, quick and asymmetric — in
/// over 0.14s with an ease-out, out over 0.09s with an ease-in. Appearing
/// slower than disappearing is what makes a panel feel like it arrives rather
/// than blinks, while leaving fast keeps it from being in the way once
/// dismissed.
enum PanelPresentation {
    static let appearDuration: TimeInterval = 0.14
    static let dismissDuration: TimeInterval = 0.09
    private static let startScale: CGFloat = 0.97
    private static let endScale: CGFloat = 0.98

    private static let appearKey = "opusPanelAppear"
    private static let dismissKey = "opusPanelDismiss"

    /// Orders the panel front, makes it key, and fades it in.
    ///
    /// Key status is taken BEFORE the animation starts, not after: a panel
    /// that becomes key only once it has finished fading drops the keystrokes
    /// typed during those 140ms, which is exactly the window a fast user
    /// types in after hitting the hotkey.
    static func appear(_ panel: NSPanel) {
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }
        // A dismiss animation left attached (isRemovedOnCompletion is false
        // below, so the panel stays scaled down while hidden) would otherwise
        // fight this one and the panel would open at 98%.
        layer.removeAnimation(forKey: dismissKey)

        panel.alphaValue = 0
        layer.transform = CATransform3DMakeScale(startScale, startScale, 1)
        panel.orderFrontRegardless()
        panel.makeKey()

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DMakeScale(startScale, startScale, 1)
        scale.toValue = CATransform3DIdentity
        scale.duration = appearDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = CATransform3DIdentity
        layer.add(scale, forKey: appearKey)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fades the panel out, then runs `completion` — which is where the caller
    /// orders it out. Ordering out here instead would take the window off
    /// screen before anything had faded.
    static func dismiss(_ panel: NSPanel, completion: @escaping () -> Void) {
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 0
            completion()
            return
        }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DIdentity
        scale.toValue = CATransform3DMakeScale(endScale, endScale, 1)
        scale.duration = dismissDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        // Held past completion so the panel does not snap back to full size
        // for the last frame before it is ordered out. appear() removes it.
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        layer.add(scale, forKey: dismissKey)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: completion)
    }
}
