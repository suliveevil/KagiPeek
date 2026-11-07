import AppKit
import SwiftUI

/// Text sizes, one step per macOS system text style. Views must use these tokens instead
/// of raw point sizes: the panel is dense enough that a single stray 9.5 or 11.5 turns
/// into a visible rhythm break, and macOS never renders text below 10 pt.
enum TypeScale {
    /// `.title3` — empty-state headlines.
    static let display: CGFloat = 15
    /// `.body` — menu titles, row labels, search field.
    static let body: CGFloat = 13
    /// `.callout` — group headers and card titles.
    static let callout: CGFloat = 12
    /// `.subheadline` — hints, keycaps, status badges.
    static let caption: CGFloat = 11
    /// `.footnote` — the floor: counts, layer tags, compact chrome.
    static let micro: CGFloat = 10
}

/// SF Symbol sizes. Symbols are sized by the glyph they draw, not by the text scale,
/// so they stay in their own small table.
enum IconScale {
    /// Empty-state and permission-card symbols.
    static let large: CGFloat = 20
    /// The panel's own empty-state illustration.
    static let hero: CGFloat = 22
}

enum Theme {
    /// Corner radii, four steps and no more: the panel window, the cards inside it,
    /// the compact controls in a row, and the badges that sit inside those controls.
    /// Before this there were nine: 3, 4, 5, 6, 7, 8, 10, 12, plus the 1.5 indicator
    /// sliver, which is a hairline rather than a container and stays off the ladder.
    static let radiusWindow: CGFloat = 12
    static let radiusCard: CGFloat = 8
    static let radiusControl: CGFloat = 6
    static let radiusTag: CGFloat = 4
    /// The panel window's radius. Kept as the old name so call sites read as a window.
    static let cornerRadius: CGFloat = radiusWindow
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
    static let isPreview: Bool = ProcessInfo.processInfo.environment["KANAME_PREVIEW"] != nil

    static var reduceTransparency: Bool {
        isPreview || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Semantic accents drawn on top of a palette. System colors so they track the
    /// system appearance; each use site keeps its own opacity, tuned to its context.
    /// (Previously these were bare `.yellow`/`.orange` literals scattered across views,
    /// which a palette change could never reach.)
    static let favoriteStar = Color.yellow
    static let warning = Color.orange

    /// The leading execution-status dot. Three semantic colours, deliberately kept apart
    /// from the trailing conflict badge: the dot answers "can this row run at all", the
    /// badge answers "do two shortcuts collide". A healthy row can still have a conflict.
    /// System colours so both palettes keep the same contrast; orange stands in for the
    /// amber step because pure yellow washes out on the paper palette.
    static let statusReady = Color(nsColor: .systemGreen)
    static let statusDegraded = Color(nsColor: .systemOrange)
    static let statusBlocked = Color(nsColor: .systemRed)
    /// Diameter of the leading status dot. Its slot is always reserved, even when the
    /// self-check is off, so switching the setting never reflows the command name.
    static let statusDotSize: CGFloat = 6

    /// Accent-emphasis ladder for state the accent color already carries: the completed
    /// flash is strongest, a pressed row sits under it, the selection gutter is quietest.
    static let completedRowEmphasis: Double = 0.38
    static let pressedRowEmphasis: Double = 0.28
    static let selectedGutterEmphasis: Double = 0.18
    static let tickedChipStroke: Double = 0.55
    static let tickedChipFillLight: Double = 0.16
    static let tickedChipFillDark: Double = 0.26
    /// Shift-hint glyphs: a quiet badge, so 36 labels do not turn the chord column into a
    /// wall of accent colour.
    static let hintBadgeFillLight: Double = 0.14
    static let hintBadgeFillDark: Double = 0.24

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
    /// Red used for titles of actions Kaname will never run. The dark theme needs a
    /// brighter red than `systemRed` to stay legible on graphite.
    let restrictedText: Color
    let secondaryText: Color
    let tertiaryText: Color
    /// A disabled row's text. Kept above 4.5:1 and paired with an explicit unavailable
    /// marker in the row: dimming the whole row to 48 % opacity dropped it to ~2:1 and
    /// left colour as the only signal.
    let disabledText: Color
    let rule: Color
    let selection: Color
    let hover: Color
    /// Hover fill for a control, one step louder than the card hover: at 6 % the pointer
    /// feedback on the panel's icon buttons was invisible on a dark panel.
    let controlHover: Color
    let key: Color
    let keyHighlight: Color
    let border: Color
}

extension PanelTheme {
    /// The palette after the setting meets the window's appearance: an explicit choice wins,
    /// `system` follows what the window reports.
    func palette(isDarkSystem: Bool) -> PanelPalette {
        switch self {
        case .light: return Self.lightPalette
        case .dark: return Self.darkPalette
        case .system: return isDarkSystem ? Self.darkPalette : Self.lightPalette
        }
    }

    /// Graphite, kept as the dark palette.
    private static var darkPalette: PanelPalette {
        PanelPalette(
            isLight: false,
            backgroundSolid: Color(white: 0.10),
            text: .white.opacity(0.92),
            restrictedText: Color(.sRGB, red: 1.0, green: 0.45, blue: 0.45, opacity: 1.0),
            secondaryText: .white.opacity(0.62),
            // 0.32 measured ~2.9:1 on the 10 % grey surface, below the 3:1 minimum for
            // auxiliary text. 0.45 measures ~4.5:1 and still reads as clearly quieter than
            // secondaryText at 0.62.
            tertiaryText: .white.opacity(0.45),
            disabledText: .white.opacity(0.55),
            rule: .white.opacity(0.10),
            selection: .white.opacity(0.12),
            hover: .white.opacity(0.06),
            controlHover: .white.opacity(0.13),
            key: .white.opacity(0.72),
            keyHighlight: Color.accentColor,
            border: .white.opacity(0.16)
        )
    }

    /// Paper, kept as the light palette.
    private static var lightPalette: PanelPalette {
        PanelPalette(
            isLight: true,
            backgroundSolid: Color(white: 0.98),
            text: Color.black.opacity(0.88),
            restrictedText: Color(nsColor: .systemRed),
            secondaryText: Color.black.opacity(0.58),
            // 0.34 measured below 3:1 on the 98 % paper surface. 0.55 measures ~4.7:1 and
            // keeps the same relationship to secondaryText at 0.58.
            tertiaryText: Color.black.opacity(0.55),
            disabledText: Color.black.opacity(0.60),
            rule: Color.black.opacity(0.12),
            selection: Color.accentColor.opacity(0.14),
            hover: Color.black.opacity(0.05),
            controlHover: Color.black.opacity(0.08),
            key: Color.black.opacity(0.66),
            keyHighlight: Color.accentColor,
            border: Color.black.opacity(0.12)
        )
    }
}

/// A keycap used across the overlay, the search panel and the main window.
struct KeycapView: View {
    let text: String
    var compact = false
    var foreground: Color = .primary
    var background: Color = Color.primary.opacity(0.10)
    var border: Color = Color.primary.opacity(0.18)

    var body: some View {
        Text(text)
            .font(.system(size: compact ? TypeScale.caption : TypeScale.callout, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, compact ? 4 : 8)
            .padding(.vertical, compact ? 2 : 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .stroke(border, lineWidth: 0.5)
            )
            .foregroundStyle(foreground)
            .fixedSize()
    }
}
