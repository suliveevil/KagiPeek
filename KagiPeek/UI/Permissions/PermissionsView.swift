import AppKit
import SwiftUI

/// First-run / on-demand permission guide: one horizontal card per permission —
/// title, reasons, and the grant action in a single strip — with a live status that
/// updates while System Settings is open and a Continue button that waits for the
/// required grant.
struct PermissionsView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @EnvironmentObject private var localization: Localization
    @ObservedObject var permissions: AppPermissions

    let onQuit: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            header
            cards
            footer
        }
        .padding(20)
        .frame(width: 740, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: permissions.state) { _, _ in
            engine.bringPermissionsWindowForward()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(localization.text(.permissionsTitle))
                .font(.system(size: 20, weight: .semibold))
            Text(localization.text(.permissionsSubtitle))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Label(localization.text(.permissionsPrivacy), systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var cards: some View {
        VStack(spacing: 12) {
            ForEach(permissions.all) { permission in
                PermissionCardView(permission: permission)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(localization.text(.permissionQuit), action: onQuit)
                .buttonStyle(.bordered)
            Spacer()
            Button(localization.text(.permissionContinue)) {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!permissions.isReady)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionCardView: View {
    @ObservedObject var permission: AppPermission
    @EnvironmentObject private var localization: Localization

    private var tint: Color {
        switch permission.iconColorName {
        case "blue": return .blue
        case "orange": return .orange
        case "red": return .red
        default: return .accentColor
        }
    }

    /// The card's reasons as one flowing line; two lines of it fit the strip, and the
    /// full text rides along as a tooltip so nothing is lost to the tighter layout.
    private var details: String {
        permission.detailKeys.map { localization.text($0) }.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: permission.iconName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(localization.text(permission.titleKey))
                        .font(.system(size: 13, weight: .semibold))
                    Text(localization.text(permission.isRequired ? .permissionRequiredBadge : .permissionOptionalBadge))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(permission.isRequired ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.12)))
                        .foregroundStyle(permission.isRequired ? .orange : .secondary)
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(details)
            }

            Spacer(minLength: 12)

            if permission.isGranted {
                Label(localization.text(.permissionGrantedDone), systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 10) {
                    if permission.id == .accessibility {
                        DragAppIcon(side: 26)
                    }
                    Button(localization.text(.permissionGrant)) {
                        permission.performRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    // Two grants of the same kind in two colours made the orange one read as
                    // "riskier". The colour stays on the icon and the badge, where it groups.
                    .tint(.accentColor)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                .decorative()
        )
    }
}
