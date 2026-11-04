import AppKit

/// Short-lived toast shown after a shortcut completes, equivalent to which-key's
/// "command executed" feedback.
///
/// Conforms to `NoticePresenting` (`Core/Ports/PresentationPorts.swift`): the engine says
/// "show this" and knows nothing about panels or labels.
@MainActor
final class HUDPanelController: NoticePresenting {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        // Long errors are sentences, not chord titles: wrap up to three lines instead of
        // truncating at 460 pt. The width cap only bounds the toast, it no longer decides
        // how much of the message survives.
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
        panel.contentView = effect
    }

    func show(chord: String, title: String, kind: NoticeKind) {
        let body = chord.isEmpty ? title : "\(chord)   \(title)"
        // Only a success gets the marker. A failure that ended with "✓" contradicted its
        // own message; the "!" prefix the callers pass is enough.
        present(kind == .success ? "\(body) ✓" : body, after: duration(for: kind))
    }

    /// Same toast, without the chord/marker framing: standalone explanations such as why
    /// the panel just vanished under secure input.
    func showNotice(text: String, kind: NoticeKind) {
        present(text, after: duration(for: kind))
    }

    /// Failures need reading time: 5 s against 0.75 s for a success and 2.5 s for an
    /// explanation. The old 0.75 s failure vanished mid-sentence.
    private func duration(for kind: NoticeKind) -> TimeInterval {
        switch kind {
        case .success: 0.75
        case .failure: 5.0
        case .info: 2.5
        }
    }

    private func present(_ text: String, after delay: TimeInterval) {
        hideWorkItem?.cancel()
        label.stringValue = text
        // An uncapped toast grew to the width of the longest command title and hung across
        // the screen, so the width stays capped. The cap is 520 pt and the label wraps at
        // it; the height grows to fit up to three lines.
        let width = min(520, max(180, label.intrinsicContentSize.width + 34))
        label.preferredMaxLayoutWidth = width - 28
        let fitting = label.sizeThatFits(
            NSSize(width: width - 28, height: .greatestFiniteMagnitude)
        )
        panel.setContentSize(NSSize(width: width, height: max(44, fitting.height + 20)))
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                // The completion handler is `@Sendable` and nonisolated in the SDK, so it
                // cannot touch the panel directly any more. Hop instead of asserting: a
                // `Task` is a promise about where the work runs, an `assumeIsolated` is only
                // a promise about where it happened to be called.
                Task { @MainActor in
                    self.panel.orderOut(nil)
                }
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 90
        ))
    }
}
