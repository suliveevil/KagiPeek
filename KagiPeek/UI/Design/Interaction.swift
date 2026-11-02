import SwiftUI
import UniformTypeIdentifiers

/// Click affordances shared by the panel chrome and the panel rows.
///
/// The floating surfaces are drawn on top of somebody else's window, so a control has to
/// answer the pointer cheaply: a soft fill on hover, a quick dip while the mouse is held
/// down, and a dimmed body when it is disabled. Nothing here changes a control's action.

// MARK: - Icon buttons

/// Hover + press feedback for the small glyph-only buttons (header actions, pager, clear).
///
/// `.plain` removes every hint that a glyph is a button; this style puts the hint back
/// without adding chrome, so the header stays quiet until the pointer arrives.
struct IconButtonStyle: ButtonStyle {
    var hoverFill: Color
    var size: CGFloat = 24
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        IconButtonBody(
            configuration: configuration,
            hoverFill: hoverFill,
            size: size,
            cornerRadius: cornerRadius
        )
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let hoverFill: Color
        let size: CGFloat
        let cornerRadius: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(hoverFill)
                        .opacity(hovering && isEnabled ? 1 : 0)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .opacity(bodyOpacity)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var bodyOpacity: Double {
            guard isEnabled else { return 0.35 }
            return configuration.isPressed ? 0.7 : 1
        }
    }
}

// MARK: - Shared components

/// The ring-plus-arrow treatment the guide panel puts around the icon.
///
/// LobeHub's macOS permission guide marks its drag source with a rotating dashed ring and a
/// bobbing up-arrow badge, so the affordance reads before any text does. Both are
/// decoration: they are hidden from accessibility and never intercept the drag.
enum DragCue {
    /// The bare icon — used everywhere the icon is a supporting illustration.
    case none
    /// The guide panel: dashed ring and up arrow, both frozen under Reduce Motion.
    case dragTarget
}

/// The app icon as a real drag source: drop it into the Accessibility or Input Monitoring
/// list in System Settings. Two surfaces show it at different sizes, so the side is a
/// parameter rather than two components that can drift.
struct DragAppIcon: View {
    var side: CGFloat = 40
    var cue: DragCue = .none

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringRotation: Double = 0
    @State private var arrowBobbing = false

    /// Room for the ring outside the icon, and for the badge above it.
    private var ringInset: CGFloat { side * 0.22 }

    var body: some View {
        ZStack {
            if cue == .dragTarget {
                Circle()
                    .strokeBorder(
                        Color.primary.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1.4, dash: [4, 4])
                    )
                    .frame(width: side + ringInset, height: side + ringInset)
                    .rotationEffect(.degrees(ringRotation))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.23, style: .continuous))
                .onDrag {
                    NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
                }
                .help("Drag into System Settings")
        }
        .overlay(alignment: .topTrailing) {
            if cue == .dragTarget { arrowBadge }
        }
        .onAppear(perform: startCueAnimations)
        .onChange(of: reduceMotion) { _, _ in startCueAnimations() }
    }

    /// The "this goes up into the list" badge. It bobs rather than points, because a static
    /// arrow reads as a button.
    private var arrowBadge: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: max(7, side * 0.22), weight: .heavy))
            .foregroundStyle(.white)
            .padding(max(2, side * 0.07))
            .background(Circle().fill(Color.accentColor))
            .offset(x: side * 0.12, y: -side * 0.16 + (arrowBobbing ? -3 : 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Reduce Motion is checked here rather than per-frame: a permission panel that keeps
    /// spinning while the user has asked the system to stop is worse than no cue at all.
    private func startCueAnimations() {
        guard cue == .dragTarget, !reduceMotion else {
            ringRotation = 0
            arrowBobbing = false
            return
        }
        ringRotation = 0
        withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
            ringRotation = 360
        }
        arrowBobbing = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            arrowBobbing = true
        }
    }
}

// MARK: - Export plumbing

/// The one save-panel configuration the export surfaces share: a default name, folder
/// creation, and a single allowed type. Returns nil when the user cancelled.
@MainActor
enum ExportPanel {
    static func run(defaultName: String, pathExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Decorative shapes

extension View {
    /// A border, rule or highlight that must never intercept a click meant for what is
    /// underneath it. A stroked shape only hit-tests its outline today, but an explicit
    /// opt-out keeps a frame-wide decoration from swallowing edge clicks when it changes.
    func decorative() -> some View {
        allowsHitTesting(false)
    }
}
