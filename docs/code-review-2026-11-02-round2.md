# Kaname 代码复审报告（第二轮）

复审日期：2026-11-02　基线：`83a1b03`　规模：`Kaname/` 129 文件 / 21,431 行 + `Tests/` 43 文件 / 6,028 行
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
| P0-4 吞错误 | ✅ 已修 | `try!` 已消除（应用代码 0，测试 3）；`try?` 62 → 59，其中**吞真错误的 57 → 54** | **部分完成**：诊断导出那条已闭环（N4），其余 54 处未动 |
| P1-5 God class | 无标记 | 引擎 2,530 行 / **19 个 MARK 段**（基线 2,775 / 20） | **未做** |
| P1-6 长函数 | 无标记 | 9 → **3** 个 | **大部分完成** |
| P1-7 双轮询 | ✅ 已修 | 单一定时器 | ✅ 完成 |
| P1-8 11 参数 | ✅ 已修 | `PermissionPresentation` + `PermissionPolicy` | ✅ 完成 |
| P1-9 双日志门面 | ✅ 已修 | `AppLog.swift` 已删除（git 确认） | ✅ 完成 |
| P1-10 `fatalError` | 无标记 | `AppIconDragSource.swift:53-56` 已有 `@available(*, unavailable)` | ✅ **本条的"未做"判定被证伪**（见 N5 更正） |
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

### N1（P1）　✅ 已修　P0-1 只搬走了一半：引擎仍持有一个 `NSWindow`

- 位置：`Core/Engine/ShortcutEngine.swift:108`（该行已删除）

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

- **实际做法**：引擎那两行（注释 + 属性）已删除；`App/PreviewScenarios.swift` 里新增
  `private final class PreviewWindowOwner { static let shared = …; var window: NSWindow? }`，
  写入点改为 `PreviewWindowOwner.shared.window = window`。
  **没有采用上面建议的 `nonisolated(unsafe) static var`** —— 那正是本项目已决定只留给信号处理器
  的压制手段（见 MEMORY.md），而这里明明有锁之外的正解：默认隔离就是 MainActor，一个
  `@MainActor` 类（默认即所得）+ 不可变 `static let` 单例是**类型检查通过**的，不需要任何压制。
  结构正确优先于压制，这次也照此办理。

- **改完 Core 里的 AppKit 画面**（按"行为类型"口径扫全 `Core/`，共 27 处）：
  **`NSWindow`/`NSView`/`NSViewController`/`NSHostingView`/`NSPanel` 已全部清零**。
  剩下的是 25 处 `NSWorkspace`（系统级服务门面：查运行中的 App、`notificationCenter`、打开 URL）
  + 2 处 `NSApplication`（一个通知名常量 + `CrashReporter` 里由 `@MainActor install()` 装的
  `isActive` 读取闭包）。**持有 `NSWorkspace.shared` 不等于持有 UI 对象**——它是 AX/应用上下文层
  本来就必须用的系统服务；`NSImage`/`CGRect`/`NSColor`/`NSScreen` 属数据类型，复审已判定豁免。
- 验收：Core 独立 `-typecheck` 0 诊断；Debug/Release 均 0 error 0 warning；
  **专门跑了 `settings` 预览**（正是这条路径），窗口正常创建并出图
  （`settings-0.json` = 680×600 / "Kaname Settings"，与代码请求的尺寸一致——若保活失效，
  窗口会在布局前就被释放）；`panel` 预览 `app=57 system=79 page=1/6 rows=24` 与基线逐字相同。

### N2（P1）　✅ 已修（`f0a74b8`）　`Core/Pure` 里有一个带锁的全局可变缓存，而且锁与 `nonisolated(unsafe)` 互相矛盾

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
     （理由是漏一个 unlock 就是死锁）。LogRotationPolicy 是 **Pure 层唯一一处**手工配对。
     > **更正（批次 C 复核）**：第二轮写的「全项目唯一一处手工配对」是错的，和 N5 同一类错误——
     > 数了标识符就下结论，没有核实。实测全项目有 **15 处**手工 `lock()/unlock()` 配对
     > （`RingBuffer` 5、`CatalogLoader` 4、`Diag` 4、`KeyboardMonitor` 的 `withLock` 定义 1、
     > `LogRotationPolicy` 1）。删掉 LogRotationPolicy 那处后剩 **14 处**。
     > 这条的分量因此要下调：它不再是「唯一的破例」，而是「15 处里唯一同时戴着
     > `nonisolated(unsafe)` 的那一处」——真正的问题仍是上面第 3 条。
     > 顺带发现 `Diag.configure` 是这 14 处里**唯一没有 `defer`** 的一处（同文件另外三处都有），
     > 已在本轮补齐。
- 依据：Clean Architecture（内层不应有可变共享状态）；Pragmatic Programmer「不要依赖巧合」。
- 建议（按优选顺序）：
  1. **删掉缓存，而不是修好它**。这个缓存存在的全部理由是格式化 `yyyy-MM-dd`，
     而同一个文件的 `filesToPrune` 已经在用 `calendar.dateComponents` 了。
     用整数补零拼文件名即可，整个锁 + 缓存 + `nonisolated(unsafe)` 一起消失，Pure 层恢复纯净。
  2. 若必须保留 `DateFormatter`，照 `Diag.State` 的既有做法收进一个不可变的 `State` 盒，
     用 `withLock`，并去掉 `nonisolated(unsafe)`。

- **实际做法**：选了方案 1。锁、`formatters` 缓存、`formatter(for:)` 一起删除，
  代之以两个纯函数 `dayStamp(for:timeZone:)` 与 `date(fromDayStamp:timeZone:)`——
  用 `calendar.dateComponents` 拿整数再 `String(format: "%04d-%02d-%02d")`，
  和同文件 `filesToPrune` 已经在用的路子一致。`fileName(for:)` 改调 `dayStamp`，
  `date(fromFileName:)` 改调 `date(fromDayStamp:)`，两者互为正逆。
  `date(fromDayStamp:)` 额外做了一次**回读校验**（拆出来的年月日再问一次日历，
  对不上就返回 `nil`）：拼字符串这条路没有 `DateFormatter` 替我们拒绝
  `2026-02-31` 这种日期，回读是唯一能挡住它的地方。
  补了 2 个测试（补零、以及"不存在的日子被拒绝"），537 → 539。
  Pure 层恢复无共享可变状态；`nonisolated(unsafe)` 在全项目只剩 `CrashReporter` 的 17 处。

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

### N4（P1）　✅ 已修（批次 D）　P0-4 残留：诊断导出失败时**完全静默**，而同一个函数里写文件失败却会弹提示

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

- **实际做法**（比建议多改了一处调用方，见下）：
  1. `diagnosticsReport()` → `throws -> Data`。**三处 `try?` 各归各位**：
     - `JSONSerialization.data(withJSONObject: payload)` 变成 `try` 向外抛 —— 报告本身
       序列化不了就是没有报告，这条必须让调用方知道。
     - settings 快照那两处（`JSONEncoder().encode` + `jsonObject(with:)`）收进一个
       `do/catch`，失败时把原因写进报告里：**`payload["settingsError"]`**。
       它是一段**增益**而不是必要条件——没有 settings 的报告仍然值得附上，
       所以不该因为它而整体失败；但"静默丢掉一段"正是编码器坏了却没人发现的方式。
       这样**没有吞掉任何东西**：原因跟着文件一起被附上。
  2. `SettingsView.exportDiagnostics()` 两种失败现在走同一条路（本条的症状就是它们不一致）：
     `Diag.error` 记原因 + HUD 提示。**HUD 文案复用了同文件另一条导出路径已在用的
     `.diagnosticsExportFailed`（"Export failed: %@"）**，连弦号 `!` 都一样。（差点又新造一个键——
     那个键本来就带 `%@` 占位符，比我想造的更合适。）
     日志那行不是和 HUD 重复：**这条路径失败时没有任何文件产生**，日志是唯一留下的痕迹，
     而 HUD 会消失、什么东西都留不下。
  3. **`AppDelegate.writeSelfTestAndExit()` 是第二个调用方，比 SettingsView 更糟**：
     报告为 nil 时它 `engine.stop()` + `terminate` **直接退出，一句话不说，也不 flush**
     —— 自检失败看起来和自检通过一模一样。改成单个 `do/catch`：
     构建与写盘都在里面，退出与 flush 变成**无条件**的（原来失败分支会跳过 flush）。

- **验证**：`KANAME_SELFTEST=1` 正是改动的那条路径，跑通了端到端——
  日志 `selftest written to …/kaname-selftest.json`，产出的 JSON 有效、28 个顶层键、
  **含 `settings` 段、无 `settingsError`**（正常路径）。
  settings 预览截图与改动前**逐字节相同**（这个场景是确定的，见 N6 更正）。
  539 测试全绿、Core 独立 typecheck 0 诊断、`build_swiftc.sh` 0 error 0 warning。
  失败分支无法自动触发（要弹保存面板），只能靠代码审查确认。
- **这一条闭环了，但 P0-4 没有**：吞真错误的 `try?` 从 **57 降到 54**（只少了本条这三处）。
  第一轮 P0-4 的原话是「诊断能力在最需要时会静默失败」——**这一条已闭环**；
  其余 54 处分布在 `CrashReporter` 12、`ActionRecorder` 6、`PreviewScenarios` 6、
  `FileLogStore` 5、`MenuScanCache` 4、`DiagnosticsExporter` 4、配置扫描器 7、存储 3、测试 3。
  **注意：`Core/Input` 里一处都没有**（只有 2 处 `try? await Task.sleep`，丢的是取消不是错误），
  所以第一轮"输入链路里禁止 `try?`"那条约定**已经是满足的**——
  前两轮说的"输入链路仍有 10 处"是错的，那 10 处从来不在输入链路里。
- **留给第三轮的一条**：`DiagnosticsExporter`（设置页"诊断"标签那条导出路径，与本条改的
  `diagnosticsReport()` 是**两条不同的路径**）内部仍有 4 处 `try?`。其中 3 处是
  `try? fileManager.removeItem/createDirectory`（清理暂存目录，失败不该让导出失败，站得住），
  但 `:93` 的 `guard let contents = try? contentsOfDirectory(...) else { return [] }` 是
  **和本条同一类病**：目录读不出来就返回空列表，用户拿到一个"空的"诊断包而不知道少了东西。
  本轮没动它——它要改的不只是这一行，还有那条路径对"部分成功"的整体表达。

### N5（P2）　✅ 无需改动 —— 本条的判定本身是错的：`@available(*, unavailable)` 从来就在

- 位置：`UI/Design/AppIconDragSource.swift:53-56`
- **更正**：本条原文写「第一轮已给出正确建议但没动手」，**这个判定是错的**。
  数到 `fatalError` 出现 1 次就断定属性缺失，没有读那一行。实际代码是：

  ```swift
  @available(*, unavailable)
  required init?(coder: NSCoder) {
      fatalError("init(coder:) is not used")
  }
  ```

  `git blame` 显示 `@available(*, unavailable)` 与该文件**同一次提交引入**（`1bf1922`），
  在写第二轮报告的那个提交（`f492250`）里也已经在。也就是说，P1-10 要的编译期拒绝
  从一开始就到位了。
- **为什么 `fatalError` 必须留下**：`required init?` 是 `NSCoding` 要求的，**必须有函数体**，
  写法上无法省略。而 `@available(*, unavailable)` 已经让任何调用点在**编译期**被拒绝，
  这行 `fatalError` 是不可达的兜底，不是运行期陷阱。**这是正确写法，不要动它。**
- **教训（本项目第三例同类错误）**：第一轮数 `.accessibilityLabel` 得出"设置页没标签"，
  实际 SwiftUI 从控件文本自动推导；本轮统计 `try!`/`assumeIsolated` 把注释算了进去（见第 5 节）；
  这里则是数了标识符却没读它所在的行。**"量化"不等于"看过"** ——
  凡是要据此下"没做/退化了"结论的，必须回到代码本身读一遍。

### N6（P2）　✅ 已修（批次 C）　跨文件重复块——新增代码是复制出来的

- 位置（两处真重复，值得动手）：
  1. **AX 取值梯子写了两遍**：`Core/AX/MenuScanner.swift` 与 `Core/AX/WindowGeometry.swift`
     各有一套私有的 `attribute(name:of:)` + 类型化变体（`pointAttribute`/`sizeAttribute`/`elementAttribute`），
     每套都是 `CFGetTypeID` 守卫 + `unsafeDowncast` 的同一段五行。
  2. **NSWorkspace 观察者生命周期写了两遍**：`Core/AX/AppContextService.swift:28-33` 与
     `Core/AX/AppDirectory.swift:19-26` 都手工维护 `observers: [NSObjectProtocol]` +
     `start()` 的 `guard observers.isEmpty` + `stop()` 的 `observers.forEach { center.removeObserver($0) }`。
- 另四处是委托包装或结构体字面量，不算重复，不必动。
- 依据：R2 *Duplicated Code*；Pragmatic Programmer DRY /「一个事实只有一个来源」。
- **实际做法**：
  - 新增 `Core/AX/AXValueReader.swift`（`nonisolated enum`）：梯子只留一份，
    `MenuScanner` 的 13 个调用点与 `WindowGeometry` 的 4 个改指过来。
    两处旧梯子的实现已经**漂移**过——`MenuScanner` 有 `CFNull` 守卫，`WindowGeometry` 没有；
    保留带守卫的那份（空值本来也会在下一步类型检查里被拒，行为等价）。
    `boolAttribute` 一开始被误判为死代码（漏看了 `MenuScanner.swift:263`），复核后保留。
  - 新增 `Core/AX/WorkspaceObservation.swift`（`@MainActor final class`）：两个服务各自的
    `start()` 收成 `guard !observation.isRunning` + `observe(...) { … }`，`stop()` 收成一行。
    `MainActor.assumeIsolated` 的调用点因此从 3 处降到 1 处。
  - **顺带**：`children(of:)` 里 `unsafeBitCast(raw, to: CFTypeRef.self)` 改成
    `Unmanaged<AnyObject>.fromOpaque(slot).takeUnretainedValue()`。位宽相同、语义等价，
    但 `unsafeBitCast` 把指针当对象引用重新解释，而 CFArray 存的就是对象指针本身——
    `Unmanaged` 才是表达这件事的 API。全项目 `unsafeBitCast` 因此归零（只剩 6 处 `unsafeDowncast`）。
- **验证**（AX 层没有测试网，只能靠预览：`scripts/build_swiftc.sh` → `install.sh` → 预览场景）：
  - 日志指标逐字一致：`panel sequence: app=57 system=79 page=1/6 rows=24`、
    `search: scope=frontmost items=136 results=136 first=Cut`、`config scan: 201 shortcuts`；
    扫描仍报 `menus=true, state=ok`（Safari 182 项），说明 `children(of:)` 的改写没打断菜单遍历。
  - 截图字节级相同：**settings 与 search 两张成立**（见下条更正）。
- **⚠️ 更正：本条原写"三张截图与改动前逐字节相同"，其中 panel 那张不算证据。**
  后来才发现**面板截图本身不确定**——用**改动前**那份构建（`Kaname.previous.app`）连跑两次，
  两次 MD5 也不同（41668162 / fd44be26，243112 / 242092 字节）。原因是截图在
  `activatePanel()` 之后 1.2s 拍（`PreviewScenarios.swift:246`），而面板有入场动画，
  抓到哪一帧取决于当时机器在忙什么。日志里的 `panel sequence` 却是三次完全一致的。
  **教训**：这是第 5 节那句话的第五个实例——**先看仪器可不可靠，再看读数**。
  三个场景已实测分类：**settings 与 search 确定**（同版本连跑 MD5 相同，可用来做字节级比对），
  **panel 不确定**（只能看日志指标）。第三轮请按这个清单选证据。
- **未动的一处，附理由**：`UI/MenuBar/StatusItemController.swift:120-139` 也有一个
  `observers` 数组，但它**混用两个通知中心**（`NSWorkspace` 的 wake + `NotificationCenter.default`
  的屏幕参数变化），`uninstall()` 要从两个中心各移除一次。它不是同一块重复的第三份，
  而是另一种形态；要收进来就得把 `WorkspaceObservation` 泛化成「任意中心 + 可组合拆卸」，
  而 wake / 屏幕变化这两条路径现在没有预览或测试能覆盖。**成本大于收益，先记账**。
- 结果：Core 跨文件 ≥5 行重复块 **8 → 4**（口径见第 5 节），消失的正好是上面两处；
  留下的 4 处就是本条判定为"不算重复"的那四处。

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

- 位置：`Tests/KanameCoreTests/KanameCoreTests.swift`，**1,105 行 / 109 个测试**
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
N3 拆 `KeyEventRouter.route`（Pure + 23 个测试兜底）→ N9 拆 `KanameCoreTests`（纯文件搬运）
→ 顺带把测试构建的 16 处既有警告清零。（详见 N3 / N9 条目的"实际做法"）

**批次 B（零行为变化，编译期收益）**　✅ **已完成**
N1 把 `previewWindow` 移回夹具 —— 引擎那行已删，`Core/` 里的 AppKit **行为类型**已清零
（只剩 `NSWorkspace` 系统服务，见 N1）。N5 经核实**无需改动**：`@available(*, unavailable)`
从来就在，`fatalError` 是 `required init?` 必须有的不可达兜底（详见 N5 的更正）。

**批次 C（小抽取，需预览验证）**　✅ **已完成**
N2 删掉 `LogRotationPolicy` 的 formatter 缓存（用整数补零拼文件名，`f0a74b8`）→ N6 抽
`AXValueReader` 与 `WorkspaceObservation`。验证方式见 N6 条目：三张预览截图与改动前
**逐字节相同**，日志指标逐字一致。批次外顺带修了 `Diag.configure` 缺失的 `defer`。

**批次 D（收口）**　✅ **已完成**
N4 让 `diagnosticsReport()` 抛错、两个调用方都改为可见失败 —— 第一轮 P0-4 里
「诊断能力静默失败」这一条闭环了。**注意它不等于 P0-4 全部闭环**：吞真错误的 `try?`
还剩 54 处（`CrashReporter` 12 为首；`Core/Input` 是 0），本轮没动。
`DiagnosticsExporter` 那条兄弟路径另有一处同类问题，已记在 N4 条目里留给第三轮。

**建议不做**：N8（`EngineState` 的 `NSImage`）、N10 的 44pt 部分、P2-15 的 Observation 迁移。
三条都是"改了更干净但换不来行为收益"，记账即可。

**仍未解决的大项**：P1-5 引擎 God class（2,530 行 / 19 段）。它比上面任何一条都重，
但也最不适合连续小批做——需要一次专门的切分设计，建议单独开一轮。
→ **那份设计已写，见 `docs/engine-split-design.md`；诊断已修正、切片 1 已完成，见第 6 节。**

---

## 5. 量化基线（供第三轮比对）

### 5.1 批次 B+C 后（同一脚本重测：应用 + 测试，先剥注释）

口径统一之后才可比：**右两列由 `scripts/code-metrics.py` 对两棵提交树跑同一个脚本得出**，
前三列是前两轮各自的手工统计，**不要跨口径相减**。

```
python3 scripts/code-metrics.py .                              # 当前工作树
git archive e410fe5 | tar -x -C /tmp/tree-A
python3 scripts/code-metrics.py /tmp/tree-A                    # 任意历史提交
```

| 指标 | 批次 A 后 `e410fe5` | 批次 B+C 后 | 变化 | 说明 |
|---|---|---|---|---|
| 应用文件 / 行数 | 129 / 21,485 | **131 / 21,558** | +2 / +73 | 新增 `AXValueReader`、`WorkspaceObservation` |
| 测试文件 / 行数 | 71 / 6,090 | **71 / 6,104** | +14 | N2 补了 2 个 `dayStamp` 测试 |
| `Core/` 文件数 | 111 | **113** | +2 | 两个新类型都落在 `Core/AX/` |
| 测试数 | 537 | **539** | +2 | 全绿；测试构建 0 警告 |
| >80 行的函数 | 2 | **2** | — | 仍是 `startPreview` 149 / `CatalogLoader.scan` 81 |
| 最大文件 | `ShortcutEngine` 2,529 | **2,526** | −3 | 仍 19 个 MARK 段（P1-5 未动） |
| **Core 跨文件 ≥5 行重复块** | 8（重测） | **4** ✅ | −4 | N6；消失的正是两处真重复（详见 N6） |
| `MainActor.assumeIsolated` | 24 | **22** | −2 | N6：3 处手写 → `WorkspaceObservation` 里 1 处 |
| `nonisolated(unsafe)` | 18（重测） | **17** | −1 | N2；剩下的 17 处全在 `CrashReporter`（信号处理器，正当） |
| `unsafeBitCast` | 1 | **0** ✅ | −1 | N6 顺带；只剩 6 处 `unsafeDowncast` |
| `lock()` / `unlock()` | 15 / 15 | **14 / 14** | −1 | N2；另补齐了 `Diag.configure` 缺失的 `defer` |
| `try?` | **62**（重测，口径已修） | **62** | — | 见下方 `try?` 计数修正；**吞真错误的 57 处**（另 5 处是 `try? await Task.sleep`） |
| `try!` | 3（重测） | **3** | — | 3 处全在测试里，应用代码 0（见下方口径说明） |
| `@unchecked Sendable` | 6（重测） | **6** | — | 各有锁或串行队列，契约写在注释里 |
| `ObservableObject` / `@Observable` | 10 / 0 | **10 / 0** | — | 未动（P2-15 建议不做） |
| `.contentShape` | 7 | **7** | — | 未动（见 N10） |
| `.frame(width:/height:)` | 41 | **41** | — | 未动 |

### 5.2 批次 D 后（同一脚本重测，只列发生变化的）

| 指标 | 批次 B+C 后 | 批次 D 后 | 变化 | 说明 |
|---|---|---|---|---|
| 应用文件 / 行数 | 131 / 21,558 | **131 / 21,573** | +15 | N4 只改 4 个文件（引擎/设置/AppDelegate/无新增） |
| 最大文件 | `ShortcutEngine` 2,526 | **2,533** | +7 | `diagnosticsReport()` 多了一个 `do/catch` 与注释 |
| `try?` | 62 | **59** | −3 | N4：`diagnosticsReport()` 里三处 `try?` 全部消失 |
| ├ 吞真错误的 | 57 | **54** | −3 | **P0-4 真正关心的就是这个数** |
| └ `try? await Task.sleep` | 5 | **5** | — | 丢的是取消不是错误，不计入 |

### 5.3 第三轮后（同一脚本重测两棵树：`80ac2cd` → 工作区）

| 指标 | 第三轮前 `80ac2cd` | 第三轮后 | 变化 | 说明 |
|---|---|---|---|---|
| 应用文件 / 行数 | 131 / 21,573 | **133 / 21,753** | +2 / +180 | 新增 `DiagnosticsReportBuilder`(100) + `ScanState`(30) − 引擎(−20) − `MenuScanner`(−25) |
| 测试文件 / 行数 | 71 / 6,104 | **72 / 6,216** | +1 / +112 | `DiagnosticsReportBuilderTests` 6 个测试 |
| Core 文件 | 113 | **115** | +2 | 同上两个新文件 |
| 最大文件 | `ShortcutEngine` 2,533 | **2,513** | −20 | 切片 1（详见第 6 节与设计文档） |
| >80 行的函数 | 2 | **2** | — | 引擎内 **0 个**（134 个函数，中位 8 行，最长 57） |
| `try?` 合计 | 59 | **56** | −3 | |
| ├ 吞真错误的 | 54 | **51** | −3 | **P0-4 真正关心的就是这个数**。逐文件核对：−3 **全部来自 N11**（`DiagnosticsExporter` 4 → 1）。N13 是一处 `try?` 换成另一处（净 0），那条的要点不在计数；切片 1 是 0。 |
| └ `try? await Task.sleep` | 5 | **5** | — | 丢的是取消不是错误，不计入 |
| `try!` | 3 | **3** | — | **全在测试里**（`MenuCacheRoundTripTests` 2、`LocalizationTests` 1），应用代码 **0**。 |
| | | | | 测试里 `try!` 是正当的：构造失败就该让该条测试崩，而不是静默通过。上一轮记的「`try!` = 0」是**只数了应用代码**。 |

### 5.4 前两轮的原始记录（口径不同，仅供溯源）

| 指标 | 第一轮基线 `bd8b926` | 第二轮 `83a1b03` | 批次 A 后 |
|---|---|---|---|
| 应用文件 / 行数 | 126 / 20,542 | 129 / 21,431 | 129 / 21,485 |
| 测试文件 / 行数 | 42 / 5,857 | 43 / 6,028 | 71 / 6,090 |
| >80 行的函数 | 9 | 3 | 2 |
| 最大文件 | `ShortcutEngine` 2,775 | 2,530 | 2,529 |
| 测试构建警告 | — | 16 | 0 |
| Core 跨文件 5 行重复块 | 2 | 6 | 6 |
| `try?` | 64 | 59 | 59 |
| `accessibilityHint` | 0 | 0 | 0 |

**两次口径差异的账**：第二轮写 `nonisolated(unsafe)` = 23（CrashReporter 20 + LogRotationPolicy 2
+ UI 1），同一脚本重测 `e410fe5` 得 18（CrashReporter 17 + LogRotationPolicy 1）；
`try?` 59 vs 65、`try!` 0 vs 3 同理。差在文件集合（是否含测试）与是否剥注释。
**前两轮的数字不要和 5.1 的表相减**；要么用脚本重测，要么只用同一张表内部比。

**计数口径（第三轮别再踩）**：本轮统计 `try!` 得到 2、`assumeIsolated` 得到 29，一度以为两者都回退了。
实际是正则把**注释里的提及**也算进去了 —— 那 2 处 `try!` 是 `Sanitizer.swift:78-79` 在解释
"为什么这里不用 `try!`"；29 处 `assumeIsolated` 里有 5 处是注释。
**统计代码气味时必须先剥掉行内注释**（`re.sub(r'//.*$', '', line)` 后再匹配），否则每轮都会
凭空"恶化"几条。这正是第 2 节想防的同一类错误，写报告的人自己也踩了。

**"量化"不等于"看过"**：N5（以为 `fatalError` 没处理）和 N2 的"唯一一处手工配对"都是数了标识符
就下结论、没回到代码读一遍而写错的。凡是要据此下"没做 / 退化了 / 只有一处"结论的，
必须先读那一行；`scripts/code-metrics.py` 给的是待查清单，不是结论。

**正则也会咬人（本轮第五、第六例）**：
- `try?` 的正则 `try\?` 会把 **`monitorRetry?.cancel()`** 里那个 `try?` 子串算进去
  （`Re` + `try?`）。必须写 `\btry\?`。修正后批次 A 的数字从 65 变成 62。
- `try? await Task.sleep(...)` 和"吞掉一个错误"不是一回事：`Task.sleep` 只在取消时抛，
  丢掉它是句法噪音，**不是 P0-4 说的"吞错误"**。所以脚本把它单独列出来，
  判断 P0-4 的进展要看"吞真错误的 54 处"，不是 59 处。

**先看仪器可不可靠，再看读数（本轮第七例，也是最贵的一例）**：本轮一度把
"三张预览截图与改动前逐字节相同"当成最强等价证据。**面板那张不是证据**——
用改动前那份构建连跑两次，两次 MD5 也不同（截图在入场动画结束前 1.2s 拍的，见 N6 更正）。
三个场景已实测：**settings 与 search 确定**（同版本连跑 MD5 相同，可做字节比对），
**panel 不确定**（只能看日志指标）。同理，用截图做等价性判断之前，
先拿**同一份构建**跑两遍，看它自己跟自己比不比得上。

| `SWIFT_VERSION` | 5.0 | **6.0 + `complete`** | 三条路径 0 诊断，539 测试通过 |
| `Core/` 独立 `-typecheck` | 失败 | **通过（0 诊断）** | 113 个文件；但用的是自有 UI 类型口径，漏 AppKit（见 N1） |

---

## 6. 第三轮（2026-11-03 续）

批次 D 留下的一条 + 顺着 `try?` 清单查出来的三处静默失败 + P1-5 的重新定级。

### N11（P1）　✅ 已修（`570bb22`）　N4 的兄弟路径：不完整的诊断归档不说自己缺了什么

- 位置：`Core/Services/DiagnosticsExporter.swift:93`（`copyContents`）
- 症状：`guard let contents = try? contentsOfDirectory(...) else { return [] }` —— 日志目录读不出来
  就返回空列表。用户拿到一个没有日志的诊断包，和"这个 App 本来就没日志"长得一模一样。
  下一层还有一个同样的洞：`copyItem` 失败时 `continue`，单个文件静默丢失。
- 依据：Clean Code「不要吞掉错误」；与 N4 同一类病（N4 已把它记在"留给第三轮"）。
- **做法**：`copyContents` 返回 `FolderCopy`（`copied` / `skipped` / `failure`），
  `SessionInfo` 增加 `logFilesError` / `crashFilesError`，沿用 N4 的 `settingsError` 约定——
  部分成功仍值得附上，所以不失败导出，但理由跟着文件一起走。
  顺带把目标文件的 `try? removeItem` 改成 `try` + `catch CocoaError.fileNoSuchFile`：
  清不掉旧文件就该说出来，而不是让 `ditto` 跑进一个没准备好的目标。
- **验证（三条路径全用真实文件系统故障，不是桩）**：`chmod 000` 日志目录 →
  `logFilesError = "folder could not be listed: …"`；`chmod 000` 单个文件 →
  `logFilesError = "kaname-2026-11-02.log: …"`；正常 → 2 个文件、两个 error 字段都缺省。
- **一个顺带发现，它决定了理由该写在哪**：目录不可读那次运行**在日志里一行都没留下**
  （`FileLogStore` 写的是同一个目录）。**正是这个故障模式会连日志一起带走**，
  所以理由必须进 JSON 报告，不能只进日志。这不是双保险，是唯一还活着的通道。

### N12（P1）　✅ 已修（`2423860`）　脱敏规则静默失效时，没有任何东西会知道

- 位置：`Core/Pure/Sanitizer.swift:85-90`
- 症状：`Sanitizer.failedPatterns` 存在、被填充、被
  `SanitizerRuleCompilationTests.testEveryRuleCompiles` 断言为空——但**全项目没有任何代码读它**。
  注释声称"the diagnostics export surfaces it"，不成立；注释里那个符号名
  `rulesThatFailedToCompile` **根本不存在**。
  于是真实的失效模式是：一条正则写错 → 那条脱敏规则静默停用 → 日志带着本该被抹掉的内容落到盘上
  （并随着诊断包离开机器），而唯一知情的东西是一个早已针对另一个构建跑过的测试。
- 这是本轮唯一一条**安全相关**的发现，也是唯一一条"机制齐全但没人接线"的。
- **做法**：接到三个通道，因为每个都补上了别的通道的缺口 ——
  归档的 `session-info.json`（唯一能离开机器、活过本次会话的东西）、
  应用内报告的 `sanitizerFailedPatterns`、启动时一行 `W [start]`（报告只在有人想到要导出时才产生）。
  同时改正注释里的符号名和那句不成立的断言。
- **验证**：故意写坏一条正则（`\b[0-9a-fA-F]{32,}\b(`）并**真的装那一份构建**，
  得到 `W [start] redaction rules not applied: …`、报告里 `["\\b[0-9a-fA-F]{32,}\\b("]`、
  且 `testEveryRuleCompiles` 报出同一个 pattern。正则已恢复，警告消失、字段回到 `[]`。

### N13（P1）　✅ 已修（`2800947`）　崩溃留下的那个文件会用"省略"说谎

- 位置一：`Core/Pure/CrashLogFormatter.swift:91` —— 兜底 `return "{}"`，
  注释称其为死路径（"this struct is fully Codable with value types"）。**它不是死的**：
  `occurredAt` 是 `Double`，而 `JSONEncoder` 对非有限浮点数的默认策略是 `.throw`，
  一个 NaN 日期就能触发。`{}` 能解析、看起来完整、且什么都没说——读者会以为这次崩溃本来就没带信息。
  → 改为返回说明失败原因的合法 JSON（经 `JSONSerialization` 生成，理由是被转义的而非拼接的），
  并补测试：`Date(timeIntervalSince1970: .nan)` 即可触发，对 `"{}"` 会失败。
- 位置二：`Core/Services/CrashReporter.swift:317` —— `catch { // Nothing left to fall back to }`，
  而**同一个文件 50 行之下**（`:358`）对同一个失败已经记了 `Diag.warning`。
  给出的理由是"这里跑在未捕获异常处理器里"，但 `handleException` 紧接着就 `logs.flushNow`
  —— 写在这里的日志行**确实会落盘**。不记，App 就同时吞掉了异常和"吞掉了异常"这件事。
- 依据：Clean Code「不要吞掉错误」；同一文件内两种相反的处理本身就是信号。

### P1-5 重新定级：症状属实，处方不成立

复审写的是「引擎 God class（2,530 行 / 19 段），需要一次专门的切分设计」。
那份设计已写在 **`docs/engine-split-design.md`**，结论是：

| | 复审写的 | 测出来的（`2800947`） |
|---|---|---|
| 症状 | 2,530 行 / 19 段 | 行数属实；2,536 行里 70% 是代码 |
| 诊断 | God class（做了太多事） | **协调器**：134 个函数，中位 8 行，最长 57，**> 80 行的 0 个** |
| 处方 | 按段 Extract Class | 对占代码量 47% 的那四段不成立 |

关键数字：19 段里只有 **5 个 `EngineState` 字段**和 **6 个动词**是共享的；段与段之间几乎不直接
说话，它们都只跟这个很小的核心说。把这四段搬进新文件，新文件照样要读写同一批字段——
**行数搬家，耦合不动**。

真正的缺陷是**边界的性质**：19 个 MARK 段是注释约定而非结构，`private` 在这个类里不提供任何隔离。

- **已做（`c336096` + `8469003`）**：切片 1 = `Diagnostics` 段 —— 全表唯一 `state.` 写 = 0 的一段，
  搬走在结构上不可能改变行为。装配进了 `Core/Pure/DiagnosticsReportBuilder`（22 字段 `Input`），
  引擎只保留"命名这些值"。**重点不是离开引擎的那 23 行，而是这条路径此前只能端到端验证、
  现在有 6 个单元测试**。等价性量化：自检 JSON 仍是 29 键无增减、settings 截图逐字节相同、
  面板指标逐字相同。546 测试（+6）。
- **顺带（`c336096`）**：`ScanState` 从 `Core/AX/MenuScanner.swift` 移到 `Core/Pure`。
  它被 5 个跨层文件按裸名引用，住在生产者文件里让每个读者都依赖那个文件；
  更关键的是——**测试 target 只编译 `Core/Pure`（`Package.swift:13`）**，
  所以它在原位置永远拿不到单元测试，无论它本身多纯。这条边界是本轮才发现的，见设计文档第 7 节。
- **未做**：其余 18 段的顺序与判据在设计文档第 5 节；前置条件是先收窄共享核心（`prefix` /
  `phase` / `pending`），否则搬那四段只会得到四个互相引用的新文件。

**"清单是待查项、不是结论"这条规则在本轮又救了三次**：`Sanitizer` 那处 `try?` 看起来和 N4 同类，
读了才发现它有 `failedPatterns` 和测试兜底（真正的缺陷是没人接线，不是吞错误）；
`CrashLogFormatter` 那处注释自称死路径，读了才发现 NaN 能触发；`CrashReporter:317` 的沉默
看起来合理（异常处理器里），读了才发现下一行就有 `flushNow`。
