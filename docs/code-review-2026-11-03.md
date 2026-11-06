# Kaname 代码审查报告（第四轮）

- 审查日期：2026-11-03
- 仓库：`/Users/suliveevil/Documents/GitHub/Kaname`
- 工作树起点：clean（HEAD `3b140a1`）
- 参考资料：《macOS Apprentice》第三版、Apple Human Interface Guidelines（macOS）、《Clean Code》、《Clean Architecture》、《The Pragmatic Programmer》、《Migrating to Swift 6》
- 前置文档：`docs/code-review-2026-11-02.md`、`docs/code-review-2026-11-02-round2.md`、`docs/engine-split-design.md`、`docs/ARCHITECTURE.md`

---

## 1. 执行摘要

Kaname 已历经三轮审查并持续重构，当前是一个**质量显著高于同类 macOS 工具的 Swift 6 项目**：分层清晰、依赖方向正确、并发以编译器可验证的方式隔离、纯逻辑可单元测试、注释解释“为什么”而非“做什么”。本轮不重复前三轮已闭合的结论，而是在全库独立精读后，聚焦**仍存在的真实重复与一个零测试的用户路径**，并实际落地了三项行为保持的重构。

结果（全部经构建与测试验证）：

- Core 层跨文件重复块（`scripts/code-metrics.py` 口径，≥5 行）从 **4 降到 2**；剩余 2 个经核实均为合理（见 §6.1）。
- 测试从 **546 增至 557**（新增 11 个），`swift test` 0 失败；应用目标 `xcodebuild` **BUILD SUCCEEDED**、零代码警告。
- 搜索框键盘导航这一原本埋在 UI 事件监视器、**完全无测试**的路径，其决策被提取为纯的、可测试的 `SearchKeyRouter`。

结论分级沿用前置文档：`confirmed`（源码/运行直接证明）、`inferred`（多证据推断）、`unknown`（未取得证据）。本轮正文的事实性结论均为 `confirmed`，除非另行标注。

---

## 2. 本轮定位与方法论

前三轮已系统覆盖：依赖方向、Swift 6 并发隔离、错误吞咽（`try?`）、God class 重新诊断、UI 细节与可访问性。为避免“以篇幅掩盖增量”，本轮采用与前置文档一致的纪律：

1. **先读代码再下判断**，不以文档结论替代源码核实；
2. 所有数字来自 `scripts/code-metrics.py` 或 `swift test`/`xcodebuild` 的真实输出，口径与前置文档完全一致；
3. 只改行为可保持、且有测试安全网的部分；凡涉及行为语义的改动，先完整枚举净行为再重构，并用测试钉住；
4. 对每条疑似问题主动寻找反例（前置文档反复强调“量化不等于看过”）。本轮即有一处初判被反例推翻，记录在 §4.3 的方法论说明中。

代码规模（本轮基线）：134 个应用源文件 / 21,802 行，28 个测试文件；最长文件仍为 `ShortcutEngine.swift`（2,513 行），其“协调器而非 God class”的定性与 `engine-split-design.md` 一致，本轮不重复论证。

---

## 3. 整体架构的独立评估（对照六本资料）

在落地具体改动前，对入口、组合根、端口、引擎、存储、服务、AX、UI 各层做了独立精读。以下结论均可回链到源码。

| 维度 / 资料 | 评估（confirmed） | 主要证据 |
|---|---|---|
| 依赖方向 / Clean Architecture | 内层通过端口协议向外依赖，App 层为组合根，依赖箭头恒指向内 | `Core/Ports/PresentationPorts.swift` 全为协议；`App/AppDelegate.swift` 构建具体控制器并经 `EnginePresenters` 注入；Core 不 import AppKit UI 层 |
| 端口–适配器 / Hexagonal | UI、AX、注入、持久化均在接口之后，引擎只与抽象协作 | `OverlayPresenting`、`MenuBarPresenting`、`ShortcutInjecting`、`CatalogLoader` 等；`StatusItemController` 等为具体适配器 |
| 纯逻辑可测 / Clean Code + Pragmatic | 决策逻辑集中于 `nonisolated` 纯枚举/值类型，AppKit 仅做装配与副作用 | `RowKeyRouter`、`NavigationKey`、`ConflictDetector`、`KeyOrder`、`MenuContentPolicy` 等，均有对应测试 |
| 并发 / Migrating to Swift 6 | 共享可变状态以 `@MainActor`、`Sendable`、私有串行队列、锁盒等**编译器可验证**方式隔离；危险逃逸点显式标注且有理由 | `EngineState` 为 `@MainActor`；`FileLogStore` 为 `@unchecked Sendable` 且状态仅在私有队列；`CrashReporter` 的 `nonisolated(unsafe)` 受 async-signal-safe 约束 |
| 函数职责 / Clean Code | 引擎为短函数协调器，计算委托 Pure，无长方法（仅 2 个 >80 行函数，均在测试/加载装配处） | `metrics`：`functions >80 lines = 2`（`PreviewScenarios` 149、`CatalogLoader` 81） |
| 崩溃面 / Pragmatic（契约式设计） | 全库无 `as!`、无 `try!`（3 处 `try!` 经核实均为测试/编码常量路径）、无危险强制解包 | 见 §6.2；唯一 `URL(string: "https://…")!` 为编译期常量，必然有效 |
| macOS 惯例 / HIG + macOS Apprentice | 非激活面板、键盘焦点、减少动效、VoiceOver 标签、模板状态栏图标等均符合平台惯例 | `PermissionGuidePanel.canBecomeKey = false`；`StatusItemController` 模板图标；`Interaction.swift` 尊重 Reduce Motion；图标按钮均补无障碍标签 |

**总评（inferred）**：该项目的工程实践与六本资料倡导的原则高度一致，且已超越“风格整洁”的层面，进入“用类型系统表达不变量、用测试钉住契约”的阶段。因此本轮的边际收益不在宏观风格，而在少数残留的重复与测试盲点。

---

## 4. 已实施的重构

### 4.1 提取冲突排序比较器，消除双份复制（DRY）

**问题**：同一份 `BindingConflict` 排序逻辑——“类别降序 → 不同所有者数降序 → 组合键升序”——在两个地方逐字复制：

- `Core/Pure/ConflictDetector.swift` 的 `conflicts(in:external:)` 末尾；
- `Core/Engine/ConflictCenter.swift` 的 `CrossAppConflictBuilder.sorted()`。

排序规则若新增一级 tiebreak，需两处同步修改，存在漂移风险。这正是《The Pragmatic Programmer》的 DRY 与《Clean Code》“同一知识只应有一处权威表达”所指。

**改动**：在值类型上提供唯一的比较器，并让两处调用它。

- 新增 `nonisolated extension BindingConflict { static func bySeverity(_:_:)`（`ConflictDetector.swift:204`）；
- `ConflictDetector.swift:315` → `conflicts.sorted(by: BindingConflict.bySeverity)`；
- `ConflictCenter.swift:228` → `conflicts.sorted(by: BindingConflict.bySeverity)`。

**关键细节（并发）**：extension 必须显式 `nonisolated`。应用目标设置了默认 `MainActor` 隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION`），未标注的 extension 方法会被推断为 `@MainActor`，导致在 nonisolated 的 `sorted(by:)` 调用处报“loses global actor 'MainActor'”。该错误在首轮 `xcodebuild` 实测出现，显式 `nonisolated` 后消除——这与项目既有的 `nonisolated extension KeyChord` 写法一致。

**原理映射**：DRY（Pragmatic）、单一知识来源（Clean Code）、纯值比较天然 nonisolated（Swift 6）。

### 4.2 提取文本配置扫描骨架，消除两个扫描器的重复流程

**问题**：`HammerspoonScanner` 与 `SkhdScanner` 的 `scan` 方法共享同一“找首个存在路径 → 读为文本 → 交解析器”的 `guard` 链，仅搜索路径与解析函数不同。

**改动**：在共享的 `ConfigFileScanner` 上提供模板方法，两个扫描器改为单行委托。

- 新增 `ConfigFileScanner.scanTextConfig(searchPaths:homeDirectory:fileManager:parse:)`（`ConfigFileScanner.swift:145`）；
- `HammerspoonScanner.swift:16` 与 `SkhdScanner.swift:13` 改为调用该方法，分别传入 `ConfigTool.hammerspoon/skhd.relativeSearchPaths` 与 `bindings(from:)`。

“文件缺失或不可读均返回空数组”的行为由模板统一保持，与原内联 `guard` 完全一致。其余扫描器（Karabiner、Keyboard Maestro、BetterTouch Tool、Alfred）读的是 plist/data 而非 text，不适用此模板，故不强行泛化（避免过度抽象）。

**原理映射**：模板方法/共享骨架（Clean Architecture、Pragmatic 的“正交性”）、按实际复用范围决定抽象边界（Pragmatic：不为想象中的复用过度设计）。

### 4.3 提取搜索框按键路由为纯逻辑并补齐测试（测试盲点 + 可读性）

**问题**：搜索框的按键决策内联在 `SurfacePanelController.installSearchKeyMonitor()` 的本地事件监视器中，**没有任何单元测试**；且同一“移动选择”行为通过两条路径表达——`NavigationKey` 只覆盖“无修饰符”与“纯 ⌃”的方向键，其余修饰符（如 ⌘↓、⇧↑）走后面的兜底分支，读者难以一眼看出净行为。

**一处被反例推翻的初判（方法论记录）**：本轮最初将兜底分支判为“死代码”，但逐路径枚举后发现：`⌘↓` 会使 `NavigationKey.direction` 因修饰符非空且非纯 `[.control]` 而返回 `nil`，从而**确实会到达**兜底分支。因此它不是死代码，而是“同一行为走两条路径”的可读性问题。这一纠正直接决定了重构方式——保留全部行为，只做纯逻辑提取，而非删除。

**完整枚举的净行为（重构前后必须等价）**：

- 纯 `/`（无修饰符、查询为空）→ 返回面板；查询非空或带修饰符（含 ⌘/ 帮助键）→ 放行；
- 上/下键，**任意修饰符**（含 Emacs ⌃N/⌃P）→ 移动选择（−1/+1）并吞键；
- 左/右键，**任意修饰符**（含 ⌃B/⌃F）→ 放行给文本框移动光标；
- Esc（不检查修饰符）→ 关闭并吞键；
- 其他字符 → 放行。

**改动**：

- 新增纯的 `Core/Pure/SearchKeyRouter.swift`：`SearchKeyAction`（moveSelection/close/returnToPanel/passThrough）与 `SearchKeyRouter.action(keyCode:modifiers:isQueryEmpty:)`（`SearchKeyRouter.swift:23`），复用 `NavigationKey` 以保留 Emacs 键；
- `SurfacePanelController.swift:219` 改为“获取决策 → 执行动作”的薄封装；输入法组合状态（`TextComposition.isComposing`）因涉及面板状态，仍保留在控制器并提前放行；
- 新增 `Tests/KanameCoreTests/SearchKeyRouterTests.swift`，11 个测试覆盖物理方向键、Emacs 键、带修饰符方向键、`⌃⌘P/⌃⌥P 必须放行`的回归点、Esc、斜杠各边界与普通字符。

**原理映射**：决策与机制分离（Clean Architecture、Pragmatic 的“分离关注点”）、纯逻辑可测（Clean Code）、把隐式行为显式化并钉住（契约式设计）。

---

## 5. 改动清单

| 文件 | 性质 | 说明 |
|---|---|---|
| `Core/Pure/ConflictDetector.swift` | 修改 | 新增 `BindingConflict.bySeverity`，本文件排序改用之 |
| `Core/Engine/ConflictCenter.swift` | 修改 | `CrossAppConflictBuilder.sorted()` 改用共享比较器 |
| `Core/Pure/ConfigFileScanner.swift` | 修改 | 新增 `scanTextConfig` 模板 |
| `Core/Pure/HammerspoonScanner.swift` | 修改 | 改用 `scanTextConfig` |
| `Core/Pure/SkhdScanner.swift` | 修改 | 改用 `scanTextConfig` |
| `Core/Pure/SearchKeyRouter.swift` | 新增 | 搜索框按键纯路由（45 行） |
| `UI/Surface/SurfacePanelController.swift` | 修改 | 事件监视器改为调用纯路由（净减约 20 行） |
| `Tests/KanameCoreTests/SearchKeyRouterTests.swift` | 新增 | 11 个测试（145 行） |

`git diff --stat`（已跟踪文件）：6 文件，+58 / −54；另含两个新增文件共 190 行。

---

## 6. 仍存在的事项与后续建议

以下项目前三轮已充分论证，本轮不重复，仅基于当前源码状态给出处理建议；均不构成当前正确性缺陷。

### 6.1 剩余 2 个“重复块”经核实为合理，**建议保持**

- `ShortcutTester.verdict` 与 `ShortcutTestSession.verdict`：函数签名相同，但前者（AppKit 层）仅委托给后者（纯层），是项目刻意的“AppKit 机制 / 纯决策”分层，签名相同属必然，非逻辑重复；
- `HammerspoonScanner` 与 `SkhdScanner` 调用 `scanTextConfig` 的调用点：两者现在调用同一 API，调用点自然相似，已无重复逻辑，进一步消除只能靠额外间接，属过度设计。

### 6.2 错误吞咽与强制解包（沿用前置结论）

- 51 处吞真错误的 `try?`（不含 5 处 `try? await Task.sleep`）前三轮已逐类核查，大量集中于 `CrashReporter`（async-signal-safe）、`FileLogStore`（日志失败静默降级）、缓存与配置扫描（有 `?? []` 等兜底），均有正当理由。**建议维持现状**，仅在未来新增代码时继续遵守“能处理就不用 `try?`”的纪律。
- 全库无 `as!`、无危险强制解包；3 处 `try!` 位于测试/编码确定路径，常量 URL 的强制解包安全。无需改动。

### 6.3 引擎拆分（长期，按 `engine-split-design.md` 推进）

`ShortcutEngine` 已完成切片 1（装配搬入 App 层）。文档第 7 节明确的下一步前置是**收窄共享核心**（`prefix`/`phase`/`pending`），其后四大段（导航/执行/录制/搜索）才具备可搬条件。本轮未触碰该结构，建议后续按文档逐切片推进，每切片独立构建+测试，不做一次性大爆炸式拆分。

### 6.4 测试覆盖的结构性缺口（inferred，非阻塞）

纯层测试充分，但引擎与输入层（事件监视器、tap 装配）依赖真实 AppKit/AX，难以单测。本轮已将其中可纯净化的搜索按键决策提取并测试；剩余 AppKit 装配逻辑建议继续遵循“能提取为纯决策就提取”的渐进路线，而非引入重型 UI 测试框架。

---

## 7. 验证记录

- `swift test`：**Executed 557 tests, with 0 failures**（含新增 11 个 `SearchKeyRouterTests`）。
- `xcodebuild -scheme Kaname -configuration Debug build CODE_SIGNING_ALLOWED=NO`：**BUILD SUCCEEDED**；除“多目标 destination 选择”提示外无代码警告/错误。
- 重复度：`metrics` 的 Core 跨文件 ≥5 行重复块 **4 → 2**，剩余项已在 §6.1 核实为合理。
- 覆盖范围与缺口：本轮结论基于对 App/Core(Pure, Engine, Input, Ports, Services, Storage, AX)/UI 各层代表文件及测试的独立精读；未逐行阅读的文件不做全称判断，所有“全部/无”类结论均限定在已核查范围内。

---

## 8. 交付说明

本报告与改动均位于项目目录，可直接 `git diff` 审阅或提交。建议将本轮三项重构作为一个或多个聚焦提交（如 `refactor: share conflict ordering comparator`、`refactor: extract text config scan template`、`refactor: extract search key router with tests`），保持提交意图单一。

---

## 9. 安装后运行时崩溃修复（EXC_BREAKPOINT / 隔离不匹配）

本轮重构构建并覆盖安装后，应用在后台持久化时闪退。该问题不在静态精读与编译期可见，属运行时隔离断言，故独立记录。

### 9.1 现象与证据（confirmed）

- 系统报告 `~/Library/Logs/DiagnosticReports/Kaname-2026-11-03-020959.ips`：`EXC_BREAKPOINT (SIGTRAP)`，崩溃线程位于后台队列 `com.suliveevil.kaname.usage-write`，栈为 `_dispatch_assert_queue_fail → dispatch_assert_queue → _swift_task_checkIsolatedSwift → swift_task_isCurrentExecutorWithFlagsImpl → closure #1 in UsageStore.flush()/schedulePersist()`。
- 即运行时检测到“当前 executor 与声明的 actor 隔离不符”，主动触发 trap。

### 9.2 根因（两层，均与默认 MainActor 隔离有关）

1. **存储类型被隐式隔离**：`JsonFileStore`（`DataDirectory.swift` 内）未标注 `nonisolated`，在应用目标 `-default-isolation MainActor` 下被推断为 `@MainActor`，其 `save` 成为 MainActor 隔离方法，被派到后台队列执行时执行器检查失败。
2. **闭包本身被隔离（更易漏）**：即使把 `JsonFileStore` 改为 `nonisolated`，在 `@MainActor` 上下文里直接形成的 `DispatchWorkItem` 闭包，**闭包自身**仍被推断为 `@MainActor`，后台执行时运行时输出 `warning: data race detected: @MainActor function ... was not called on the main thread`。

### 9.3 修复（confirmed）

- `JsonFileStore` 改为 `nonisolated struct ... Sendable`，并支持注入 `directory`（默认 `DataDirectory.url`），`save` 内部自行 `createDirectory`，使存储可用临时目录测试且不污染真实 Application Support。
- `UsageStore` 新增 `nonisolated static func makeWriteItem(...)` 工厂，在非隔离上下文中创建 `DispatchWorkItem`，使闭包非隔离；私有 `Payload` 显式标注 `nonisolated ... Sendable`，让 MainActor 上构建的载荷可安全传入。`flush`/`schedulePersist` 统一改用该工厂。

### 9.4 验证（confirmed）

- 新增 `scripts/verify_usage_store_isolation.sh`：以与应用相同的默认 MainActor 隔离编译，在后台队列真实执行 `DispatchWorkItem` 写入；以 `-warnings-as-errors` 与运行时 grep `data race detected` 双重防护。**负向**：修复前代码运行时稳定输出 `data race detected`；**正向**：修复后无警告、输出 `ok`。
- 真实应用：重装启动后 `init` 的后台 `flush` 写入成功（`usage.json` 重新生成、内容有效），进程持续存活，无新系统崩溃报告、无 data race；真实按键经 event tap 后进程仍健康。`swift test` 557 全绿，Debug/Release 应用目标构建零警告。
- 说明：SPM 的 Core target 仅指向 `Core/Pure`，无法访问 `Core/Storage`，且 Xcode 工程无单元测试 target，故 Storage 层以独立脚本而非 SPM 测试验证；独立最小程序无法稳定复现生产的硬 trap（只到 data race warning 级别），生产硬 trap 以真实 `.ips` 为准。

### 9.5 教训（inferred）

在 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下，“编译通过”不代表后台执行安全：不仅类型方法会被隐式隔离，**在 MainActor 上下文形成的逃逸闭包也会被隔离**。跨 actor/队列的工作项应在显式 `nonisolated` 工厂中构造，并以 `Sendable` 传递不可变载荷；这类问题需在真实后台队列运行时验证，纯静态精读与编译无法覆盖。
