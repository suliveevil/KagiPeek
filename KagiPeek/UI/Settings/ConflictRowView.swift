import SwiftUI

/// One chord that more than one shortcut claims, with what that actually means.
///
/// The old list answered "two things want this combo" and stopped. The question everybody
/// asks next is "so which one fires?", and an honest answer has three parts: how much the
/// clash bites, who the layers say wins, and — when that is only a guess — an offer to go
/// and find out for real.
struct ConflictRowView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @EnvironmentObject private var localization: Localization

    let conflict: BindingConflict
    let style: KeyFormatter.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            verdict
            members
            liveTest
        }
        .padding(.vertical, 4)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 7) {
            KeycapView(text: KeyFormatter.render(chord, style: style), compact: true)
            CategoryBadge(category: conflict.category, localization: localization)
            Spacer(minLength: 0)
        }
    }

    private var chord: KeyChord {
        conflict.items.first?.chord ?? .empty
    }

    /// Why this clash is worth looking at at all.
    ///
    /// The winner line is only shown when the stack actually decided something. For a menu
    /// item blocked by one always-on source there is nothing to weigh — that source always
    /// wins — and printing "macOS most likely wins, but an event tap could take the key"
    /// there contradicted the badge right above it.
    private var verdict: some View {
        VStack(alignment: .leading, spacing: 2) {
            if conflict.category.isAlwaysOnPair {
                Text(verdictText)
                    .font(.caption)
            }
            Text(localization.text(conflict.category.explanationKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verdictText: String {
        guard let verdict = conflict.verdict else {
            return localization.text(.conflictVerdictUnknown)
        }
        switch verdict {
        case .winner(let itemID, let layer):
            guard let item = conflict.items.first(where: { $0.id == itemID }) else {
                return localization.text(.conflictVerdictUnknown)
            }
            let name = engine.displayOwner(of: item)
            return localization.format(.conflictVerdictWinnerFormat, name)
                + " " + localization.text(layer.explanationKey)
        case .tied:
            return localization.text(.conflictVerdictTied)
        case .menuOrder:
            return localization.text(.conflictVerdictMenuOrder)
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(conflict.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    LayerBadge(layer: ShortcutLayer.classify(item), localization: localization)
                    Text("\(engine.displayOwner(of: item)) — \(item.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Live test

    @ViewBuilder
    private var liveTest: some View {
        switch engine.liveTestState {
        case .listening(let remaining):
            if isCurrentTest {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(localization.format(.testListeningFormat, remaining))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(localization.text(.testCancel)) { engine.cancelLiveTest() }
                        .controlSize(.small)
                }
            }
        case .finished:
            if let verdict = engine.liveTestVerdict(for: chord) {
                LiveTestCallout(verdict: verdict)
            } else {
                startButton
            }
        case .unavailable(let reason):
            if isCurrentTest {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            startButton
        }
    }

    /// Whether the tester's current state belongs to this row's combo.
    private var isCurrentTest: Bool {
        engine.liveTestChord == chord
    }

    private var startButton: some View {
        Button(localization.text(.testStart)) {
            engine.startLiveTest(for: chord)
        }
        .controlSize(.small)
    }
}

/// How much a clash bites, as a coloured pill.
struct CategoryBadge: View {
    let category: ConflictCategory
    let localization: Localization

    var body: some View {
        Text(localization.text(category.labelKey))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(stroke, lineWidth: 0.5))
    }

    private var fill: Color {
        switch category {
        case .menuOrder: return Color.secondary.opacity(0.12)
        case .systemShadow, .toolShadow: return Color.orange.opacity(0.16)
        case .toolSelfOverlap, .systemVsSystem, .systemVsTool, .toolVsTool: return Color.red.opacity(0.16)
        }
    }

    private var stroke: Color {
        switch category {
        case .menuOrder: return Color.secondary.opacity(0.3)
        case .systemShadow, .toolShadow: return Color.orange.opacity(0.45)
        case .toolSelfOverlap, .systemVsSystem, .systemVsTool, .toolVsTool: return Color.red.opacity(0.45)
        }
    }
}

/// Where in the keyboard stack a shortcut is hooked.
struct LayerBadge: View {
    let layer: ShortcutLayer
    let localization: Localization

    var body: some View {
        Text(localization.text(layer.badgeKey))
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.secondary.opacity(0.14)))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// What a live test actually observed, with the tone it deserves.
struct LiveTestCallout: View {
    @EnvironmentObject private var localization: Localization
    let verdict: LiveTestVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(headline)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Text(localization.text(verdict.toneKey))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var headline: String {
        guard let argument = verdict.headlineArgument else {
            return localization.text(verdict.headlineKey)
        }
        return localization.format(verdict.headlineKey, argument)
    }

    private var summary: String {
        if let second = verdict.summarySecondArgument, let first = verdict.summaryArgument {
            return localization.format(verdict.summaryKey, first, second)
        }
        if let argument = verdict.summaryArgument {
            return localization.format(verdict.summaryKey, argument)
        }
        return localization.text(verdict.summaryKey)
    }

    private var tint: Color {
        switch verdict.tone {
        case .confirmed: return .green
        case .informative: return .orange
        case .inconclusive: return .secondary
        }
    }

    private var iconName: String {
        switch verdict.tone {
        case .confirmed: return "checkmark.seal"
        case .informative: return "info.circle"
        case .inconclusive: return "eye.slash"
        }
    }
}
