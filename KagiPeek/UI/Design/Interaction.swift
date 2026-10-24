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

/// The app icon as a real drag source: drop it into the Accessibility or Input Monitoring
/// list in System Settings. Two surfaces show it at different sizes, so the side is a
/// parameter rather than two components that can drift.
struct DragAppIcon: View {
    var side: CGFloat = 40

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: side, height: side)
            .onDrag {
                NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
            }
            .help("Drag into System Settings")
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
