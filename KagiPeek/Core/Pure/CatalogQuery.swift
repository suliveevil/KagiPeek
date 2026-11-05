/// The four knobs `CatalogLoader.load` takes, as one value. Three of its callers want the
/// same "this app's own commands, from cache" query, so they build it from the settings
/// snapshot and change only the field that differs.
nonisolated struct CatalogQuery: Equatable, Sendable {
    var language: AppLanguage
    var includeBuiltIn: Bool
    var showAppleMenu: Bool
    var force: Bool

    init(settings: AppSettingsSnapshot) {
        language = settings.language
        includeBuiltIn = settings.includeBuiltInCatalog
        showAppleMenu = settings.showAppleMenu
        force = false
    }
}
