import AppKit
import SwiftUI

/// First-run / on-demand permission guide, modelled after Thaw's permission cards:
/// one card per permission with the concrete reasons, a live status that updates while
/// System Settings is open, and a Continue button that waits for the required grant.
struct PermissionsView: View {
    @EnvironmentObject private var engine: ShortcutEngine
    @EnvironmentObject private var localization: Localization
    @ObservedObject var permissions: AppPermissions

    let onQuit: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            header
            cards
            footer
        }
        .padding(24)
        .frame(width: 740, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: permissions.state) { _, _ in
            engine.bringPermissionsWindowForward()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(localization.text(.permissionsTitle))
                .font(.system(size: 22, weight: .semibold))
            Text(localization.text(.permissionsSubtitle))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Label(localization.text(.permissionsPrivacy), systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 14) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: permission.iconName)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(localization.text(permission.titleKey))
                    .font(.headline)
                Spacer(minLength: 0)
                Text(localization.text(permission.isRequired ? .permissionRequiredBadge : .permissionOptionalBadge))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(permission.isRequired ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.12)))
                    .foregroundStyle(permission.isRequired ? .orange : .secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(permission.detailKeys, id: \.self) { key in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 3))
                            .padding(.top, 5)
                            .foregroundStyle(.tertiary)
                        Text(localization.text(key))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if permission.isGranted {
                Label(localization.text(.permissionGrantedDone), systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            } else {
                Button(localization.text(.permissionGrant)) {
                    permission.performRequest()
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .frame(maxWidth: .infinity)

                if permission.id == .accessibility {
                    HStack(spacing: 8) {
                        DragAppIcon()
                        Text(localization.text(.permissionDragHint))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                .decorative()
        )
    }
}

/// Real drag source: drop the app into the Accessibility list in System Settings.
private struct DragAppIcon: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 30, height: 30)
            .onDrag {
                NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
            }
            .help("Drag into System Settings")
    }
}
