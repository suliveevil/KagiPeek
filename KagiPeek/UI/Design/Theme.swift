import AppKit
import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 16
    // The numbers the panel window is sized with live in `OverlayMetrics` (pure, testable);
    // the view reads the same ones, so a resize rule can be asserted rather than eyeballed.
    static let rowHeight: CGFloat = OverlayMetrics.rowHeight
    /// Row padding and the row's trailing slot come from `RowLayout` so the pure layout and
    /// the view cannot write two different numbers for the same thing.
    static let rowHorizontalPadding: CGFloat = RowLayout.horizontalPadding
    static let rowGutterWidth: CGFloat = RowLayout.gutterWidth
    static let rowColumnGap: CGFloat = RowLayout.columnGap
    static let groupHeaderHeight: CGFloat = OverlayMetrics.groupHeaderHeight
    static let padding: CGFloat = OverlayMetrics.padding

    /// Used by the screenshot helper: materials cannot be captured with `cacheDisplay`,
    /// so preview builds draw a solid backdrop instead.
    static let isPreview: Bool = ProcessInfo.processInfo.environment["KAGIPEEK_PREVIEW"] != nil

    static var reduceTransparency: Bool {
        isPreview || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var borderOpacity: Double {
        increaseContrast ? 0.42 : 0.16
    }

    /// Materials do not survive `cacheDisplay`, so screenshot previews use a flat colour.
    @ViewBuilder
    static var surface: some View {
        if isPreview {
            Color(white: 0.12)
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

/// Colours for one panel theme.
struct PanelPalette {
    let isLight: Bool
    let backgroundSolid: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
    let rule: Color
    let selection: Color
    let hover: Color
    let key: Color
    let keyHighlight: Color
    let border: Color
}

extension PanelTheme {
    var palette: PanelPalette {
        switch self {
        case .graphite:
            return PanelPalette(
                isLight: false,
                backgroundSolid: Color(white: 0.10),
                text: .white.opacity(0.92),
                secondaryText: .white.opacity(0.62),
                tertiaryText: .white.opacity(0.32),
                rule: .white.opacity(0.10),
                selection: .white.opacity(0.12),
                hover: .white.opacity(0.06),
                key: .white.opacity(0.72),
                keyHighlight: Color.accentColor,
                border: .white.opacity(0.16)
            )
        case .midnight:
            return PanelPalette(
                isLight: false,
                backgroundSolid: Color(red: 0.03, green: 0.06, blue: 0.13),
                text: .white.opacity(0.94),
                secondaryText: Color(red: 0.64, green: 0.74, blue: 0.90),
                tertiaryText: .white.opacity(0.36),
                rule: .white.opacity(0.12),
                selection: Color(red: 0.24, green: 0.38, blue: 0.62).opacity(0.55),
                hover: .white.opacity(0.07),
                key: Color(red: 0.72, green: 0.82, blue: 0.98),
                keyHighlight: Color(red: 0.45, green: 0.72, blue: 1.0),
                border: .white.opacity(0.18)
            )
        case .paper:
            return PanelPalette(
                isLight: true,
                backgroundSolid: Color(white: 0.98),
                text: Color.black.opacity(0.88),
                secondaryText: Color.black.opacity(0.58),
                tertiaryText: Color.black.opacity(0.34),
                rule: Color.black.opacity(0.12),
                selection: Color.accentColor.opacity(0.14),
                hover: Color.black.opacity(0.05),
                key: Color.black.opacity(0.66),
                keyHighlight: Color.accentColor,
                border: Color.black.opacity(0.12)
            )
        }
    }
}

/// A keycap used across the overlay, the search panel and the main window.
struct KeycapView: View {
    let text: String
    var compact = false
    var foreground: Color = .white
    var background: Color = Color.white.opacity(0.14)
    var border: Color = Color.white.opacity(0.18)

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 11 : 12.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, compact ? 5 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(border, lineWidth: 0.5)
            )
            .foregroundStyle(foreground)
            .fixedSize()
    }
}
