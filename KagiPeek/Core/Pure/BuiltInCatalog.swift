import Foundation

// The bundled fallback catalog.
//
// The primary data source is the frontmost app's menu bar (see MenuScanner). This catalog
// covers system-level shortcuts that never show up in an app menu (screenshots, Spotlight,
// text-editing Emacs bindings) and is used when an app exposes no menu bar at all.

enum BuiltInGroup: String, CaseIterable, Sendable {
    case system, finder, textEditing, screenshot, browser

    var titleKey: L10nKey {
        switch self {
        case .system: return .groupSystem
        case .finder: return .groupFinder
        case .textEditing: return .groupTextEditing
        case .screenshot: return .groupScreenshot
        case .browser: return .groupBrowser
        }
    }
}

struct BuiltInEntry: Sendable {
    let descriptor: String
    let titleZH: String
    let titleEN: String
    let group: BuiltInGroup
    let bundleID: String?
}

enum BuiltInCatalog {
    static let entries: [BuiltInEntry] = [
        .init(descriptor: "cmd+x", titleZH: "剪切", titleEN: "Cut", group: .system, bundleID: nil),
        .init(descriptor: "cmd+c", titleZH: "拷贝", titleEN: "Copy", group: .system, bundleID: nil),
        .init(descriptor: "cmd+v", titleZH: "粘贴", titleEN: "Paste", group: .system, bundleID: nil),
        .init(descriptor: "cmd+z", titleZH: "撤销", titleEN: "Undo", group: .system, bundleID: nil),
        .init(descriptor: "cmd+shift+z", titleZH: "重做", titleEN: "Redo", group: .system, bundleID: nil),
        .init(descriptor: "cmd+a", titleZH: "全选", titleEN: "Select All", group: .system, bundleID: nil),
        .init(descriptor: "cmd+f", titleZH: "查找", titleEN: "Find", group: .system, bundleID: nil),
        .init(descriptor: "cmd+g", titleZH: "查找下一个", titleEN: "Find Next", group: .system, bundleID: nil),
        .init(descriptor: "cmd+shift+g", titleZH: "查找上一个", titleEN: "Find Previous", group: .system, bundleID: nil),
        .init(descriptor: "cmd+h", titleZH: "隐藏当前 App", titleEN: "Hide App", group: .system, bundleID: nil),
        .init(descriptor: "cmd+opt+h", titleZH: "隐藏其他 App", titleEN: "Hide Others", group: .system, bundleID: nil),
        .init(descriptor: "cmd+m", titleZH: "最小化窗口", titleEN: "Minimize", group: .system, bundleID: nil),
        .init(descriptor: "cmd+opt+m", titleZH: "最小化所有窗口", titleEN: "Minimize All", group: .system, bundleID: nil),
        .init(descriptor: "cmd+o", titleZH: "打开", titleEN: "Open", group: .system, bundleID: nil),
        .init(descriptor: "cmd+p", titleZH: "打印", titleEN: "Print", group: .system, bundleID: nil),
        .init(descriptor: "cmd+s", titleZH: "保存", titleEN: "Save", group: .system, bundleID: nil),
        .init(descriptor: "cmd+t", titleZH: "新建标签页", titleEN: "New Tab", group: .system, bundleID: nil),
        .init(descriptor: "cmd+w", titleZH: "关闭窗口", titleEN: "Close Window", group: .system, bundleID: nil),
        .init(descriptor: "cmd+opt+w", titleZH: "关闭全部窗口", titleEN: "Close All Windows", group: .system, bundleID: nil),
        .init(descriptor: "cmd+q", titleZH: "退出 App", titleEN: "Quit App", group: .system, bundleID: nil),
        .init(descriptor: "cmd+opt+esc", titleZH: "强制退出窗口", titleEN: "Force Quit Window", group: .system, bundleID: nil),
        .init(descriptor: "cmd+space", titleZH: "Spotlight 搜索", titleEN: "Spotlight Search", group: .system, bundleID: nil),
        .init(descriptor: "cmd+opt+space", titleZH: "Finder 中 Spotlight", titleEN: "Spotlight in Finder", group: .system, bundleID: nil),
        .init(descriptor: "cmd+ctrl+space", titleZH: "Emoji 与符号", titleEN: "Emoji & Symbols", group: .system, bundleID: nil),
        .init(descriptor: "cmd+ctrl+f", titleZH: "全屏开关", titleEN: "Toggle Full Screen", group: .system, bundleID: nil),
        .init(descriptor: "cmd+tab", titleZH: "切换到下一个 App", titleEN: "Switch to Next App", group: .system, bundleID: nil),
        .init(descriptor: "cmd+`", titleZH: "切换同一 App 的窗口", titleEN: "Cycle Windows", group: .system, bundleID: nil),
        .init(descriptor: "cmd+,", titleZH: "打开设置/偏好设置", titleEN: "Settings…", group: .system, bundleID: nil),
        .init(descriptor: "cmd+ctrl+q", titleZH: "锁定屏幕", titleEN: "Lock Screen", group: .system, bundleID: nil),
        .init(descriptor: "cmd+shift+q", titleZH: "注销（需确认）", titleEN: "Log Out…", group: .system, bundleID: nil),
        .init(descriptor: "cmd+opt+shift+q", titleZH: "立即注销", titleEN: "Log Out Immediately", group: .system, bundleID: nil),
        .init(descriptor: "cmd+d", titleZH: "复制文件", titleEN: "Duplicate", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+e", titleZH: "推出磁盘/卷宗", titleEN: "Eject", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+i", titleZH: "显示简介", titleEN: "Get Info", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+r", titleZH: "刷新/重新载入", titleEN: "Refresh / Reload", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+j", titleZH: "显示视图选项", titleEN: "Show View Options", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+k", titleZH: "连接服务器", titleEN: "Connect to Server", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+n", titleZH: "新建窗口", titleEN: "New Window", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+opt+n", titleZH: "新建智能文件夹", titleEN: "New Smart Folder", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+n", titleZH: "新建文件夹", titleEN: "New Folder", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+ctrl+n", titleZH: "以所选项新建文件夹", titleEN: "New Folder with Selection", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+c", titleZH: "打开电脑窗口", titleEN: "Open Computer", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+d", titleZH: "打开桌面文件夹", titleEN: "Open Desktop", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+f", titleZH: "打开最近项目", titleEN: "Open Recents", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+h", titleZH: "打开个人文件夹", titleEN: "Open Home", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+i", titleZH: "打开 iCloud Drive", titleEN: "Open iCloud Drive", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+k", titleZH: "打开网络窗口", titleEN: "Open Network", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+opt+l", titleZH: "打开下载文件夹", titleEN: "Open Downloads", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+o", titleZH: "打开文稿文件夹", titleEN: "Open Documents", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+p", titleZH: "显示/隐藏预览面板", titleEN: "Show/Hide Preview", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+r", titleZH: "打开 AirDrop", titleEN: "Open AirDrop", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+t", titleZH: "显示/隐藏标签栏", titleEN: "Show/Hide Tab Bar", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+shift+u", titleZH: "打开实用工具文件夹", titleEN: "Open Utilities", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+ctrl+t", titleZH: "添加到侧边栏", titleEN: "Add to Sidebar", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+opt+p", titleZH: "显示/隐藏路径栏", titleEN: "Show/Hide Path Bar", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+opt+s", titleZH: "显示/隐藏边栏", titleEN: "Show/Hide Sidebar", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+/", titleZH: "显示/隐藏状态栏", titleEN: "Show/Hide Status Bar", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+opt+t", titleZH: "显示/隐藏工具栏", titleEN: "Show/Hide Toolbar", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+opt+v", titleZH: "移动（粘贴并移除原文件）", titleEN: "Move Item Here", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+y", titleZH: "快速查看", titleEN: "Quick Look", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+opt+y", titleZH: "快速查看幻灯片", titleEN: "Quick Look Slideshow", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+1", titleZH: "图标视图", titleEN: "Icon View", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+2", titleZH: "列表视图", titleEN: "List View", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+3", titleZH: "分栏视图", titleEN: "Column View", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+4", titleZH: "画廊视图", titleEN: "Gallery View", group: .finder, bundleID: "com.apple.finder"),
        .init(descriptor: "cmd+b", titleZH: "加粗", titleEN: "Bold", group: .textEditing, bundleID: nil),
        .init(descriptor: "cmd+u", titleZH: "下划线", titleEN: "Underline", group: .textEditing, bundleID: nil),
        .init(descriptor: "cmd+shift+s", titleZH: "另存为/复制文稿", titleEN: "Save As / Duplicate", group: .textEditing, bundleID: nil),
        .init(descriptor: "cmd+opt+f", titleZH: "跳转到搜索栏", titleEN: "Jump to Search Field", group: .textEditing, bundleID: nil),
        .init(descriptor: "cmd+opt+c", titleZH: "拷贝样式", titleEN: "Copy Style", group: .textEditing, bundleID: nil),
        .init(descriptor: "cmd+opt+i", titleZH: "显示/隐藏检查器", titleEN: "Show/Hide Inspector", group: .textEditing, bundleID: nil),
        .init(descriptor: "cmd+opt+shift+v", titleZH: "粘贴并匹配样式", titleEN: "Paste and Match Style", group: .textEditing, bundleID: nil),
        .init(descriptor: "opt+delete", titleZH: "删除左侧一个单词", titleEN: "Delete Word Left", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+h", titleZH: "删除左侧字符", titleEN: "Delete Character Left", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+d", titleZH: "删除右侧字符", titleEN: "Delete Character Right", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+k", titleZH: "剪切到段落末尾", titleEN: "Kill to End of Paragraph", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+a", titleZH: "移动到行首", titleEN: "Move to Beginning of Line", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+e", titleZH: "移动到行尾", titleEN: "Move to End of Line", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+f", titleZH: "向前移动一个字符", titleEN: "Move Forward One Character", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+b", titleZH: "向后移动一个字符", titleEN: "Move Backward One Character", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+l", titleZH: "光标居中到可视区域", titleEN: "Center Selection in View", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+p", titleZH: "上移一行", titleEN: "Move Up One Line", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+n", titleZH: "下移一行", titleEN: "Move Down One Line", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+o", titleZH: "在后方插入新行", titleEN: "Insert Newline After", group: .textEditing, bundleID: nil),
        .init(descriptor: "ctrl+t", titleZH: "交换相邻字符", titleEN: "Transpose Characters", group: .textEditing, bundleID: nil),
        .init(descriptor: "cmd+shift+3", titleZH: "全屏截图", titleEN: "Screenshot (Full Screen)", group: .screenshot, bundleID: nil),
        .init(descriptor: "cmd+shift+4", titleZH: "区域截图", titleEN: "Screenshot (Selection)", group: .screenshot, bundleID: nil),
        .init(descriptor: "cmd+shift+5", titleZH: "截图与录屏控制", titleEN: "Screenshot & Recording Controls", group: .screenshot, bundleID: nil),
        .init(descriptor: "cmd+l", titleZH: "定位地址栏", titleEN: "Focus Address Bar", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+r", titleZH: "重新载入网页", titleEN: "Reload Page", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+opt+r", titleZH: "重新载入并忽略缓存", titleEN: "Reload Ignoring Cache", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+[", titleZH: "后退", titleEN: "Back", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+]", titleZH: "前进", titleEN: "Forward", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+shift+[", titleZH: "上一标签页", titleEN: "Previous Tab", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+shift+]", titleZH: "下一标签页", titleEN: "Next Tab", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+opt+1", titleZH: "切换到第 1 个标签页", titleEN: "Switch to Tab 1", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+opt+2", titleZH: "切换到第 2 个标签页", titleEN: "Switch to Tab 2", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+opt+3", titleZH: "切换到第 3 个标签页", titleEN: "Switch to Tab 3", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+opt+4", titleZH: "切换到第 4 个标签页", titleEN: "Switch to Tab 4", group: .browser, bundleID: "com.apple.Safari"),
        .init(descriptor: "cmd+shift+t", titleZH: "恢复关闭的标签页", titleEN: "Reopen Closed Tab", group: .browser, bundleID: "com.apple.Safari"),
    ]

    static func items(language: AppLanguage) -> [BindingItem] {
        entries.map { entry in
            BindingItem(
                chord: KeyChord(descriptor: entry.descriptor),
                title: language == .chinese ? entry.titleZH : entry.titleEN,
                group: [L10n.string(entry.group.titleKey, language: language)],
                isEnabled: true,
                source: .builtIn,
                appBundleID: entry.bundleID
            )
        }
    }
}
