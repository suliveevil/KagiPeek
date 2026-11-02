# ShortcutEngine 切分设计

第二轮复审把 P1-5 记为「引擎 God class（2,530 行 / 19 段），比任何一条都重，需要一次专门的
切分设计，建议单独开一轮」。这一份就是那次设计。

**测量基线**：`2800947`（切片 1 之前）。所有数字由 `scripts/code-metrics.py` 与下文的两段
一次性脚本产出，可以对任意提交重跑。

**结论先行**：文件的**行数**是真的，**"God class"这个诊断是错的**。它是个协调器——宽，而不深。
按 19 个 MARK 段切成 19 个文件不会减少耦合，只会把耦合从"一个文件内的调用"变成"跨文件的调用"。
真正值得做的是另外两件事，本文给出顺序与验收标准。

---

## 1. 测出来的形状

2,536 行，其中 **70% 是代码（1,784）**、22% 是注释（560）、7% 空行。

**函数长度分布**（brace matching，剥注释后）：

| | |
|---|---|
| 函数数 | 134 |
| 中位函数体 | **8 行** |
| 最长函数体 | **57 行**（`reloadCatalog`） |
| > 80 行的函数 | **0 个** |

这是决定性的一个数字。R2 的 *Large Class* 描述的是"一个类做了太多事"，典型症状是长方法、
一群只被一部分方法用到的字段。这里**没有长方法**：134 个短函数、中位 8 行。项目的另外两个
> 80 行函数都不在这个文件里（`PreviewScenarios.startPreview` 149、`CatalogLoader.scan` 81）。

## 2. 十九段的真实耦合度

每段的代码行数、`state.` 读取次数、`state.` **写入**次数、用到的协作者数量：

| 段 | 代码 | `state.` 读 | `state.` 写 | 协作者 |
|---|---:|---:|---:|---:|
| State | 1 | 0 | 0 | 0 |
| Collaborators | 35 | 1 | 1 | 23 |
| Lifecycle | 98 | 10 | 6 | 15 |
| Settings | 73 | 9 | 6 | 2 |
| Permissions | 126 | 17 | 13 | 8 |
| Catalog | 94 | 39 | 23 | 4 |
| Input | 259 | 70 | 8 | 5 |
| Panel lifecycle | 107 | 48 | 13 | 4 |
| Panel content | 220 | 70 | **2** | 4 |
| Favourites and panel actions | 111 | 35 | 3 | 3 |
| Panel execution | 156 | 33 | 1 | 4 |
| Statistics | 68 | 20 | 3 | 5 |
| Cross-app conflicts | 4 | 0 | 0 | 0 |
| Third-party config files | 44 | 16 | 4 | 2 |
| Live shortcut test | 29 | 7 | 4 | 1 |
| Search | 211 | 91 | 10 | 6 |
| Hotkey recording | 58 | 6 | 5 | 1 |
| Commands from the UI | 26 | 6 | 1 | 2 |
| Diagnostics | 47 | 14 | **0** | 3 |

**写入**那一列是能否安全搬走的判据：读 `state` 可以改成传值，写 `state` 意味着搬走的那段
必须能改回共享状态，那就等于把 `EngineState` 一起搬走，或者注入一个引用——后者没有减少任何东西。

## 3. 耦合集中在两处，都不在段与段之间

**共享动词**（被其它段调用的次数）：

| 调用 | 次数 | 定义段 |
|---|---:|---|
| `rebuildPanel` | 16 | Panel content |
| `dismissPanel` | 15 | Panel lifecycle |
| `publishInputState` | 9 | Input |
| `applyHotkeySwallowing` | 7 | Input |
| `reloadCatalog` | 6 | Catalog |
| `dismissEverything` | 6 | Panel lifecycle |

**共享字段**（被 3 段以上读取的 `EngineState` 字段）：

| 字段 | 段数 |
|---|---:|
| `prefix` | 6 |
| `phase` | 5 |
| `orderedHitsCache` | 5 |
| `searchCorpus` | 5 |
| `pending` | 3 |

约 28 个字段里只有 5 个是共享的，其余都是一两段的局部字段。

这两张表说明的不是"19 个职责挤在一起"，而是：**19 段围着一个很小的共享核心（5 个字段、
6 个动词）**。段与段之间几乎不直接说话，它们都只跟核心说。

## 4. 诊断修正

| | 复审写的 | 测出来的 |
|---|---|---|
| 症状 | 2,530 行 / 19 段 | 行数属实；但 134 个函数中位 8 行、最长 57、无一个 >80 |
| 诊断 | God class（做了太多事） | 协调器（编排 23 个协作者 + 十几个 Pure 类型） |
| 隐含处方 | Extract Class，按段拆 | 对大部分段不成立，见下 |

`Panel content`（220 行代码）是个好例子：它读 70 次 `state`，只写 2 次。而且它**已经在把逻辑
交付给 Pure 类型**——`OverlayMetrics`、`FavoritesPolicy`、`RowBudgetKey`、`PrefixResolver`、
`PanelBudget`、`PanelRowBuilder`。引擎里剩下的是编排。把编排搬到一个新文件，那个新文件还是要
读同样的 70 次 `state`：行数搬家，耦合不动。

**真正的缺陷不在体积，在边界的性质**：19 个 MARK 段是**注释约定**，不是结构。`private` 在这
个类里不提供任何隔离——134 个方法互相都能调用。所以"某段被别段依赖"这件事，今天既没有被
编译器阻止，也没有被编译器记录，只能靠人读。

## 5. 切片计划（按风险递增，每片独立可回滚）

判据：**`state.` 写 = 0 或极少**、**协作者 ≤ 3**、**搬走后能获得测试**。

| 片 | 段 | 代码 | 写 | 协作者 | 判据 |
|---|---|---:|---:|---:|---|
| **1** ✅ | Diagnostics | 47 | **0** | 3 | 已完成（`8469003`），见第 6 节 |
| 2 | Cross-app conflicts | 4 | 0 | 0 | 已是纯委托，搬走是文档性收益，优先级最低 |
| 3 | Commands from the UI | 26 | 1 | 2 | 写 1 次，需先确认写的是哪个字段 |
| 4 | Live shortcut test | 29 | 4 | 1 | 只有 `shortcutTester`；4 次写多为任务字段 |
| 5 | Third-party config files | 44 | 4 | 2 | 任务字段 + `searchCorpus`，需要先分离缓存 |
| 6 | Hotkey recording | 58 | 5 | 1 | 写 5 次，多半是录制状态机 |

**不建议按现状拆的四段**（占引擎代码量的 47%）：`Search`（211 / 写 10）、`Panel content`
（220 / 写 2）、`Input`（259 / 写 8）、`Panel execution`（156 / 写 1）。

它们的共同点不是"太大"，而是**它们就是对 `EngineState` 的那几个共享字段的操作**。要让它们
可搬，得先做一件别的事：

> **先把共享核心收窄。** `prefix` / `phase` / `pending` 这三个字段被 5-6 段读写，是这四段
> 真正共用的东西。如果它们能被收成一个显式的值（例如一个 `PanelMatchState`，由 Input 段
> 产出、由这四段**只读**消费），那四段的写就会掉到接近 0，届时搬走才有意义。
> 顺序必须是：先收窄核心，再搬段。反过来做只会得到四个互相引用的新文件。

## 6. 切片 1：已完成（`c336096` + `8469003`）

选 Diagnostics 是因为它是全表唯一 `state.` 写 = 0 的一段——**搬走它在结构上不可能改变行为**。

- `DiagnosticsReportBuilder`（`Core/Pure`）接一个 22 字段的 `Input`，引擎只保留"命名这些值"
  这一件别人做不了的事。
- 三个决定让它可以被测试：`generatedAt` 由调用方传入（输出因此确定）、`windowTitles` 由调用方
  传入（AppKit 因此留在新文件外）、`scanState` 复用 `ScanState.diagnosticCode` 而不重写三行。
- `ScanState` 从 `Core/AX/MenuScanner.swift` 移到 `Core/Pure`：它被 5 个跨层文件按裸名引用，
  住在生产者文件里让每个读者都依赖那个文件，并且**它因此永远无法被测试**——测试 target 只编译
  `Core/Pure`（`Package.swift:13`），`Core/AX` 与 `Core/Engine` 都在外面。这一点是本轮才发现的：
  测试网的边界是 Pure，所以在 Pure 之外的任何东西都拿不到单元测试，无论它本身有多纯。

**验收**（等价性是量出来的，不是看出来的）：
- `KAGIPEEK_SELFTEST=1` 产出同样的 29 个顶层键，无缺失、无多余；
- settings 预览截图与改动前逐字节相同（`b43e2206…`，该场景是确定的，见复审 N6）；
- 面板日志指标逐字相同：`app=57 system=79 page=1/6 rows=24`、182 项、201 快捷键、`state=ok`；
- 新增 6 个测试（546 总数）；Core 独立 typecheck 115 文件 0 诊断。

引擎 2,536 → 2,513 行。**23 行不是重点**，重点是这条路径此前只能端到端验证，现在有单元测试了。

## 7. 下一轮该看的

1. **测试 target 只覆盖 Pure**（`Package.swift:13`）。这是"缺的是对引擎/输入层的测试"的根因，
   不是"测试太少"。要不要把 `Core/` 整体纳入测试 target 是个独立决策——会拖进 AppKit 依赖，
   且 `StrictConcurrency` 实验特性与 app 的 `complete` 未必给出同样诊断，动之前要先试。
2. **共享核心收窄**（第 5 节），这是让那四段变得可搬的前置条件。
3. `Lifecycle`（15 个协作者）和 `Collaborators`（23 个）本身是"装配"而非逻辑，
   它们大是因为协作者多。若真的要把引擎变小，减少协作者比搬方法有效。
