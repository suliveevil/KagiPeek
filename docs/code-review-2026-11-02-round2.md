# KagiPeek 代码复审报告（第二轮）

复审日期：2026-11-02　基线：`83a1b03`　规模：`KagiPeek/` 129 文件 / 21,431 行 + `Tests/` 43 文件 / 6,028 行
对照：2026-11-02 第一轮（`docs/code-review-2026-11-02.md`，基线 `bd8b926`，126 文件 / 20,542 行）

参考原则同第一轮：《重构》第 2 版（R2）、《Clean Code》、《Clean Architecture》（依赖规则）、
《The Pragmatic Programmer》、《Migrating to Swift 6》、Apple《macOS 人机界面指南》。

---

## 0. 上一轮 20 项的真实结案情况

第一轮的条目**不是全部修完**。逐条实测（不信文档上的 ✅ 标记，每个都重新量过）：

| 条目 | 文档标记 | 实测 | 结论 |
|---|---|---|---|
| P0-1 依赖倒置 | ✅ 已修 | `Core/` 对自有 `UI/` 类型 0 引用；111 文件独立 `-typecheck` 通过 | **基本完成，有一处残留**（见 N1） |
| P0-2 assumeIsolated | ✅ 已解决 | 24 处，均为 SDK 签名强制 | ✅ 完成 |
| P0-3 无界队列 | ✅ 已修 | `InputMailbox` 有界 + 丢弃计数 + resync，有单测 | ✅ 完成 |
| P0-4 吞错误 | ✅ 已修 | `try!` 已消除；但 `try?` 仍有 59 处，输入链路 10 处 | **部分完成**（见 N4） |
| P1-5 God class | 无标记 | 引擎 2,530 行 / **19 个 MARK 段**（基线 2,775 / 20） | **未做** |
| P1-6 长函数 | 无标记 | 9 → **3** 个 | **大部分完成** |
| P1-7 双轮询 | ✅ 已修 | 单一定时器 | ✅ 完成 |
| P1-8 11 参数 | ✅ 已修 | `PermissionPresentation` + `PermissionPolicy` | ✅ 完成 |
| P1-9 双日志门面 | ✅ 已修 | `AppLog.swift` 已删除（git 确认） | ✅ 完成 |
| P1-10 `fatalError` | 无标记 | `AppIconDragSource.swift:55` 仍在 | **未做**（见 N5） |
| P2-11 注释体量 | 无标记 | `KeyboardMonitor` 27.8%（非"接近一半"），事故年表已压成 1 行 | **已不成问题**（原描述被证伪） |
| P2-12 命名一致性 | ✅ 已修 | — | ✅ 完成 |
| P2-13 无障碍 | 无标记 | `8586235` 已修：图标按钮补标签、装饰图标隐藏 | ✅ **已完成，文档漏标**（原度量方法错误，见第 3 节） |
| P2-14 命中区域 | 无标记 | `.contentShape` 仍 7 处，与基线一字未变 | **未做**（见 N10，且建议改判） |
| P2-15 Observation | 无标记 | `ObservableObject` 仍 10 处，`@Observable` 仍 0 | **未做**（见 N10） |
| P2-16 固定尺寸 | 无标记 | `.frame(width:/height:)` 仍 41 处，与基线一字未变 | **未做** |
| P3-17 测试只覆盖 Pure | 无标记 | 537 个测试、43 个文件；但引擎与输入层仍无测试 | **部分改善**（见 N9） |
| P3-18 并发迁移 | 无标记 | Swift 6 + `complete`，三条路径 0 诊断 | ✅ 完成 |
| P3-19 构建依赖已装产物 | 无标记 | `scripts/Info.plist` 已入库，已装产物退为兜底 | ✅ **已完成，文档漏标** |

**一句话**：P0 与 P1-7/8/9、P3-18/19 真做完了；**P1-5、P1-10、P2-14/15/16 完全没动**；
P0-4、P1-6、P3-17 做了一部分；P2-13、P3-19 已做完但文档没标。

---

## 1. 本轮新发现

### N1（P1）　P0-1 只搬走了一半：引擎仍持有一个 `NSWindow`

- 位置：`Core/Engine/ShortcutEngine.swift:108`

  ```swift
  /// The fixture's own settings window: an `NSWindow` with `isReleasedWhenClosed = false`
  /// has to be retained by someone, and the fixture lives in another file.
  var previewWindow: NSWindow?
  ```

- 症状：`startPreview` 整体搬到了 `App/PreviewScenarios.swift`，但**它创建的窗口仍由引擎持有**——
  因为 `isReleasedWhenClosed = false` 意味着总得有人保留它。于是「引擎不持有 UI 对象」这条只成立在
  `UI/` 目录的自有类型上，不成立在 AppKit 上。
- 依据：Clean Architecture 依赖规则。第一轮验证用的两个检查都**恰好漏掉这一类**：
  「枚举 `UI/` 的 28 个类型在 `Core/` 内检索」查不到 `NSWindow`（它是 AppKit 的），
  「`Core/` 独立 `-typecheck`」也查不到（AppKit 是 SDK，不是本项目的 UI 文件）。
- 为什么它不是小事：这条注释说明**依赖是被"谁保留窗口"这个内存管理细节逼出来的**，
  而不是被设计选择的。也就是说，解除它的办法不在架构层，而在夹具层。
- 建议：让夹具自己保留窗口。`PreviewScenarios.swift:132` 是唯一写入点、且**从无读取点**——
  它存在的唯一目的就是保活。在夹具文件里放一个 `private nonisolated(unsafe) static var retainedWindow: NSWindow?`
  （或一个 `PreviewWindowKeeper` 值类型），引擎的这行即可删除。零行为变化，编译期依赖真正断开。

### N2（P1）　`Core/Pure` 里有一个带锁的全局可变缓存，而且锁与 `nonisolated(unsafe)` 互相矛盾

- 位置：`Core/Pure/LogRotationPolicy.swift:29-45`

  ```swift
  private static let formatterLock = NSLock()
  /// ... `nonisolated(unsafe)` says so where the compiler can see it;
  /// the lock below is what makes it true.
  nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

  private static func formatter(for timeZone: TimeZone) -> DateFormatter {
      formatterLock.lock()
      defer { formatterLock.unlock() }
      ...
  }
  ```

- 症状（三条，一条比一条重）：
  1. **层违规**：`Core/Pure` 的定位是「可单测的纯决策」。这个文件里其余四个函数
     （`fileName`、`date(fromFileName:)`、`shouldRollover`、`filesToPrune`）全是纯的，
     唯独 `formatter(for:)` 是个跨调用共享的进程级缓存。纯策略和全局单例被焊在同一个 `enum` 里。
  2. **依赖注入被绕过**：文件头注释自豪地写着「`now` 是注入的，时区是参数，所以测试能钉住它」——
     但 `formatter` 的缓存是隐式全局，测试之间不隔离。
  3. **`nonisolated(unsafe)` 与锁自相矛盾**：`nonisolated(unsafe)` 的语义是「这个状态没有锁能保护它」
     （那正是 `CrashReporter` 信号处理器里 17 处用法的正当理由）。这里**有**锁。
     于是它的实际效果只是**关掉编译器检查**：以后任何不持锁访问 `formatters` 的写法都能顺利编译通过。
     锁的契约从「编译器可验证」退化成「注释里写着」。
  4. 附带的风格问题：项目约定是只用 `withLock`、不写 `lock()/defer { unlock() }` 配对
     （理由是漏一个 unlock 就是死锁）。这是全项目唯一一处手工配对。
- 依据：Clean Architecture（内层不应有可变共享状态）；Pragmatic Programmer「不要依赖巧合」。
- 建议（按优选顺序）：
  1. **删掉缓存，而不是修好它**。这个缓存存在的全部理由是格式化 `yyyy-MM-dd`，
     而同一个文件的 `filesToPrune` 已经在用 `calendar.dateComponents` 了。
     用整数补零拼文件名即可，整个锁 + 缓存 + `nonisolated(unsafe)` 一起消失，Pure 层恢复纯净。
  2. 若必须保留 `DateFormatter`，照 `Diag.State` 的既有做法收进一个不可变的 `State` 盒，
     用 `withLock`，并去掉 `nonisolated(unsafe)`。

### N3（P1）　✅ 已修（`9334117`）　`KeyEventRouter.route`：80 行代码 + 10 个参数，且在 Pure 层、已有 23 个测试

- 位置：`Core/Pure/KeyEventRouter.swift:67-173`（拆分后 `route` 只剩 16 行）
- 实测：107 行 = **80 行代码** + 18 行注释 + 9 行空行。不是被注释撑大的，是真的长。
- 症状：两个 R2 味道叠在同一个函数上 —— *Long Function* + *Long Parameter List*（全项目参数最多）。
  10 个参数天然分成四组，而函数体正是按这四组顺序走的一条决策链：

  | 组 | 参数 | 函数体对应段 |
  |---|---|---|
  | 事件 | `keyCode` `key` `modifiers` `isRepeat` | 全程 |
  | 应用态 | `phase` `settings` | 全局热键判定 |
  | 面板态 | `panel` `prefix` `pending` | 导航/行键/⌫/和弦 |
  | 数据 | `items` | 和弦解析 |
- 依据：R2 *Long Parameter List* → *Introduce Parameter Object*；*Long Function* → *Extract Function*。
- 为什么它是下一个最该动的：它在 **Pure 层**（拆分零运行时风险），且 `KeyEventRouterTests`
  已有 **23 个测试**兜底——这是全项目唯一「有测试网还敢拆」的长函数。相比之下
  `startPreview`（149 行）是截图夹具、`CatalogLoader.scan`（81 行）在 AX 层无测试。
- 建议：参数对象收「面板态」三个（`panel`/`prefix`/`pending` 本就是同一件事的三面）；
  函数体按已有顺序切三段：`routeHotkey` → `routePanelKey` → `routeStroke`。
  **顺序必须逐条保留**——函数上方的注释明确写了「顺序是有意义的：两个热键共用同一和弦时，
  先问的那个回答」，`HotkeyChoice` 的声明顺序也是承重的。

- **实际做法（`9334117`）**：`route` 107 → **16 行**。10 个参数按"两样东西"分，不是按四组：
  ① `keyCode`/`key`/`modifiers`/`isRepeat` 本来就是 `KeyEvent` 的字段，引擎手上就有这个对象，
  直接传它（Preserve Whole Object，不必新造类型）；② 其余六个每次都从 `EngineState` 读、
  且**本文件四个函数签名都要同一组**，收成 `RoutingContext`。
  **参数对象值不值得成类型，判据是"这一组是否穿过多个签名"** ——只出现一次的话不值得。
  函数体切三段：`routeActiveKey` 25 → `ownedKey` 54 → `composedStroke` 27。顺序逐条保留。
  `ownedKey` 留 54 行没再切：其中约 20 行是承重注释，剩下的是一条五问的链，合着读比切开好。

- **⚠️ 拆分过程中踩到一个 Swift 陷阱，测试抓住的，值得单独记**：
  `ownedKey` 最初返回 `KeyDownAction?`，而 `KeyDownAction` **自身有 `case none`**。
  在返回 Optional 的函数里，裸 `.none` 会被编译成 **`Optional.none`**（"这键不归面板管，继续"），
  而不是 `Optional.some(.none)`（"面板吃下这键，答案是：啥也不做"）。**能编译、能跑**，
  且只在三元表达式里才警告 —— `return .none` 完全不警告。后果是顶层 ⌫ 从终结分支静默变成
  穿透进和弦合成，正好被 `testBackspaceAtTopLevelIsIgnored` 钉住。
  正解不是写全 `KeyDownAction.none`（那只修一处、陷阱还在），而是**让两种含义无法写成同一个样子**：
  私有 `enum OwnedKey { case action(KeyDownAction); case notOurs }`，`.action(...)` 参数位的类型是
  非 Optional 的 `KeyDownAction`，那里的 `.none` 只能是枚举分支。
  全项目扫过同类：6 个类型声明了 `case none`，**没有其他函数**在 Optional 返回里写裸 `.none`。
- 验收：537 测试全绿（含本路由 23 个表征测试）；Core 独立 `-typecheck` 0 诊断；
  panel 预览 `app=57 system=79 page=1/6 rows=24` 与拆分前逐字相同；search 预览
  `items=136 results=136 first=Cut` 相同且截图 **78474 字节完全一致**。

### N4（P1）　P0-4 残留：诊断导出失败时**完全静默**，而同一个函数里写文件失败却会弹提示

- 位置：`UI/Settings/SettingsView.swift:1019-1026`

  ```swift
  private func exportDiagnostics() {
      guard let data = engine.diagnosticsReport() else { return }        // 序列化失败：什么都不发生
      guard let url = ExportPanel.run(...) else { return }
      do { try data.write(to: url, options: [.atomic]) }
      catch { engine.showHUD(chord: "!", title: error.localizedDescription) }  // 写失败：弹 HUD
  }
  ```

- 症状：用户点「导出诊断」，如果 JSON 序列化失败，**按钮看起来没反应**。
  而紧挨着的写文件失败会弹 HUD。同一个六行函数里，两种失败的处理方式相反。
- 为什么会失败：`ShortcutEngine.diagnosticsReport()` 的返回值是
  `try? JSONSerialization.data(withJSONObject:)`（`:2528`），加上里面还有两处 `try?`。
  `[String: Any]` 里混入不可序列化的值时整体变 nil。
- 这正是第一轮 P0-4 描述的原话：「诊断能力在最需要时会静默失败」。
- 依据：Clean Code「不要吞掉错误」。
- 建议：`diagnosticsReport()` 改为 `throws` 并让三处 `try?` 各自说明失败原因；
  调用方沿用已有的 `catch` 分支弹 HUD。改完这条，P0-4 才算真正闭环。

### N5（P2）　P1-10 未做：`fatalError("init(coder:) is not used")` 仍在

- 位置：`UI/Design/AppIconDragSource.swift:55`
- 现状：第一轮已给出正确建议（标 `@available(*, unavailable)` 让编译器拒绝，而不是运行期 trap），
  但没动手。属轻微，一行改动。

### N6（P2）　跨文件重复块从 2 处涨到 6 处——新增代码是复制出来的

- 位置（两处真重复，值得动手）：
  1. **AX 取值梯子写了两遍**：`Core/AX/MenuScanner.swift` 与 `Core/AX/WindowGeometry.swift`
     各有一套私有的 `attribute(name:of:)` + 类型化变体（`pointAttribute`/`sizeAttribute`/`elementAttribute`），
     每套都是 `CFGetTypeID` 守卫 + `unsafeDowncast` 的同一段五行。
  2. **NSWorkspace 观察者生命周期写了两遍**：`Core/AX/AppContextService.swift:28-33` 与
     `Core/AX/AppDirectory.swift:19-26` 都手工维护 `observers: [NSObjectProtocol]` +
     `start()` 的 `guard observers.isEmpty` + `stop()` 的 `observers.forEach { center.removeObserver($0) }`。
- 另四处是委托包装或结构体字面量，不算重复，不必动。
- 依据：R2 *Duplicated Code*；Pragmatic Programmer DRY /「一个事实只有一个来源」。
- 建议：抽 `AXValueReader`（取值梯子）与 `WorkspaceObservation`（token 持有者，顺带让 `start/stop` 对称）。
  两者都是小抽取，AX 层无测试网，改动要配合预览验证。

### N7（P2）　`Core/Pure` 有一个文件 `import SQLite3`

- 位置：`Core/Pure/BetterTouchToolScanner.swift:2`
- 症状：Pure 层唯一直接依赖 C 数据库 API 的文件（另四个 `import CoreGraphics` 是几何数学，可接受）。
  它意味着这个"纯"扫描器只能在有真实 BTT 数据库时才有意义。
- 判断：**成本已付、收益不大**，现阶段不建议动（其余六个扫描器共用 `ConfigFileScanner`，
  骨架重复只有 1 处 5 行，整体是健康的）。记录在此，是为了让"Pure = 无副作用"这个约定
  有一个明确的例外清单——约定没有清单就会被人默认成立。

### N8（P2）　`EngineState` 持有 `NSImage`（AppKit）——形式上的依赖违反，建议保留

- 位置：`Core/Engine/EngineState.swift:23`（`appIcon`）、`:61`（`searchScopeIcon`）
- 症状：引擎的状态结构体装着一个 UI 框架类型。`:59-60` 的注释写明了这是有意为之
  （「图标是 AppKit 的，只能留在引擎侧」）。
- 判断：**不建议改**。依赖规则关心的是「UI 的变化会不会逼业务规则改」——
  `NSImage` 是数据类型不是行为类型，它不会。换成 `Data` 或一个端口要付真实的复杂度，换不来行为收益。
- 建议：保持现状，但把理由写进这条注释（现在只写了"只能留在引擎侧"，没写"为什么这样是安全的"），
  免得第三轮又把它当成漏网的违规重新查一遍。

### N9（P3）　✅ 已修（`8a4909e`）　最大的测试文件是个杂物抽屉

- 位置：`Tests/KagiPeekCoreTests/KagiPeekCoreTests.swift`，**1,105 行 / 109 个测试**
- 症状：它是按 *target* 命名的，不是按类型命名的。拆开时才发现比原先描述的更具体——
  它不是"一个类测了十几个类型"，而是**塞了 29 个 `XCTestCase` 类**（`KeyChordTests`、
  `KeyFormatterTests`、`DescriptionCleanerTests`……`PanelHighlighterTests`）。
  其余 42 个测试文件都遵循「一类型一文件」，唯独最大的这个不遵循。
- 代价：测试失败时，从文件名看不出是哪个类型坏了；`KeyChord` 的测试和 `L10n` 的测试
  挤在同一个文件里，改前者要打开后者。
- 建议：按被测类型拆开。纯文件搬运，零风险，可以随时中断——这是最适合"有空就做一点"的一类改动。

- **实际做法（`8a4909e`）**：拆成 29 个文件，原文件删除。作为**纯搬运**提交：
  29 个新类的内容拼接后与原文 **SHA256 一致**（`59cff75194207a06`），测试函数 109 → 109，
  diff 是 29 新增 + 1 删除、**0 修改**。
  三件事让它可以脚本化而不是手搬：① 29 个类**互不引用**（先按类名交叉检索确认过，
  所以没有共享 helper 需要复制或上提）；② 文件顶层只有两行 import；③ 4 个类的文档注释
  落在**上一个类之后的空档里**而不是自己头顶，按语义重新挂回各自注释的类
  （菜单路径加权→`MenuPathWeightTests`、磁盘缓存新鲜度→`MenuCachePolicyTests`、
  面板高度→`PanelSizeStabilityTests`、`BindingItem` JSON 往返→`MenuCacheRoundTripTests`）。
- **顺带（`e410fe5`）**：这轮才第一次认真看 `swift test` 的输出，发现测试 target 有
  **16 处既有警告**（应用 target 自 Swift 6 迁移起就是 0 警告，所以它们一直没露出来）：
  13 处"返回值未使用"（`InputMailbox.post`、`ModifierTapTracker.flagsChanged`，两者在测试里
  本就故意丢弃返回值，用 `_ =` 是诚实写法而非压制）+ 3 处"var 从未改值"（改 `let`）。
  现在测试构建也是 0 警告。值得做的原因不只是整洁：第二轮刚纠正过第一轮的四个度量数字，
  一个无警告的测试构建是下一轮"是不是变差了"的稳定基线。

### N10（P2）　P2-14 / P2-15 / P2-16 未做，且 P2-14 的判定本身值得改

- **P2-14 命中区域**：`.contentShape` 仍 7 处、与基线一字未变。但第一轮的建议（44×44pt）
  **对本项目的主要界面并不适用**：面板是启动器式的密集列表，行高 **30pt**
  （`OverlayMetrics.rowHeight`，`Theme.rowHeight` 从它派生），
  把收藏星标撑到 44pt 会直接毁掉这个产品赖以成立的信息密度。
  实测 `OverlayView.swift:724-748` 的星标是 14×14 + `.contentShape(Rectangle())`，
  即已保证 14pt 内可点（含透明区），且**行被键盘选中时星标也会显形**，键盘用户可达。
  → 建议改判：密集面板不套用 44pt；这条只对设置窗口这类标准界面成立，而设置窗口用的是文字按钮。
- **P2-15 Observation**：`ObservableObject` 10 处、`@Observable` 0，未动。
  `EngineState` 一次按键会改多个 `@Published`，确实在付无谓刷新。可选优化，不做也不算债。
- **P2-16 固定尺寸**：`.frame(width:/height:)` 41 处未变，其中设置窗口 9 处。
  长本地化文案下截断的风险仍在，但属「等真的出现再说」——中英双语已齐（`L10n` 851 行），
  没有观测到截断。

---

## 2. 上一轮度量口径的修正（第三轮别再踩）

上一轮有四个数字是错的，都会误导「是否变差」的判断：

| 上一轮写的 | 实测 | 影响 |
|---|---|---|
| 「201 个 Swift 文件」 | 基线 `bd8b926` 是 **169 个 `.swift`**（126 应用 + 42 测试 + Package.swift）；217 是全部受控文件数 | 基数错了 32 个，"规模增长"无从判断 |
| 「P2-13 设置页 1 个 `accessibilityLabel`」 | 设置页 59 个控件里 11 个 `Toggle` 全是 `Toggle(localization.text(...), isOn:)`，27 个 `Button` 里 26 个带文字 —— **SwiftUI 从文本自动推导标签** | 真实缺口是「图标按钮」和「装饰图标」各一个，已在 `8586235` 修掉。按"标签数"衡量会得出相反的结论 |
| 「P2-11 `KeyboardMonitor` 注释接近一半」 | 实测 **27.8%**（188/677），且事故年表已压成 1 行（`:27`，引用日期作为证据，属正当的"为什么"） | 这条本来就不构成问题 |
| 「P3-17 测试只覆盖纯逻辑」 | 现在 537 个测试 / 43 个文件 —— 覆盖面确实大幅改善，只是**引擎与输入层本身**仍无测试 | 措辞要精确：缺的是"对引擎/输入层的测试"，不是"测试太少" |

另有一条方法上的教训：第一轮用「枚举 `UI/` 类型在 `Core/` 内检索」验证 P0-1，
这个检查**查不到 AppKit 类型**，因此 N1 的 `NSWindow` 漏网。
第三轮验证依赖方向时，检查清单里要显式包含 AppKit 的**行为**类型
（`NSWindow` / `NSView` / `NSViewController` / `NSHostingView` / SwiftUI 的 `View`），
数据类型（`NSImage` / `NSColor` / `CGRect`）可以豁免并在文档里写明。

---

## 3. 原则映射（本轮）

| 发现 | R2 | Clean Code / Architecture | Pragmatic / Swift 6 / HIG |
|---|---|---|---|
| N1 引擎持有 NSWindow | — | 依赖规则（形式违反：AppKit 不在检查清单内） | — |
| N2 Pure 层的可变缓存 | *Mutable Data* | 依赖规则（内层不应有共享可变状态） | Migrating to Swift 6：`nonisolated(unsafe)` 只用于无锁可加的状态 |
| N3 route 长函数 + 10 参数 | *Long Function* + *Long Parameter List* | 函数只做一件事 | — |
| N4 静默失败 | — | 不要吞掉错误 | 崩溃可观测性 |
| N5 fatalError | — | 用编译期拒绝代替运行期 trap | — |
| N6 重复块 2→6 | *Duplicated Code* | DRY | 一个事实只有一个来源；「破窗」 |
| N8 EngineState 的 NSImage | — | 依赖规则（形式违反，但成本 > 收益） | — |
| N9 测试杂物抽屉 | — | 测试的组织应镜像被测单元 | — |
| N10 命中区域 44pt | — | — | HIG：44pt 不适用于密集启动器界面 |

---

## 4. 建议的下一批（按风险递增，每批可独立回滚）

**批次 A（零风险，有测试网）**　✅ **已完成**：`9334117` + `8a4909e` + `e410fe5`
N3 拆 `KeyEventRouter.route`（Pure + 23 个测试兜底）→ N9 拆 `KagiPeekCoreTests`（纯文件搬运）
→ 顺带把测试构建的 16 处既有警告清零。（详见 N3 / N9 条目的"实际做法"）

**批次 B（零行为变化，编译期收益）**
N1 把 `previewWindow` 移回夹具（唯一写入点、无读取点）→ N5 `fatalError` 换 `@available(*, unavailable)`。

**批次 C（小抽取，需预览验证）**
N2 删掉 `LogRotationPolicy` 的 formatter 缓存（用整数补零拼文件名）→ N6 抽 `AXValueReader` 与
`WorkspaceObservation`。

**批次 D（收口）**
N4 让 `diagnosticsReport()` 抛错、调用方沿用已有 HUD 分支 —— 做完这条 P0-4 才闭环。

**建议不做**：N8（`EngineState` 的 `NSImage`）、N10 的 44pt 部分、P2-15 的 Observation 迁移。
三条都是"改了更干净但换不来行为收益"，记账即可。

**仍未解决的大项**：P1-5 引擎 God class（2,530 行 / 19 段）。它比上面任何一条都重，
但也最不适合连续小批做——需要一次专门的切分设计，建议单独开一轮。

---

## 5. 量化基线（供第三轮比对）

| 指标 | 第一轮基线 `bd8b926` | 第二轮 `83a1b03` | 批次 A 后 `e410fe5` | 说明 |
|---|---|---|---|---|
| 应用文件 / 行数 | 126 / 20,542 | 129 / 21,431 | **129 / 21,485** | 批次 A 只动 Pure 与引擎各一处 |
| 测试文件 / 行数 | 42 / 5,857 | 43 / 6,028 | **71 / 6,090** | N9：1 个 1,105 行文件 → 29 个一类一文件 |
| 函数总数 / 中位长度 | 711 / 6 行 | 752 / 8 行 | **755 / 9 行** | 中位变长是拆分的正常产物 |
| >80 行的函数 | 9 | 3 | **2** ✅ | `startPreview` 149 / `CatalogLoader.scan` 81（`route` 已拆，见 N3） |
| 最大文件 | `ShortcutEngine` 2,775 | 2,530 | **2,529** | 仍 19 个 MARK 段（P1-5 未动） |
| 测试构建警告 | — | 16 | **0** ✅ | `e410fe5`；应用构建自 Swift 6 迁移起就是 0 |
| Core 跨文件 5 行重复块 | 2 | 6 | **6** | 未动（N6 待做） |
| `try?` | 64 | 59 | **59** | 未动；输入链路仍有 10（P0-4 待收口） |
| `try!` | 1 | 0 | **0** ✅ | 见下方计数口径说明 |
| `MainActor.assumeIsolated` | 31（字符串匹配） | 24（真实调用点） | **24** | 未动；均为 SDK 签名强制 |
| `@unchecked Sendable` | 0 | 8 | **8** | 5 个类型，各有锁或串行队列，契约写在注释里 |
| `nonisolated(unsafe)` | — | 23 | **23** | CrashReporter 20（信号处理器，正当）+ LogRotationPolicy 2（**不正当**，见 N2）+ UI 1 |
| `ObservableObject` / `@Observable` | 10 / 0 | 10 / 0 | **10 / 0** | 未动 |
| `accessibilityHint` | 0 | 0 | **0** | 但 P2-13 的真实缺口（图标按钮/装饰图标）已修 |
| `.contentShape` | 7 | 7 | **7** | 未动（见 N10） |
| `.frame(width:/height:)` | 41 | 41 | **41** | 未动 |

**计数口径（第三轮别再踩）**：本轮统计 `try!` 得到 2、`assumeIsolated` 得到 29，一度以为两者都回退了。
实际是正则把**注释里的提及**也算进去了 —— 那 2 处 `try!` 是 `Sanitizer.swift:78-79` 在解释
"为什么这里不用 `try!`"，真实代码 0 处；29 处 `assumeIsolated` 里有 5 处是注释，真实调用点仍是 24。
**统计代码气味时必须先剥掉行内注释**（`re.sub(r'//.*$', '', line)` 后再匹配），否则每轮都会
凭空"恶化"几条。这正是第 2 节想防的同一类错误，写报告的人自己也踩了。
| `SWIFT_VERSION` | 5.0 | **6.0 + `complete`** | 三条路径 0 诊断，537 测试通过 |
| `Core/` 独立 `-typecheck` | 失败 | **通过（0 诊断）** | 但用的是自有 UI 类型口径，漏 AppKit（见 N1） |
