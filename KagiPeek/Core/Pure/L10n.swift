import Foundation

/// User interface language.
enum AppLanguage: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case english
    case chinese

    var titleKey: L10nKey {
        switch self {
        case .system: return .languageSystem
        case .english: return .languageEnglish
        case .chinese: return .languageChinese
        }
    }
}

/// Every user-visible string in the app.
enum L10nKey: String, CaseIterable, Sendable {
    // Application / menu bar
    case appName, menuSearch, menuPanel, menuSettings, menuPause, menuResume, menuQuit
    case statusReady, statusPaused, statusNoPermission, statusScanning

    // Permissions
    case permissionTitle, permissionAccessibility, permissionAccessibilityHint
    case permissionInputMonitoring, permissionInputMonitoringHint
    case permissionGranted, permissionMissing, permissionRequest, permissionOpenSettings
    case permissionRecheck, permissionSecureInput, permissionDragHint
    case permissionsTitle, permissionsSubtitle, permissionsPrivacy
    case permissionWizard, permissionGrant, permissionGrantedDone, permissionContinue, permissionQuit
    case panelFavoritesFilter, panelPin, panelUnpin, panelCopyShortcut, panelSettings, panelNoFavorites
    case panelClose, panelPreviousPage, panelNextPage
    case panelModifierFilterHint
    case searchResultCount, searchResultCountOne, searchClearHint
    case searchSubtitle
    case appearanceTheme, themeGraphite, themeMidnight, themePaper
    case appearanceKeyPosition, keyPositionLeft, keyPositionRight
    case favoritesPinTop, favoritesFilterable
    case generalIgnoredCommands, generalIgnoredCommandsHint
    case ignoredAddCommand, ignoredSheetTitle, ignoredScopeGlobal, ignoredScopeApp
    case ignoredAppPicker, ignoredCommandTitle, ignoredCommandPlaceholder, ignoredSuggestionsHint
    case ignoredAdd, ignoredCancel, ignoredEmpty
    case generalAddApp, generalRemoveApp, generalNoExcludedApps
    case permissionRequiredBadge, permissionOptionalBadge
    case permissionAccessibilityDetail1, permissionAccessibilityDetail2, permissionAccessibilityDetail3
    case permissionInputMonitoringDetail1, permissionInputMonitoringDetail2
    case permissionGuideDrag, permissionGuideStaleHint
    case permissionGuideGranted, permissionGuideClose

    // Trigger
    case triggerTitle, triggerMode, triggerHoldModifiers, triggerDoubleTap, triggerHotkey, triggerOff
    case triggerHoldDelay, triggerDoubleTapWindow, triggerPanelHotkey, triggerSearchHotkey
    case triggerSwitchHotkey, triggerRecording, triggerRecordingHint

    // Appearance
    case appearanceTitle, appearanceKeyStyle, appearanceStyleSymbols, appearanceStyleWords
    case appearanceColumns, appearanceMaxItems, appearanceMaxDescription, appearanceShowDisabled
    case appearanceLanguage, appearancePlacement, appearanceFixedWidth, appearanceFixedHeight
    case placementCoverWindow, placementFixedSize, placementFillScreen, placementBesideWindow
    case languageSystem, languageEnglish, languageChinese

    // Ranking
    case rankingTitle, rankingMode, rankingModeHint
    case statisticsTitle
    case sortSmart, sortFrequencyDesc, sortKeyOrder, sortAlphabetical
    case rankingUsageSummary, rankingReset, rankingHUD, rankingIncludeBuiltIn
    case rankingDefaults

    // General
    case generalTitle, generalLaunchAtLogin, generalExcludedApps, generalExcludedAppsHint
    case generalShowAppleMenu, generalShowAppleMenuHint
    case generalShowDockIcon, generalShowDockIconHint

    // App menu (built in AppDelegate)
    case menuEdit, menuCut, menuCopy, menuPaste, menuSelectAll, menuSearchShortcuts

    // Statistics
    case statsSection, statsByApp, statsGenericApp, statsNoData, statsOpenDataFolder, statsShortcuts
    case statsUnknownCommand

    // Main window
    case settingsTitle

    // Row actions
    case rowActionSection, rowActionExecute, rowActionCopy, rowActionHint
    case panelActionHint, panelActionHintSearch, panelActionHintCompact

    // Overlay
    case overlayNoCandidates, overlayScanning, overlayPageFormat, overlayUnavailableBadge
    case overlayBuiltInBadge
    case scanPermissionDenied, scanFallbackHint
    case overlayConflictBadge, overlayConflictHint, overlayHint, panelCopied, panelCopyFailed, panelNothingToCopy, panelIdleHint
    case searchScopeLoading, searchBuiltInNotice, conflictScanFailed, conflictScanPartialFormat
    case rankingResetConfirmTitle, rankingResetConfirmMessage
    case rankingDefaultsConfirmTitle, rankingDefaultsConfirmMessage

    // HUD
    case hudExecuted

    // Search panel
    case searchTitle, searchSubtitleScoped, searchPlaceholder, searchHintRun, searchNoResults
    case searchBackToPanel

    // Conflicts
    case conflictTitle, conflictListTitle, conflictNone, conflictFoundFormat

    // Conflict layers
    case layerDriver, layerEventTap, layerSystem, layerGlobalHotkey, layerGlobal, layerMenuItem
    case layerDriverExplanation, layerEventTapExplanation, layerSystemExplanation
    case layerGlobalHotkeyExplanation, layerGlobalExplanation, layerMenuItemExplanation

    // Conflict categories
    case conflictCategoryMenuOrder, conflictCategorySystemShadow, conflictCategoryToolShadow
    case conflictCategoryToolSelfOverlap
    case conflictCategorySystemVsSystem, conflictCategorySystemVsTool, conflictCategoryToolVsTool
    case conflictCategoryMenuOrderExplanation, conflictCategorySystemShadowExplanation
    case conflictCategoryToolShadowExplanation, conflictCategoryToolSelfOverlapExplanation
    case conflictCategorySystemVsSystemExplanation
    case conflictCategorySystemVsToolExplanation, conflictCategoryToolVsToolExplanation

    // Conflict verdicts
    case conflictVerdictWinnerFormat, conflictVerdictTied, conflictVerdictMenuOrder
    case conflictVerdictUnknown, conflictVerdictTitle, conflictLayerPrefix

    // Conflict filters
    case conflictType, conflictTypeAllFormat, conflictTypeEmpty
    case conflictOwner, conflictOwnerAll, conflictOwnerGlobal
    case conflictRescan, conflictScanning, conflictNeverScanned, conflictScannedAtFormat
    case conflictShowMoreFormat

    // Third-party config tools
    case configToolsTitle, configToolsSubtitle, configToolsToggle, configToolsRescan
    case configToolsNoneFound, configToolCountFormat, configToolUnreadable
    case configToolsPrivacyNote

    // Combo lookup
    case comboLookupTitle, comboLookupFree, comboLookupOwnerFormat, comboLookupOwnersFormat
    case comboLookupHint

    // Diagnostics
    case diagnosticsTitle, diagnosticsEnable, diagnosticsEnableHint
    case diagnosticsVerbose, diagnosticsVerboseHint
    case diagnosticsPath, diagnosticsOpenFolder, diagnosticsExport
    case diagnosticsPrivacyNote, diagnosticsExportDone, diagnosticsExportFailed

    // Live shortcut test
    case testTitle, testStart, testCancel, testListeningFormat, testHint
    case testUnavailableNoPermission, testUnavailableNoTap
    case testVerdictSwallowedByTap, testVerdictSwallowedByTapOne
    case testVerdictReachedApp, testVerdictAlreadyFrontmost
    case testVerdictUnregisteredApp, testVerdictSurvivedUnclaimed
    case testVerdictRewritten, testVerdictNothingSeen
    case testToneConfirmed, testToneInformative, testToneInconclusive
    case testSummarySwallowedNone, testSummarySwallowedOne, testSummarySwallowedMany
    case testSummaryReachedApp, testSummaryAlreadyFrontmost, testSummaryUnregisteredApp
    case testSummarySurvived, testSummarySurvivedRuledOut
    case testSummaryRewritten, testSummaryNothingSeen

    // About
    case aboutTitle, aboutVersion, aboutRepository, aboutLicense, aboutBuild, aboutSystem, aboutDataFolder, aboutDiagnostics, aboutMenuItems
    case aboutExportDiagnostics, aboutDiagnosticsHint

    // Groups used by the built-in fallback catalog
    case groupSystem, groupFinder, groupTextEditing, groupScreenshot, groupBrowser, groupSystemHotkeys

    // Search scope and export
    case frontmostApp, exportMarkdown

    // Update check
    case updateCheck, updateAvailable, updateNone, updateFailed, updateOpen

    // Errors
    case errorEventTap, errorNoAccessibility
}

enum L10n {
    /// Resolves `.system` to a concrete language using the user's preferred languages.
    static func resolvedLanguage(
        _ preference: AppLanguage,
        preferred: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch preference {
        case .english: return .english
        case .chinese: return .chinese
        case .system:
            let first = preferred.first?.lowercased() ?? "en"
            return first.hasPrefix("zh") ? .chinese : .english
        }
    }

    static func string(_ key: L10nKey, language: AppLanguage) -> String {
        guard let entry = table[key] else { return key.rawValue }
        return language == .chinese ? entry.zh : entry.en
    }

    /// Format helper; falls back to the format string when arguments do not fit.
    static func format(_ key: L10nKey, language: AppLanguage, _ arguments: CVarArg...) -> String {
        String(format: string(key, language: language), arguments: arguments)
    }

    static let availableLanguages: [AppLanguage] = [.system, .english, .chinese]

    // MARK: - Table

    private typealias Entry = (en: String, zh: String)

    private static let table: [L10nKey: Entry] = [
        .appName: ("KagiPeek", "KagiPeek"),
        .menuSearch: ("Search Shortcuts…", "搜索快捷键…"),
        .menuPanel: ("Shortcut Panel", "快捷键面板"),
        .menuSettings: ("Settings…", "设置…"),
        .menuPause: ("Pause Hints", "暂停提示"),
        .menuResume: ("Resume Hints", "恢复提示"),
        .menuQuit: ("Quit KagiPeek", "退出 KagiPeek"),

        .statusReady: ("Listening", "监听中"),
        .statusPaused: ("Paused", "已暂停"),
        .statusNoPermission: ("Permission required", "需要授权"),
        .statusScanning: ("Scanning menus…", "正在读取菜单…"),

        .permissionTitle: ("Permissions", "权限"),
        .permissionAccessibility: ("Accessibility", "辅助功能"),
        .permissionAccessibilityHint: (
            "Required to read the frontmost app's menu bar and to listen for keys.",
            "用于读取前台 App 的菜单栏并监听全局按键。"
        ),
        .permissionInputMonitoring: ("Input Monitoring", "输入监控"),
        .permissionInputMonitoringHint: (
            "Optional fallback if key events are not delivered with Accessibility alone.",
            "可选。若仅授予辅助功能仍收不到按键事件，则需要此项。"
        ),
        .permissionGranted: ("Granted", "已授权"),
        .permissionMissing: ("Not granted", "未授权"),
        .permissionRequest: ("Request", "请求授权"),
        .permissionOpenSettings: ("Open System Settings", "打开系统设置"),
        .permissionRecheck: ("Re-check", "重新检查"),
        .permissionsTitle: ("Enable Permissions", "启用权限"),
        .permissionsSubtitle: (
            "KagiPeek needs these permissions to read the frontmost app's menu bar and to listen for shortcuts.",
            "KagiPeek 需要以下权限来读取前台 App 的菜单栏并监听快捷键。"
        ),
        .permissionsPrivacy: (
            "Everything stays on your Mac. Nothing is uploaded.",
            "所有数据只在本机处理，不会上传。"
        ),
        .panelFavoritesFilter: ("Favorites", "只看收藏"),
        .panelPin: ("Pin", "收藏"),
        .panelUnpin: ("Unpin", "取消收藏"),
        .panelCopyShortcut: ("Copy Shortcut", "复制快捷键"),
        .panelSettings: ("Settings…", "设置…"),
        .panelClose: ("Close", "关闭"),
        .panelPreviousPage: ("Previous page", "上一页"),
        .panelNextPage: ("Next page", "下一页"),
        .panelModifierFilterHint: (
            "Tick modifiers to keep only the shortcuts that carry them (add several to require all of them)",
            "勾选修饰键后只保留包含它们的快捷键（可多选，需同时满足）"
        ),
        .panelNoFavorites: (
            "No pinned shortcuts yet. Hover a row and click the star.",
            "还没有收藏的快捷键。悬停某一行，点击右侧星标即可。"
        ),
        .appearanceKeyPosition: ("Key position", "键位位置"),
        .keyPositionLeft: ("Keys left", "键位在左"),
        .keyPositionRight: ("Keys right", "键位在右"),
        .favoritesPinTop: ("Pin favourites to top", "收藏置顶"),
        .favoritesFilterable: ("Filters can hide favourites", "收藏可被搜索/过滤隐藏"),
        .appearanceTheme: ("Panel theme", "面板主题"),
        .themeGraphite: ("Graphite", "石墨"),
        .themeMidnight: ("Midnight", "午夜蓝"),
        .themePaper: ("Paper", "纸张"),
        .generalIgnoredCommands: ("Ignored commands", "忽略的命令"),
        .generalIgnoredCommandsHint: (
            "Commands listed here stay out of the panel and the search. A command can be hidden everywhere or only inside one app — “Reload Page” in a browser is not the same command as “Reload Page” in an editor.",
            "这里的命令不会出现在面板和搜索里。可以全局隐藏，也可以只在某个 App 内隐藏——浏览器里的“重新载入”和编辑器里的“重新载入”不是同一条命令。"
        ),
        .ignoredAddCommand: ("Add command…", "添加命令…"),
        .ignoredSheetTitle: ("Ignore a command", "忽略命令"),
        .ignoredScopeGlobal: ("All apps", "所有 App"),
        .ignoredScopeApp: ("Only this app", "仅指定 App"),
        .ignoredAppPicker: ("App", "应用"),
        .ignoredCommandTitle: ("Command", "命令"),
        .ignoredCommandPlaceholder: ("Command title, e.g. Reload Page", "命令名称，例如：重新载入页面"),
        .ignoredSuggestionsHint: (
            "Pick a command from the list, or type the title exactly. Matching ignores case.",
            "从列表中选择，或精确输入名称。匹配不区分大小写。"
        ),
        .ignoredAdd: ("Add", "添加"),
        .ignoredCancel: ("Cancel", "取消"),
        .ignoredEmpty: ("No ignored commands.", "尚未忽略任何命令。"),
        .generalAddApp: ("Add app…", "添加 App…"),
        .generalRemoveApp: ("Remove", "移除"),
        .generalNoExcludedApps: (
            "No excluded apps — the panel appears in every app.",
            "没有排除的 App——所有 App 都会弹出面板。"
        ),
        .searchSubtitleScoped: ("This app's shortcuts", "这个 App 的快捷键"),
        .searchSubtitle: ("Search every shortcut", "搜索所有快捷键"),
        .searchResultCount: ("%d results", "%d 条结果"),
        .searchResultCountOne: ("1 result", "1 条结果"),
        .searchClearHint: ("Clear", "清除"),
        .permissionWizard: ("Permission guide", "权限向导"),
        .permissionGrant: ("Grant Permission", "授权"),
        .permissionGrantedDone: ("Permission granted", "已授权"),
        .permissionContinue: ("Continue", "继续"),
        .permissionQuit: ("Quit", "退出"),
        .permissionRequiredBadge: ("Required", "必需"),
        .permissionOptionalBadge: ("Optional", "可选"),
        .permissionAccessibilityDetail1: (
            "Read the frontmost app's menu bar and its shortcuts.",
            "读取前台 App 的菜单栏及其快捷键。"
        ),
        .permissionAccessibilityDetail2: (
            "Listen for the global hotkeys and the shortcuts you press.",
            "监听全局热键和你按下的快捷键。"
        ),
        .permissionAccessibilityDetail3: (
            "Replay a shortcut into the front app when you run a row (the run key, ↩ by default).",
            "执行某一行时把该快捷键回放给前台 App（默认按回车执行）。"
        ),
        .permissionInputMonitoringDetail1: (
            "Fallback key listening if Accessibility alone does not deliver key events.",
            "当仅授予辅助功能仍收不到按键事件时作为兜底。"
        ),
        .permissionInputMonitoringDetail2: (
            "Only needed on some macOS versions and setups.",
            "只有部分 macOS 版本或环境才需要。"
        ),
        .permissionDragHint: (
            "Or drag the KagiPeek icon from here into the list in System Settings.",
            "也可以把这里的 KagiPeek 图标直接拖进系统设置的列表里。"
        ),
        .permissionGuideDrag: (
            "Drag KagiPeek into the list above",
            "把上面的 KagiPeek 图标拖进列表"
        ),
        .permissionGuideStaleHint: (
            "Already listed but the switch won't stick? Remove it with −, drop the icon in again, and switch it on.",
            "若列表里已有 KagiPeek 但开关无效：先用 − 移除，再拖入并打开。"
        ),
        .permissionGuideGranted: (
            "Permission granted",
            "已授权"
        ),
        .permissionGuideClose: (
            "Close the guide",
            "关闭引导"
        ),
        .permissionSecureInput: (
            "Secure keyboard entry is active — hints are paused.",
            "当前处于安全键盘输入状态，提示已暂停。"
        ),

        .triggerTitle: ("Trigger", "触发"),
        .triggerMode: ("Trigger mode", "触发方式"),
        .triggerHoldModifiers: ("Hold modifiers", "按住修饰键停顿"),
        .triggerDoubleTap: ("Double-tap ⌘", "连按两次 ⌘"),
        .triggerHotkey: ("Global hotkey", "全局热键"),
        .triggerOff: ("Off", "关闭"),
        .triggerHoldDelay: ("Hold delay", "停顿延时"),
        .triggerDoubleTapWindow: ("Double-tap window", "双击间隔"),
        .triggerPanelHotkey: ("Panel hotkey", "面板热键"),
        .triggerSearchHotkey: ("Search hotkey", "搜索热键"),
        .triggerSwitchHotkey: ("Switch panel/search", "切换面板/搜索"),
        .triggerRecording: ("Record", "录制"),
        .triggerRecordingHint: ("Press a new key combination…", "请按下新的组合键…"),

        .appearanceTitle: ("Appearance", "外观"),
        .appearanceKeyStyle: ("Key style", "按键显示"),
        .appearanceStyleSymbols: ("Symbols (⌘)", "符号（⌘）"),
        .appearanceStyleWords: ("Words (command)", "文字（command）"),
        .appearanceColumns: ("Columns", "列数"),
        .appearanceMaxItems: ("Max rows per page", "每页最大行数"),
        .appearanceMaxDescription: ("Max description length", "描述最大长度"),
        .appearanceShowDisabled: ("Show unavailable items", "显示当前不可用的菜单项"),
        .appearancePlacement: ("Panel placement", "面板位置"),
        .placementCoverWindow: ("Cover the front window", "覆盖前台窗口"),
        .placementFixedSize: ("Fixed size", "固定长宽"),
        .placementFillScreen: ("Fill the screen", "铺满屏幕"),
        .placementBesideWindow: ("Beside the front window", "前台窗口旁边"),
        .appearanceFixedWidth: ("Fixed width", "固定宽度"),
        .appearanceFixedHeight: ("Fixed height", "固定高度"),
        .appearanceLanguage: ("Language", "语言"),
        .languageSystem: ("System", "跟随系统"),
        .languageEnglish: ("English", "English"),
        .languageChinese: ("Chinese", "中文"),

        .rankingTitle: ("Ranking", "排序"),
        .statisticsTitle: ("Statistics", "统计"),
        .rankingMode: ("Sort order", "排序方式"),
        .rankingModeHint: (
            "Decides the order of both lists on this page. The panel is always in key order; the search palette orders by match.",
            "决定本页两个列表的顺序。面板始终按按键顺序排列，搜索面板按匹配度排序。"
        ),
        .sortSmart: ("Smart order", "智能排序"),
        .sortFrequencyDesc: ("Most used first", "高频优先"),
        .sortKeyOrder: ("Key order", "按键顺序"),
        .sortAlphabetical: ("Alphabetical", "字母顺序"),
        .rankingUsageSummary: (
            "%d shortcuts tracked, %d presses in total",
            "已学习 %d 个快捷键，累计 %d 次触发"
        ),
        .rankingReset: ("Reset statistics", "重置统计"),
        .rankingHUD: ("Show “executed” HUD", "执行后显示轻提示"),
        .rankingIncludeBuiltIn: (
            "Use built-in catalog when menus are unavailable",
            "菜单不可用时使用内置快捷键目录"
        ),
        .rankingDefaults: ("Restore all settings…", "恢复全部设置…"),

        .generalTitle: ("General", "通用"),
        .generalLaunchAtLogin: ("Launch at login", "开机自启动"),
        .generalExcludedApps: ("Excluded apps", "排除的 App"),
        .generalShowAppleMenu: (
            "Include the Apple menu in scans",
            "扫描时包含 Apple 菜单"
        ),
        .generalShowAppleMenuHint: (
            "The Apple menu belongs to the system rather than to the app in front, so its commands (“About This Mac”, “Sleep”, …) are hidden by default. Turning this on adds them to every app's list.",
            "Apple 菜单属于系统而非前台 App，其命令（“关于本机”“睡眠”等）默认隐藏。开启后会出现在每个 App 的列表里。"
        ),
        .statsSection: ("Statistics", "使用统计"),
        .statsByApp: ("Presses by app", "按 App 统计"),
        .statsGenericApp: ("System / built-in", "系统 / 内置"),
        .statsNoData: ("No usage recorded yet", "还没有统计数据"),
        .statsOpenDataFolder: ("Show data folder", "显示数据目录"),
        .statsShortcuts: ("shortcuts", "个快捷键"),
        .statsUnknownCommand: ("Not scanned yet", "尚未扫描到"),
        .generalExcludedAppsHint: (
            "Apps in this list never show the panel. Add one with the + button (Finder opens), select a row and press − to remove it.",
            "列表中的 App 不会弹出面板。用 + 从访达中添加，选中一行后按 − 移除。"
        ),

        .settingsTitle: ("Settings", "设置"),


        .rowActionSection: ("Row actions", "行操作"),
        .rowActionExecute: ("Run the shortcut", "执行快捷键"),
        .rowActionCopy: ("Copy the shortcut", "复制快捷键"),
        .rowActionHint: (
            "Clicking a row uses the run key. Both keys are recorded: a modifier is optional for keys such as Return, while a bare letter is refused so that filtering still works. The run key wins if both are recorded to the same chord.",
            "点击行等同于执行键。两个键都可录制：Return 这类键可以不按修饰键，纯字母会被拒绝，以免影响筛选输入。若两个键录成同一组合，执行键优先。"
        ),

        .overlayNoCandidates: ("No matching shortcuts", "没有匹配的快捷键"),
        .scanPermissionDenied: (
            "Accessibility permission is off, so no menus could be read",
            "辅助功能权限未开启，无法读取菜单栏"
        ),
        .scanFallbackHint: (
            "Built-in catalog · Accessibility off",
            "内置目录 · 辅助功能未开启"
        ),
        .overlayBuiltInBadge: ("built-in", "内置"),
        .overlayScanning: ("Scanning menu bar…", "正在读取菜单栏…"),
        .overlayPageFormat: ("%d/%d", "%d/%d"),
        .overlayUnavailableBadge: ("Unavailable", "不可用"),
        .overlayConflictBadge: ("Conflict", "冲突"),
        .overlayConflictHint: (
            "Some shortcuts are bound more than once",
            "有快捷键被重复绑定"
        ),
        .overlayHint: ("⌫ back · Esc close", "⌫ 返回 · Esc 关闭"),
        .panelCopied: ("Copied", "已复制"),
        .panelCopyFailed: ("Could not copy", "复制失败"),
        .panelNothingToCopy: ("No shortcut to copy", "没有可复制的快捷键"),
        .panelIdleHint: ("Press a shortcut to identify it · / searches · Esc closes", "按下快捷键查看说明 · / 搜索 · Esc 关闭"),
        .panelActionHint: (
            "↑↓ select · %1$@ run · %2$@ copy · Esc close",
            "↑↓ 选择 · %1$@ 执行 · %2$@ 复制 · Esc 关闭"
        ),
        // The same hint with the palette's key in it. The footer picks this one only when
        // the window is wide enough to hold it: at 300 pt the extra clause wrapped onto a
        // third line and overlapped the last rows.
        .panelActionHintSearch: (
            "↑↓ select · %1$@ run · %2$@ copy · / search · Esc close",
            "↑↓ 选择 · %1$@ 执行 · %2$@ 复制 · / 搜索 · Esc 关闭"
        ),
        // One column, 300 pt: the two keys that do something and nothing else.
        .panelActionHintCompact: ("%1$@ run · Esc close", "%1$@ 执行 · Esc 关闭"),

        .hudExecuted: ("%@  ✓", "%@  ✓"),

        .frontmostApp: ("Frontmost app", "前台 App"),
        .exportMarkdown: ("Export Markdown", "导出 Markdown"),
        .searchTitle: ("Search Shortcuts", "搜索快捷键"),
        .searchPlaceholder: ("Search title or shortcut", "搜索名称或快捷键"),
        // The palette has no copy action: Return always replays the shortcut.
        .searchHintRun: ("↑↓ select · ↵ run · Esc close", "↑↓ 选择 · ↵ 执行 · Esc 关闭"),
        .searchNoResults: ("No matches", "无匹配结果"),
        .searchBackToPanel: ("Back to the shortcut panel (/)", "返回快捷键面板（/）"),

        .conflictTitle: ("Conflicts", "冲突"),
        .conflictListTitle: ("Findings", "冲突列表"),
        .conflictNone: ("No conflicts detected", "没有检测到冲突"),
        .conflictFoundFormat: (
            "%d chords are bound more than once",
            "有 %d 个组合键被重复绑定"
        ),

        // Conflict layers
        .layerDriver: ("Driver", "驱动层"),
        .layerEventTap: ("Event Tap", "事件拦截"),
        .layerSystem: ("System", "系统"),
        .layerGlobalHotkey: ("Global Hotkey", "全局热键"),
        .layerGlobal: ("Global", "全局"),
        .layerMenuItem: ("Menu Item", "菜单项"),
        .layerDriverExplanation: (
            "Remapped in a virtual keyboard driver, before macOS or any app sees the event.",
            "在虚拟键盘驱动里改写，macOS 和任何 App 都还没看到这个按键。"
        ),
        .layerEventTapExplanation: (
            "Hooked by a CGEvent tap, which sees the key ahead of the system's own shortcuts and can swallow it.",
            "由 CGEvent 事件拦截挂钩，比系统自带快捷键更早看到按键，并且可以把它吞掉。"
        ),
        .layerSystemExplanation: (
            "A macOS system shortcut. It beats app level shortcuts, but an event tap can take the key first.",
            "macOS 系统快捷键。它压过 App 级快捷键，但事件拦截层可以先把键拿走。"
        ),
        .layerGlobalHotkeyExplanation: (
            "A global hotkey registered with Carbon. It fires system wide, but only if nothing lower in the stack claimed the key.",
            "用 Carbon 注册的全局热键，全系统有效，但前提是栈里更低的层没有先拿走这个键。"
        ),
        .layerGlobalExplanation: (
            "An always-on global shortcut. KagiPeek cannot tell from the config which layer it hooks, so its position here is a guess.",
            "常驻的全局快捷键。KagiPeek 无法从配置判断它挂在哪一层，这里的位置是推测。"
        ),
        .layerMenuItemExplanation: (
            "An app menu shortcut. It fires only when that app is frontmost and nothing global claimed the key.",
            "App 菜单快捷键。只有该 App 在前台、且没有全局快捷键抢走这个键时才会触发。"
        ),

        // Conflict categories — named by which two things collide, because that is what
        // decides where the user has to go to fix it.
        .conflictCategoryMenuOrder: ("Same app's menu", "同一 App 菜单内"),
        .conflictCategorySystemShadow: ("Blocked by macOS", "被系统快捷键挡住"),
        .conflictCategoryToolShadow: ("Blocked by a tool", "被第三方工具挡住"),
        .conflictCategoryToolSelfOverlap: ("Same tool, two rules", "同一工具内两条规则"),
        .conflictCategorySystemVsSystem: ("Two macOS shortcuts", "两条系统快捷键"),
        .conflictCategorySystemVsTool: ("macOS vs tool", "系统快捷键 vs 工具"),
        .conflictCategoryToolVsTool: ("Two tools", "两个工具相撞"),
        .conflictCategoryMenuOrderExplanation: (
            "Two commands of the same app share this combo. macOS takes whichever comes first in the menu, and nothing needs changing.",
            "同一个 App 的两条菜单命令共用这个组合键。macOS 按菜单顺序取第一条，不需要处理。"
        ),
        .conflictCategorySystemShadowExplanation: (
            "A macOS shortcut claims this combo before any app sees it, so the menu item can never fire. Turn the system shortcut off in System Settings → Keyboard → Shortcuts.",
            "macOS 系统快捷键在任何 App 之前就拿走了这个组合键，这条菜单命令永远不会被触发。到「系统设置 → 键盘 → 键盘快捷键」关掉那条系统快捷键。"
        ),
        .conflictCategoryToolShadowExplanation: (
            "A tool you installed takes this combo before the app sees it. Change or disable that rule in the tool's own config.",
            "你安装的工具在 App 之前拿走了这个组合键。到那个工具的配置里改掉或停用这条规则。"
        ),
        .conflictCategoryToolSelfOverlapExplanation: (
            "One tool binds this combo twice, so one of its own rules never runs. Open that tool's config and delete or rebind one of them.",
            "同一个工具里两条规则绑了同一个组合键，其中一条永远不会生效。到那个工具的配置里删掉或改掉其中一条。"
        ),
        .conflictCategorySystemVsSystemExplanation: (
            "Two macOS shortcuts share this combo. macOS keeps the one it registered first; turn one off in System Settings.",
            "两条 macOS 系统快捷键共用这个组合键，系统保留先注册的那条。到系统设置里关掉其中一条。"
        ),
        .conflictCategorySystemVsToolExplanation: (
            "A macOS shortcut and a tool you installed both stay on all the time. The tool usually sits lower in the stack, so it wins in every app — the fix is in that tool or in System Settings.",
            "系统快捷键和你装的工具都常驻。工具层通常更靠下，所以在任何 App 里都是它先拿到——改动落在工具配置或系统设置里。"
        ),
        .conflictCategoryToolVsToolExplanation: (
            "Two tools you installed claim the same combo in every app. Which one wins depends on its layer — and on the same layer, on registration order, which nothing on disk records. Use the test below to find out.",
            "两个工具在任何 App 里都会抢这个组合键。谁赢取决于各自所在的层；同层则取决于注册顺序，磁盘上没有任何记录。用下面的实测确认。"
        ),

        // Conflict verdicts
        .conflictVerdictTitle: ("Who wins", "谁会生效"),
        .conflictLayerPrefix: ("Layer", "所在层"),
        .conflictVerdictWinnerFormat: ("%@ most likely wins.", "%@ 最可能生效。"),
        .conflictVerdictTied: (
            "Several shortcuts hook the same layer, so whichever registered first wins. That order is not recorded anywhere KagiPeek can read.",
            "多个快捷键挂在同一层，谁先注册谁生效。这个顺序没有记录在任何 KagiPeek 能读到的地方。"
        ),
        .conflictVerdictMenuOrder: (
            "These are all menu shortcuts of this app, so macOS matches them in menu order and the first one wins.",
            "这些都是当前 App 的菜单快捷键，macOS 会按菜单顺序匹配，靠前的那个生效。"
        ),
        .conflictVerdictUnknown: ("KagiPeek cannot tell which one wins.", "KagiPeek 无法判断谁会生效。"),

        // Conflict filters
        .conflictType: ("Type", "类型"),
        .conflictTypeAllFormat: ("All types (%d)", "全部类型（%d）"),
        .conflictTypeEmpty: (
            "No clashes of this type.",
            "没有这一类型的冲突。"
        ),
        .conflictOwner: ("Related app", "相关 App"),
        .conflictOwnerAll: ("All apps", "全部 App"),
        .conflictOwnerGlobal: ("Global only", "仅全局"),
        .conflictRescan: ("Rescan", "重新扫描"),
        .conflictScanning: ("Scanning running apps…", "正在扫描运行中的 App…"),
        .conflictNeverScanned: ("Not scanned yet", "尚未扫描"),
        .conflictScannedAtFormat: ("Scanned %@", "扫描于 %@"),
        .conflictShowMoreFormat: (
            "Show %d more (%d in total)",
            "再显示 %d 条（共 %d 条）"
        ),

        // Third-party config tools
        .configToolsTitle: ("Config file sources", "配置文件来源"),
        .configToolsSubtitle: (
            "Shortcuts written into configuration files sit below macOS in the keyboard stack, so they can swallow a menu shortcut before the app ever sees it.",
            "写进配置文件的快捷键位于键盘事件栈中比 macOS 更低的位置，因此能在 App 看到按键之前就把它吞掉。"
        ),
        .configToolsToggle: ("Scan config files", "扫描配置文件"),
        .configToolsRescan: ("Scan now", "立即扫描"),
        .configToolsNoneFound: (
            "No supported config files found. Karabiner, skhd, Keyboard Maestro, BetterTouchTool, Hammerspoon and Alfred are recognised.",
            "没有找到受支持的配置文件。支持 Karabiner、skhd、Keyboard Maestro、BetterTouchTool、Hammerspoon 和 Alfred。"
        ),
        .configToolCountFormat: ("%1$@ — %2$d shortcuts", "%1$@ — %2$d 条快捷键"),
        .configToolUnreadable: ("Could not read", "读取失败"),
        .configToolsPrivacyNote: (
            "Files are read in place and never copied or uploaded.",
            "只在本机就地读取，不会复制或上传这些文件。"
        ),

        // Combo lookup
        .comboLookupTitle: ("This combo", "这个组合键"),
        .comboLookupFree: ("Nothing claims this combo.", "没有任何快捷键占用这个组合键。"),
        .comboLookupOwnerFormat: ("%@ claims this combo.", "%@ 占用了这个组合键。"),
        .comboLookupOwnersFormat: ("%d shortcuts claim this combo.", "有 %d 个快捷键占用了这个组合键。"),
        .comboLookupHint: (
            "Type a combo such as \"cmd shift 4\" to ask who owns it.",
            "输入形如 “cmd shift 4” 的组合键，可以直接问是谁占用了它。"
        ),

        // Live shortcut test
        .testTitle: ("Live test", "实测"),
        .testStart: ("Test this combo", "实测这个组合键"),
        .testCancel: ("Cancel test", "取消实测"),
        .testListeningFormat: ("Listening for %d seconds…", "正在监听 %d 秒…"),
        .testHint: (
            "Press the combo once. KagiPeek watches a real keypress instead of guessing from config files.",
            "按下这个组合键一次。KagiPeek 会观察一次真实按键，而不是根据配置文件猜测。"
        ),
        .testUnavailableNoPermission: (
            "Testing needs Accessibility permission.",
            "实测需要辅助功能授权。"
        ),
        .testUnavailableNoTap: (
            "macOS refused a keyboard listener. Quitting and reopening KagiPeek usually clears this.",
            "macOS 拒绝了键盘监听。退出并重新打开 KagiPeek 通常能解决。"
        ),
        .testVerdictSwallowedByTap: ("An event tap took the key", "有事件拦截层拿走了这个键"),
        .testVerdictSwallowedByTapOne: ("%@ took the key", "%@ 拿走了这个键"),
        .testVerdictReachedApp: ("%@ got the key", "%@ 收到了这个键"),
        .testVerdictAlreadyFrontmost: ("%@ was already in front", "%@ 本来就在前台"),
        .testVerdictUnregisteredApp: ("%@ took the key", "%@ 拿走了这个键"),
        .testVerdictSurvivedUnclaimed: ("No visible winner", "看不出谁拿到了"),
        .testVerdictRewritten: ("The key was rewritten first", "按键先被改写了"),
        .testVerdictNothingSeen: ("Nothing reached the listener", "没有按键到达监听器"),
        .testToneConfirmed: ("Confirmed", "已确认"),
        .testToneInformative: ("Informative", "有信息量"),
        .testToneInconclusive: ("Inconclusive", "无法判断"),
        .testSummarySwallowedNone: (
            "The key reached KagiPeek's first listener and never arrived at the second, so an event tap swallowed it on the way. Nothing in the scan claims this combo at that layer, so whatever took it is a tool KagiPeek cannot read the config of.",
            "按键到达了 KagiPeek 的第一个监听器，却没有到达第二个，说明途中有事件拦截层把它吞了。扫描结果里没有谁在这一层占用这个组合键，所以拿走它的是 KagiPeek 读不到配置的工具。"
        ),
        .testSummarySwallowedOne: (
            "The key reached KagiPeek's first listener and never arrived at the second, so an event tap swallowed it on the way. %@ is the only tool in the scan that hooks that layer with this combo, so it is almost certainly holding the key.",
            "按键到达了 KagiPeek 的第一个监听器，却没有到达第二个，说明途中有事件拦截层把它吞了。%@ 是扫描结果里唯一在这一层占用这个组合键的工具，几乎可以肯定就是它拿走了按键。"
        ),
        .testSummarySwallowedMany: (
            "The key reached KagiPeek's first listener and never arrived at the second, so an event tap swallowed it on the way. %@ all hook that layer with this combo, and the tap chain does not record which of them acted.",
            "按键到达了 KagiPeek 的第一个监听器，却没有到达第二个，说明途中有事件拦截层把它吞了。%@ 都在这一层占用这个组合键，而事件拦截链不会记录到底是谁动了手。"
        ),
        .testSummaryReachedApp: (
            "%@ came to the front right after the press, and it does claim this combo. Nothing swallowed the key at the event tap layer, so this is as close to a confirmed answer as watching from outside can get.",
            "按下之后 %@ 立刻来到前台，而且它确实占用这个组合键。没有事件拦截层吞掉按键，这是从外部观察所能得到的最接近确认的答案。"
        ),
        .testSummaryAlreadyFrontmost: (
            "No event tap took the key and nothing came to the front. %@ was already frontmost and has a menu shortcut on this combo, so that one most likely fired. A macOS system shortcut could also have taken the key silently, which nothing outside the OS can see.",
            "没有事件拦截层拿走按键，也没有 App 切到前台。%@ 本来就在前台，而且有这个组合键的菜单项，所以最可能是它触发了。也有可能是 macOS 系统快捷键静默拿走了按键，这在系统外部无法观察。"
        ),
        .testSummaryUnregisteredApp: (
            "%@ came to the front right after the press, but nothing in the scan records it claiming this combo. Either it registers the shortcut somewhere KagiPeek cannot read, or it was on its way to the front for an unrelated reason.",
            "按下之后 %@ 立刻来到前台，但扫描结果里没有它占用这个组合键的记录。要么它的快捷键注册在 KagiPeek 读不到的地方，要么它切到前台只是出于别的原因。"
        ),
        .testSummarySurvived: (
            "The key got past every event tap, and nothing came to the front to give the winner away. From there a macOS system shortcut or a global hotkey can take a key without leaving a trace anything outside the OS can follow.",
            "按键穿过了所有事件拦截层，也没有 App 切到前台来暴露赢家。再往上，macOS 系统快捷键或全局热键可以拿走按键而不留下任何系统外部能追踪的痕迹。"
        ),
        .testSummarySurvivedRuledOut: (
            "The key got past every event tap, and nothing came to the front to give the winner away. From there a macOS system shortcut or a global hotkey can take a key without leaving a trace anything outside the OS can follow. What this does settle is that %@ did not take it.",
            "按键穿过了所有事件拦截层，也没有 App 切到前台来暴露赢家。再往上，macOS 系统快捷键或全局热键可以拿走按键而不留下任何系统外部能追踪的痕迹。能确定的是，%@ 没有拿走它。"
        ),
        .testSummaryRewritten: (
            "You pressed something, and what reached macOS was %1$@ rather than %2$@. That means it was rewritten below the operating system, which is what a virtual keyboard driver like Karabiner-Elements does. Worth pressing again to rule out a slip of the fingers before believing that.",
            "你按下的键到达 macOS 时变成了 %1$@，而不是 %2$@。这说明它在操作系统之下就被改写了，这正是 Karabiner-Elements 这类虚拟键盘驱动做的事。建议再按一次排除手误，然后再相信这个结论。"
        ),
        .testSummaryNothingSeen: (
            "KagiPeek listened and no keypress arrived at all. If you did press the combination, something intercepted it below the event tap layer, which in practice means a keyboard driver remap. If you did not, run the test again.",
            "KagiPeek 监听了但没有收到任何按键。如果你确实按下了那个组合键，说明它在事件拦截层之下就被截走了，实际上就是键盘驱动层的重映射。如果你没按，请再测一次。"
        ),

        .aboutTitle: ("About", "关于"),
        .aboutVersion: ("Version", "版本"),
        .aboutRepository: ("Repository", "仓库"),
        .aboutLicense: ("License", "协议"),
        .aboutBuild: ("Build", "构建号"),
        .aboutSystem: ("System", "系统"),
        .aboutDataFolder: ("Data folder", "数据目录"),
        .aboutDiagnostics: ("Diagnostics", "诊断"),
        .aboutMenuItems: ("Menu items", "菜单条目"),
        .aboutExportDiagnostics: ("Export diagnostics…", "导出诊断…"),
        .aboutDiagnosticsHint: (
            "Writes a JSON report (permissions, scan result, settings, log excerpt) that can be attached to a bug report. Nothing is uploaded.",
            "导出一份 JSON 报告（权限、扫描结果、设置、日志摘要），可附在问题反馈里。不会上传任何内容。"
        ),

        .diagnosticsTitle: ("Diagnostics", "诊断"),
        .diagnosticsEnable: ("Write diagnostics to disk", "将诊断写入本地"),
        .diagnosticsEnableHint: (
            "Logs, crash reports and the last actions stay in this Mac's Application Support folder. Nothing is uploaded.",
            "日志、崩溃报告与最近操作都保存在本机的 Application Support 目录，不会上传任何内容。"
        ),
        .diagnosticsVerbose: ("Include verbose detail", "记录详细级别"),
        .diagnosticsVerboseHint: (
            "Adds high-frequency entries (key handling, scan details). Turn it on right before reproducing a problem.",
            "补充高频条目（按键处理、扫描细节）。建议在复现问题前临时打开。"
        ),
        .diagnosticsPath: ("Log folder", "日志位置"),
        .diagnosticsOpenFolder: ("Open log folder", "打开日志文件夹"),
        .diagnosticsExport: ("Export diagnostics…", "导出诊断…"),
        .diagnosticsPrivacyNote: (
            "Account names, tokens, URL parameters and e-mail addresses are redacted before anything reaches a log file. Filter text and clipboard content are never recorded; verbose mode does record which shortcut combinations were pressed.",
            "写入日志文件前会脱敏账号、令牌、URL 参数与邮箱；筛选框文本与剪贴板内容从不记录（详细级别会记录用过的组合键）。"
        ),
        .diagnosticsExportDone: ("Diagnostics exported", "诊断已导出"),
        .diagnosticsExportFailed: ("Export failed: %@", "导出失败：%@"),

        .generalShowDockIcon: ("Show a Dock icon as well", "同时在 Dock 显示图标"),
        .generalShowDockIconHint: (
            "A second way in when a menu bar manager (Thaw, Ice, Bartender…) hides the menu bar icon. The keyboard shortcuts keep working either way.",
            "菜单栏管理工具（Thaw、Ice、Bartender 等）把图标藏起来时的备用入口。无论开关如何，快捷键都照常工作。"
        ),

        .menuEdit: ("Edit", "编辑"),
        .menuCut: ("Cut", "剪切"),
        .menuCopy: ("Copy", "拷贝"),
        .menuPaste: ("Paste", "粘贴"),
        .menuSelectAll: ("Select All", "全选"),
        .menuSearchShortcuts: ("Search Shortcuts", "搜索快捷键"),

        .groupSystem: ("System", "系统"),
        .groupFinder: ("Finder", "Finder"),
        .groupTextEditing: ("Text Editing", "文本编辑"),
        .groupScreenshot: ("Screenshots", "截图"),
        .groupBrowser: ("Browser", "浏览器"),
        .groupSystemHotkeys: ("System hotkeys", "系统热键"),


        .updateCheck: ("Check for updates", "检查更新"),
        .updateAvailable: ("Version %@ is available", "有新版本 %@"),
        .updateNone: ("You're up to date", "已是最新版本"),
        .updateFailed: ("Could not check for updates", "检查更新失败"),
        .updateOpen: ("Open release page", "打开发布页"),

        .searchScopeLoading: ("Loading this app's shortcuts…", "正在加载这个 App 的快捷键…"),
        .searchBuiltInNotice: ("Built-in shortcuts · menus unavailable", "内置快捷键 · 菜单不可用"),
        .conflictScanFailed: ("Conflict scan failed — results are incomplete", "冲突扫描失败——结果不完整"),
        .conflictScanPartialFormat: ("%d app(s) could not be scanned — results are incomplete", "%d 个 App 未能扫描——结果不完整"),
        .rankingResetConfirmTitle: ("Reset statistics?", "重置统计？"),
        .rankingResetConfirmMessage: ("Press counts will be cleared. Pinned shortcuts are kept.", "将清除触发次数，已收藏的快捷键会保留。"),
        .rankingDefaultsConfirmTitle: ("Restore all settings?", "恢复全部设置？"),
        .rankingDefaultsConfirmMessage: ("Hotkeys, excluded apps, ignored commands, appearance, diagnostics and the launch-at-login item will return to their defaults.", "快捷键、排除的 App、忽略命令、外观、诊断和开机启动都会恢复默认值。"),

        .errorEventTap: (
            "Could not create the keyboard event tap.",
            "无法创建键盘事件监听。"
        ),
        .errorNoAccessibility: (
            "Accessibility access is required.",
            "需要辅助功能权限。"
        )
    ]
}
