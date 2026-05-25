// OnboardingWindowController — shown on first launch (or when the user
// resets opus.onboardingShown). Sequentially triggers each macOS permission
// prompt with a brief explanation so the user isn't surprised mid-session.

import AppKit

final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private let stack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var grantedSteps: Set<String> = []

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Opus"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "Opus needs a few permissions")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        let blurb = NSTextField(wrappingLabelWithString:
            "Granting them now keeps macOS prompts from interrupting your work later. " +
            "Each one opens the system dialog — pick \"Allow\" to grant.")
        blurb.font = NSFont.systemFont(ofSize: 13)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(blurb)

        addStep(id: "automation-terminal",
                title: "Control Terminal.app",
                rationale: "Lets Opus open Terminal windows that join the shared Claude session.",
                action: #selector(requestTerminalAutomation))

        // TODO: extend with addStep(...) for additional perms after audit
        // (see Task 9.1 — audit deferred to a human runtime observation pass).

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        stack.addArrangedSubview(spacer)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(statusLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let skip = NSButton(title: "Skip for now", target: self, action: #selector(finishOnboarding))
        skip.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(finishOnboarding))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        row.addArrangedSubview(skip)
        row.addArrangedSubview(done)
        stack.addArrangedSubview(row)
    }

    private func addStep(id: String, title: String, rationale: String, action: Selector) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12

        let textCol = NSStackView()
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2

        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let r = NSTextField(wrappingLabelWithString: rationale)
        r.font = NSFont.systemFont(ofSize: 11)
        r.textColor = .secondaryLabelColor
        r.preferredMaxLayoutWidth = 340
        textCol.addArrangedSubview(t)
        textCol.addArrangedSubview(r)

        let btn = NSButton(title: "Grant", target: self, action: action)
        btn.bezelStyle = .rounded
        btn.identifier = NSUserInterfaceItemIdentifier(id)

        row.addArrangedSubview(textCol)
        row.addArrangedSubview(btn)
        stack.addArrangedSubview(row)
    }

    @objc private func requestTerminalAutomation() {
        // Fire a no-op AppleScript that requires Automation → Terminal.app.
        // macOS prompts the user on first call.
        let src = """
        tell application "Terminal" to count windows
        """
        var err: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
        // The user's "Allow" / "Deny" decision is reflected next time we run.
        // We don't try to read it here — just mark this step touched.
        grantedSteps.insert("automation-terminal")
        statusLabel.stringValue = "Terminal permission requested."
    }

    @objc private func finishOnboarding() {
        OpusPreferences.shared.onboardingShown = true
        close()
    }

    func showIfNeeded() {
        guard !OpusPreferences.shared.onboardingShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
