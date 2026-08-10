// KeyMods — modifier normalization for shortcut matching.
// .deviceIndependentFlagsMask keeps .capsLock, so `mods == .command` is false
// whenever Caps Lock is engaged and every Cmd shortcut silently dies.
// Strip lock/derived bits that never participate in our shortcuts.

import AppKit

enum KeyMods {
    static func shortcutMods(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
             .subtracting([.capsLock, .numericPad, .function])
    }
}
