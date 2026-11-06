# Kaname 代码审查报告

审查日期：2026-11-02　基线：`bd8b926`（main）　规模：201 个 Swift 文件 / 20,525 行

参考原则：《重构：改善既有代码的设计》第 2 版（下文简称 R2）、《Clean Code》、《Clean Architecture》
（依赖规则）、《The Pragmatic Programmer》、《Migrating to Swift 6》、Apple《macOS 人机界面指南》。

> **复审已做，见 `docs/code-review-2026-11-02-round2.md`。**
> 那份报告逐条实测了本文 20 个条目的真实状态，结论是：P0 与 P1-7/8/9、P3-18/19 真做完了；
> P1-5、P1-10、P2-14/15/16 **完全没动**；P0-4、P1-6、P3-17 做了一部分；
> P2-13 与 P3-19 已做完但本文漏标。本文第 0 节的「201 个 Swift 文件」、
> 第 104 行起的 P0-3/P0-4（无实施记录）、P2-13 的「1 个 accessibilityLabel」等度量口径均有误，
> 修正见复审报告第 2 节。

---

## 0. 结论摘要

这个代码库的**分层意识是好的**，问题不在"到处是烂代码"，而在**一条边界被击穿**和**一处并发模型混用**：

1. `Core/Engine` 直接 `import SwiftUI` 并构造 5 个 UI 控制器，UI 控制器又持有引擎 —— 依赖方向反了，且成环。这是所有"引擎无法单测、无法单独编译、UI 卡死连累输入链路"的结构性根因。
2. 31 处 `MainActor.assumeIsolated` 把"我确信在主线程"写成**运行期断言**。它不是降级，是 trap；这正是 Swift 6 迁移的第一个拦路石。
3. `emit` 用一个**无界**的 `DispatchQueue.main.async` 把每个键鼠事件投给主线程。主线程一旦 wedge，事件积压没有上限，恢复后会一次性回放。

其余为可维护性问题（God class、长函数、双轮询、双日志门面），不影响正确性但显著提高改动成本。

**量化基线**（用于以后判断是否变差）：

| 指标 | 当前值 | 说明 |
|---|---|---|
| 函数总数 / 中位长度 | 711 / 6 行 | 整体健康 |
| >80 行的函数 | 9 个 | 集中在引擎、Overlay、Scanner |
| 最大文件 | `ShortcutEngine.swift` 2,780 行 | 19 个 MARK 段 |
| Core 层跨文件 5 行重复块 | 2 处 | 其中 1 处是委托包装，不算重复 |
| `MainActor.assumeIsolated` | 31 | Swift 6 迁移阻塞点 |
| `@unchecked Sendable` | 0 | 好 |
| `try?` | 64（CrashReporter 15、Engine 14） | 静默失败面 |
| `@Observable` / `ObservableObject` | 0 / 10 | 未用 Observation 框架 |
| `SWIFT_VERSION` | 5.0，无 `SWIFT_STRICT_CONCURRENCY` | 迁移未启动 |

**同表在 2026-11-02 晚（批次 3/4 + Swift 6 迁移后）的实测值**，便于以后判断是否变差：

| 指标 | 新值 | 变化说明 |
|---|---|---|
| 摘要第 1 条（依赖倒置） | **已修** | 五个出站端口 + `PresenterFactory`；`Core/` 对 `UI/` 的 28 个类型 0 引用；`Core/` 独立 `-typecheck` 通过 |
| 摘要第 2 条（assumeIsolated） | 31 → **27 调用点**（另 4 处是注释）→ **24** | 3 处改为静态保证；剩余 24 处为 SDK 签名所强制，见 P0-2 |
| 摘要第 3 条（无界队列） | **已修** | 有界邮箱 + 整批单次跳转，丢弃计数进诊断 |
| `MainActor.assumeIsolated` | 24 | 不再是阻塞点：迁移已完成 |
| `@unchecked Sendable` | 3 | `FileLogStore`/`KeyboardMonitor`/`ActionRecorder`，各自已有锁或串行队列，契约写在注释里 |
| `SWIFT_VERSION` | **6.0 + `complete`** | 三条构建路径一致，Debug/Release 均 0 诊断；537 纯测试通过 |
| `Core/` 可独立编译 | **是** | 111 文件、Swift 6、`complete`、0 诊断，不依赖任何 UI 文件 |

---

## 1. 问题清单（按严重程度）

### P0 — 结构性缺陷，会直接导致不可用或不可诊断

#### P0-1　依赖方向倒置：Core 依赖 UI，且成环　✅ 已修

- 位置：`Kaname/Core/Engine/ShortcutEngine.swift:5`（`import SwiftUI`）、`:47-51`（`lazy var surface/hud/permissionsWindow/permissionGuide/settingsWindow`）、`:1102-1103`（`Theme.padding` / `Theme.rowHeight`）、`:2530`（`SettingsTab`）、`:2622`（`SettingsView`）
- 症状：
  - 引擎构造 UI 控制器，控制器构造时又拿到 `engine: self` → **双向依赖**。任何一方都替换不掉。
  - 业务计算（`panelCapacity`）读 UI 主题常量（`Theme.rowHeight`），布局改动会改到分页逻辑。
  - 引擎无法单独编译、无法单测：本次审查中 `-typecheck` 到引擎即因缺 `SurfacePanelController` 等类型而失败，只能退化为"检查 Core 除引擎外全部通过"。
- 依据：Clean Architecture 依赖规则（依赖只能指向内层）;R2 *Divergent Change*（同一类因 UI/业务两类原因被修改）。
- 建议：
  1. 引入**出站端口**：`protocol PanelPresenting { func show(state:); func hide(); func hud(_:) }`，引擎只依赖协议，实现留在 UI 层并在 `AppDelegate` 注入。
  2. `Theme.rowHeight/padding` 这类引擎真正需要的数值，下沉为 `Core/Pure/PanelMetrics`（纯值），UI 主题从它派生，方向反过来。
  3. `startPreview`（148 行截图夹具）整体移到 `PreviewScenarios.swift`，只在 `#if DEBUG` 或独立文件里存在。
- 注意：这是**唯一需要 Xcode 才能安全做**的改动，见第 4 节。

**✅ 已修（2026-11-02，批次 3/4）并已验证：**

- `Core/Ports/PresentationPorts.swift`：五个出站端口（`PanelPresenting`/`NoticePresenting`/`SettingsPresenting`/`PermissionsPresenting`/`PermissionGuidePresenting`）+ `EnginePresenters` 值类型。引擎只认协议，`App/AppDelegate.swift:12-20` 是唯一构造具体窗口的地方。
- 引擎的接线方式改为**注入工厂闭包**：`typealias PresenterFactory = @MainActor (ShortcutEngine) -> EnginePresenters`，`private lazy var presenters = makePresenters(self)`。运行时对象图仍是双向的（控制器点关闭时要回调引擎），消失的是**编译期**认知——那才是引擎无法独立构建、无法单测的原因。
- `panelPageSize` 改读 `OverlayMetrics.fillScreenPageSize(visibleFrame:maxItemsPerPage:)`（`Core/Pure`，纯函数 + 断言），不再读 UI 主题常量。
- `startPreview`（148 行截图夹具）整体移到 `App/PreviewScenarios.swift` 的 `extension ShortcutEngine`。刻意不加 `#if DEBUG`：截图取自用户手上的 Release 构建。
- 引擎文件已无 `import SwiftUI`。
- **验证（决定性）**：枚举 `UI/` 的 28 个顶层类型，逐个在 `Core/` 内做词边界检索 → **0 处引用**。并且 `Core/` 的 111 个文件在 **Swift 6 + `complete`** 下 `-typecheck` 独立通过、0 诊断，不需要任何一个 UI 文件——评审时这一步是失败的。

#### P0-2　31 处 `MainActor.assumeIsolated` 把隔离写成运行期断言　✅ 已解决（27 调用点 → 24，均为强制）

- 位置（计数）：`ShortcutEngine` 8、`CatalogLoader` 4、`StatusItemController` 3、`ShortcutTester` 3、`AppPermissions` 3、`SurfacePanelController` 2、`PermissionGuidePanelController` 2、`AppContextService` 2、`SettingsStore`/`UpdateChecker`/`AppDirectory`/`AppDelegate` 各 1
- **实测分类（2026-11-02 补查，推翻了初稿的"随时会 trap"）**：31 处无一落在无保证的线程上——
  - 20 处是 `addObserver(queue: .main)` / `DispatchQueue.main.async` / `RunLoop.main.add` / `asyncAfter`，主队列即主 actor 执行器，**当前安全**；
  - 2 处是 `NSEvent` 本地/全局监视器，AppKit 只在主线程回调；
  - 2 处是 `ShortcutTester` 的 tap 回调，挂在 `CFRunLoopGetMain()`，且 tap 是 **`.listenOnly`**（拿事件副本，不阻塞事件流），所以即使主线程 wedge 也不会重演五次卡死；
  - 其余是 `@Published` 的 Combine sink 等主线程写入点。
  - 所以它不是当下的崩溃源，**风险是性质上的**：保证来自"这个队列是主队列"，而不是"这个值的类型是 MainActor"。历史上已经发生过一次队列变更（tap 回调迁到独立线程），那次改动会让任何依赖队列的断言静默失效。
- 依据：*Migrating to Swift 6*（用隔离而非断言表达并发前提）;Pragmatic Programmer「不要依赖巧合」。
- 建议（迁移路径，不要一次全改）：
  1. 先开 `SWIFT_STRICT_CONCURRENCY = targeted` 让编译器列出真实问题，而不是靠人审查 31 处。
  2. 有 `queue: .main` 的地方改成 `@MainActor` 闭包或 `Task { @MainActor in }`，让类型系统接手这个保证；`Queue.main` 与 `MainActor` 的等价关系不该由注释维护。
  3. 最后才开 `complete` + `SWIFT_VERSION = 6`。

**✅ 已解决（2026-11-02）：迁移已完成，`assumeIsolated` 从 31 处降到 24 处，且这 24 处是结构性强制的，不是遗漏。**

- 迁移按上述三步走完：`targeted` → `complete` → `SWIFT_VERSION = 6.0`。三条构建路径（Xcode target、`scripts/build_swiftc.sh`、`Package.swift` 的 Pure target）现在编译同一种语言，实测 **0 error 0 warning**。
- **31 → 27**：初稿把 4 处**注释**也算了进去（`HUDPanelController` 与 `CatalogLoader` 已改成 hop、`PermissionGuidePanelController` 已改成 `isolated deinit`，三处只剩说明文字在提这个名字）。真实调用点是 27 处。
- **27 → 24**：其中 3 处（`ShortcutEngine` 的 `onListeningChanged`、`state.searchChangeHandler`、`permissions.onChange`）是**非 `@Sendable` 的普通闭包**，挂在 `@MainActor` 类型上。在 main-actor 默认隔离下，赋值端与调用端都会被推断为主 actor，编译器就是保证 → 断言直接删掉，构建仍然干净。这正是不建议里第 2 条想要的结果，只是达成方式不同：不必改成 `Task { @MainActor in }`（那会引入一次异步跳转），靠默认隔离即可静态成立。
- **剩下 24 处全部结构性强制**，接收端签名决定了闭包装不进主 actor：
  - 9 处 `addObserver(queue: .main)` / `DistributedNotificationCenter` —— 参数要求 `@Sendable`；
  - 4 处 `Timer`（`scheduledTimer` / `Timer(timeInterval:)` 的 block 是 `@Sendable`）；
  - 2 处 `NSEvent` 本地/全局监视器 —— 除了 `@Sendable`，其 handler **必须同步返回 `NSEvent?`**，连 hop 都做不到；
  - 4 处 Combine `.sink` / `DispatchWorkItem` / `DispatchQueue.main.async`；
  - 5 处 tap 回调（引擎 3 处经有界邮箱在 `DispatchQueue.main.async` 上投递；`ShortcutTester` 2 处是 `CGEventTapCallBack` 的 C 函数指针，定义上非隔离）。
- 结论：`assumeIsolated` 在这些位置**不是被压下去的警告，而是唯一能写的拼写**——它把"这个队列就是主 actor 的执行器"这句 SDK 层面的事实，变成了每次运行都检查一次的不变式。第 4 节里"归零"那条验收标准因此作废，替换为"`complete` 下 0 error，且每处 `assumeIsolated` 都能说出它的保证来自哪一行 SDK 契约"。

#### P0-3　事件投递队列无界：主线程 wedge 后一次性回放　✅ 已修

- 位置：`Kaname/Core/Input/KeyboardMonitor.swift:609-616`（`emit` 内 `DispatchQueue.main.async { handler?(event) }`）
- 症状：这是把输入链路移出主线程（`dbafe89`）的正确代价，但代价没有被约束。主线程卡 30 秒、期间用户敲了 300 个键 → 恢复瞬间这 300 个事件按序涌入引擎，面板会疯狂开关、和弦状态被一串过期事件污染。
- 依据：Pragmatic Programmer「没有无界的队列」;R2 *Comment as deodorant*（注释解释了为什么异步，但没解决没有上界）。
- 建议：
  1. 加**有界邮箱**（容量 ~64）与丢弃策略：溢出时优先丢 `.flagsChanged` 与 `isRepeat` 的按键，保留最新状态；计数器写进 `Diag`，让"发生过丢弃"可观测。
  2. 因为引擎只关心"当前状态"，还可以按 kind 合并（连续多个 `.flagsChanged` 只留最后一个）。这是**纯逻辑**，可以放进 `Core/Pure` 单测。

#### P0-4　错误处理：诊断能力在最需要时会静默失败　✅ 已修

- 位置：`Core/Services/CrashReporter.swift`（15 处 `try?`）、`Core/Services/ActionRecorder.swift`（6 处）、`Core/Pure/Sanitizer.swift:56`（`try!`）
- 症状：崩溃上报与录制的写入失败被 `try?` 吞掉，于是"用户报告卡死"时，恰恰最该有记录的两条链路可能什么都没写。`Sanitizer.swift:56` 的 `try!` 在正则表被改错时会**上线即崩**。
- 依据：Clean Code「不要返回/吞掉错误」;R2 *Replace Exception with Test*（可编译性应在初始化时验证一次）。
- 建议：
  1. `Sanitizer` 的规则表在类型初始化时编译一次并缓存；失败走 `preconditionFailure` 之外的可诊断路径（打印规则名 + 降级为不脱敏），不要 `try!` 每条消息一次。
  2. `CrashReporter` 的 15 处 `try?` 至少留一处**计数**：失败次数进诊断摘要，而不是彻底无声。
  3. 硬性约定：**输入链路（Core/Input + Core/Engine）里禁止 `try?`**，改为显式 `do/catch` + `Diag`。

### P1 — 可维护性风险，改动成本的主要来源

#### P1-5　`ShortcutEngine` 是 God class（2,780 行 / 19 个职责段）

- 位置：`Core/Engine/ShortcutEngine.swift`
- 症状：一个类同时承担生命周期、权限、目录扫描、输入状态机、面板内容、收藏、执行、统计、跨 App 冲突、第三方配置、实时测试、搜索、录制、诊断、预览。`startPreview` 148 行、`handleKeyDown` 118 行、`handleModifiers` 94 行、`rebuildPanel` 83 行。
- 依据：R2 *Large Class* / *Divergent Change*;Clean Code「类应该只有一个改变的理由」。
- 建议：按"变化原因"而非"文件名"切分，且**先抽 Pure 决策、后抽类**（前者零风险）：
  1. 输入状态机（`handleModifiers` 的窄化/粘滞/超时逃逸）→ 把分支判断抽成 `PanelNarrowing`（Pure）。
  2. 分页/容量（`panelCapacity` 读 `Theme`）→ `PanelMetrics`（Pure）。
  3. 冲突与统计已有独立 Pure 件，只差把持有它们的字段从这里搬走。
  4. 预览整段移出（见 P0-1）。

#### P1-6　长函数（>80 行）

| 位置 | 行数 | 建议 |
|---|---|---|
| `ShortcutEngine.swift:2583` `startPreview` | 148 | 整体移出到独立文件（P0-1） |
| `ShortcutEngine.swift:759` `handleKeyDown` | 118 | 按"修饰键组合 / 单键 / 特例键"拆三段 |
| `OverlayView.swift:91` `headerContent` | 98 | 拆身份块 / 芯片行 / 动作行三个子视图 |
| `ShortcutEngine.swift:653` `handleModifiers` | 94 | 拆安全输入 / 双击命令 / 窄化 / 静默态 |
| `MenuScanner.swift:50` `scan` | 87 | 抽 `scanMenuBarItem(at:)`，三层嵌套降为两层 |
| `OverlayView.swift:600` `rowView` | 83 | 拆行主体 + 行内动作菜单 |

#### P1-7　两套权限轮询并存，职责重叠　✅ 已修

- 位置：`Core/AX/AppPermissions.swift:129`（每权限 3s，仅在缺失时跑）、`:263` `startRevocationWatch`（全局 5s）
- 症状：两者都能发现"授权恢复"，且日志分不清是谁先发现（历史上已因此误判过一次"自愈"）。两套定时器也意味着两倍的唤醒。
- 建议：合并为**一个** 3s 的 `PermissionPoller`，内部对每个权限做前后差异比较，输出"谁在何时发现"的单一事实；删除另一套。

#### P1-8　`AppPermission.init` 11 个参数

- 位置：`Core/AX/AppPermissions.swift:62-73`
- 依据：R2 *Long Parameter List* → *Introduce Parameter Object*。
- 建议：把 `titleKey/iconName/iconColorName/detailKeys` 收进 `PermissionPresentation`，把 `isRequired/settingsURL/promptPreRegisters` 收进 `PermissionPolicy`。调用点只有 2 处。

#### P1-9　两套日志门面（`Diag` 78 处调用 / `AppLog` 43 处调用）

- 位置：`Core/Services/Diag.swift:14`、`Core/Services/AppLog.swift:13`
- 症状：同一件事有两个入口，读者无法从调用点判断"这条会不会进文件、会不会进诊断导出"。历史上排查卡顿时，两处都要 grep。
- 建议：保留一个门面（`Diag` 作 UI/内部诊断，`AppLog` 作为**唯一**落盘入口），另一个退化为适配器并在注释里写明关系；或直接合并，迁移 43 处调用。

#### P1-10　`fatalError("init(coder:) is not used")`

- 位置：`UI/Design/AppIconDragSource.swift:55`
- 说明：NSView 子类的 `required init?(coder:)` 是惯例写法，但可消除：标 `@available(*, unavailable)` 让编译器拒绝而不是运行期崩。属轻微。

### P2 — 可读性、一致性与 HIG 细节

- **P2-11 注释体量**：`KeyboardMonitor` 627 行中注释接近一半，部分在复述历史（哪一天卡了几次）。保留"为什么"，把"事故年表"移入 `CHANGELOG`/`docs`——R2 指出过长注释常是"代码说不清"的代偿，而这里的代码其实已经能说清。
- **P2-12 命名一致性**：`Diag` / `AppLog`（见 P1-9）；`InputWatchdog.tick(acknowledged:)` 刚由 `mainAcknowledged` 改名（已修，记录在此以免回退）；`HUDState` 等 6 处死代码已删除。
- **P2-13 无障碍标注分布不均**：`OverlayView` 24 处（行有 `accessibilityElement(children:.ignore)` + label + value + `.isButton` + `accessibilityAction`，做得很好），而 `SettingsView` 1 处、`PermissionsView` 1 处；全项目 `accessibilityHint` 0 处。HIG 要求所有可交互控件都有可读标签 → 设置页与权限页需要补。
- **P2-14 命中区域**：多处图标 14–26pt（`OverlayView.swift:216/250/697`、`SettingsView.swift:204/548`），而 `.contentShape` 全项目仅 7 处。HIG 建议可点区域约 44×44pt；小图标应通过 `padding` + `contentShape` 扩大命中区，视觉尺寸不变。
- **P2-15 未采用 Observation**：`ObservableObject` 10 处、`@Observable` 0。`@Observable` 能显著减少无谓刷新（面板一次按键会改多个 `@Published`）。属可选优化，与 Swift 6 迁移同批做更省事。
- **P2-16 固定尺寸**：`.frame(width:|height:)` 41 处，多数是图标尺寸（合理），但设置窗口的若干固定高度在长本地化文案下会截断。

**符合 HIG 的方面（不要"优化"掉）**：Reduce Motion 在 `Interaction.swift:131` 与 `PermissionGuidePanelController.swift:366` 都有显式判断并降级为静止/淡入；面板行无障碍完整；有 `NSApp.mainMenu`（`AppDelegate.swift:204`）；工具提示 16 处；面板是非激活面板（启动器类 App 的正确形态）。

### P3 — 工程与工具链

- **P3-17 测试只覆盖纯逻辑**：`Package.swift` 的 testTarget 只含 `Core/Pure`。引擎/输入层没有任何自动化测试（本次只能靠类型检查与一次性探针）。建议随 P0-1 解耦后，为 `PanelNarrowing`、`PanelMetrics`、事件邮箱补测。
- **P3-18 并发迁移未起步**：`SWIFT_VERSION = 5.0`，无 `SWIFT_STRICT_CONCURRENCY`。建议在 P0-2 第一步就开 `targeted`，让问题以警告形式暴露，而不是等 Swift 6。
- **P3-19 构建依赖已安装产物**：`scripts/build_swiftc.sh` 的 `Info.plist` 模板取自 `/Applications/Kaname.app`，App 被删除后即使有 Xcode 也构建不了。建议模板进仓库（或用 `GENERATE_INFOPLIST_FILE`）。

---

## 2. 原则映射（问题 → 原则）

| 问题 | R2 | Clean Code / Architecture | Pragmatic / Swift 6 |
|---|---|---|---|
| P0-1 分层倒置 | Divergent Change | 依赖规则、稳定依赖 | 正交性（UI 改动不应牵动输入逻辑） |
| P0-2 assumeIsolated | — | 错误处理：不要把不变式变成断言 | Migrating to Swift 6：用隔离表达前提 |
| P0-3 无界队列 | Comment as deodorant | — | 「没有无界的队列」 |
| P0-4 吞错误 | — | 不要吞异常 | 崩溃可观测性 |
| P1-5/6 大类长函数 | Large Class / Long Function | 单一职责 | — |
| P1-7 双轮询 | Duplicated Code | DRY | 一个事实只有一个来源 |
| P1-8 11 参数 | Long Parameter List | — | — |
| P1-9 双门面 | Divergent Change | 一致抽象 | — |

---

## 3. 实施顺序（按风险递增，每批可独立回滚）

**批次 0（已完成，`a624870` / `4d5b20b` / `bd8b926`）**
死代码 6 处；`KeySwallowRules` + `TapDiagnostics` 抽为 Pure 并测试；`keyDown/keyUp` 重复消除；31 处锁样板收敛为 `withLock`；`handleDisable` 拆分；`mainAcknowledged` 更名；构建脚本报错修正。

**批次 1（约 1–2 小时，零架构风险）**
P0-3 有界邮箱（Pure + 测试）→ P0-4 `Sanitizer` 预编译 + `CrashReporter` 失败计数 → P1-9 日志门面收敛。

**批次 2（约半天）**
P1-7 合并双轮询 → P1-8 参数对象 → P2-13/14 设置页与权限页无障碍与命中区。

**批次 3（已完成 2026-11-02，`c5b9c9d` / `bed5476` / `a48d926`）**
P1-6 五个长函数按原有接缝拆开（`handleKeyDown` 118→19、`handleModifiers` 94→40、`headerContent` 98→14、`rowView` 83→37、`MenuScanner.scan` 87→56）；P0-1 依赖倒置：`Core/Ports/PresentationPorts.swift` 五个出站端口 + `EnginePresenters`，引擎改为接收 `PresenterFactory` 闭包，`AppDelegate` 成为唯一知道具体窗口的地方；`Localization` 下沉 `Core/Services`；`panelPageSize` 改读 `OverlayMetrics.fillScreenPageSize`（纯函数 + 断言）；`startPreview` 整体移到 `App/PreviewScenarios.swift`，引擎文件去掉 `import SwiftUI`，`Core/` 不再出现任何 UI 类型。


**批次 4（已完成一部分 2026-11-02，`fa02e4a` / `9893723` / `a9bb100` / `23add2b`）**
P1-8 `AppPermission.init` 11 参数 → `PermissionPresentation` + `PermissionPolicy` 两个参数对象（`init(id:presentation:policy:check:requestPrompt:)`）；P1-9 `AppLog` 删除，43 处调用收敛到 `Diag`（其中 10 处是与相邻 `Diag` 行重复，直接删掉），四个 `Logger` 变成 `Diag` 镜像的私有细节；P1-5 剩余：跨 App 冲突扫描整体移到 `ConflictCenter`（引擎 2611→2430 行，冲突段只剩 4 个一行委托）。

**批次 5（进行中，`23add2b`）**
P0-2 第一步：`SWIFT_STRICT_CONCURRENCY = targeted` 同时开在 Xcode target、`build_swiftc.sh`、`Package.swift` 三处。当时只有 4 条警告（两个 `NSAnimationContext` 完成回调直接碰面板、`UpdateChecker` 把 `[weak self]` 可变绑定交给主队列），已全部修掉，现在 `targeted` 下 0 警告。
**实测 `complete` = 107 条**，大头是 `CatalogLoader` 的 `@MainActor (CatalogSnapshot) -> Void` 完成回调跨 `@Sendable` 传递（约 13 条）、`Diag`/`FileLogStore` 的静态可变状态（约 12 条）。下一步就是这批，不是"随手开一下"。

仍未做：31 处 `assumeIsolated` 归零、`complete` 迁移、`ObservableObject` → `@Observable`。

---

## 4. 重构后必须验证的关键点

1. **收窄（narrow）仍是唯一不可退的功能**：按住/点选修饰键 → 列表收窄、高亮、重排；⌫ 先撤销点选再 pop；Return 在收窄到一项时透传（非合成路径由前台 App 执行，合成路径由 `ShortcutInjector` 回放整条和弦）。
2. **吞键三通道**：全局热键、面板导航键、Escape；`⌥;` 这类带修饰键的绑定不得被裸 `;` 的捕获吃掉（`KeySwallowRulesTests` 已固定）。
3. **删除授权不再冻机**（五次事故的回归）：日志应出现 `accessibility revoked` → tap 拆除；或最多一次重装后 `event tap torn down`，**输入全程可用**。
4. **事件邮箱不丢关键状态**：主线程卡顿恢复后，面板状态应等于"最后一个事件"而非"回放整串"；丢弃计数可在诊断里看到。
5. **无障碍**：VoiceOver 走一遍面板行（应有"标题 + 快捷键 + 是否可用"）、设置页每个控件。
6. **Swift 6**：`SWIFT_STRICT_CONCURRENCY=complete` 下 0 error（✅ 达成，2026-11-02）；`assumeIsolated` **不归零**——剩下 24 处为 SDK 签名所强制，验收标准改为"每处都能指出保证来自哪一行 SDK 契约"（详见 P0-2）。
7. **构建产物**：`install.sh` 后 `codesign --verify --strict` 通过、`KanameCommit` 与 HEAD 一致、辅助功能授权未被重置（稳定签名）。
8. **回归基线**：`KeySwallowRulesTests`(11) + `TapDiagnosticsTests`(4) + `TapHealthTests` + `InputWatchdogTests` + `ComposedSwallowTests` 全绿；`install.sh` 能构建。

---

## 5. 本次无法完成的部分（如实记录）

- **~~无法构建与安装~~（已解除）**：本机 Xcode 只剩 692 KB 占位下载，`/Applications/Kaname.app` 也已不存在；Command Line Tools 缺 `libSwiftUIMacros.dylib`，任何含 `@State` 的文件都无法展开。因此批次 3 的全部内容、以及批次 1 中涉及 UI 的改动，本次**只出方案不动手**。
  - **后续：Xcode 已恢复（`/Applications/Xcode.app`），上面三条限制全部消失。** 批次 3/4 已动手完成并装到 `/Applications`。
  - 遗留的环境坑只有一条：本机 `sandbox-exec` 被拒，导致 xcodebuild 的 `swift-plugin-server` 展开 `@State` 宏时随机报 "malformed response"。`scripts/install.sh` 因此有 `build_swiftc.sh` 回退路径（用 `-load-plugin-library` 直接加载宏插件），重试或走回退即可，不是代码问题。
- 已验证的：`Core/Pure + Core/Input + Core/AX + Core/Services + Core/Storage` 类型检查 0 错误；全项目 `-parse` 0 错误；两个新纯类型的 27 条断言全部通过（XCTest 不可用，用一次性可执行探针执行）。
- 未验证的：`ShortcutEngine` 与全部 UI 文件本轮没有任何编译证据；`handleKeyDown` 等长函数的行为等价性没有测试兜底。
  - **后续：已验证。** 537 条纯逻辑测试通过（XCTest 恢复可用）；Debug 与 Release 双配置在 Swift 6 + `complete` 下 0 诊断；`Core/` 111 文件独立 `-typecheck` 通过；Release 已安装、启动、跑过 `panel`/`search` 预览与正常启动，日志无 crash。
  - 仍无测试兜底的：长函数拆分后的**行为等价性**依旧靠人工比对与预览验证，没有针对引擎的自动化测试（P3-17 未做）。
