// ArtifactActions — what a row does when acted on.
//
// Every action uses the artifact's REAL values. Redaction happens at the
// view layer only: opening a redacted URL would open nothing, and copying
// one would hand the user a broken link.

import AppKit
import OpusArtifactsKit

enum ArtifactActions {
    static func open(_ artifact: Artifact) {
        if let path = artifact.resolvedPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let raw = artifact.urlString, let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        }
    }

    static func revealInFinder(_ artifact: Artifact) {
        guard let path = artifact.resolvedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func revealParent(_ artifact: Artifact) {
        guard let path = artifact.resolvedPath else { return }
        let parent = (path as NSString).deletingLastPathComponent
        NSWorkspace.shared.open(URL(fileURLWithPath: parent))
    }

    static func copyPath(_ artifact: Artifact) {
        guard let path = artifact.resolvedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func copyLink(_ artifact: Artifact) {
        guard let raw = artifact.urlString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }

    /// Menu items that make sense for this artifact. Items with no meaning
    /// for its kind are ABSENT rather than disabled: a permanently greyed
    /// "Copy Link" on every file row is noise that teaches nothing.
    static func menu(for artifact: Artifact, target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(ArtifactMenuTarget.menuOpen), keyEquivalent: "")
        if artifact.resolvedPath != nil {
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(ArtifactMenuTarget.menuReveal), keyEquivalent: "")
            menu.addItem(withTitle: "Reveal Parent Folder", action: #selector(ArtifactMenuTarget.menuRevealParent), keyEquivalent: "")
            menu.addItem(withTitle: "Copy Path", action: #selector(ArtifactMenuTarget.menuCopyPath), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Copy Link", action: #selector(ArtifactMenuTarget.menuCopyLink), keyEquivalent: "")
        }
        for item in menu.items { item.target = target }
        return menu
    }
}

/// The selectors `ArtifactActions.menu` wires. Implemented by
/// ArtifactsDrawerView, which is the only object that knows which row was
/// right-clicked.
@objc protocol ArtifactMenuTarget {
    func menuOpen()
    func menuReveal()
    func menuRevealParent()
    func menuCopyPath()
    func menuCopyLink()
}
