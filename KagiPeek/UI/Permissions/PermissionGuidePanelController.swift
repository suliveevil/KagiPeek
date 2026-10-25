import AppKit
import Combine
import SwiftUI

/// The iScroll-style drag guide: a horizontal non-activating bar that hugs the System
/// Settings window's bottom-right corner, follows that window as it moves, and carries
/// the app icon the user drops into the permission list.
///
/// The bar never becomes key, so dragging the icon out of it is one gesture — System
/// Settings stays frontmost for the whole drop. It dismisses itself on the first of:
/// the grant landing, the Settings window going away, the close button, or a fresh
/// `present` replacing the guide for the other permission.
@MainActor
final class PermissionGuidePanelController {
    /// The anchored follow loop runs at screen-cadence: fast enough that the panel visibly
    /// tracks a dragged Settings window, slow enough to be a rounding error on CPU.
    private static let tickInterval: TimeInterval = 0.25
    /// System Settings can take a few seconds to launch and open its window; give up
    /// quietly after this many ticks so a broken pane URL never leaves an invisible timer.
    private static let settingsWaitTicks = 24
    /// Once visible, tolerate this many consecutive "no Settings window" ticks (sheets,
    /// Spaces transitions) before concluding Settings was closed and letting go.
    private static let settingsLostTicks = 12
    /// How long the granted state stays up before the guide fades out.
    private static let grantedLinger: TimeInterval = 0.9

    private var panel: PermissionGuidePanel?
    private var trackingTimer: Timer?
    private var currentPermission: AppPermission?
    private var grantSink: AnyCancellable?
    private var grantedWork: DispatchWorkItem?
    private var waitingTicks = 0
    private var lostTicks = 0

    deinit {
        trackingTimer?.invalidate()
        grantedWork?.cancel()
    }

    func present(_ permission: AppPermission, localization: Localization) {
        guard !permission.isGranted else { return }
        currentPermission = permission
        waitingTicks = 0
        lostTicks = 0
        grantedWork?.cancel()
        grantedWork = nil

        rebuildContent(permission: permission, localization: localization)
        observeGrant(of: permission)
        startTracking()
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        grantSink = nil
        grantedWork?.cancel()
        grantedWork = nil
        currentPermission = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: - Content

    private func rebuildContent(permission: AppPermission, localization: Localization) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let root = PermissionGuideView(permission: permission) { [weak self] in
            self?.dismiss()
        }
        .environmentObject(localization)

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        if let old = panel.contentView as? NSVisualEffectView {
            old.subviews.forEach { $0.removeFromSuperview() }
            old.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: old.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: old.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: old.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: old.bottomAnchor)
            ])
            // The SwiftUI tree fixes the width; its intrinsic height decides the panel's,
            // so the panel hugs the (localized) text on every language.
            panel.setContentSize(NSSize(width: PermissionGuideView.width, height: hosting.fittingSize.height))
        }
    }

    private func makePanel() -> PermissionGuidePanel {
        let panel = PermissionGuidePanel(
            contentRect: NSRect(x: 0, y: 0, width: PermissionGuideView.width, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        return panel
    }

    // MARK: - Grant detection

    private func observeGrant(of permission: AppPermission) {
        grantSink = permission.$isGranted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                guard granted else { return }
                self?.permissionGranted()
            }
    }

    /// The view flips itself into its granted state (it observes the same permission);
    /// the controller only stops tracking and schedules the fade-out.
    private func permissionGranted() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        grantedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grantedLinger, execute: work)
    }

    // MARK: - Anchored tracking

    private func startTracking() {
        trackingTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        trackingTimer = timer
    }

    private func tick() {
        guard let panel, let permission = currentPermission else {
            dismiss()
            return
        }
        // The Combine sink is the primary grant signal; this guards against a sink dropped
        // with the panel (both hold the permission weakly through different paths).
        if permission.isGranted {
            permissionGranted()
            return
        }

        guard let settingsFrame = SettingsWindowLocator.settingsWindowFrame() else {
            if panel.isVisible {
                lostTicks += 1
                if lostTicks >= Self.settingsLostTicks { dismiss() }
            } else {
                waitingTicks += 1
                if waitingTicks >= Self.settingsWaitTicks { dismiss() }
            }
            return
        }
        lostTicks = 0

        let visibleFrame = SettingsWindowLocator.screenVisibleFrame(forSettingsFrame: settingsFrame)
        let origin = PermissionGuidePlacement.anchoredOrigin(
            panelSize: panel.frame.size,
            settingsFrame: settingsFrame,
            visibleFrame: visibleFrame
        )
        let target = NSRect(origin: origin, size: panel.frame.size)

        if panel.isVisible {
            // Sub-pixel jitter from the coordinate flip would animate forever; only chase
            // moves the user can see.
            guard abs(target.origin.x - panel.frame.origin.x) > 0.5
                || abs(target.origin.y - panel.frame.origin.y) > 0.5 else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().setFrame(target, display: true)
            })
        } else {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            })
        }
    }
}

/// Never key, never main: the guide floats over System Settings without stealing focus,
/// which is what keeps drag-icon-into-list one continuous gesture.
final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The guide bar's content: the draggable app icon on the left, the permission and the
/// drag instruction beside it, and the remove-then-add hint underneath — everything on
/// one strip so the bar stays out of the way of the list it points at.
private struct PermissionGuideView: View {
    static let width: CGFloat = 460

    @EnvironmentObject private var localization: Localization
    @ObservedObject var permission: AppPermission
    let onClose: () -> Void

    private var tint: Color {
        switch permission.iconColorName {
        case "blue": return .blue
        case "orange": return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        Group {
            if permission.isGranted {
                Label(localization.text(.permissionGuideGranted), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(localization.text(permission.titleKey))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(tint)
                                .lineLimit(1)
                            Text(localization.text(.permissionGuideDrag))
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                        }
                        Text(localization.text(.permissionGuideStaleHint))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    closeButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width)
        // The bar's height is fixed when the instructions are laid out; the granted
        // state is smaller, so it centers in the space instead of hanging to one side.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(IconButtonStyle(hoverFill: .white.opacity(0.14), size: 22, cornerRadius: 6))
        .help(localization.text(.permissionGuideClose))
    }

    /// The drag source, with the same hand cue iScroll paints next to its icon so the
    /// affordance reads before any text does.
    private var icon: some View {
        DragAppIcon(side: 44)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(tint))
                    .offset(x: 4, y: 4)
            }
    }
}
