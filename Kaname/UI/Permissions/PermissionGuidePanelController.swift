import AppKit
import Combine
import SwiftUI

/// Drives the guide panel's scale during the entrance. The window frame animates on the
/// AppKit side; the scale lives in SwiftUI because a layer transform on a non-layer-backed
/// hosting view is a fight with the layout engine.
@MainActor
final class PermissionGuideAnimation: ObservableObject {
    @Published var scale: CGFloat = 1
}

/// The macOS permission drag guide: a horizontal non-activating bar that floats inside the
/// System Settings window, under the list, carrying the app icon the user drops into that
/// list.
///
/// The bar never becomes key, so dragging the icon out of it is one gesture — System
/// Settings stays frontmost for the whole drop.
///
/// Modelled on LobeHub's desktop guide (`feat/macos-permission-drag-guide`, PR #20932):
/// the panel is a small state machine, not a static hint. It reports the four ways the flow
/// goes wrong — Settings closed, the user navigated away, the password prompt was
/// cancelled — instead of repeating a drag instruction the user cannot act on, and it flies
/// in from the Kaname window along an arc so the panel is visibly *from* the thing that
/// was clicked.
@MainActor
final class PermissionGuidePanelController {
    /// The anchored follow loop runs at screen-cadence: fast enough that the panel visibly
    /// tracks a dragged Settings window, slow enough to be a rounding error on CPU.
    private static let tickInterval: TimeInterval = 0.25
    /// System Settings can take a few seconds to launch and open its window; give up quietly
    /// after this many ticks so a broken pane URL never leaves an invisible timer.
    private static let settingsWaitTicks = 40
    /// Once visible, tolerate this many consecutive "no Settings window" ticks (Spaces
    /// transitions, a sheet taking the list with it) before concluding Settings was closed.
    private static let settingsLostTicks = 8
    /// How long the granted state stays up before the guide closes itself.
    private static let grantedLinger: TimeInterval = 1.2
    private static let flightInterval: TimeInterval = 1.0 / 60.0

    private var panel: PermissionGuidePanel?
    private var trackingTimer: Timer?
    private var flightTimer: Timer?
    private var currentPermission: AppPermission?
    private var localization: Localization?
    private var phase: PermissionGuidePhase = .dragging
    private let animation = PermissionGuideAnimation()

    private var grantSink: AnyCancellable?
    private var grantedWork: DispatchWorkItem?
    private var waitingTicks = 0
    private var lostTicks = 0
    private var promptWasUp = false
    private var hasAnchored = false
    private var targetOrigin: CGPoint?
    private var flightOrigin: CGPoint?
    private var flightStartedAt: Date?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `isolated deinit` (SE-0371, Swift 6.2): this controller is `@MainActor`, and the
    /// timers and work item it owns are non-`Sendable`. A plain deinit is nonisolated and
    /// Swift 6 rejects reading those properties there. Inheriting the actor's isolation
    /// makes teardown run on the main actor — which is also where the timers were scheduled —
    /// instead of asserting it with `assumeIsolated` or hiding the properties behind
    /// `nonisolated(unsafe)`.
    isolated deinit {
        trackingTimer?.invalidate()
        flightTimer?.invalidate()
        grantedWork?.cancel()
    }

    // MARK: - Lifecycle

    func present(_ permission: AppPermission, localization: Localization) {
        guard !permission.isGranted else { return }
        currentPermission = permission
        self.localization = localization
        phase = .dragging
        waitingTicks = 0
        lostTicks = 0
        promptWasUp = false
        hasAnchored = false
        targetOrigin = nil
        flightOrigin = nil
        grantedWork?.cancel()
        grantedWork = nil
        animation.scale = 1

        permission.setGuideStatus(.waiting)
        rebuildContent()
        observeGrant(of: permission)
        startTracking()
    }

    /// Closes the guide. `interrupted` is the honest half: a guide that was dismissed before
    /// the grant landed leaves the permission row saying "continue", not "waiting" forever.
    func dismiss() {
        dismiss(interrupted: true)
    }

    private func dismiss(interrupted: Bool) {
        trackingTimer?.invalidate()
        trackingTimer = nil
        stopFlight()
        grantSink = nil
        grantedWork?.cancel()
        grantedWork = nil

        if interrupted, let permission = currentPermission, !permission.isGranted {
            permission.setGuideStatus(.interrupted)
        }
        currentPermission = nil
        flightOrigin = nil
        targetOrigin = nil

        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // The handler is `@Sendable` and runs unisolated as far as the type system knows;
            // `Task { @MainActor }` states where the work runs instead of asserting where the
            // callback was made.
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    // MARK: - Content

    private func rebuildContent() {
        guard let permission = currentPermission, let localization else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        let root = PermissionGuideView(
            permission: permission,
            animation: animation,
            phase: phase,
            onClose: { [weak self] in self?.dismiss(interrupted: true) },
            onAction: { [weak self] action in self?.run(action) }
        )
        .environmentObject(localization)

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        guard let old = panel.contentView as? NSVisualEffectView else { return }
        old.subviews.forEach { $0.removeFromSuperview() }
        old.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: old.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: old.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: old.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: old.bottomAnchor)
        ])
        // The SwiftUI tree fixes the width; its intrinsic height decides the panel's, so the
        // panel hugs the (localized) text on every language and every phase. Laying out
        // first matters: `fittingSize` on a tree that has never been laid out reports the
        // size of an empty view, which collapsed the panel to the default rect.
        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height, PermissionGuideView.minHeight)
        if panel.frame.size != NSSize(width: PermissionGuideView.width, height: height) {
            panel.setContentSize(NSSize(width: PermissionGuideView.width, height: height))
        }
    }

    private func makePanel() -> PermissionGuidePanel {
        let panel = PermissionGuidePanel(
            contentRect: NSRect(x: 0, y: 0, width: PermissionGuideView.width, height: PermissionGuideView.minHeight),
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
        panel.becomesKeyOnlyIfNeeded = true
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

    /// The permission's button in the panel. Reopening Settings is a user action, never a
    /// reaction to a state change: the panel must not put a System Settings window on screen
    /// by itself.
    private func run(_ action: PermissionGuideAction) {
        switch action {
        case .openSettings:
            currentPermission?.openSettingsPane()
        }
    }

    // MARK: - State machine

    private func apply(_ event: PermissionGuideEvent) {
        let next = PermissionGuideState.next(phase, on: event)
        guard next != phase else { return }
        phase = next
        rebuildContent()
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

    /// The view flips itself into its granted state (it observes the same permission); the
    /// controller stops tracking, waits out the linger, closes, and hands the front back to
    /// Kaname — the grant happened inside System Settings, so without the explicit
    /// activation the user is left staring at a settings window with no next step.
    private func permissionGranted() {
        guard phase != .granted else { return }
        trackingTimer?.invalidate()
        trackingTimer = nil
        stopFlight()
        animation.scale = 1
        currentPermission?.setGuideStatus(.idle)
        apply(.granted)

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss(interrupted: false)
            NSApp.activate(ignoringOtherApps: true)
        }
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

        let windows = SettingsWindowLocator.settingsWindows()
        guard let main = windows.first else {
            handleSettingsGone(panel: panel)
            return
        }
        lostTicks = 0
        if !hasAnchored {
            hasAnchored = true
            // The window the guide has been waiting for: fly to it.
            flightOrigin = flightOrigin ?? kanameAnchor()
        } else if phase == .settingsClosed {
            apply(.settingsAppeared)
        }

        detectPrompt(windows: windows)

        let visibleFrame = SettingsWindowLocator.screenVisibleFrame(forSettingsFrame: main)
        targetOrigin = anchoredOrigin(panelSize: panel.frame.size, settingsFrame: main, visibleFrame: visibleFrame)
        if flightTimer == nil { followTarget(panel: panel) }
    }

    /// No Settings window on screen. Before the first one appeared that is just a slow
    /// launch; afterwards it is news, and the panel moves to the middle of the screen and
    /// offers to reopen — LobeHub's fallback for the same dead end.
    private func handleSettingsGone(panel: PermissionGuidePanel) {
        guard hasAnchored else {
            waitingTicks += 1
            if waitingTicks >= Self.settingsWaitTicks { dismiss(interrupted: true) }
            return
        }
        lostTicks += 1
        if lostTicks >= Self.settingsLostTicks, phase != .settingsClosed {
            apply(.settingsLost)
        }
        guard phase == .settingsClosed else { return }
        targetOrigin = PermissionGuidePlacement.screenCenterOrigin(
            panelSize: panel.frame.size,
            visibleFrame: SettingsWindowLocator.mainScreenVisibleFrame
        )
        if flightTimer == nil { followTarget(panel: panel) }
    }

    /// A password / Touch ID prompt is a second Settings window over the main one: its
    /// appearance is "waiting for confirmation", and its disappearance without a grant is
    /// the cancellation the panel has to admit to.
    private func detectPrompt(windows: [NSRect]) {
        let isUp = SettingsWindowLocator.showsConfirmationPrompt(windows: windows)
        guard isUp != promptWasUp else { return }
        promptWasUp = isUp
        apply(isUp ? .sheetShown : .sheetDismissed)
    }

    // There is deliberately no "the user navigated to another page" detection. LobeHub reads
    // it from the Settings window title (Screen Recording), and the permission-free
    // substitute — `CurrentExtensionURL` — neither carries the page in a matchable form nor
    // updates while Settings runs; see `SettingsPaneProbe`. Guessing cost more than it paid:
    // it fired for every user and hid the drag icon.

    /// Inside the Settings window, centred under the list, is the placement that makes the
    /// drop one short move up. A window too small to hold the panel falls back to hugging
    /// the window from outside, which is what this guide did before.
    private func anchoredOrigin(panelSize: CGSize, settingsFrame: NSRect, visibleFrame: NSRect) -> CGPoint {
        let contentArea = PermissionGuidePlacement.contentArea(
            settingsFrame: settingsFrame,
            sidebarWidth: SettingsWindowLocator.sidebarWidth() ?? 0
        )
        if let inside = PermissionGuidePlacement.insideBottomCenterOrigin(
            panelSize: panelSize,
            contentArea: contentArea,
            visibleFrame: visibleFrame
        ) {
            return inside
        }
        return PermissionGuidePlacement.anchoredOrigin(
            panelSize: panelSize,
            settingsFrame: settingsFrame,
            visibleFrame: visibleFrame
        )
    }

    /// Moves the panel to `targetOrigin`, animating only the moves a person can see.
    private func followTarget(panel: PermissionGuidePanel) {
        guard let targetOrigin else { return }
        let target = NSRect(origin: targetOrigin, size: panel.frame.size)

        if panel.isVisible {
            // Sub-pixel jitter from the coordinate flip would animate forever; only chase
            // moves the user can see.
            guard abs(target.origin.x - panel.frame.origin.x) > 0.5
                || abs(target.origin.y - panel.frame.origin.y) > 0.5
            else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().setFrame(target, display: true)
            })
        } else {
            startEntrance(panel: panel, target: target)
        }
    }

    private func startEntrance(panel: PermissionGuidePanel, target: NSRect) {
        // Reduce Motion: the panel appears where it belongs, with a cross-fade. Flying it
        // across the screen is exactly the kind of motion the setting exists to stop.
        guard !reduceMotion, let origin = flightOrigin, origin != target.origin else {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            })
            return
        }

        panel.setFrame(NSRect(origin: origin, size: target.size), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        animation.scale = PermissionGuideFlight.startScale
        flightStartedAt = Date()

        flightTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.flightInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFlight() }
        }
        timer.tolerance = Self.flightInterval / 4
        flightTimer = timer
    }

    private func tickFlight() {
        guard let panel, let startedAt = flightStartedAt, let from = flightOrigin, let to = targetOrigin else {
            stopFlight()
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let progress = CGFloat(min(max(elapsed / PermissionGuideFlight.duration, 0), 1))
        let position = PermissionGuideFlight.point(progress: progress, from: from, to: to)
        panel.setFrame(NSRect(origin: position, size: panel.frame.size), display: true)
        animation.scale = PermissionGuideFlight.scale(progress: progress)

        if progress >= 1 {
            stopFlight()
            panel.setFrame(NSRect(origin: to, size: panel.frame.size), display: true)
            animation.scale = 1
        }
    }

    private func stopFlight() {
        flightTimer?.invalidate()
        flightTimer = nil
        flightStartedAt = nil
    }

    /// Where the panel flies out of: the largest visible Kaname window, which is the one
    /// the user just clicked in. Nil when nothing of ours is on screen, in which case the
    /// panel simply fades in.
    private func kanameAnchor() -> CGPoint? {
        let candidate = NSApp.windows
            .filter { $0.isVisible && $0.level == .normal && $0.frame.width > 80 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let frame = candidate?.frame else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// Never key, never main: the guide floats over System Settings without stealing focus,
/// which is what keeps drag-icon-into-list one continuous gesture.
final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The guide bar's content: the draggable app icon on the left, the phase's message beside
/// it, and either the drop target's own action or the close button on the right.
///
/// The bar is one strip so it stays out of the way of the list it points at, and its text is
/// allowed to wrap rather than truncate: the recovery messages are the whole point of the
/// panel, and an ellipsis there is worse than a taller panel.
private struct PermissionGuideView: View {
    static let width: CGFloat = 520
    static let minHeight: CGFloat = 76

    @EnvironmentObject private var localization: Localization
    @ObservedObject var permission: AppPermission
    @ObservedObject var animation: PermissionGuideAnimation
    let phase: PermissionGuidePhase
    let onClose: () -> Void
    let onAction: (PermissionGuideAction) -> Void

    private var tint: Color {
        switch permission.presentation.iconColorName {
        case "blue": return .blue
        case "orange": return .orange
        case "red": return .red
        default: return .accentColor
        }
    }

    private var action: PermissionGuideAction? {
        PermissionGuideState.action(for: phase)
    }

    var body: some View {
        Group {
            if phase == .granted {
                grantedLabel
            } else {
                strip
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .scaleEffect(animation.scale, anchor: .center)
        // The bar's height is fixed when the instructions are laid out; the granted state is
        // smaller, so it centers in the space instead of hanging to one side.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var grantedLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: IconScale.large, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.text(.permissionGuideGranted))
                    .font(.system(size: TypeScale.body, weight: .semibold))
                Text(localization.text(.permissionGuideGrantedHint))
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var strip: some View {
        HStack(spacing: 12) {
            leadingGlyph
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(localization.text(headlineKey))
                        .font(.system(size: TypeScale.callout, weight: .semibold))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(localization.text(PermissionGuideState.detailKey(for: phase)))
                        .font(.system(size: TypeScale.callout, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if PermissionGuideState.showsDragSource(phase) {
                    Text(localization.text(.permissionGuideStaleHint))
                        .font(.system(size: TypeScale.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)

            if let action {
                Button(localization.text(PermissionGuideState.actionKey(for: action))) {
                    onAction(action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            closeButton
        }
    }

    private var headlineKey: L10nKey {
        PermissionGuideState.headlineKey(for: phase, permissionTitle: permission.presentation.titleKey)
    }

    /// The drag source while a drop is possible, and a plain status glyph when it is not —
    /// offering something to drag with no list to drag it into is what made the old flow
    /// feel broken. Note the direction of the rule: only "no window to drop into" and
    /// "already granted" take the icon away. A message alone never does.
    @ViewBuilder
    private var leadingGlyph: some View {
        if PermissionGuideState.showsDragSource(phase) {
            DragAppIcon(side: 40, cue: .dragTarget)
        } else {
            Image(systemName: statusGlyphName)
                .font(.system(size: IconScale.large, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
        }
    }

    private var statusGlyphName: String {
        phase == .settingsClosed ? "macwindow.badge.plus" : permission.presentation.iconName
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(IconButtonStyle(hoverFill: .white.opacity(0.14), size: 22, cornerRadius: 6))
        .accessibilityLabel(localization.text(.permissionGuideClose))
        .help(localization.text(.permissionGuideClose))
    }
}

/// The port the engine drives (`Core/Ports/PresentationPorts.swift`). The guide keeps no
/// reference to the engine, so the localization travels with the call.
extension PermissionGuidePanelController: PermissionGuidePresenting {
    func presentPermissionGuide(_ permission: AppPermission, localization: Localization) {
        present(permission, localization: localization)
    }
}
