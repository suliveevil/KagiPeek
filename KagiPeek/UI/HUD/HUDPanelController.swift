import AppKit

/// Short-lived toast shown after a shortcut completes, equivalent to which-key's
/// "command executed" feedback.
@MainActor
final class HUDPanelController {
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
        label.lineBreakMode = .byTruncatingTail
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

    func show(chord: String, title: String) {
        present("\(chord)   \(title) ✓", after: 0.75)
    }

    /// Same toast, without the chord/✓ framing: standalone explanations such as why the
    /// panel just vanished under secure input, which read better a beat longer.
    func showNotice(text: String) {
        present(text, after: 1.2)
    }

    private func present(_ text: String, after delay: TimeInterval) {
        hideWorkItem?.cancel()
        label.stringValue = text
        // An uncapped toast grew to the width of the longest command title and hung across
        // the screen; past this the label truncates instead.
        let width = min(460, max(180, label.intrinsicContentSize.width + 34))
        panel.setContentSize(NSSize(width: width, height: 44))
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
                self.panel.orderOut(nil)
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
