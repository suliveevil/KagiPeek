import SwiftUI

/// The direct answer to a query that spells out a key combo.
///
/// The results list below it only ever shows shortcuts, and the conflict list only shows
/// clashes. A combo with a single owner appears in neither, so asking "who has ⌘⇧4?" used
/// to come back as empty space. This answers it in words: who claims it, or that it is free.
struct ComboLookupBanner: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @EnvironmentObject private var localization: Localization

    let answer: ComboLookup.Answer
    let palette: PanelPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: answer.items.isEmpty ? "checkmark.circle" : "keyboard")
                    .font(.system(size: 10))
                    .foregroundStyle(answer.items.isEmpty ? palette.tertiaryText : palette.keyHighlight)
                Text(localization.text(.comboLookupTitle))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.tertiaryText)
                Spacer(minLength: 0)
            }
            Text(headline)
                .font(.system(size: 12))
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)

            // Named only when the answer is short enough to read at a glance; a long list
            // belongs in the results below, not in a banner.
            if !distinctItems.isEmpty, distinctItems.count <= 3 {
                ForEach(distinctItems) { item in
                    Text("• \(engine.displayOwner(of: item)) — \(engine.displayName(of: item))")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.selection)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// One source was reported twice for the same chord, so the banner printed the same line
    /// twice. Keyed by owner and title, order preserved.
    private var distinctItems: [BindingItem] {
        var seen: Set<String> = []
        return answer.items.filter { item in
            seen.insert("\(engine.displayOwner(of: item))\u{1F}\(item.title)").inserted
        }
    }

    private var headline: String {
        switch answer {
        case .free:
            return localization.text(.comboLookupFree)
        case .claimed(_, let owners):
            if owners.count == 1, let only = owners.first {
                return localization.format(.comboLookupOwnerFormat, engine.displayOwner(of: only))
            }
            // Count what is printed: the same source is sometimes reported twice for one
            // chord, and a headline of 3 over a list of 2 reads like a bug.
            return localization.format(.comboLookupOwnersFormat, distinctItems.count)
        }
    }
}
