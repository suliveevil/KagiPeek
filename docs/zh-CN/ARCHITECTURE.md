# 架构

[English](../en/ARCHITECTURE.md) · [中文](ARCHITECTURE.md)


> **哪些是历史记录，哪些不是。** 下面那一段版本编年史，以及所有标题里带 *development* 的章节，都是历史：
> 它们说的是代码怎么走到这里的，其中任何计数、行号或文件清单描述的只是写作当时的树。它们与代码冲突时，代码是权威。
> 其余部分描述的是这个 App 今天的行为。

本文描述 v2.2.0 的架构。此后一个开发分支（v2.3.0 重构）把引擎的决策逻辑抽进了纯粹的、有单元测试的模块——见
[引擎状态与按键路由](#引擎状态与按键路由v220-之后的开发)。v1.2.0 的重写用实时的辅助功能（AX）菜单扫描、多段组合键解析器、
搜索索引和一组小型 SwiftUI 面板，替换了 v1.1 的静态清单；v2.0 让面板可以用键盘驱动、也能点击；v2.1.0 把它做成**持久**面板，
并新增四种面板位置、分词与拼音搜索、Hyper 键热键匹配、Application Support 里的 JSON 存储与按 App 统计、授权引导、
独立的"关于"标签页，以及面板/搜索切换热键。

v2.2.0 移除了独立的浏览器窗口——搜索面板接管了它的两项职责，App 范围与 Markdown 导出——并把面板的菜单项收进两张卡片，
按快捷键本身排序，一份行契约与两个录制的动作键。标题栏变为响应式，并携带可勾选的 ⌃ ⌥ ⇧ ⌘ 芯片来收窄列表；
按住的修饰键会在每个存活菜单项的组合键里点亮，而不是被剥离。设置拆成八个标签页，两个空转的"执行菜单命令"开关被删除，
App 自身的激活不再被读成前台 App 的输入。检查更新仍是唯一的联网代码，并且只在你按按钮时运行。

约束条件如下：

- **默认只观察，只有一处刻意的例外。** Kaname 观察菜单栏与按键事件；它不重映射快捷键，也不读文本。它消费的事件是自己那三个热键
  （面板、搜索、切换）加上面板的导航键与动作键。完成的快捷键会关闭面板并且**不**被吞掉：前台 App 照常收到它。例外是*执行菜单项*：
  按下执行键、点击菜单项，或在搜索面板里按 Return，都会通过 `MenuTrigger`（`AXPress`）按压那个菜单项，只有在没有元素或按压失败时
  才通过 `ShortcutInjector`（`CGEvent`，HID tap）回放它的组合键。浏览时什么都不注入，复制键也永不注入。
- **一次手动联网。** 唯一的出站请求是你自己触发的检查更新；没有轮询，没有后台流量。
- **UI 线程绝不等辅助功能。** 在卡死的 App 里，AX 调用可能阻塞数秒。每次扫描都在主线程之外运行，并带每调用超时。
- **纯逻辑可测。** 组合键解析、前缀匹配、排序、格式化、描述清洗、冲突检测、搜索（语料、分词、拼音）、热键匹配、
  面板定位、使用统计、Markdown 导出与语义化版本，都住在一个不依赖 AppKit 的 SwiftPM 目标里。
- **写入是刻意且原子的。** 搜索查询是瞬态的。设置与统计写成 JSON 文件并原子替换，损坏的文件被保留而不是被覆盖。
  其余碰磁盘的东西都是派生或诊断数据，可以删：菜单扫描（10 分钟）、冲突缓存、每日日志与崩溃报告。
- **降级，从不失败。** 没有菜单栏、没有权限、或某个 App 很慢时，仍应留下可用的兜底目录与一段说明性的界面。

## 目录

[源码结构](#源码结构) · [运行时总览](#运行时总览) · [菜单扫描](#菜单扫描辅助功能) · [兜底目录](#兜底目录) · [数据模型与索引](#数据模型与索引) · [系统热键与冲突](#系统热键与冲突) · [配置文件来源](#配置文件来源) · [排序](#排序) · [触发管线](#触发管线) · [面板内容](#面板内容与高亮) · [面板交互](#面板交互与执行) · [搜索面板](#搜索面板) · [搜索面板的 App 范围与导出](#搜索面板的-app-范围与-markdown-导出) · [设置窗口](#设置窗口) · [检查更新](#检查更新) · [展示](#展示) · [权限](#权限) · [持久化](#持久化) · [测试与 CI](#测试与-ci) · [发布](#发布) · [已知限制](#已知限制)

## 源码结构

```
Kaname/
├── App/
│   ├── AppDelegate.swift          # lifecycle, single instance, diagnostics, login item, main menu
│   └── Main.swift                 # AppKit entry point (no SwiftUI App/scene, so no window at launch)
├── Core/
│   ├── Pure/                      # SwiftPM target KanameCore (Foundation only)
│   │   ├── KeyChord.swift         # keys, modifiers, normalization, parsing
│   │   ├── RowKeys.swift          # key codes, Enter alias, RowKeyRouter
│   │   ├── BindingItem.swift      # one shortcut/action binding
│   │   ├── PrefixResolver.swift   # prefix → child bindings, chord traversal
│   │   ├── ChordComposition.swift # one pure decision: build a stroke, classify it, swallow?
│   │   ├── UsageSorting.swift     # shortcut / app / description order for the statistics list
│   │   ├── NumericSettingInput.swift # typed whole numbers: full-width folding, range check
│   │   ├── KeyFormatter.swift     # ⌘⇧C formatting, glyphs, localization
│   │   ├── KeyMapper.swift        # virtual key codes ↔ characters
│   │   ├── NavigationKey.swift    # arrows, ⌃F/⌃B/⌃N/⌃P
│   │   ├── PagingKeyPlan.swift    # four optional paging pairs, character-first decision
│   │   ├── DescriptionCleaner.swift # whitespace, trailing chord hints, the "—" placeholder
│   │   ├── SearchIndex.swift      # SearchCorpus + Pinyin + tokenized scoring
│   │   ├── ConflictDetector.swift # same chord claimed by multiple bindings, typed findings
│   │   ├── ShortcutLayer.swift    # driver → eventTap → system → global → menu
│   │   ├── ConfigTool.swift       # the six config sources, their paths and layers
│   │   ├── ConfigFileScanner.swift# one scan over every tool + shared file guards
│   │   ├── KarabinerScanner.swift # karabiner.json complex modifications
│   │   ├── SkhdScanner.swift       # skhdrc
│   │   ├── KeyboardMaestroScanner.swift # macro library hot key triggers
│   │   ├── HammerspoonScanner.swift # hs.hotkey.bind calls in init.lua
│   │   ├── AlfredScanner.swift    # workflow hotkey triggers
│   │   ├── BetterTouchToolScanner.swift # btt_data_store (SQLite, read-only)
│   │   ├── ComboLookup.swift      # "who owns this combo?" for a combo query
│   │   ├── LiveTestVerdict.swift  # what one real keypress proved
│   │   ├── HotkeyMatcher.swift    # global hotkey matching, Hyper superset rule
│   │   ├── PanelPlacement.swift   # cover / fixed / fill / beside the front window
│   │   ├── PanelSections.swift    # app / system / tool sections, folding and heading budget
│   │   ├── PanelState.swift       # immutable panel snapshot (menu items, groups, prefix)
│   │   ├── PanelRowBuilder.swift  # one menu item/group builder for both rebuild paths
│   │   ├── PanelHighlighter.swift # which menu items belong to the shortcut in progress
│   │   ├── PanelOrdering.swift    # the panel's chord order and modifier filter rule
│   │   ├── PanelSortOrder.swift   # which order the panel uses: by modifier or by menu group
│   │   ├── PendingModifiers.swift # held (transient) vs latched (ticked) modifiers
│   │   ├── ModifierTapTracker.swift # a press-and-release of a modifier becomes a tick
│   │   ├── LatchedTicks.swift     # tick/untick, and which one ⌫ undoes
│   │   ├── PanelKeyIntake.swift   # keys the panel consumes as itself, read by the tap too
│   │   ├── PanelSelection.swift   # the only menu item is selected; a stale index is dropped
│   │   ├── PanelEmptyKind.swift   # which "nothing here": permission, scanning, no favourites, no match
│   │   ├── PanelFilter.swift      # the panel's ordered modifier and letter token queue
│   │   ├── PanelFilterPlan.swift  # which rows a filter keeps, and what a key-down does to the queue
│   │   ├── DisabledNoticeGate.swift # one explanation per disabled row per 3 s
│   │   ├── RowLayout.swift        # the row's three column widths, as arithmetic
│   │   ├── PanelTheme.swift       # panel palettes
│   │   ├── HeaderLayout.swift     # responsive title-bar thresholds
│   │   ├── SystemHotkeyNames.swift# names for the system hotkeys macOS leaves unnamed
│   │   ├── IgnoredCommands.swift  # a title ignored globally or for one app
│   │   ├── MenuCachePolicy.swift  # when a cached menu scan is still valid
│   │   ├── L10n.swift             # English / Simplified Chinese strings
│   │   ├── AppSettingsModel.swift # settings values, defaults, normalization
│   │   ├── SettingsPayload.swift  # schema envelope + versioned migration hook
│   │   ├── UsageStatistics.swift  # pure usage model, 800-entry LRU, per-app rollup
│   │   ├── UsageBreakdown.swift   # per-app press and shortcut counts
│   │   ├── MarkdownExporter.swift # shortcut sheet rendered as Markdown
│   │   ├── SemanticVersion.swift  # tag parsing/comparison for the update check
│   │   ├── LogLevelFilter.swift   # diagnostic log levels
│   │   ├── LogRotationPolicy.swift# when the daily log file is rotated
│   │   ├── CrashLogFormatter.swift# crash report text
│   │   ├── SentinelState.swift    # clean-exit sentinel, so a crash is not mistaken for a quit
│   │   ├── Sanitizer.swift        # strips identifiers from exported diagnostics
│   │   ├── DiagModel.swift        # DiagLevel, DiagTag, ActionRecord
│   │   ├── DiagnosticsReportBuilder.swift # fields of the JSON report and the zip archive
│   │   ├── ComposedSwallow.swift  # the tap's swallow decision, read from a published snapshot
│   │   ├── InputMailbox.swift     # bounded (32) hand-over from the tap thread to the main actor
│   │   ├── KeySwallowRules.swift  # one value, three channels: identifiers, key codes, characters
│   │   ├── TapHealth.swift        # backoff for a tap the system keeps disabling
│   │   ├── InjectionTargetPolicy.swift # which process a replayed chord is posted to
│   │   ├── CatalogQuery.swift     # when a query spells a combo instead of text
│   │   └── BuiltInCatalog.swift   # 100 fallback shortcuts
│   ├── AX/
│   │   ├── MenuScanner.swift      # AXMenuBar recursion, key equivalents, axPath
│   │   ├── MenuTrigger.swift      # AXPress on a menu item (primary trigger)
│   │   ├── MenuScanCache.swift    # menu-cache/ on disk + control.json fingerprint
│   │   ├── CatalogLoader.swift    # background scan + per-app cache
│   │   ├── AppContextService.swift# frontmost app (never itself), bundle id, icon
│   │   ├── AppPermissions.swift   # grant checks
│   │   ├── PermissionCenter.swift # Accessibility / Input Monitoring state
│   │   ├── WindowGeometry.swift   # panel placement next to the focused window
│   │   ├── SystemHotkeyReader.swift # Carbon system shortcuts + SystemHotkeyNames
│   │   └── AppDirectory.swift     # running regular apps for the search scope
│   ├── Input/
│   │   ├── KeyboardMonitor.swift  # global CGEventTap, swallow rules, lazy decoding
│   │   ├── ModifierFlags.swift    # NSEvent.ModifierFlags → ModifierSet
│   │   ├── ShortcutInjector.swift # replays one chord into the front app
│   │   └── ShortcutTester.swift   # head/tail listen-only taps for "test this combo"
│   ├── Storage/
│   │   ├── DataDirectory.swift    # Application Support folder + JsonFileStore
│   │   ├── SettingsStore.swift    # settings.json, single debounced writer, preview session
│   │   └── UsageStore.swift       # usage.json, debounced background writes
│   ├── Services/
│   │   ├── Diag.swift             # the one diagnostic façade: the four os.Logger categories
│   │   │                          # (scan/input/storage/ui) plus the file sink
│   │   ├── FileLogStore.swift     # logs/kaname-<date>.log, rotation, redaction
│   │   ├── ActionRecorder.swift   # last 30 action names, for a crash report
│   │   ├── CrashReporter.swift    # signal handlers, crash/, clean-exit sentinel
│   │   ├── DiagnosticsExporter.swift # one JSON/zip report for a bug report
│   │   ├── ConflictCache.swift    # conflicts-cache.json, read at launch
│   │   └── UpdateChecker.swift    # manual GitHub release check
│   └── Engine/
│       ├── ShortcutEngine.swift   # input router + lifecycle + collaborator wiring
│       ├── EngineState.swift      # @Observable state container
│       ├── PanelSession.swift     # panel menu items, ordering, paging, menu item actions
│       ├── SearchSession.swift    # palette open/close, scope, results
│       ├── CatalogCoordinator.swift # what to scan, stale-result guards, config files
│       ├── RowRunner.swift        # resolve element → press menu → replay chord
│       ├── BindingEditor.swift    # recording target + binding writes
│       ├── LiveTestCoordinator.swift # shortcut test listening and verdict
│       ├── DiagnosticsReporter.swift # support report assembly
│       └── ConflictCenter.swift   # conflict ownership index
├── UI/
│   ├── Surface/                   # one NSPanel hosting panel + search palette
│   ├── Overlay/                   # panel and palette views, cards, rows, footer
│   ├── HUD/                       # 0.75 s "executed" toast
│   ├── Permissions/               # first-run permission guide
│   ├── Settings/                  # seven tabs: general, trigger, appearance, statistics,
│   │                              # conflicts, permissions, about
│   ├── MenuBar/                   # self-owned NSStatusItem and its menu
│   └── Design/                    # Theme, Localization, Interaction, TextComposition
└── Assets.xcassets/

Package.swift                      # KanameCore library + KanameCoreTests
Tests/KanameCoreTests/           # XCTest coverage for Core/Pure
scripts/build_release.sh           # build → sign → notarize (optional) → DMG
scripts/build_swiftc.sh            # fallback build for hosts where xcodebuild cannot run
scripts/install.sh                 # atomic install, refuses ad-hoc; backups go to Application Support
scripts/backup_app.sh              # dated, commit-tagged pre-install backups; keeps the newest 5
scripts/publish_release.sh         # upload the DMG, render the cask, optionally push the tap
scripts/setup_signing.sh           # create the stable "Kaname Local" identity
Distribution/kaname.rb             # Homebrew cask template (placeholders; rendered by publish_release.sh)
```

`Kaname/Core/Pure` 编译两次：一次作为 App 目标的一部分，一次作为 `Package.swift` 里的 `KanameCore` 库。这才让 `swift test`
能在不启动 AppKit App、也不申请权限的前提下检验引擎。

上面这棵树只列出读者认路所需的模块；它不是完整文件清单。`ls Kaname/Core/Pure` 是唯一完整的答案，
这里少了某个文件时，以它为准。

## 运行时总览

```
                       ┌──────────────────────────┐
  frontmost app ──────►│ AppContextService        │
  (pid, bundle id,     │ NSWorkspace activation   │
   focused window)     └────────────┬─────────────┘
                                    │ scan request
                       ┌────────────▼─────────────┐
                       │ MenuScanner (AX)         │
                       │ AXMenuBar → items        │
                       │ 0.35 s per AX call       │
                       └────────────┬─────────────┘
                                    │ [menu entries]
                       ┌────────────▼─────────────┐
                       │ ShortcutEngine           │
                       │ + BuiltInCatalog         │
                       │ 20 s in-memory cache     │
                       └──────┬────────────┬──────┘
                              │            │
                 ┌────────────▼──┐   ┌─────▼─────────────────┐
                 │ PrefixResolver│   │ SearchCorpus          │
                 │ PanelOrdering │   │ tokenizer + pinyin    │
                 └────────┬──────┘   └─────┬─────────────────┘
                          │                │
                 ┌────────▼──────┐  ┌──────▼────────────┐
                 │ OverlayPanel  │  │ SearchPanel       │
                 │ phase: idle/  │  │ (mutually         │
                 │ armed/active  │  │  exclusive)       │
                 └────────▲──────┘  └──────▲────────────┘
                          │                │
                 ┌────────┴────────────────┴────────────┐
                 │ ShortcutEngine / PanelState          │
                 │ heldModifiers, highlightedRowIDs,    │
                 │ completedRowID, selectionIndex       │
                 └────────▲─────────────────────────────┘
                          │ events
                 ┌────────┴─────────────────────────────┐
                 │ KeyboardMonitor → HotkeyMatcher      │
                 │ gesture / 3 hotkeys / secure input  │
                 └──────────────────────────────────────┘

  JsonFileStore ◄── SettingsStore ──► every component
                ◄── UsageStore    ──► UsageSorting (statistics list)
  PanelPlacement ──► OverlayPanelController geometry
  SystemHotkeyReader (Carbon) ──► ConflictDetector ◄── scan entries
  AppDirectory (running apps) ──► search scope / conflict scan
  MarkdownExporter            ──► Export Markdown (NSSavePanel)
  UpdateChecker               ──► api.github.com releases/latest
                                  (manual, Settings → About)
```

## 菜单扫描（辅助功能）

`MenuScanner` 从前台应用的 `AXUIElement` 出发，沿着这棵树走：

```
AXMenuBar
└── AXMenuBarItem ("File")
    └── AXMenu
        ├── AXMenuItem ("New", ⌘N)
        ├── AXMenuItem ("Open…", ⌘O)
        └── AXMenuItem ("Open Recent") → AXMenu → …
```

对每个 `AXMenuItem` 它读：

| 属性 | 用途 |
| --- | --- |
| `AXTitle` | 菜单项标签 |
| `AXMenuItemCmdChar` | 快捷键的字符键 |
| `AXMenuItemCmdVirtualKey` | 虚拟键码，在没有暴露字符时使用 |
| `AXMenuItemCmdModifiers` | 快捷键的修饰键掩码 |
| `AXEnabled` | 该菜单项当前是否可操作 |
| `AXChildren` | 子菜单（递归） |

设计要点：

- **菜单路径是数据。** 面包屑"File → Open Recent → …"和面板里每个菜单项下方的备注都来自这次遍历本身，所以它们跟随 App 使用的语言与结构。
- **没有快捷键也仍是菜单项。** 缺少 `AXMenuItemCmdChar` 或 `AXMenuItemVirtualKey` 的菜单项会变成一个带*空组合键*的菜单项：
  Kaname 仍不会去猜 App 没有声明的快捷键，但这个菜单项仍然可达——按压它就能触发（`MenuTrigger`），那是到达它的唯一方式。
  这类菜单项排在所有有组合键的菜单项之后，快捷键列留空，也永不匹配修饰键前缀（它们没有可用来收窄的修饰键）。
  这里从 Menu-Bar-Search 借来的一条结构规则：有子节点的菜单项是子菜单的父级，只遍历、不记录——除非它自己也带快捷键。
- **Apple 菜单默认关闭。** 它的条目属于系统，而不属于前台 App，会把每张列表都塞满 App 并不拥有的菜单项——所以
  `showAppleMenu` 默认 `false`（Menu-Bar-Search 的 `showAppleMenu` 设置）。打开它就会包含这些条目；两种情况下菜单栏索引都会计入，
  所以缓存下来的菜单路径不会因为开关翻转而移位。
- **AX 索引路径。** 每个被记录的条目都携带它在菜单树中的位置（`axPath`，例如 `"2,0,5"`——同样来自 Menu-Bar-Search 的 `pathIndices`）。
  空组合键没有组合键可以拿来让 id 或使用键唯一，而两个动态条目可能共享同一路径与标题；没有索引，它们会静默合并成一个菜单项，
  只剩一个点击目标与一套统计。
- **深度与数量都有上限。** 递归有界并防环（菜单包含自己）；过大的菜单会被截断，而不是一直扫下去。
- **超时。** 应用元素的 `AXUIElementSetMessagingTimeout` 设为 0.35 秒。卡死的 App 无法无限拖住扫描队列。
- **线程。** 扫描在专用串行队列上发生。结果投给主 actor；UI 状态只在主 actor。
- **读谁的菜单。** 菜单栏恰好有一个拥有者，而在切换过程中它不总是前台那个：`AppContextService` 优先用
  `NSWorkspace.menuBarOwningApplication`，退回 `frontmostApplication`（Menu-Bar-Search 的 `menuBarOwningApplication`）。
  Kaname 自己仍然永远不是来源——否则激活它自己的窗口就会用兜底目录替换真 App 的快捷键。
- **扫描会说明为什么它是空的。** `MenuScanner` 在遍历前检查 `AXIsProcessTrusted()`，每个结果都带一个 `ScanState`：
  `.ok`、`.noMenus`（App 什么都没暴露）、或 `.permissionDenied`（根本读不到——Menu-Bar-Search 的 `initState`）。
  空列表与"根本没读成"对用户看起来是一样的，所以面板的空状态与"内置"徽标会说明是哪一种，而不是两者都读成"没有匹配的快捷键"。
- **缓存，两层。** 内存里按 App 标识为键、保留 20 秒。磁盘上每个 App 一个 JSON 条目（`menu-cache/menus-<identity>.json`），
  外加一个控制文件，记录这些条目是在哪些设置下写入的（Menu-Bar-Search 的缓存）。切换 App 正是磁盘缓存存在的理由：
  它交还用户上次为那个 App 看到的菜单项，而不是再走一遍菜单栏。规则写在 `MenuCachePolicy` 里：
  - **指纹。** 只有当条目是在当前设置下写入时才使用；影响扫描的设置（今天只有 `showAppleMenu`）与条目 schema 都进指纹，
    改动任一项都会让所有条目失效，而不必去读其中一条。
  - **十分钟上限。** App 运行期间菜单会变。十分钟足够长，重开同一个 App 的面板——或重启 Kaname——能跳过 AX 遍历；
    也足够短，过期的列表会很快刷新。窗口内的按压会重走该菜单项的 `axPath` 并校验标题，所以缓存之下变了的菜单会解析成 nil，
    永远不会解析成顶替它的那个菜单项。
  - **强制重载是一次显式刷新。** 搜索面板的范围刷新、设置变更、授权完成都会绕过两层缓存并重扫。App 启动/退出只丢内存快照：
    某个 App 启动，并不能说明用户正在用的那个 App 的菜单有什么变化。仍然没有实时菜单栏观察者，所以 App 内部的菜单编辑要到下一次扫描才被看到。

从磁盘恢复的快照携带菜单项但不携带元素——`AXUIElement` 无法序列化——所以按压这类菜单项时，会用
`MenuScanner.element(atAxPath:pid:expectingTitle:)` 按快照的 pid 重走它的 `axPath`，这是几次 AX 调用而不是一次扫描，
结果会记忆在快照上。

`MenuScanner` 在 `CatalogSnapshot.elements` 里按菜单项 id 保留每个已记录条目背后的 `AXUIElement`。执行读的就是这张表：
按压菜单项是主触发器，回放组合键是兜底（见[面板交互与执行](#面板交互与执行)）。兜底目录条目没有 AX 元素，所以它们只能回放组合键。

## 兜底目录

`BuiltInCatalog` 含 100 条常见 macOS 快捷键（系统、文本编辑、Finder 与截图）。它在以下情况使用：

- 前台 App 没有菜单栏（部分浮层、游戏与自绘 UI），或
- 辅助功能权限未授予，或
- 扫描失败或超时。

目录可在设置里关闭。目录条目标为 `builtIn` 且没有 AX 目标，所以它们从不被执行，从搜索或面板里都不执行；只能复制。
当实时菜单项与目录条目占用同一组合键时，两者仍会一起被报告。

## 数据模型与索引

`KeyChord` 是一次或多次按键的标准表示。一段是"一个键 + 一组修饰键"；一条组合键是一串段（例如 `⌘K ⌘C`）。
标准化会排序修饰键、解析左右变体，并把虚拟键码映射成显示字符。

`BindingItem` 是展示给用户的一个菜单项：

- 一个展示身份，外加用于统计的 `usageKey`，形如 `bundleID|chord`（`*` 标记没有所属 App 的系统与内置条目）
- 组合键
- 标题与清洗后的描述
- 菜单路径（分组标题）与来源 App
- 来源：实时菜单、内置目录，或一条只读的全局系统快捷键
- 启用状态（来自 `AXEnabled`）

AX 层保留执行所需的元素引用；`BindingItem` 本身保持纯粹。

`PrefixResolver` 按"当前前缀之后的下一个段"给绑定分组。它以很低的开销回答三个问题：

1. 这个前缀之后可以接什么？
2. 这个前缀自己还有后续吗（所以组合键应当保持打开）？
3. 按下的键是否不存在（所以面板关闭、HUD 可以显示）？

`ConflictDetector` 按标准化后的组合键给绑定分组。标题、分组与来源都相同的条目被当作重复而不是冲突。
真正不同的绑定组成一组时，会给每个受影响条目标 ⚠︎，并喂给 **设置 → 冲突**。冲突只是信息：决定哪个菜单项真正拿到快捷键的
是 macOS，不是 Kaname。

`SearchCorpus` 每份目录构建一次，并预先算出查询可能命中的每一个"草堆"：小写标题、它的各种拼音形式、拉丁词首字母、
菜单路径、渲染后的组合键、原始键词元，以及修饰键单词/符号。`SearchIndex` 仍是一个薄的、向后兼容的入口，每次调用构建一份语料。

分词器把查询转小写、把 `+` 当作分隔符、按空白切分，所以词项是**无序**的：`com op x`、`op cm x` 与 `cmd+opt+x`
的搜索方式相同。每个词项都必须命中（AND）；一个词项可以匹配修饰键别名（`com`/`cmd`/`command`/`cm`/`⌘`、
`op`/`opt`/`option`/`alt`/`⌥`、`ct`/`ctl`/`ctrl`/`control`/`⌃`、`sh`/`sft`/`shift`/`⇧`）、一个精确键词元，
或通过精确/前缀/子串/子序列打分命中任一草堆。`Pinyin` 为中文标题补上全拼（`jian qie`）、带空格的分音节与首字母（`jq`），
这就是中文菜单项不必输入汉字也能被找到的原因。结果按分数顺序返回并截断；`total = Σ 每词项的最佳分`。不持久化任何东西。

**菜单路径按层级加权。** 语料为每一层菜单保留一个草堆，最近的祖先在前，第 *n* 层的命中按它模糊分的 `1 / 2^(n+1)` 计入——
来自 Menu-Bar-Search 的 `levelAdjust *= 2`，并多加一步，好让即使最近的祖先也被折价。叶子永远赢：像"View"这样的顶层名字是几十个菜单项的祖先，
所以搜 `view` 会把"View Source"（标题前缀）排在"Show Sidebar"（位于 View 菜单内）之前，而直接父级里的词排在顶层菜单里的词之前。
把路径拼成一个草堆会给每一层与菜单项自身标题同样的权重，这正是菜单名曾经压过它内部菜单项的原因。

## 系统热键与冲突

macOS 用窗口服务器注册自己的全系统快捷键（聚焦搜索、调度中心、截图、切换输入源……）。它们不属于任何 App 的菜单栏，
所以 `MenuScanner` 从来看不到它们。`SystemHotkeyReader` 通过 Carbon 的 `CopySymbolicHotKeys` 读取，它返回一个字典数组：

| 键 | 用途 |
| --- | --- |
| `kHISymbolicHotKeyCode` | 该快捷键的虚拟键码 |
| `kHISymbolicHotKeyModifiers` | Carbon 修饰键掩码（⌘、⇧、⌥、⌃） |
| `kHISymbolicHotKeyEnabled` | 已禁用的条目不收集 |
| `kHISymbolicHotKeyDescription` | 文档里叫标题——**在写这段时每一台 Mac 上的每一条都是空的**（本文所用机器上 233/233） |

规则：

- 只收集**已启用**的快捷键，且只收集修饰键组合与键码可识别的。
- 系统条目使用 `BindingSource.system`，不带 bundle identifier，归在本地化的"系统热键" / "System hotkeys" 标题下。
- **名字来自 `SystemHotkeyNames`，不来自系统。** 描述字段是文档里的常量，macOS 从不填它，所以读取器会去一张"标准 Mac 自带分配"表里查这个组合键
  （⌘Space → 聚焦搜索，⇧⌘3 → 截图，⌃↑ → 调度中心，⌘M → 最小化……），并用界面语言作答。不在表里的组合键——因为用户重新分配过，
  或因为它是 macOS 列为已启用但背后没有功能的约 55 个条目之一（⌃F4、⌃↩、⇧A……）——就把组合键留作标题并标注为系统热键；
  它不再被破折号取代，那个破折号过去读起来像"没有快捷键"。
- **这张表是刻意"参考"而不是"信任"的。** Carbon 表里也有过期槽位；某个组合键存在只意味着"macOS 在这里注册过东西"，
  这正是冲突列表对它的全部断言——不多不少。
- 它们住在 `EngineState.systemBindings` 而不是 App 的目录里，所以 App 自身的扫描仍是它菜单的一份干净画面。它们在面板里作为三个分区中的第二个出现
  （`PanelSections`）——系统占用的组合键该紧挨着 App 的菜单项，因为"我按这个为什么没反应"这个问题就是在那里被问的——
  而未选范围的搜索面板会把它们与前台 App 的条目（`searchItems`）一起搜，因为"⌘Space 归谁"同样是一个可搜索的问题。
- **第三方配置绑定是第三个分区，一个工具一张卡，默认关闭。** `ConfigTool`（Karabiner、skhd、Keyboard Maestro、BetterTouchTool、Hammerspoon、Alfred）
  同样把它们挡在 App 的目录之外。`AppSettingsSnapshot.showConfigToolsInPanel`（默认 `false`，设置 → 冲突 → 配置文件）决定面板是否绘制该分区：
  隐藏时不生成卡片、不计入 `cardAndHeadingBudget`、没有行进入页码预算，搜索面板的未选范围列表与面板的内联筛选语料也都不含工具行。
  它只是一个**显示**开关——`scanConfigFiles` 仍然管扫描，`configBindings` 与冲突列表不变，组合键问答（"这条还归谁"）在工具行隐藏时仍然读它们，
  因为隐藏一张卡并不会让冲突的工具不再占用某个组合键。每张工具卡默认折叠但仍渲染标题与行数，所以"有 N 条配置快捷键"不必占行就能看见；
  点某张卡的标题只展开或折叠**那一张**（`PanelState.expandedTools`，按 `ConfigTool` 为键），同一帧里重算标题预算。筛选生效期间所有卡自动展开
  （`ToolSectionFold`）：折叠卡后面的匹配会被计入却够不着。用户自己的折叠选择永不被覆盖——清掉筛选会精确还原他留下的开卡状态。
  这些行可以复制、收藏、搜索，但**永不执行**：激活返回 `.unsupportedSource`，永远到不了 `RowRunner`。
- **六个动整台 Mac 的动作根本不执行。** 睡眠（⌥⌘Power）、重启（⌃⌘Power）、关机（⌃⌥⌘Power）、锁屏（⌃⌘Q）、
  退出登录与强制退出登录（⇧⌘Q、⌥⇧⌘Q）以及强制退出（⌥⌘Esc）在 `RestrictedActionPolicy` 里按组合键匹配，不按标题；
  同一组合键在菜单分区与系统分区都受限。点击只会复制组合键而不是执行，受限行的右键菜单只给两个复制动作，
  `PanelSession` 与 `RowRunner` 都拒绝执行路径。⌘Q 刻意不在集合里：它退出前台 App，不是 Mac 会话。
- 列表在启动时读一次、在界面语言变化时（分组标题是本地化的）、以及每次 App 被重新激活时读，所以在系统设置里做的编辑不必重启就能被看到。
- `ConflictDetector.conflicts(in:external:)` 把 App 条目、系统条目与配置文件条目按标准化组合键分组。标题完全相同的视为重复；真正不同的绑定成为冲突。每个成员——包括系统条目——都会在面板里标 ⚠︎。
- **只读。** Kaname 从不绑定、修改、禁用或重映射任何系统快捷键；它只报告撞车。读取这张列表不需要额外权限。

### 一次冲突有多要命

一张"两样东西都想要 ⌘⇧4"的平铺列表会引出下一个问题——*那到底是谁先开火？*——而它答不上来。三个纯类型提供答案，全都不需要键盘就能测：

**`ShortcutLayer`** 把每个绑定放到 macOS 的事件栈上：`driver`（Karabiner）→ `eventTap`（skhd、BetterTouchTool、Keyboard Maestro）→ `system` →
`globalHotKey`（Hammerspoon、Alfred）→ `otherGlobal` → `menuItem`。越低越赢。`ShortcutLayer.classify(_:)` 读的是*工具*而不只是来源：
六个配置扫描器共用 `BindingSource.configFile`，只看来源会把一条 Karabiner 规则排到菜单项同一层。

**可以叫一条 Karabiner 规则让路，而这是 Kaname 对它能做的唯一一件事。** Karabiner 在驱动层抢走物理键盘，通过自己的虚拟键盘重新投递结果，
所以绑在触发键上的规则（`left_command` 配 `to_if_alone` 是常见形状）在面板打开时照样开火，而面板——它只能看到会话层事件——收到的是规则的输出
而不是那次修饰键按压。tap 之上的任何东西都没法通知 Karabiner，而吞掉随之而来的 `flagsChanged` 只会把前台 App 一起饿死。
反向通道是 Karabiner 自己的变量命名空间：`KarabinerPanelSignal`（纯）命名那个变量（`kaname_panel`）并构建 `--set-variables` 载荷，
`KarabinerBridge` 在自己的工具队列上每次状态变化跑一次 CLI——合并、值与上次写入相同时跳过、CLI 缺失时日志里最多一条警告、
退出时做一次阻塞写以免退出把它截断——而 `ShortcutEngine.signalKarabiner()` 在每个生命周期边上陈述面板的可见性：`start()`（顺带清掉强退留下的一颗陈旧 1）、
面板激活、关闭、`stop()`、以及开关翻转。用户那一半是自己规则上的一条条件：
`conditions: [{"type": "variable_unless", "name": "kaname_panel", "value": 1}]`——用 *unless* 而不是 *if*，
所以规则只在面板关闭时生效；`KarabinerScanner` 看不到这样的规则（它只保留带强制修饰键的 manipulator），所以这个开关是两者相遇的唯一地方。
设置项是 `karabinerPanelSignalEnabled`，默认开，设置 schema 11，位于 **设置 → 触发**，卡片标题是 **面板打开时通知 Karabiner**。

**`ConflictCategory`** 按后果给发现分类，并且命名的是"哪两样东西撞了"，而不是严重度：

| 类别 | 含义 |
| --- | --- |
| `.menuOrder` | 同一个 App 的两个菜单项占用该组合键。macOS 按菜单顺序匹配；没坏，但其中一个够不着。 |
| `.systemShadow` | 一条已启用的系统快捷键盖住了这个 App 的菜单项，所以该菜单项永不开火。 |
| `.toolShadow` | 第三方工具的规则盖住了某个菜单项或系统快捷键。 |
| `.systemVsSystem` | 两条 macOS 快捷键占用同一组合键。 |
| `.systemVsTool` | 系统快捷键与某工具的规则撞车。 |
| `.toolVsTool` | 两个工具占用该组合键。 |
| `.toolSelfOverlap` | 同一个工具把同一组合键绑了两次。 |

**`LayerVerdict`** 说明谁赢：某一个绑定严格更低时是 `.winner`；多个共享最低层时是 `.tied`——注册顺序决定，而没有配置文件记录它，所以它如实这么说
而不是猜——当每个绑定都是前台 App 的菜单项、事件栈无话可说时是 `.menuOrder`。

`ConflictFilter` 在 **设置 → 冲突 → 发现** 里按两条独立轴收窄列表：撞车的*种类*（`ConflictCategory`——同一个 App 的菜单、被 macOS 挡住、被工具挡住、
某工具自己的两条规则、两条系统快捷键、macOS 对工具、两个工具）与*拥有者*（发现里出现的任何 App、仅全局、或全部 App）。
列表跨所有运行中的 App 构建——每个 App 一次扫描，缓存优先——因为"这个撞车是哪个 App 的"是你不在那个 App 里时才会问的问题。
因为种类命名了撞车的是哪两样东西，它也就说明了修复住在哪：系统设置、某个工具的配置文件、或者根本无处可修。
每一行显示类别徽标、带该层自身解释的裁决、每个成员的徽标，以及一个 **测试这个组合键** 按钮。

### 实时快捷键测试

`LayerVerdict` 靠文件推理，可能出错。`ShortcutTester`（`Core/Input`）通过观察一次真实按键把它定下来：它装**两个只监听的事件 tap**，
一个在 tap 链的最前，一个在最后。一个到达最前却从不到达最后的键，是在中间被另一个 App 的 tap 吞掉了——这是事实，不是推断。
tap 层之上什么都观察不到，所以它退回"是否有 App 到了前台"。

`LiveTestVerdict` 把那次观察变成六种结果之一，并带明确的语气（`confirmed` / `informative` / `inconclusive`），同时说清自己的盲区：
越过 tap 层，一条系统快捷键可以拿走某个键而不留痕迹。测试监听期间，`ShortcutEngine` 挂起所有面板行为与全部吞键，
所以 Kaname 永远不会是那个吃掉这个键的元凶。

## 配置文件来源

改写键盘的工具把快捷键放在文件里而不是菜单栏里，而且它们都在 App 菜单所在的层*之下*挂键盘。没有它们，冲突列表只能说"两样东西都想要 ⌘⇧4"，
永远说不出"⌘⇧4 到不了 Safari"。

`ConfigFileScanner` 知道这张清单；每个工具有一个扫描器，它的 `parse` 接受文本、数据或已解码的 plist，它的 `scan` 负责找到文件。
这个切分让解析器能对着 fixture 测试，而不是对着真实的 `~/.config`。

| 工具 | 文件 | 层 |
| --- | --- | --- |
| Karabiner-Elements | `~/.config/karabiner/karabiner.json`——只看复杂修改，且只看带*强制*修饰键的 manipulator（裸键是重映射，不是快捷键） | `driver` |
| skhd | `~/.config/skhd/skhdrc` | `eventTap` |
| Keyboard Maestro | `Keyboard Maestro Macros.plist`——`MacroTriggerType == "HotKey"`，跳过未激活的宏与组 | `eventTap` |
| BetterTouchTool | 最新的 `btt_data_store.version_*`，**只读**打开；`BTTTriggerClass == "BTTTriggerTypeKeyboardShortcut"`，跳过 App 范围内的条目 | `eventTap` |
| Hammerspoon | `~/.hammerspoon/init.lua`——参数为字面量的 `hs.hotkey.bind`；变量修饰键表会被丢弃而不是半解析 | `globalHotKey` |
| Alfred | `Alfred.alfredpreferences/workflows/*/info.plist`，跟随 `prefs.json` 找同步偏好；`hotstring` 为空的触发器是未分配，跳过 | `globalHotKey` |

配置绑定携带 `configTool`，它喂给 `ShortcutLayer` 并让 id 按拥有者保持唯一。它们**不**并入 App 的目录：没有菜单项可按、没有元素可触发，
所以放进 App 自己的块里只是一行看起来能点的装饰。它们改以独立分区到达——一个工具一张卡，默认折叠（`PanelSectionID.tool`、
`PanelState.toolSectionExpanded`）——在那里可以搜索、复制、收藏但永不执行；激活一条配置行只会复制它的组合键。它们也喂给冲突检测、组合键查询与设置列表。

扫描**默认开着**，**设置 → 冲突 → 配置文件来源** 可以整体关掉它，此后会忘掉已发现的内容，并且不再打开 Kaname 自己数据目录之外的任何文件。
扫描在启动时和按需运行，刻意*不*在每次切换 App 时跑：这些文件在用户编辑它们时改变，而不在他换 App 时改变。

### 组合键查询

冲突列表只显示撞车，所以一个独占地被某样东西拥有的组合键过去会查回来空，而空列表读起来像"没扫过"而不是"没有别人想要它"。
`ComboQuery` 解析一个拼出组合键的查询（`cmd shift 4`、`⌘⇧4`、`opt cmd t`）——每个词元必须是修饰键或一个键，必须恰好一个键且至少一个修饰键，
这正是让 `cmd safari` 保持为普通文本搜索的原因——而 `ComboLookup` 回答谁拥有它、或者说它是自由的，匹配用的是 `ConflictDetector` 分组所依据的同一个组合键键值，
所以两者永不可能不一致。

## 排序

三个不同的问题、三种不同的顺序，把它们混在一起曾经是一个真实的 bug：

- **面板按它选定的顺序**（`PanelSortOrder`）。默认的**按修饰键**是参考卡顺序（`PanelOrdering`）：段数少的在前，然后按重要性排修饰键集合
  （⌘、⌥、⌃、⇧），再按键，功能键按它名字里的那个词排序（`f`、`f1`、`f2`……`g`），没有快捷键的菜单项排在所有组合键之后。
  **按菜单分组**让每个顶层菜单在菜单栏顺序里保持连续（`axPath` 的第一段），菜单内部仍用同一套快捷键顺序。没有辅助功能路径的条目跟在有排名的菜单之后，
  空组最后。`usageSortField` 不影响这两种顺序。
- **搜索面板按匹配顺序**——`SearchCorpus` 打分，在*搜索面板*一节描述。在那里面选一种排序等于丢掉回答查询的那个排名。
- **统计页是一张平铺列表，按 `usageSortField` 顺序**（`UsageSorting`），每个 `usageKey` 一行：快捷键领衔，所属 App 与命令描述是这一行的备注，
  同一个组合键被两个 App 使用就画成两行。频率不再排序任何东西；三个字段就是全部选择。

| 排序方式 | 行的顺序 |
| --- | --- |
| 快捷键（默认） | `PanelOrdering.compare`，所以统计页与面板对"沿键盘走"的理解一致；没有组合键的行排在所有组合键之后。 |
| App | 本地化 App 名，然后是该 App 内的快捷键。 |
| 命令 | 本地化菜单项标题；没有已知标题的行排最后。 |

禁用菜单项保留它在顺序里的位置——比较器看组合键，不看 `AXEnabled`——它们只是画成灰的，并在**显示不可用菜单项**关闭时整体隐藏。

按住修饰键时，能从它们到达的菜单项彼此之间保持同一顺序，这正是"按下的修饰键越多、收窄后的列表重新排序"的原因。**收藏置顶**开启时收藏浮在所有内容之上。
Shift 提示层（`ShiftHintLayer.labels(for:)`）每次重建都从当前显示的序列重建，所以 `0`–`9` / `a`–`z` 跟随屏幕上的顺序，而不是固定绑在某个菜单项上。
菜单路径随菜单项一起走，形式是标题与组合键之间的一条小备注而不是分区标题，这也是排序再也不能把 ⌘ 块切成两半的原因。

`UsageStore` 按 `bundleID|chord` 记录一个计数与最后使用时间戳，所以同一个快捷键在两个 App 里分开跟踪，本地化标题变化也不会丢掉历史。
系统与内置条目用 `*|chord`，报告为 **系统 / 内置** / **System / built-in**；配置工具条目用工具的原值。
`UsageBreakdown.entries(records:known:)` 把每条记录与它命名的目录条目连接起来，并且**不**合并拥有者，所以共享一个组合键的两个 App 是两行；
`UsageSorting.entries(_:by:appName:)` 按快捷键、App 或命令给这张表排序。模型维护一个累计的 `totalPresses`，记录上限 800 条，按最近最少使用裁剪。
它从不存储原始按键事件、输入的文本或窗口内容。重置统计会清掉记录；设置不受影响。持久化见[持久化](#持久化)。

## 触发管线

`KeyboardMonitor` 在辅助功能授权下装一个全局事件 tap。它观察 `flagsChanged` 与 `keyDown`（外加 tap 被禁用的通知），并把事件原样放行，例外是：

- 三个录制热键（面板、搜索、切换）被消费掉，前台 App 收不到——走的是激活所用的同一条 `HotkeyMatcher` 规则，包含 Hyper 超集宽容；
- 面板活动期间，它的导航键（↑/↓/←/→、⌃F/⌃B/⌃N/⌃P）、每个启用分页对的字符（`,`/`.`、`[`/`]`、`-`/`=`、`;`/`'`）、
  两个动作键被录制到什么（含小键盘 Enter 别名）、Esc 以及一个裸 `/` 都会通过 `updateCapturedKeys` 被捕获。捕获 `/` 是为了让背后的 App 也看不到它——
  在浏览器里那个键是*快速查找*，否则它会在 Kaname 刚打开的面板之上再开一层；
- **完成**一个快捷键的键不被吞掉：面板关闭，事件继续到前台 App。
- 被捕获键的重复也被吞掉。放行会让面板选区移动、同时让前台 App 滚动；引擎另外会为不该二次触发的动作忽略重复。

字符是惰性解码的：`KeyboardMonitor` 只在某个界面正在接收按键、或在录制绑定时才读 Unicode 字符串（`updateDecodesKeyEvents`），
因为 tap 看到会话里的每一次按键。面板活动期间，`ShortcutEngine` 还会用 `updateCapturedCharacters` 发布启用的分页字符，
这样吞键检查比较的是布局实际产生的字符（拼音布局上的 `；`），而不是写死的 ASCII 键码；键码仍是没有解码字符的事件时的兜底。
热键匹配在虚拟键码上做，所以不解码也能工作。

它从不记录事件。它唯一合成的东西是一条组合键，且只按请求：菜单项执行时由 `ShortcutInjector` 投递（见[面板交互](#面板交互与执行)）。
run-loop 源挂在**带自己 run loop 的专用线程**上，所以卡死的主线程既拖不住 tap 也冻不住键盘；吞键决定在那个线程上、依据引擎发布的快照回答
（`ComposedSwallow.decide` 作用于 `ComposedSwallowState`），事件通过 `InputMailbox` 交给主 actor 上的引擎，邮箱最多持有 32 个事件、
每跳按批投递，并在丢弃导致面板对键盘的认知过期时追加一个 `.interruption`。如果 tap 在某个系统上收不到事件，`PermissionCenter` 会退而建议输入监控。

`ShortcutEngine` 跑一个三相状态机。v2.1.0 把旧的 `browsing`/`pinned` 一对改名为单一的 `active` 阶段，因为现在每个面板都是持久的：

| 阶段 | 含义 | 进入方式 | 离开方式 |
| --- | --- | --- | --- |
| `idle` | 什么都没显示 | 关闭、松开的按住、Esc | 按住延迟、触发键双击、某个热键 |
| `armed` | 正在计时一次按住；面板还不可见 | 触发键被松开，或另一个键被按下 | 延迟走完（→ `active`） |
| `active` | 面板可见且持久 | `activatePanel()` | 完成的快捷键（高亮约 0.4 秒后）、Esc、再按一次面板热键 |

| 触发器 | 检测方式 |
| --- | --- |
| 修饰键手势，按住 | `modifierTriggerEnabled`；选定的 `triggerKey` 被按住 `holdDelay`（默认 0.5 秒，0.3–0.9 秒按 0.1 秒步进），期间没有其他键 |
| 修饰键手势，双击 | `modifierTriggerEnabled`；`triggerKey` 两次干净的按下与松开，中间没有其他键。只有两次点击之间的间隔被计时：`DoubleTapTiming` 从系统双击速度推导它，钳在 0.25–0.6 秒。慢的按下仍算数，长的第二次按下仍能完成 |
| 触发键 | 任意非 Shift 修饰键、左 Control、左 Option、左 Command、右 Command（默认），或右 Option。`flagsChanged` 的键码区分左右；不支持组合 |
| 面板热键 | 全局热键，默认 ⌃⌥⌘K；切换面板，并在前台 App 变化时原地刷新 |
| 搜索热键 | 全局热键，默认 ⌃⌥⌘F；打开或关闭搜索面板 |
| 切换热键 | 全局热键，默认 ⌃⌥⌘S；在面板与搜索之间互换（见下） |
| 热键开关 | `hotkeyTriggerEnabled` 独立于手势地给三个热键上闸；两个开关都关时什么都不触发（暂停态） |

附加规则：

- **手势拥有它的键。** `modifierTriggerEnabled` 开着时，tap 会吞掉 `triggerKey` 物理键码的按下与松开，所以前台 App 永远看不到那个"可能触发面板"的修饰键边缘；
  被取消的按住不会被回放。Shift 与 Caps Lock 永不吞。录制热键期间，任何修饰键都不吞。热键路径只在 `hotkeyTriggerEnabled` 开着时发布自己的吞键规则。
- **触发的那次按压不是筛选词元。** `activatePanel` 让每个面板都从整张列表开始：按住、双击与热键都以空前缀、空筛选打开，所以每个菜单项都是一个完整组合。
  召唤的那次按压停在 `triggerNarrowPending` 后面，直到它的键松开，而触发键自己的物理键永不入队。面板打开期间，每个修饰键的**按下沿**向有序筛选追加一个词元
  （`handleModifiers`），前缀被清空以免同样的修饰键收窄两次，`panel.heldModifiers` 跟随 `filter.modifiers`。孤立的 ⇧ 是提示层，不是一个维度。
  标题栏的 ⌃ ⌥ ⇧ ⌘ 芯片仍是独立的粘性集合（`panel.latchedModifiers`）：筛选为空时，一次勾选通过纯修饰键前缀收窄；一旦筛选非空，收窄就归筛选管。
  勾选会一直留到被取消勾选或面板被关闭。
- 按下一个非修饰键会取消待定的按住；在 `active` 里，这个键被交给完成/组合键解析器。
- **松开修饰键不会关闭面板。** 没有空闲计时器，也没有自动隐藏任务；面板由 Esc、面板/切换热键、或一个完成的快捷键关闭。
  切换前台 App 或活动 Space 也会关闭它，因为它的内容属于它被打开时所覆盖的那个 App。
- 显示任何东西之前都会检查安全输入；若它在活动，面板隐藏、触发器被忽略。
- **面板与搜索互斥。** `showSearch()` 会先关闭面板，而 `activatePanel()`（经面板热键）不允许叠在搜索之上；切换热键编码了这条规则：
  搜索可见 → 面板，面板可见 → 搜索，都不可见 → 面板。
- **触发器只教一次。** `AppDelegate` 在引擎启动后从 `UserDefaults` 读 `KanameTriggerTipShown`；若未设置，一个 HUD 说 **按住 ⌘ 或双击它打开面板**，并写入该键。
  **设置 → 触发** 里不再有重播它的按钮。
- **面板顺序是被通告的，不是被标注的。** 面板可见时改变 `panelOrder` 会用一行 HUD（`showHUD`）显示它的名字；面板自身不带常驻模式标签，所以这次变化是一次性通知。
  面板隐藏时在设置里改它则保持安静。

### 引擎状态与按键路由（v2.2.0 之后的开发）

*历史记录。* 从这里到 *按状态切分的 OverlayView* 的几节逐步描述一次重构。它们被保留是因为其中的推理解释了当前形状；其中的计数与文件边界属于它们写作时的那棵树。

引擎的决策那一半一直在搬进 `Core/Pure`，那里是 XCTest 套件够得着的地方：

- **`KeyEventRouter` 取代 `handleKeyDown` 里的内联决策树。** 引擎现在调用 `KeyEventRouter.route(...)` 并执行返回的 `KeyDownAction`；
  路由顺序不变（任意阶段的热键 → 阶段转换 → 面板自己的键 → 组合键组装），所以面板行为照旧，但每个分支都是一个命名过、被测试过的动作，
  而不是长方法里的嵌套 `if`。characterize 测试按分支把既有行为钉住。
- **`ModifierDoubleTap`、`DoubleTapTiming` 与 `HyperEscape` 是两个手势状态机。** 触发键双击钉住与"hyper 轻点当 Escape"手势过去在引擎上养着三个日期/标志字段
  （`lastCommandDownAt`、`hyperArmedAt`、`hyperUsedKey`），计时规则写在内联；现在各是一个带自己测试的纯结构体。`ModifierDoubleTap` 读触发键的按下状态，
  所以同一个机器服务六个触发键；`DoubleTapTiming` 从系统双击速度推导自己的窗口（钳在 0.25–0.6 秒），这就是没有双击滑块的原因；
  `HyperEscape` 仍拥有 1 秒的松开窗口与"期间用过某个键"的标志。
- **`FavoritesPolicy` 汇总三个收藏布尔。** 星标开关（`showsFavoritesOnly`）与两个设置（`pinFavoritesToTop`、`favoritesCanBeFiltered`）过去被分别传给每次重建，
  并在两个缓存键（`OrderedHitsKey`、`RowBudgetKey`）里重复；现在一个缓存键持有一个 `FavoritesPolicy` 值，所以三者任一变化会同时让顺序与预算失效。
- **`SearchSnapshot` 是搜索面板的状态。** `comboAnswer`、`searchQuery`/`searchResults`/`searchSelection` 三件套、`isSearchVisible` 与三个范围发布器
  合成一个被观察的 `search` 快照；范围图标留在引擎侧，因为它是个 `NSImage`。只有 `query` 变化才重跑搜索——`refreshSearch()` 把结果/选中/可见性写回快照而不会打转。
- **`EnginePhase` 取代引擎私有的 `Phase` 枚举**，好让纯路由器不必导入引擎就能读面板阶段。

### 引擎/状态切分：`EngineState` 作为状态容器（开发，P0-2）

`ShortcutEngine` 过去是一个 `@MainActor` 类，持有约 40 个 `@Published` 值、会话状态、缓存、手势机与进行中的任务，旁边是每个协作者与每个行为方法。
P0-2 这一步把它一分为二，行为零变化：

- **`Core/Engine/EngineState.swift`** 是一个 `@MainActor @Observable final class EngineState`，持有 UI 绑定的、以及协调逻辑读写的一切：
  被观察的值（`panel`、`settings`、`search`、`conflicts`、`catalogSize`……）、会话状态（`phase`、`prefix`、`previousModifiers`、
  `ModifierDoubleTap`/`HyperEscape`/`ModifierTapTracker` 三个机器、`lastSecureInputLog`）、目录与缓存（`catalog`、`catalogGeneration`、`orderedHitsCache`、
  `rowBudgetCache`、`usageBreakdownCache`、`conflictIDs`）、搜索范围（`searchScopeCatalog`、`searchCorpus`、`searchCorpusKey`）以及进行中的任务句柄。
  它还从这些状态算出搜索面板的标题/图标（`searchPaletteTitle`、`searchPaletteIcon`）与过滤后的冲突列表（`visibleConflicts`、`conflictTypeOptions`）。
- **两个协作注入点让容器保持纯粹。** `defaultTitle` 由引擎用本地化 App 名设置；`searchChangeHandler` 是引擎的 `refreshSearch`，装上后查询变化就重新搜索，
  而容器不必知道目录的存在。`search` 的 `didSet` 只在*查询*变化时才触发 handler，所以 `refreshSearch()` 把结果/选中/可见性写回不会打转。
- **`ShortcutEngine` 现在是协调器**：协作者（`settingsStore`、`usageStore`、`surface`、`hud`、`appContext`……）加上全部行为方法，
  以及一个 `let state = EngineState()` 取代从前的声明块。引擎在 `init` 里播种 `state.settings`/`state.defaultTitle`/`state.searchChangeHandler`，并像以前一样写状态；
  SwiftUI 界面直接绑定到容器。
- **UI 接线。** `OverlayView`、`SettingsView` 与 `ConflictRowView` 新增 `@Environment(EngineState.self) private var state` 并读 `state.panel`；
  宿主控制器（`SurfacePanelController`、`SettingsWindowController`）注入 `.environment(engine.state)`，所以 `engine` 环境对象只留给协作者。
  搜索字段与两个冲突过滤器用显式 `Binding` 值，因为 Observation 没有投影值。
- **引擎与状态之间共享的类型挪到文件作用域**：`HotkeyTarget` 现在是文件级枚举，缓存键 `OrderedHitsKey`/`RowBudgetKey` 住在 `EngineState.swift` 末尾
  （它们不再嵌在引擎里）。`EngineState` 属于 AppKit 目标而不是 SwiftPM 的 `KanameCore` 目标，所以纯层保持不碰 AppKit。

### 引擎协作者切分（开发，R-3）

`EngineState` 接过状态之后，`ShortcutEngine` 仍是单个文件，把所有协作者与输入路由器放在一起。R-3 把协作者拆出去，行为不变：
引擎留下状态机、事件 tap 调用与指针，其余全部委派。

| 模块 | 拥有 | 依赖 |
| --- | --- | --- |
| `Core/Engine/ShortcutEngine.swift` | `handleKeyDown` 路由、阶段/前缀、面板开关、tap 捕获、指针返回 | 全部协作者 |
| `PanelSession.swift` | 菜单项、排序、分页、选中、收藏、复制、激活/下钻、完成 | `EngineState`、`RowRunner`、`UsageStore`、`Presenters` |
| `SearchSession.swift` | 搜索面板开关、范围切换与加载、结果排名、Markdown 导出 | `EngineState`、`RowRunner`、`CatalogCoordinator` |
| `CatalogCoordinator.swift` | 前台目录扫描、世代守卫、排除、系统热键、配置扫描 | `CatalogLoader`、`AppDirectory`、`EngineState` |
| `RowRunner.swift` | 元素解析（含恢复快照的重走）、菜单按压、组合键回放、HUD/失败 | `CatalogLoader`、`UsageStore`、`Presenters` |
| `BindingEditor.swift` | 录制目标、`RecordingPolicy` 应用、设置写入 | `EngineState`、`SettingsStore`、`RecordingPolicy` |
| `LiveTestCoordinator.swift` | 快捷键测试的启动/取消/裁决/轮询 | `EngineState`、`ShortcutTester` |
| `DiagnosticsReporter.swift` | 支持报告字段 | `EngineState`、各存储器 |

依赖方向仍朝内：`Core/Pure`（策略、计划、状态形状）对 AppKit、I/O 与 `Core/Engine` 一无所知；上面的协作者持有 AppKit 仅因为它们执行副作用，
而 `Ports/PresentationPorts` 把它们向外的调用留在协议后面。引擎的公开表面保持为一行转发器，所以 UI 与 `PreviewScenarios` 的调用点没有移动。

刻意的边界：
- **输入路由留在引擎里。** `handleKeyDown`、阶段转换、捕获键集合、双击/hyper 机与指针返回是一个状态机；
  把它们分到多个模块会把每个键变成一次分布式事务。
- **开关留在路由旁边。** `activatePanel`/`dismissPanel` 操作阶段、tap 与指针，所以它们留在路由器旁边，而 `PanelSession` 从"面板可见"开始。
- **录制规则是纯的。** `RecordingPolicy` 与 `SearchScopePlan` 住在 `Core/Pure`；它们的测试钉住设置 UI 能够抵达的分支。

### 实时快捷键测试作为纯会话机（开发，P1-3）

实时测试的编排过去私藏在 `ShortcutTester`（AppKit）里：嵌套的 `State` 枚举、待定按下/早到尾部字段、配对窗口与观察构建，都紧挨着 `CGEvent` tap 而无法测试。
P1-3 用与引擎切分同样的方式把它拆开：

- **`Core/Pure/ShortcutTestSession.swift`** 是一台纯事件机：`begin(chord:permissionGranted:)`、`abortTapsUnavailable()`、`tick(remaining:)`、
  `keyAtHead(...)`、`keyAtTail(...)`、`appActivated(...)`、`settle()` 与 `verdict(for:items:ownerNameForBundleID:)`。它拥有 `ShortcutTestState` 枚举
  （idle / unavailable(reason) / listening(secondsRemaining) / finished(observation)）与计时常量（`listenWindow`、`settleNanoseconds`、`tailPairingNanoseconds`），
  所以首/尾配对窗口与激活归属被单元测试钉住，不需要键盘。
- **`ShortcutTester` 只留下 AppKit 那一半**：首/尾事件 tap、`NSWorkspace` 前台 App 读取、激活观察者、倒计时/收尾的 `Task`s 与 `PermissionCenter`。
  每个决定都是对会话机的一次委派；`ShortcutTester.State` 现在是指向 `ShortcutTestState` 的 `typealias`，所以引擎的 `liveTestState` 类型不变。

### 按状态切分的 OverlayView（开发，P2-2）

那个界面过去是一个约 1000 行的 `OverlayView`，它的 `body` 直接读 `EngineState` 的大部分内容，所以任何发布的变化——选区移动、扫描进度更新、一条搜索结果——
都会让整棵树失效并重算。P2-2 把它切成四个子视图，每个通过 `@EnvironmentObject` 订阅自己那一片状态：

- **`OverlayHeaderView`**——共享标题栏：App 身份、搜索字段、范围菜单、修饰键芯片、收藏开关、扫描/冲突指示、计数、关闭。它拥有搜索字段的
  `@FocusState` 与聚焦词元/可见性逻辑。
- **`OverlayPanelContentView`**——快捷键列表（扫描中/空状态、行网格）加上行级交互状态（`hoveredRowID`、`pressedRowID`、`hoveredStarID`）。
  读 `panel.*` 与 `scanState`；App 名变化时重置悬停的逻辑也在这里。
- **`OverlaySearchContentView`**——组合键横幅与结果/空状态，读 `search.comboAnswer/results/selection/query`。
- **`OverlayFooterView`**——计数、分页与动作提示。

`OverlayView` 保持为薄壳（边框、背景、圆角、面板↔搜索面板的切换），所以某个区域内部的变化不再重画其他区域。行为与外观不变，Debug 构建与 `swift test` 均通过。

### 并发边界

- 事件 tap 在自己的线程上跑（见[触发管线](#触发管线)）：回调在那里到达，吞键决定读已发布的 `ComposedSwallowState`，事件通过 `InputMailbox` 的有界批到达主 actor。
  因此 `KeyEventRouter` 与 `ChordComposition` 在主 actor 上、晚一跳运行，在那里它们可以花掉一次按键允许的时间，但永不阻塞输入流。
- AX 菜单扫描在主线程之外的后台队列上跑，并发为二（给上一个 App 的慢扫描可能在给当前 App 的快扫描之后才完成）；一个世代计数器只让最新请求发布。
  检查更新与跨 App 冲突扫描同样是可以取消的 `Task`，结果发布回主 actor。
- `PanelState` 与搜索快照只在主线程上变更，且 `PanelState` 仍是整体替换的不可变快照——引擎从不原地改它。
- 让行高亮在完成的快捷键之后继续保持可见的那个 `completionTask` 会在关闭时取消，所以高亮不会活得比展示它的那个面板更久。

## 面板内容与高亮

`PanelState` 是一个不可变快照，每次重建时整体替换。这里要紧的字段是 `filter`（`PanelFilter`，那串收窄列表的有序词元队列——见下）、
`prefixLabels`（组合键面包屑）、`heldModifiers`（与 `filter.modifiers` 同步；它是 `PanelHighlighter` 用来匹配的、也是点亮存活行里修饰键字形的依据）、
`latchedModifiers`（点击标题栏芯片勾上的修饰键——粘性，并折进 `PendingModifiers.effective`）、`completedRowID`（正在完成的快捷键）、
`flatRowIDs`（本页的行 id）与 `showsFavoritesOnly`；键盘光标本身是 `EngineState.panelSelectionIndex`，放在快照旁边，
所以一次 ↓ 只让读它的视图失效。菜单项由 `PanelRowBuilder` 构建——一条路径，一个构建器。高亮不是存储字段：它每次重建时重算，并挂在 `PanelRow.isHighlighted` 上。

快捷键列表是一张按组合键排序的平铺列表（`PanelOrdering`）；菜单路径是每个菜单项下方、标题与组合键之间的一条备注，所以没有任何东西会重排某个块。
它有**三个来源**（`PanelSectionID`）：App 的菜单项、系统的热键、以及每个配置工具一块。每块都画成一张**卡**（`groupSection`）：
一条标题条、下面一条细线、外面一圈边框。App 那张卡只有在**面板顺序**为**按菜单分组**时才以 App 名作标题；
在组合键顺序下这个块就是一张没有边界可供标题解释的平铺列表，所以它不画标题、也不为标题预留高度。系统那张卡标题是**系统热键**，两种顺序下都带完整计数。
工具的卡以工具为标题、带行数，并且**折叠**着直到点它自己的标题——每张卡保留自己的状态（`expandedTools`），所以展开 Alfred 不会展开 Karabiner；
折叠期间它的行离开序列，标题预算在同一帧里重算。整个工具分区只在 `showConfigToolsInPanel` 开着时存在（默认关）。
筛选生效期间，每张卡都算作展开（`ToolSectionFold`），所以匹配的工具行永远不会被计在折叠卡后面却够不着。
于是两个块之间的边界是一种形状而不是一行文字，并且它在滚动和窄布局下都成立。

标题是高度算术的一部分，不是装饰：`OverlayMetrics.groupHeaderHeight` 是 24 pt，在数行之前就被减掉，所以一张没有标题的卡起点高 24 pt，而不是留一个洞。
卡与卡相隔 10 pt，内容区在第一张卡上方留 8 pt、最后一张卡下方留 10 pt——两者都在 `OverlayMetrics` 和 `chromeHeight` 里，所以页脚永远不会压在最后一个菜单项上。

**一行分别陈述选中、可用性与语音。** 选中的菜单项前缘有一条 3 pt 的强调条，标题提亮 `+0.06`；单靠填充在浅色配色上太容易漏看，而这条条在色盲阅读下仍然成立。
VoiceOver 收到 `.isSelected`，这一行是 `.contain` 容器而不是一个不透明元素（收藏星与冲突徽标保留自己的标签，装饰性标记是 `accessibilityHidden`），
它的标签仍按"菜单项名 → 快捷键 → 状态"的顺序读。App 报告为禁用的菜单项保留变灰的标题并加一个尾随 `lock.slash`；它的右键菜单在动作之上以
**这个菜单项当前不可用** 开头，点击它会在 HUD 里显示同一句话，每个菜单项每三秒最多一次（`DisabledNoticeGate`，一个纯类型）。
变灰的行与不可用的菜单项过去长得一样；那把锁说明是哪一种，而不把菜单项变成错误横幅。

**空面板有四个答案和一个优先级。** `PanelEmptyKind.kind(isScanning:permissionDenied:showsFavoritesOnly:favoritesEmpty:)`
决定权限 > 扫描中 > 只显示收藏且没有钉住的 > 没有匹配，每种情况带自己的 `L10nKey`。权限那种是唯一有出路的——**打开授权引导**——
因为没有辅助功能任何扫描都完不成；扫描中那种是唯一带转圈的。空列表与"从没扫过"过去长得一样，四条消息也可能彼此漂开。

**快捷键列是一个固定槽位，不是自然文本。** `RowLayout` 预留它的宽度，字形用等宽设计渲染，组合键在右侧时（设置把它移到左侧时则是左侧）文本对齐到槽位的尾缘。
没有快捷键的菜单项什么都不画：那一列是空白而不是破折号，因为破折号往下几行仍表示"macOS 说不出名字的系统热键"。
修饰键字形保持一个规范的打印顺序，由 `KeyFormatterTests.testCanonicalModifierOrder` 钉住。

**选区移动不重建列表。** `moveSelection` 与 `select(rowID:)` 只写 `panelSelectionIndex`；面板重建发生在顺序、筛选、搜索、分页或设置变化时。
每一行自己算 `isSelected`，并用 0.1 秒 ease-out 动画填充与标记，所以按 ↓ 不会重跑排序或扫描工作。菜单激活跨到 `RowRunner`，
它的 `MenuTrigger.press` 是 `@concurrent` 且带 250 ms 的 AX 超时：UI 线程绝不等辅助功能。

**顺序是按修饰键的重要性：⌘、然后 ⌥、然后 ⌃、然后 ⇧。** 一段从最重要的往下比较它的修饰键集合，先耗尽的集合在前，然后才比键：
`⌘X`、`⌥⌘X`、`⌃⌘X`、`⇧⌘X`、`⌥X`、`⌃⌥X`、`⇧⌥X`、`⌃X`、`⇧⌃X`、`⇧X`。⌘ 领衔因为它是人真正会按的那个修饰键；
规范的打印顺序（⌃⌥⇧⌘）是组合键*画*出来的样子，不是它该被找到的顺序。完全没有修饰键的组合键（`F5`、`⌫`）领衔列表。
（先数修饰键个数——两个版本之前的规则——把每个双修饰键快捷键排到每个单修饰键快捷键之后，把 `⌃⌥C` 从 `⌃C` 旁边拆走了。）

键按词比较：`f`、`f1`、`f2`……`f12`，然后 `g`，因为功能键是以一个字母命名的，读者就是去那里找它；数字、标点与具名键（Return、Tab、方向键）跟在后面。
统计标签页的默认**排序方式：快捷键**复用 `PanelOrdering.compare`，所以同一个快捷键不会在两张视图里坐在两个不同的位置。

```
empty prefix (hotkey summon)   ⌘ pressed while open       chord prefix ⌘K
  ⌃A   Beginning of Line        ⌘A  Select All            ⌘C  Copy
  ⌃B   Move Backward            ⌘C  Copy                  ⌘S  Save
  ⌥D   Delete Char Right        ⇧⌘A  …                    ⌘K ⌘C  Copy
  ...                          (rows narrowed; the ⌘ in   (breadcrumb ⌘ ⌘K)
                                every row is lit, not
                                stripped)
```

被收窄的菜单项保留完整组合键：按住 ⌘ 会点亮 `⌘C` 里的 ⌘，而不是藏起它只印一个裸 `C`。只有在真的敲过某个键之后，菜单项才退回 which-key 视图并显示仍缺的那一段，
因为面包屑已经写明了敲过什么。键列由 `KeyFormatter.segments` 构建，一段一个字形，所以强调是按住的那个修饰键上的颜色变化——绝不是对格式化字符串的重新解析。

**筛选是一个有序词元队列，不是一个集合。** `panel.filter`（`PanelFilter`）按加入顺序保存 `tokens`：一个修饰键的**按下沿**追加一次 `.modifier(ModifierSet)`，
无论随后按住多久；一个**裸**小写字母键的 key-down 追加 `.letter(Character)`。顺序就是重点——`⌃` 然后 `f` 是查询"⌃ f"，最后加入的是 ⌫ 第一个收回的；
一个集合会丢掉这个，让 ⌫ 去猜。`filter.modifiers` 把修饰键词元并起来，`heldModifiers` 跟随它（所以保留下来的、首段带该修饰键的行会点亮它），
而筛除非空会清掉 `prefix`——让同样的修饰键收窄两次会把规则应用两遍。

收回一个词元有两种方式，都不是松开沿：
- **⌫ 弹出尾部**（`popLastToken`）：最后来的是字母就弹字母，是修饰键就弹修饰键。弹掉最后一个词元会回到整张列表与第一页；若结果比用户所在的页更少，
  `panelPage` 把索引钳到最后一页。
- **再按同一个修饰键会把它就地移除**（`toggleModifier`），所以 `⌃ ⌥ f` 减去 ⌃ 是 `⌥ f`（保持那个顺序），而不是围绕 ⌃ 重建队列；下一次按下会在尾部追加它，一次纯切换。
  松开永不翻转词元，所以这条条件熬得过键抬起来；召唤面板的那个修饰键停在 `triggerNarrowPending` 后面，不入队。

`PanelFilterPlan.matchingIDs` 通过 `SearchCorpus.search` 回答行的问题：`PanelFilter.query` 是按队列顺序排列的修饰键字形与小写字母，
搜索面板已经在用的语料返回这些 id。没有第二个字符串匹配器，所以面板与搜索面板对"⌃ f"的理解不会分歧；空队列返回 nil（"没有筛选"）而不是空集合。
查询在排序之后、跨 App 与系统的合并序列上运行，所以筛选决定哪些行存活，绝不决定它们的顺序。

这些边界住在一个守卫里（`PanelFilterPlan.decision`）：只有 `.active` 的筛选生效；`shiftHintActive` 把 `0–9` / `a–z` 交给提示层；
`triggerNarrowPending` 在任何词元之前消费召唤的那次按压。Shift 从事件里被剥掉、永不成为维度——它是提示层；字母只有在**不带物理修饰键**（去掉 Shift 后为空）
时才被接收，这就是 ⌥⌘M 仍是系统快捷键、⌥⌘F 仍是 Safari 菜单项，而松开修饰键后裸按 `f` 会筛选面板的原因。搜索面板保留自己的字母，因为打开它会关闭面板、让阶段留在 `.idle`；
方向键与分页键（`←`/`→` 以及任何启用的标点对）不携带单个小写字符，永不追加。

**高亮的数据流。** 菜单项与它们的视觉状态一起重算，所以不存在会变陈旧的部分高亮状态：

1. `flagsChanged` → 这一沿按下的每个修饰键向 `panel.filter` 追加一个词元（孤立的 ⇧ 与触发键除外）；松开不改任何东西。`panel.heldModifiers` 跟随 `filter.modifiers`，
   非空筛选清掉 `prefix`，然后 `rebuildPanel()` 运行。
2. `rebuildPanel()` 排序与分页（`PanelOrdering`，钉住时收藏在前）；非空筛选随后只保留 `SearchCorpus.search` 对 `PanelFilter.query` 返回的 id。
   `highlightedIDs(for:)` 标出参与中的菜单项：在组合键前缀下是 `PrefixResolver` 从它到达的每个菜单项，而只按住修饰键时是首段修饰键集合为它们**超集**的每个菜单项。
   当是筛选移走了其他行，那些仍保留、且带按住修饰键的行会点亮它，所以信息既在发光里也在键标里。
3. 精确匹配某个绑定的 `keyDown` 调用 `complete(_:probe:)`：记录用量、确保菜单项所在页、设置 `panel.completedRowID` 并重建，于是菜单项的**描述**用强调色渲染。
4. 完成任务睡约 0.4 秒（380 ms），然后清掉 `completedRowID` 并关闭面板。键事件没有被消费，所以前台 App 收到这个快捷键。
5. Esc 或面板/切换热键经 `dismissPanel()` 立即关闭。

**两个不同状态。** `panelSelectionIndex`（↑/↓）是键盘光标，跨重建保持；`isHighlighted` 跟随物理按住的修饰键；`isCompleted` 是那下短暂的强调闪。
`OverlayView` 独立渲染选中、键高亮与完成，所以一个选中的菜单项与一个被修饰键匹配的菜单项长得不一样。

**组合键下钻仍然存在**，为多段快捷键服务。按压一个作为某组合键第一步的段会把它压到 `prefix` 上并往下重建一层；面包屑显示前缀。
⌫ 先收回筛选的尾部词元（上面那个队列）；队列空了之后它撤掉最后一个勾上的修饰键，然后弹掉一段组合键。它只作为无修饰键被捕获，所以 ⌘⌫ 仍是普通快捷键；
Esc 无论有无修饰键都关闭。按下一个没有匹配的键会让面板保持打开，而不是关掉它。

**一段可以由两个来源拼成。** `PendingModifiers` 把 `held`（物理按下、瞬态）与 `latched`（标题栏勾上、粘性）分开，只有 `effective`——它们的并集减去孤立的按住 ⇧——点亮菜单项。
`ChordComposition.resolve(prefix:physical:pending:key:in:)` 是那唯一的纯决定：用 `physical ∪ latched` 构建探针组合键，对它分类（`complete` / `descend` / `noMatch`）
并报告 `composed`——当组合键的一部分来自面板而不是事件时为真。不过筛选先于组装回答一次 key-down：只有**裸**小写字母才是筛选词元，仍带着物理修饰键的字母
属于组合键，哪怕这些修饰键正是正在收窄列表的那几个——⌥⌘M 必须送到系统，而不是变成查询"⌥ ⌘ m"。`PanelTriggerAudit` 用同一组纯决定回放面板列出的每条
快捷键的最后一击，标出按下去无法触发的行；警示落在行尾槽位，可在设置里关掉。组合键仍要按组合键敲——修饰键与键一起按，或从组合键前缀一层一层来。

后果是**吞键与注入是同一个决定**。`KeyboardMonitor.shouldSwallow` 在 tap 线程上、通过 `ComposedSwallow.decide` 作用于引擎发布的快照（`ComposedSwallowState`，
每次变更后更新）来回答"拼成"的那一半，而 `handleKeyDown` 在处理这个键时再问同一条纯规则，所以 tap 与 handler 不会分歧、把快捷键跑两遍。这条规则的引擎侧仍是 `ChordComposition`：

| `composed` | 结果 | tap | 引擎 |
| --- | --- | --- | --- |
| false | 任意 | 放行事件 | 前台 App 执行该快捷键；面板只让菜单项闪一下 |
| true | `complete` / `descend` | 消费该键（及其松开） | 通过 `ShortcutInjector` 回放**拼成**的组合键，或把前缀往下压一层并清掉勾选 |
| true | `noMatch` | 放行事件 | 什么都不做；勾选保留，用户在序列中途 |

要让这张表成立，得堵住两条缝。`PanelKeyIntake.isConsumedBeforeComposition` 列出面板作为*自己*消费的键——`/`、Escape、方向键、启用的分页对与动作键——
因为带着勾选的修饰键时它们到来时不携带任何东西，而 `⌥;` 若是个真实绑定，就会让 tap 吃掉一个其实只会翻页的 `;`；tap 与 `handleKeyDown` 读同一张清单。
而 tap 会记住它消费过的一次 key-down 并连松开也消费，这在修饰键于按键下面变化时恰好要紧——拼成的一段必然如此，因为面板在 key-down 时就关掉了自己，到松开时已经没有勾选可供辨认。

⌫ 先弹筛选的尾部；队列空了之后剩下的是勾选与组合键层级。半搭好的序列在面板被关闭时、以及 Esc 关掉它时被丢弃。

面板自己没有文本字段。`/` 把它换成搜索面板（`showSearchFromPanel()`），在搜索面板里 `/` 换回来（`returnToPanelFromSearch()`）——但只在字段**为空**时：
没输入任何东西就没有可丢的，所以 `/` 完成这次往返；一旦有查询，`/` 就是普通字符，因为一个拒绝词中斜杠的搜索框是更糟的 bug。macOS 的 ⌘/（帮助）永不被碰：
切换要求一个裸斜杠。

这次往返每次都开一次新搜索。`openSearch()` 在搜索面板显示之前重置查询、结果、选中、滚动请求、组合键答案与范围（`SearchSnapshot.beginNewSession()`），
所以十分钟前敲的查询不会冒充今天的搜索。搜索面板的标题栏带一个返回箭头，因为字段立刻抢焦点、否则 `/` 会变成一扇单向门。

分页是展示问题，不是数据问题：`maxItemsPerPage` 是上限，不是目标。`OverlayMetrics.fittedPageSize` 在减掉 chrome、两张卡的内边距、分组标题与间隙之后取
`min(设置, 几何尺寸)`，所以默认 24（设置里 6–60，标注为 **每个分组最多显示 / Max menu items per group**）仍放得下，而 720 pt 窗口里一页 60 条会变成 36。
总有一行留下。面板渲染 `n/m` 页，并通过可点击的 ‹ › 按钮或下面的分页键翻页——没有滚轮翻页；列表本身纵向滚动。行可以排成一到三列（默认两列），
描述文本在布局前按可配置长度（默认 30 字符）用省略号截断。分页键构成一个环：最后一页的下一页回到第一页，第一页的上一页跳到最后一页。
只有一页的列表忽略两个键——`PaginationPlan.moved` 报告没有移动，所以面板不重建、也不显示"翻过页"的状态。

## 面板交互与执行

因为每个面板都是持久的，它不用靠打开它的那个快捷键也能用。按键处理住在 `ShortcutEngine.handleKeyDown`：

| 输入 | 动作 |
| --- | --- |
| ↑ / ↓ | 选择移动一行，钳在当前页内 |
| ← / → | 上一页 / 下一页，两端环绕；选择回到第一行。只有一页的列表不移动 |
| 启用的分页对（默认 `;` / `'`；`,` / `.`、`[` / `]`、`-` / `=` 可选） | 同一个翻页环，按敲出的字符判定（`+`，即 Shift+=，永不是分页字符；只有未解码事件才用 ANSI 键码） |
| 执行键（`settings.runRowKey`，默认 Space） | 执行选中的菜单项 |
| 复制键（`settings.copyRowKey`，默认 Return） | 复制选中菜单项的组合键 |
| Esc | 关闭面板 |
| ⌫ | 弹出筛选的最后一个词元——最后来的是字母就弹字母，否则弹那个修饰键；队列空了之后，撤掉最后一个勾上的修饰键，再弹掉一层组合键。什么都没有时这个键被放行——它永不关闭面板 |
| 点击 | 同执行键 |
| 点击修饰键芯片 | 勾上它：筛选为空时通过纯修饰键前缀收窄列表 |
| `/` | 把面板换成搜索面板（以及在搜索面板字段为空时换回来） |
| 完成的快捷键 | 菜单项的描述高亮约 0.4 秒，然后关闭并放行事件 |

- **只要面板可能是执行它的那一方，快捷键就是被执行，而不是被吞。** 带着面板提供的修饰键按下的完整快捷键会被 tap 消费，并通过 `ShortcutInjector` 完整回放，
  HUD 显示拼成的组合键而不是裸键。正常按下的完整快捷键被放过，于是前台 App 自己执行它、面板只让菜单项闪一下——那条路径与组合键出现之前逐字节相同。
  收窄到只剩一个菜单项就够执行键与点击生效，因为 `PanelSelection.resolved` 会选中唯一那一行；组合键的最后一段永不被钻进去，所以点它会回放整条组合键而不是把面板清空。

- **导航键只在面板活动、且没有按住修饰键时被捕获。** `updateCapturedKeys` 用空修饰键集合登记方向键，加上两个动作键被录制到什么
  （`HotkeySpec.capturedIdentifiers`；Return 与小键盘 Enter 双向等价），`KeyboardMonitor` 吞掉这些 key-down，所以前台 App 从来看不到它们。面板关闭时这个集合被清空。
  不是动作键的修饰键+键组合（⌥⌘Esc……）不在集合里，所以它保持为普通快捷键。
- **菜单项契约是两个录制的键、一个界面（搜索面板是只管执行的第二个界面）。** `RowAction`（`.execute` / `.copy`）由 `performPanelRow` 应用：
  `.execute` 把菜单项送进 `activate(rowID:)`——分组行下钻一层、禁用菜单项被忽略、其余记录用量、关闭界面并触发菜单项——而 `.copy` 把渲染后的组合键写进剪贴板、
  弹"已复制"提示且不关闭任何东西（没有快捷键的菜单项没有东西可复制，它会这么说，而不是清空剪贴板）。`RowKeyRouter.action(for:modifiers:run:copy:)` 是这条规则的唯一实现，
  面板与搜索面板的列表共用它；执行先于复制匹配，所以把两者录到同一组合键会退化成主动作，而不是留下一个够不着的。页脚提示渲染两个录制的组合键，所以重映射不会留下撒谎的提示。
- **触发菜单项是首要目标，所以每个执行界面都先按压菜单项。** `MenuTrigger.press(_:)` 对扫描为该菜单项保留的 `AXUIElement` 执行 `AXPress`。
  这是到达一个没有键盘快捷键的菜单项的唯一方式，对有的那些它也恰好是点菜单会做的事——App 自己的校验与当前状态生效，解码错了的组合键永不被回放。
  通过 `ShortcutInjector` 回放组合键是兜底，在按压失败时（菜单变化后的陈旧元素、拒绝该动作的 App）或菜单项根本没有元素时（系统热键、兜底目录条目）使用。
  元素不必属于前台 App，所以面板可以不抢焦点就触发；搜索面板确实接管键盘，事后把它交还给它所锁定范围的那个 App。
- **全局热键的录制比动作键严格。** 全局热键必须带 ⌘/⌥/⌃，否则打字就会触发它；动作键只在面板拥有键盘时被读，所以裸 Return 没问题。裸字符与面板的导航键（Esc、方向键）两种都拒绝——
  裸字母会破坏组合键录入与筛选。
- 选中、键高亮与完成是三个独立的视觉状态，如上所述；完成的快捷键不由 Kaname 执行，所以前台 App 仍收到它。执行菜单项是那个显式例外：它关闭界面并触发菜单项——有元素就按压它，否则回放组合键。

选择基于 `flatRowIDs` 的索引，所以两列或三列的分组布局按阅读顺序移动，而不必在视图里把行摊平。每次重建与换页都把 `selectionIndex` 钳在当前页内。

## 搜索面板

搜索是一个独立的全局面板（默认 ⌃⌥⌘F），从它的热键到达，或在面板里按 `/` 到达。它在受限 App 的实时菜单绑定加系统热键（未选范围）或那一个 App 的绑定（已选范围）上搜索，
每个范围标识用一份 `SearchCorpus`——当范围、目录、键样式或语言变化时重建，这就是范围 id 是语料键一部分的原因。未选范围的语料也携带配置工具行，
但只在 `showConfigToolsInPanel` 显示它们时；组合键答案无论如何都继续读它们。

- **分词、无序匹配。** 查询转小写，`+` 当分隔符，其余按空白切分。每个词项都必须命中——`com op x`、`op cm x` 与 `cmd+opt+x` 等价。没有短语要求，也没有顺序要求。
- **修饰键别名。** `com`/`cmd`/`command`/`⌘`、`op`/`opt`/`option`/`alt`/`⌥`、`ct`/`ctl`/`ctrl`/`control`/`⌃`、`sh`/`sft`/`shift`/`⇧`。组合键真的有那个修饰键时，识别出的别名得高分。
- **键词元与文本。** 精确键词元、标题、菜单路径、渲染后的组合键，以及修饰键单词/符号都是草堆。精确/前缀/子串/子序列打分，权重偏向标题，决定排名。
- **中文拼音。** `Pinyin.forms(of:)` 用 `.mandarinToLatin` 转换中文标题，然后加上全拼（`jianqie`）、分音节（`jian qie`）与首字母（`jq`）。输入 `jq` 或 `jian qie` 就能找到剪切，不必切换输入法。
- **英文首字母。** 多词标题还贡献它们的拉丁词首字母，所以 `fs` 能找到 Find Similar。
- ↑/↓ 移动选中；Return 对它执行。
- **搜索面板执行，不复制。** `confirmSearchSelection()` → `activateSearchResult(_:)` 隐藏面板、激活它锁定范围的那个 App、记录用量并触发菜单项：
  有元素就按压，否则通过 `ShortcutInjector` 投递组合键。这里的 Return 永远是 Return：录制的动作键属于面板，所以搜索面板页脚读的是 `↵ 执行`，而不是渲染 `settings.runRowKey`。
- **这个界面没有复制路径。** `RowAction` 只由面板应用。要复制组合键而不执行，用那边的复制键。
- 执行一条搜索结果可能立刻触发破坏性动作（删除、清空废纸篓、退出），这就是第一个匹配被选中、但在你按 Return 之前什么都不执行的原因。
- **面板与搜索互斥。** `showSearch()` 先关闭面板，而切换热键（默认 ⌃⌥⌘S）从搜索到面板、从面板到搜索，或两者都不可见时打开面板。

- **搜索面板的状态是一个快照。** `SearchSnapshot` 把查询、结果、选中、可见性、组合键答案与范围标识作为引擎上的一个 `@Published` 值携带；
  只有查询变化才重跑搜索，而 `refreshSearch()` 把结果/选中/可见性写回而不会打转。范围图标是唯一留在引擎侧的东西（一个 `NSImage`）。

搜索从不记录查询。它在当前内存目录上运行；什么都不持久化。

## 搜索面板的 App 范围与 Markdown 导出

搜索面板搜前台 App 的目录加系统的热键。它的结果**每个菜单类别一张卡**（`SearchSection`）：类别是卡的标题，卡内没有任何东西重复它，
快捷键有自己的固定列，菜单项占满这一行其余部分，有更深的菜单路径时放在它下面。于是三类内容永不共享一行，两个类别的边界是一条边框而不是同一流里的一个标题。
排序、选中、悬停、点击与滚动到选中都不变：卡只是渲染，结果数组仍是引擎那张平铺的、排好序的列表。

过去住在一个独立窗口里的两件事现在都在它的标题栏里：

- **App 范围。** `runningApps`（来自 `AppDirectory`）喂一个菜单，第一项是*前台 App* 并清除范围；选另一个运行中的 App 会通过 `CatalogLoader` 以 `force: false` 加载它的目录——
  20 秒缓存能答就答——然后搜那个。搜索面板每次打开时范围都重置到前台 App，所以它永不回答上一次遗留的问题。面板不受影响：它永远跟随真实的前台 App。
- **导出 Markdown。** `makeSearchMarkdown()` 委派给纯的 `MarkdownExporter.render(appName:items:style:language:)`，有查询时写匹配项，没有时写范围的完整列表。
  搜索面板弹一个 `NSSavePanel`（默认文件名 `<App>.md`），以 UTF-8 写入，并通过 HUD 确认。

文档含一个带时间戳与菜单项计数的 `# Kaname — <App>` 标题、每个一级菜单一节 `## <菜单组>`、每节一张 `| 快捷键 | 动作 |` 表（管道符被转义，禁用菜单项加后缀 `_(不可用)_`），
以及一个页脚链接。导出器不做文件 I/O，这就是它能不用 AppKit 就被单元测试的原因。

## 设置窗口

`SettingsView` 是一个 SwiftUI 窗口，七个标签页（`SettingsTab`）：**通用**、**触发**、**外观**、**统计**、**冲突**、**权限**、**关于**。
诊断不是一个标签页：它的控件是通用末尾的一个折叠组，默认收起。统计与冲突过去共用一页"排名"，这让两者都难找，而那一页长到顶部的数字从来没被人看见。

| 标签页 | 内容 |
| --- | --- |
| 通用 | 界面语言、登录时启动、执行 HUD、*显示程序坞图标*、**菜单项动作**（两个录制的动作键）、**排除的 App**（一个由 `NSOpenPanel` 填充的可选列表，而不是一堆 bundle identifier 的文本框）、被忽略的菜单项（每个范围一个折叠组）、同一张卡里的内置目录与*包含 Apple 菜单*开关，以及一个折叠的**诊断**组（日志开关、详细日志、日志文件夹、**导出诊断归档……**（.zip）、实时状态（辅助功能、输入监控、监听中、目录计数）、**导出诊断报告……**（.json）） |
| 触发 | 两个独立开关，各自在卡片标题左侧：**修饰键手势**（按住不动 / 按两次、一个触发键、按住延迟；双击窗口跟随系统双击速度）与**全局热键**（三个可录制热键：面板、搜索、切换）。两者可全开、单开或全关——全关即暂停态 |
| 外观 | 键样式、面板主题（跟随系统 / 浅色 / 深色）、键位、列数、每页行数与描述长度（键入式；Return 或离开字段即提交，超范围输入保留上一个值）、禁用项、**面板位置**（覆盖 / 固定尺寸 / 填满屏幕 / 在旁边）、选*固定尺寸*时的固定宽高，以及一张管钉住与筛选的**收藏**卡 |
| 统计 | **排序方式**（快捷键、App 或命令）、一张快捷键平铺列表，所属 App 与命令作为备注（*显示数据文件夹*、*重置统计*）、*恢复默认* |
| 冲突 | 配置文件来源（读了什么、计数、重扫）、类别筛选、相关 App 筛选、扫描时间戳、手动重扫、分页的发现项带**测试这个组合键** |
| 权限 | 辅助功能与输入监控状态、**请求访问**（系统提示 + 打开对应系统设置面板）、以及一个可拖拽的 Kaname 图标 |
| 关于 | 图标、带提交的版本（`v2.3.0 (836e3c3)`）、系统版本、手动检查更新、数据文件夹（打开按钮）、仓库与许可 |

统计标签页由 `ShortcutEngine.usageEntries()` 喂：每个 `usageKey` 与它命名的目录条目连接（不跨拥有者合并），按按压计数、扫描时间、语言与两个绑定计数的签名缓存在
`EngineState.usageBreakdownAllCache` 里。视图随后用 `UsageSorting` 给那张表排序——引擎不依赖 AppKit，也不需要 App 显示名——并每个快捷键画一行：
组合键领衔，App 图标与名称加命令作为 12 pt 备注跟在后面。**显示数据文件夹** 在 Finder 里打开 `~/Library/Application Support/Kaname`。

设置窗口是带 `[.titled, .closable, .resizable]` 的单一工具窗口——没有 `.miniaturizable`，因为最小化的副本过去会待在程序坞里，而菜单栏项还得去找它；
关闭与原有的菜单恢复路径仍是出去的方式。窗口可见时，**打开授权引导** 以 sheet 形式挂上去（`beginSheet`），所以引导不会落到设置后面或另一个 Space 里；
首次启动、设置还从未被打开过时，引导仍独立站立。

冲突标签页启动时读 `ConflictCache`，只有在你按**重扫**时才扫描（或者什么都还没缓存时）：扫描要走遍每个运行中 App 的菜单，每次访问都做一遍正是"一打开这页就卡"的抱怨。
发现项按 40 条分页渲染，因为 `Form` 会把交给它的每一行都构建出来。

权限标签页的图标是一个真正的拖拽源（`NSItemProvider` / 文件 URL）：把它拖进系统设置里的辅助功能或输入监控列表就会加入运行中的 App，
这在列表还没有条目时很方便。**请求访问** 调系统提示、然后打开对应面板，而不是只做两者之一。

## 检查更新

**设置**的关于标签页提供一个手动发布检查，它是 App 里唯一的联网代码。

- `UpdateChecker` 是一个主 actor 的 `ObservableObject`，状态有 `idle`、`checking`、`upToDate`、`available(tag, url)` 与 `failed`。
- `check(currentVersion:)` 向 `https://api.github.com/repos/suliveevil/kaname/releases/latest` 发一个 GET，带 `Accept: application/vnd.github+json`、
  `Kaname-update-check` 用户代理与 12 秒超时。
- 响应必须含 `tag_name` 与 `html_url`。`SemanticVersion` 去掉前导 `v` 与任何预发布/构建后缀，然后把 `major.minor.patch` 与运行中的 `CFBundleShortVersionString` 比较。
- 更新的 tag → `.available`，那一行变成链接，在默认浏览器里打开发布页。相等或更旧 → "你已是最新版本"。任何网络、HTTP 或解析失败 → 一句简短的失败消息。
- **没有轮询、没有自动下载、没有安装。** 按钮被按之前什么都不跑，请求也不携带用户、App 或快捷键数据。

## 展示

- `SurfacePanelController` 拥有一个非激活的 `NSPanel`，同时承载面板与搜索面板（一次只有一个界面），所以击键继续到达前台 App，直到搜索面板需要那个字段。
- `WindowGeometry` 读前台窗口与焦点元素的边框（AX，0.2 秒超时）并换算成 Cocoa 坐标。`OverlayPanelController` 随后针对包含前台窗口的那块屏幕解析
  **`PanelPlacement`**（一个四例纯枚举），退回到指针下的屏幕：

  | 位置 | 尺寸 | 摆放 |
  | --- | --- | --- |
  | 覆盖前台窗口（默认） | 至少在两个维度上都够盖住窗口（永不小于它的自然尺寸，上限为可见帧）；更宽的列数所需的内容高度只在高于覆盖高度时才用；窗口边框还没到时用整个可见帧 | 居中于可见帧，然后 `containedFrame` + `clampedTop` |
  | 固定尺寸 | `fixedPanelWidth` × `fixedPanelHeight`（默认 720 × 620，钳到可见帧） | 居中于可见帧，然后 `containedFrame` + `clampedTop` |
  | 填满屏幕 | 可见帧，高度按 `topInset`（`max(safeAreaTop, screenMargin)`）修剪；原点留在 `visible.minY` | `visible.minX` / `visible.minY`，宽度不变 |
  | 在前台窗口旁边（v2.0 行为） | 面板的自然尺寸 | 窗口旁边，需要时换边，并避开焦点元素；没有窗口时退回右上角 |

  位置在面板每次显示或改变尺寸时重算。锚点快照刻意不跨展示保留：`hide()` 取消进行中的几何读取、复位 `isRefreshingGeometry`、清空 `PanelAnchorCache`；
  控制器还会在 `NSWorkspace.activeSpaceDidChangeNotification` 与 `NSApplication.didChangeScreenParametersNotification` 时清它，因为变化之前读到的窗口边框描述的是一个此后已经移动过的窗口。
  下一次展示会在后台重新读窗口与焦点元素边框。没有快照时，`OverlayPlacement.coverSize` 返回整个可见帧而不是猜一个比例，所以第一帧就已经盖住前面的任何窗口。
  `containedFrame` 先把尺寸钳到可见帧，只在两个边距都还放得下时加上某个方向的 8 pt `screenMargin`；`.fixedSize` 与 `.coverWindow` 随后把边框过一遍 `clampedTop`，
  当它的顶边会落进 `topInset = max(safeAreaTop, screenMargin)` 时整体下移。原生全屏下前台窗口填满屏幕、可见帧等于屏幕帧，于是 24 pt 的覆盖边距被裁掉：
  面板精确匹配屏幕、仍盖住窗口；`.fillScreen` 按那个顶边距修剪高度而不动原点。
- **Space 变化会关闭面板并刷新前台 App 的菜单。** `ShortcutEngine` 观察 `activeSpaceDidChangeNotification`：它先调 `dismissEverything()`，然后
  `SpaceRescanGate`（0.75 秒，按 pid）丢掉重复通知并强制重扫现在在前台的那个 App（`space changed → forced rescan <app>`）。
  `CatalogCoordinator.reload(force:preserveOnEmpty:)` 把结果过一遍 `CatalogPublishPolicy`：已经在显示非空列表时，一个没有菜单栏的空结果不被发布——
  上一个目录留着、加载状态复位——因为菜单栏可能还没重新挂上。一个真的没有菜单栏的 App、或者被撤销的权限，仍会发布空结果。
- **搜索面板坐在前台窗口上，不是坐在屏幕上。** 它的宽度固定 680 pt，高度至少等于窗口高度（钳到可见帧），所以它纵向跨过前台窗口，
  而不是在顶边附近的一条固定 460 pt。边框居中于窗口中心并钳进可见帧；没有窗口边框时退回到屏幕中心。前台 App 的 pid 在 `NSApp.activate()` 之前读，
  因为之后前台 App 就是 Kaname 自己了。
- **面板按会话里最宽的列表定尺寸，而不是按屏幕上这一页。** 按修饰键按定义就在收窄列表，所以按当前页定尺寸的窗口会在每次按下时变高、松开时又变回去——
  在屏幕上读起来就是面板在跳。`PanelState.rowBudget` / `headingBudget` 携带未收窄列表显示多少行、多少标题（什么都不拼、已分页，每个非空分区一个标题——
  App、系统热键，以及显示开关开着时每个有行的配置工具；筛选生效时每张工具卡都算展开），`OverlayMetrics` 从那预算与实际画出的行里取大者定尺寸，
  所以边框保持不动、列表在它内部移动、永不会裁掉一行。预算在目录、芯片、只显示收藏开关、被忽略的标题或页大小变化时重算——绝不每敲一键重算。
  内联筛选过去有自己的预算；那个筛选没了，随之没了的还有"查询之前那张列表"到底指什么的那个问题。
- `PanelTheme` 存跟随系统 / 浅色 / 深色，对着窗口的 `effectiveAppearance` 解析，并把旧的 Graphite / Midnight / Paper 文件解码到深色与浅色配色上，
  所以已有的面板不会变样。
- `Theme` 给面板 12 pt 圆角与 16 pt 外边距，内容区第一张卡上方 8 pt、最后一张卡下方 10 pt。背景跟随主题：一个 `NSVisualEffectView` 为浅色配色渲染
  `.popover`、为深色渲染 `.hudWindow`，搜索面板的实色底铺在材质之上，好让文本调校时的对比不随壁纸移动。**降低透明度** 保留实色，**增强对比度** 加强边框与文字，
  两种下键帽都可辨。
- `HUDPanelController` 渲染那句短的"已执行"提示；可以在设置里关掉。
- 这个 App 是一个 `LSUIElement` 代理：没有程序坞图标、没有 App 切换器条目、启动时没有窗口。`Main.swift` 把 App 建成纯 AppKit 而不是带场景的 SwiftUI `App`，
  因为 `Settings` 场景会在启动时开一个空窗口，而 `MenuBarExtra` 让状态项没法被自己拥有。`showDockIcon` 把激活策略切成 `.regular`，
  然后 `applicationShouldHandleReopen` 打开设置；⌘, 随时打开设置。
- 界面语言跟随系统，并可在设置里覆盖。`L10n`、`KeyFormatter` 与 `BuiltInCatalog` 提供英文与简体中文字符串；实时菜单标题来自被扫描的 App，已由那个 App 本地化。

## 权限

`PermissionCenter` 跟踪两个独立授权：

| 授权 | API | 用于 |
| --- | --- | --- |
| 辅助功能 | `AXIsProcessTrustedWithOptions` | 菜单扫描、创建全局事件 tap、`AXPress` 执行 |
| 输入监控 | `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` | 仅靠辅助功能收不到按键事件时的可选兜底 |

辅助功能是必需的。输入监控是兜底，不是第二道强制闸门：Kaname 单独检查它，并且只在键 tap 收不到事件时才指向它。缺辅助功能会留下兜底目录并禁用触发；
缺输入监控只在那些会门控按键投递的系统上才要紧。权限标签页的**请求访问**调系统提示、然后打开对应面板，该标签页还把这个 App 暴露成拖拽源，好把它拖进系统设置列表。
两个深链都用系统设置（macOS 13+）的锚点，并且只在一处写清，在 `PermissionCenter` 里。

状态用三种方式观察：对每个未授予的权限做 3 秒轮询（一旦授予就停）、一个 `DistributedNotificationCenter` 观察者盯着未公开的 `com.apple.accessibility.api` 通知
——系统在某个 App 的辅助功能信任被切换时会发它，所以 Kaname 运行中被撤权会立刻被处理，而不是等到下一次激活——以及 App 变为活动或 Mac 唤醒时的一次复查。
轮询与激活复查留作万一那个通知不再发布时的兜底；输入监控没有对应通知，靠它们。读系统热键列表走 Carbon，不需要额外授权，检查更新也不需要权限。
面向用户的指南见 [PERMISSIONS.md](PERMISSIONS.md)。

## 持久化

设置与统计住在 `~/Library/Application Support/Kaname/` 里的普通 JSON 文件中，不在 `UserDefaults` 里。那个位置不依赖偏好域，所以重装或换签名构建都能保住数据。

```text
~/Library/Application Support/Kaname/
  settings.json                  # { schemaVersion, settings } — user data
  usage.json                     # { schemaVersion, statistics, favorites } — user data
  conflicts-cache.json           # the last cross-app conflict scan, read at launch
  menu-cache/
    control.json                 # schema + settings fingerprint every entry was written under
    menus-<identity>.json        # one cached menu scan per app identity
  logs/                          # kaname-<date>.log, last-actions.json, session.active
  crash/                         # crash reports, one JSON file each
```

`DataDirectory` 解析这个文件夹（`FileManager.applicationSupportDirectory` + `Kaname`）并按需创建。`JsonFileStore` 是两个存储器共用的小库：

- **原子写。** 载荷用 `JSONEncoder` 编码并以 `.atomic` 写入，所以写一半崩溃不会留下截断的文件。
- **损坏文件被保留，不被丢弃。** 若 `JSONDecoder` 失败，文件被改名为 `<name>.corrupt-<unix 时间戳>.json`（例如 `settings.corrupt-1761112345.json`）并留在原文件旁边；
  App 用默认值继续。之后一次保存会写新文件，损坏的副本留着供检查。
- **迁移只发生一次，且按优先级。** 先 `settings.json`；若它不在，用 `settings.v2` 下 v2.0 的 `UserDefaults` 载荷；若那也不在，
  用从旧 `com.suliveevil.kaname` 域读出的那一小把 1.x 键（`settings.overlayHoldDelaySeconds`、`settings.keyDisplayStyle`、`settings.overlayColumnCount`、
  `settings.maxDisplayCount`、`settings.launchAtLoginEnabled`）。用量以同样方式从 `usage.v2` 迁移。加载后的第一次写创建 JSON 文件；此后不再读 `UserDefaults`。
- **这些文件里只有两个装用户数据。** 其余都是派生或诊断数据：`conflicts-cache.json` 与 `menu-cache/` 重扫一次就能复现，`logs/` + `crash/` 存在是为了解释某个 bug——
  `ActionRecorder` 只保留最近 30 个动作*名字*（绝不是菜单文本、输入的字符或查询），日志可在 **设置 → 通用 → 诊断** 下关掉，
  删掉这个文件夹只损失一次重扫与一段历史，别的什么都没有。搜索查询与原始按键事件无论如何都留在内存里。
- **菜单缓存是派生数据。** 与设置和统计不同，每个条目都能靠重新扫描 App 复现，所以读不出的条目被丢弃而不是留在旁边，写失败只损失一次重扫。
  它只在本机，永不离开这台机器。

`AppSettingsModel` 用纯 Swift 拥有默认值、范围与校验，所以设置不用 AppKit 就能测。v2.0.0 给统计页加了 `sortMode`（在 v10 移除）。
v2.1.0 加了 `panelPlacement`（默认 `.coverWindow`）、`fixedPanelWidth`（720，钳 320–4000）、`fixedPanelHeight`（620，钳 240–3000）与 `switchHotkey`（⌃⌥⌘S），
并**移除了 `autoHideDelay`**。v2.2.0 加了两个录制的动作键（`runRowKey`、`copyRowKey`）、`excludedBundleIDs`、`ignoredCommands`、`showAppleMenu`、`showDockIcon`
与诊断开关，并移除了 `allowPanelExecute` 和 `allowSearchExecute`（它们早已不再控制任何东西），以及 `keepBrowserOpenAfterRun` 与 `contextFirst` 排序模式
（浏览器窗口与那个冗余模式一走，它们就失去了主语）。**面板顺序**（`panelOrder`）是在那之后加的：v5 文件没有这个键，所以 `decodeIfPresent` 给出默认**按修饰键**，不必重写。
设置 schema 现在是版本 10：v6 加了 `panelOrder`，v7 移除了 `doubleTapWindow`（窗口跟随系统双击速度，所以旧值被忽略并在下一次保存时丢掉），
v8 加了 `pagingPairs`（v7 文件得到默认 `;` / `'` 对，集合里未知的成员被丢弃而不是重置整个文件），v9 加了 `showConfigToolsInPanel`
（更早的文件被钉到新默认 `false`，因为旧的无条件卡片从来不是一个选择），v10 加了 `usageSortField` 并移除 `sortMode`
（旧文件没有这个键，所以默认的**快捷键**顺序生效，被移除的键在下一次保存时丢掉）。

**移除一个键不需要迁移步骤。** `AppSettingsSnapshot` 只实现 `init(from:)`，那里每个字段都是带默认值兜底的 `decodeIfPresent`，
所以旧载荷能解码，未知键被 `CodingKeys` 忽略，下一次保存把它丢掉。`SettingsPayload`/`SettingsMigrator` 的存在是为了让*版本*被读而不只是被写：
`isOutdated(_:)` 报告某个文件来自更旧的构建，而将来一次不兼容的变更有一个地方加它的步骤。维持"无迁移步骤"这个说法诚实的不变量——解码旧载荷、去掉被移除的键再编码——
有一个单元测试。`usage.json` 现在携带自己的版本：共用设置常量曾意味着一次设置迁移会静默声称统计文件也变了。

触发设置 v5 用 `modifierTriggerEnabled`、`hotkeyTriggerEnabled`、`triggerGesture` 与 `triggerKey` 替换了四选一的 `triggerMode`。
`SettingsMigrator` 把 `holdModifiers` 映射为手势开 / 按住 / **任意修饰键**，把 `doubleTapCommand` 映射为手势开 / 双击 / **任意修饰键**，
把 `hotkey` 映射为手势关且热键仍开，把 `disabled` 映射为两个开关都关；旧键只解码一次并不写回。2.0 的 `UserDefaults` 块没有 schema 外壳，所以它走同一步迁移。

`UsageStatistics` 是 `UsageStore` 与测试共用的纯值：

```text
UsageStatistics
  totalPresses: Int
  records: [usageKey: UsageRecord]   // usageKey = "bundleID|chord" ("*" = system/built-in)
    UsageRecord: { count: Int, lastUsed: Date }
```

800 条记录的上限在每次记录按压后按最近最少使用裁剪。**设置 → 统计** 通过 `UsageBreakdown.entries(records:known:)` 把每条记录与它的目录条目连接，
并用 `UsageSorting` 给结果排序；不再有按 App 的汇总。解码失败退回到空统计而不是崩溃。重置会清掉 `totalPresses` 与所有记录。

## 测试与 CI

`Package.swift` 声明 `KanameCore`（路径 `Kaname/Core/Pure`）与 `KanameCoreTests`（路径 `Tests/KanameCoreTests`）。XCTest 套件覆盖：

- 组合键解析与标准化
- 键映射与特殊键
- 前缀匹配与组合键遍历
- 统计顺序（`UsageSorting`）：快捷键顺序把没有组合键的行放最后、App 顺序按 App 分组、命令顺序把没有已知标题的行放最后，以及共享一个组合键的两个 App 仍是两行
- 键格式化与面包屑
- 描述清洗与截断
- 冲突检测（含重复抑制）
- 搜索索引与模糊打分
- 本地化完整性（两种语言、格式化占位符一致）
- 内置目录完整性（大小、组合键唯一、两个标题）
- 使用统计（记录、800 条 LRU 上限、编解码、重置）
- 数字输入字段（`NumericSettingInput`）：trim、全角数字、范围边界，以及拒绝任何不在范围内的非整数
- `SemanticVersion` 解析（`v` 前缀、预发布后缀）与比较
- `MarkdownExporter` 的分组表渲染，含不可用标记
- 系统热键与 App 绑定的冲突，带外部条目
- 分词搜索：词项乱序、`+` 作分隔符、修饰键别名、所有词项都必须命中
- 拼音全拼/首字母形式与拉丁词首字母
- `HotkeyMatcher`：修饰键精确匹配、三个及以上修饰键时允许 Hyper 超集、三个以下严格匹配、错误键码被拒
- 从 `bundleID|chord` 解析 `bundleID`，以及让两个 App 的行分开的全拥有者连接
- `PanelPlacement` 编解码与设置默认值（覆盖窗口、切换热键）
- 旧载荷解码，含一个仍携带 `allowPanelExecute`/`allowSearchExecute` 的，以及重编码时丢掉那些键
- `RowKeyRouter`：共享组合键上执行压过复制、未绑定的键不被路由、多余的修饰键不是动作键
- `HotkeySpec` 匹配与 `capturedIdentifiers`：Return 与小键盘 Enter 双向等价，两张清单来自同一张别名表
- `PanelRowBuilder`：分组顺序、不可选行的 `index == -1`、平铺顺序排除它们
- `HeaderLayout`：460/600 阈值与每种密度保留哪些控件
- `PanelOrdering`：段数少的在前，然后按重要性顺序（⌘、⌥、⌃、⇧）逐位比较修饰键集合，所以先耗尽的集合在前、`⌃⌥C` 留在 `⌃C` 旁边；然后比键。筛选规则是"携带每一个被筛选的修饰键"
- `PanelFilter` / `PanelFilterPlan`：按下沿只追加一次修饰键、松开不改任何东西、第三次按下成为尾部、⌫ 一次一个词元地弹尾部、Shift 与触发键永不成为词元、多余的 ⌘ 不被踩、匹配走 `SearchCorpus`（⌃ 然后 f 只找到 ⌃F 快捷键）
- `PanelSortOrder`：**按修饰键**与旧顺序完全一致；**按菜单分组**让每个顶层菜单在菜单栏顺序里连续、菜单内保持快捷键顺序、未排名分组排在已排名之后且空组最后；切换顺序会把 `0`–`9` / `a`–`z` 的 Shift 标签移到新位置
- 设置 schema 写版本 8；缺 `pagingPairs` 的 v7 载荷迁移到默认 `;` / `'` 对，集合里未知的成员被丢弃而不是回滚整个文件，缺 `panelOrder` 的 v5 载荷迁移到**按修饰键**
- `PanelSelection`：零行什么都不选、一行选它、陈旧索引被丢弃而不是钳到最后一行
- `RowLayout`：备注列在 300 pt 以下消失、键列两个方向都有上限、60 pt 的标题下限只在最窄支持的行走廊内启用
- `KeyChord.isFinalStroke`："这一段是最后一段"的唯一真相来源，下钻与菜单项激活共用
- `PendingModifiers` 与 `ChordComposition`：按住 vs 勾上、孤立 ⇧ 规则、`composed` 护栏，以及完整的吞键真值表
- `PanelKeyIntake`：导航、启用的分页对、动作键、`/` 与 Escape 在组装之前被认领；⌫ 刻意不在清单上
- `PagingKeyPlan`：要么是某个启用对的第一个字符（上一页），要么是第二个（下一页），先按敲出的字符匹配、只在事件没有字符时才用 ANSI 键码；方向键永不属于它、多个对可以同时开而不互相吞、第三对是 `-` / `=`（未按 Shift），而 `+`（Shift+=）根本不是分页字符——所以它既不翻页也不与 Shift 提示层的 `0`–`9` / `a`–`z` 标签打架
- `SearchKeyRouter`：八个分页字符全部透传给搜索字段，所以获得焦点的查询字段永不翻页
- 收窄被保留：活动的 ⌘ 筛选仍保留 ⇧⌘A，因为查询是"⌘"而不是精确组合键比较
- 菜单路径加权：标题匹配压过菜单名匹配，更近的层压过更深的祖先
- `OverlayMetrics` 尺寸稳定：收窄列表保住会话高度、比屏幕行数小的预算不能裁掉它们、空预算退回画出的行、最宽列表预留的标题一直预留
- `OverlayMetrics.fittedPageSize` / `rowsPerColumn`：页脚与标题栏是 chrome，永不是行空间；`maxItemsPerPage` 是上限、几何尺寸可以把它压低（720 pt 双卡窗口里是 36 行而不是 60）；在缩放显示下精确 N 行的高度仍给出 N；比 chrome 还矮的面板仍显示一行
- `OverlayPlacement.containedFrame` 先把尺寸钳到可见帧，然后只在两个边距都还放得下时给某个方向 `screenMargin`：与屏幕一样大的边框不会被推出显示器，底部锚定的边框整体上移而不被缩放或裁切
- `OverlayPlacement` 的顶部安全区助手：`topInset` 取 `safeAreaTop` 与 `screenMargin` 的较大者，`fillScreenFrame` 修剪高度而不动原点，`clampedTop` 把边框整体下移而不缩放、也不推到 `visible.minY` 之下
- `OverlayPlacement.coverSize` 在前台窗口边框还没到时退回到整个可见帧，否则 `coverWindowSize` 跟随窗口
- `PanelAnchorCache`：`beginRead` 在新 pid 上开始一次读取，`apply` 拒绝陈旧 pid 的边框，`invalidate()` 忘掉两个边框
- `SpaceRescanGate` 丢掉 0.75 秒内同一 pid 的重复，并让新 App 立刻通过；`CatalogPublishPolicy` 只为"没有菜单栏的空结果"保留上一个列表
- `MenuCachePolicy`：指纹跟踪影响扫描的设置、条目恰好在年龄上限处过期、未来时间戳被拒、控制文件不匹配或缺失会让整个缓存失效
- `BindingItem` 经得起一次 JSON 往返（`id`、`usageKey`、带备选段的 `chord`、以及空组合键），这正是恢复缓存所依赖的
- `SystemHotkeyNames`：已知组合键在两种语言里都有名字、被重新分配的组合键与多段序列都没有、表里没有重复组合键
- 无名条目契约：空标题清洗成 `DescriptionCleaner.placeholder`，这正是 macOS 说不出名字的系统热键所显示的
- `IgnoredCommands`：标准化会在一个范围内去掉重复、同一标题在两个范围里保持两条规则、旧的平铺标题清单迁移为全局规则
- `KeyEventRouter`：热键在任意阶段都按面板→搜索→切换器的优先级作答；idle 放行、armed 取消、active 路由；按码的 Escape 在没有解码字符时也工作；裸 `/` 打开搜索；收窄时导航（方向键、⌃N/⌃P）与启用的分页对可用，此时按住的修饰键被剥掉；动作键回答执行/复制但不回答重复；⌫ 先弹勾选再弹层级；没有匹配的未知或 `nil` 键让面板保持
- `ModifierDoubleTap`：触发键两次干净的按下—松开且间隔在窗口内时开火、只给那个间隔计时（慢的按下仍算数）、敲了键就忘掉候选、绝不从按住的触发键开火；它读触发键的按下状态，所以一个机器服务全部六个触发键
- `DoubleTapTiming`：从系统双击速度推导窗口并钳到 0.25–0.6 秒，所以这个手势没有独立的用户设置
- `HyperEscape`：在 hyper 集合上武装、在窗口内干净松开时关闭、任何其他按下就清掉、期间用过某个键则取消关闭
- `FavoritesPolicy`：星标开关收窄到收藏、置顶把收藏排前并保住每组内的顺序、相等性覆盖全部三条规则

AppKit/AX/UI 行为没有单元测试：Xcode 项目只有一个 App 目标、没有测试目标，所以 `Core/AX`、`Core/Engine`、`Core/Input`、`Core/Storage` 与 `UI` 无处运行断言。
到目前为止的应对是把*能*纯的搬进 `Core/Pure`——`RowKeyRouter`、`PanelRowBuilder`、`HeaderLayout`、`PanelState`、`PanelSections`、`UsageOrdering`，
以及 v2.3.0 重构里的 `KeyEventRouter`、`ModifierDoubleTap`、`HyperEscape`、`FavoritesPolicy`、`SearchSnapshot` 与 `EnginePhase`——并在那里测它们。
引擎的 `handleKeyDown` 现在是 `KeyEventRouter` 之上的一层薄副作用执行器，所以最大的 AppKit 类的路由那一半在测试之下。

GitHub Actions 在 `macos-15` 与 `macos-26` 矩阵上跑这个 job，所以纯工具链层面的回归会表现为某一条腿失败：Debug 构建与 Release 构建（两者都关签名）、`swift test`，
以及纯目标的覆盖率报告。70% 行覆盖率下限是两条腿上的硬闸门：低于它的运行让 job 失败。打包只在 `macos-15` 那条腿上验证——`build_release.sh` 跑一遍，
DMG 对着它自己的 `.sha256` 核对。它在每次分支推送与每个 pull request 上运行。见 [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)。

## 发布

`scripts/build_release.sh` 构建 Release、**从构建好的包**读版本（`CFBundleShortVersionString`），并与 `MARKETING_VERSION` 交叉核对；
不匹配或空值是硬错误，因为一次 `sed` 挑错了那个设置的另一份副本，曾产出 `Kaname-.dmg` 与一个 `v` 发布 tag。有 Developer ID Application 身份时就用它签名
（并尝试 `notarytool` 公证；缺凭据时跳过并给一条警告），否则退回到稳定的本地身份或 ad-hoc 签名。自签名分支跳过 `--timestamp`，
所以离线构建不会在最后一步失败。`.app` 与 `.dmg` 都被签名并验证，公证时两者都被 staple，并在镜像旁边写一个 `<dmg>.sha256` 文件
（`shasum -a 256 "$DMG" | tee "$DMG.sha256"`）。

`scripts/install.sh` 构建、把包暂存到目标旁边、验证签名、用 `mv` 换上，并通过 `scripts/backup_app.sh` 把被替换的包复制到
`~/Library/Application Support/Kaname/backups/`。备份命名 `Kaname-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app`，保留最近五个；
交换中途失败会恢复最新的备份。除 `Kaname.app` 之外永不往 `/Applications` 里放东西：同一 bundle id 的第二份副本会被 LaunchServices 捡到，
而 ad-hoc 副本会变成一个独立的 TCC 身份。安装器干脆拒绝 ad-hoc 构建——要求稳定的 `Kaname Local` 或 Developer ID 签名——
因为 ad-hoc 的 cdhash 每次编译都变，于是 macOS 把每次重建都当成新 App，权限要重新问一遍。`scripts/build_swiftc.sh` 的 ad-hoc 产物只用于临时目录里的
`codesign --verify`。它先按 bundle identifier 退出 App（一个 AppleScript `quit`），最多等十秒，然后才用 `pkill -f` 针对目标自己的可执行路径
终止剩下的——路径很要紧，因为一次不过滤的 `pkill -f` 曾连构建副本和别的用户的实例都一起匹配上了。`scripts/build_swiftc.sh` 是给
Xcode 构建系统根本跑不起来的主机准备的兜底构建，因为它给每次编译都套上 `sandbox-exec`，而嵌套沙箱可能被拒。

`Distribution/kaname.rb` 是一个 Homebrew cask **模板**：`version` 与 `sha256` 是占位符（`__VERSION__`、`__SHA256__`），这个文件绝不能原样安装。
发布之后，脚本从 `build/Kaname-<version>.dmg.sha256` 里的摘要渲染它：

- `scripts/publish_release.sh` 写 `build/kaname.rb`，然后当 `KANAME_TAP_DIR` 指向 `suliveevil/homebrew-tap` 的 git 检出时，把它复制到 `Casks/kaname.rb`，
  提交并推送。
- tap 必须在 `gh release create` 与 `.sha256` 上传**之后**才更新；cask 的 URL 指向发布资产，所以先落地的 tap 提交对每个用户都是 404。
- 没有 `KANAME_TAP_DIR` 时脚本只渲染文件并打印手动步骤。若 sidecar 摘要缺失、格式错误、或渲染后仍有占位符存活，它拒绝继续。

这个 App 不通过 Mac App Store 分发。沙箱是关闭的，因为读另一个 App 的菜单栏、观察全局按键事件在 App Sandbox 里都不可能。

## 已知限制

- **只有菜单栏。** 直接实现在自定义视图、工具栏或游戏里的快捷键不可见；只有带快捷键的菜单项出现。兜底目录覆盖常见系统动作，不是每个 App 的私有 UI。
- **懒建菜单的 App** 在它们的菜单栏被打开过一次之前，可能显示不完整的结果。
- **安全输入** 按设计压制按键事件；面板隐藏。
- **面板没有空闲计时器。** 它留到 Esc 或面板/切换热键为止。这是刻意的，但留在屏幕上的面板就一直留在那儿。
- **覆盖窗口的几何是一个快照。** 覆盖尺寸在面板打开时按前台窗口的边框算出；之后再改变窗口尺寸不会重新摆放面板，直到它被重新打开。
- **Hyper 匹配按设计是宽容的。** 带三个及以上修饰键的热键也会匹配携带多余修饰键的事件，所以某个不相关的 App 加一个修饰键仍能触发它。少于三个修饰键的热键是精确匹配。
- **冲突只是信息。** macOS 挑赢家。系统快捷键列表是只读的：Kaname 不能绑定、修改或禁用聚焦搜索、调度中心或任何其他系统热键。
- **跨 App 范围是一个快照。** 搜索面板显示所选 App 那一刻的菜单扫描；20 秒缓存与懒建菜单仍然生效，而面板永不从前台 App 切走。
- **面板执行需要实时菜单项。** 兜底目录条目复制而不是执行，禁用的菜单项根本不执行。
- **检查更新是手动的。** 它需要网络，只比较版本，并且打开发布页而不是下载或安装任何东西。
- **不重映射。** Kaname 报告快捷键，并可以选择性地按压一个菜单项；它不定义自定义绑定。
- **录在收窄修饰键上的复制键有歧义。** 收窄时按住的修饰键被剥掉，所以旧的默认复制键 ⌘↩ 曾无法与 `⌘` + `↩` 区分，结果回答的是执行。
  默认复制键现在是裸 Return，没有这种撞车；把自定义复制键放在 ⌘ 上会再次撞上旧规则，所以那时要复制就得先松开 ⌘、或把它录在 ⇧↩ 上、
  或在标题栏里勾上 ⌘ 而不是按住它——勾选不在事件里。
- **tap 的 key-up 记忆是按键码的。** 一次被消费的 key-down 会让 tap 消费那个键的松开，无论那时修饰键变成什么，这是安全的方向；它区分不了两块键盘。
- **仅 macOS。** 它依赖 AppKit、辅助功能与 Core Graphics 事件 tap。
