import Combine
import Foundation

/// Resolved UI language, mirroring `AppSettingsSnapshot.language`.
@MainActor
final class Localization: ObservableObject {
    @Published private(set) var language: AppLanguage = .english

    func update(preference: AppLanguage) {
        language = L10n.resolvedLanguage(preference)
    }

    func text(_ key: L10nKey) -> String {
        L10n.string(key, language: language)
    }

    func format(_ key: L10nKey, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
