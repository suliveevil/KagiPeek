# KagiPeek 面板速查行：三列布局 / Emacs 式点选修饰键 / 收窄即透传

**日期**：2026-10-23
**分支**：`feat/v2.2`
**提交**：`5e5cb0d`（选择与执行修复 + 三列）→ `2a11400`（三处修正）→ `1134a53`（点选修饰键合成）→ `601fa28`（latch 预览）→ `5919b93`（文档）
**参与成员**：Cody（代码审查 + 实现）、Archi（架构设计）、Tessa（测试）、主理人（综合 / 复审 / 安装验证）
**本文件**：三个用户诉求的落地记录 + 复审中新发现并修掉的两个缺陷 + 验证记录

---

## 📌 TL;DR

用户提了三件事，全部落地并验证：

1. **功能、菜单路径、快捷键分成三列**，不再因为功能描述长短不一导致菜单路径上下错位。
2. **按住或点击修饰键都视为勾选**，快捷键可以像 Emacs key sequence 一样拆开敲：`⌥⌘C` 既能三键同时按，也能"点 ⌥、点 ⌘、按 C"。
3. **收窄到一项时，Return 或点击要把快捷键透传给前台 App** —— 这个由 emacs-which-key 借鉴来的特性此前完全失效，根因是两处，已修。

复审阶段又发现并修掉两个会让第 2 条"吃掉按键"的缺陷（见下文"复审新发现"）。

**测试 148 → 175**，`swiftc` Release 构建零告警，已签名覆盖安装到 `/Applications`，五张截图验证。

---

## 🎯 诉求一：三列布局

### 问题

行原本是一条 `HStack`：标题 → 菜单路径（有才显示）→ 冲突徽标（有冲突才显示）→ 收藏星标 → 快捷键。每一列都是可选的，于是每一行的菜单路径都从一个不同的 x 开始；带 ⚠︎ 的行会把快捷键再往左推约 17pt。

### 方案

新增 `Core/Pure/RowLayout.swift`：一行里四个槽位（标题 / 菜单路径 / 尾部槽 / 快捷键）的宽度全部是**与行内容无关的算术**，因此可以离开窗口单测。

- 菜单路径列：`rowWidth ≥ 300` 才显示（否则整列消失，300pt 的单列面板要把宽度留给命令名）；`≥ 380` 时拿更宽的一份。中间截断——路径的两端才是信息。
- 快捷键列：`clamp(0.28 × content, 52, 120)`（右侧）或 `clamp(0.22 × content, 48, 96)`（左侧）。**两个位置都预留快捷键**：它是尾部簇的一部分，不预留就会让长标题把快捷键顶出行外。
- 尾部槽：冲突徽标 + 子层级 chevron + 收藏星标，**永远预留**，没有就透明。徽标只在该有的时候才加，正是它让快捷键列左右横跳。
- 标题列：拿剩下的，下限 60pt。

chevron 从菜单路径列左边**移进了尾部槽**：窄面板会整列丢掉菜单路径，那时"这一行还有下一层"的标志必须跟着活下来。

---

## 🎯 诉求二：Emacs 式点选修饰键

### 设计（Archi）

一次按键可以由两个来源拼成：**物理按住的**（面板一直在做的收窄）和**标题栏点选的**（粘性，直到序列完成或取消）。`PendingModifiers` 把两者分开存，只有 `effective`（并集，去掉单独的 held ⇧）参与收窄和高亮：

```
held      物理按住，瞬态，每次 flagsChanged 更新   →  收窄（一直如此）
latched   标题栏点选，粘性                        →  收窄 + 折叠进下一击
```

于是 `⌥⌘C` 有三条路：三键同时按（原行为）、点 ⌥ 点 ⌘ 再按 C、或两者混用。narrow 功能不受任何影响——点选只是同一个"仅修饰键前缀"的第二个、粘性来源。

### 单一决策点（Archi 的要求，主理人落地为硬约束）

**"合成层的决定必须是单一纯函数产出的一对结果，而不是两侧各自判断。"**

`ChordComposition.resolve(prefix:physical:pending:key:in:)` 是那一个纯函数。它产出：

| 字段 | 含义 |
| --- | --- |
| `probe` | 用 `physical ∪ latched` 拼出的和弦 |
| `outcome` | `.complete(item)` / `.descend` / `.noMatch` |
| `composed` | 和弦里有没有一部分来自面板而不是事件 |

**事件 tap 和引擎读同一个结果**，所以"吞键"和"注入"不可能各说各话：

| `composed` | outcome | tap | 引擎 |
| --- | --- | --- | --- |
| false | 任意 | 放行 | 前台 App 自己执行；面板只闪一下行 |
| true | complete / descend | 吞掉按键（连 key-up 一起） | 把**拼好的**整条和弦回放给前台 App，或下钻一层并清掉点选 |
| true | noMatch | 放行 | 什么都不做；点选保留，用户还在序列中 |

`composed == false` 的判据是 `latched.subtracting(physical).isEmpty`：每一个点选的修饰键恰好也都物理按着，那这一击就是普通按键，必须**逐格等于改动前**——不吞、不注入、走 `complete()` 闪一下 + 事件放行。这条由 `ChordCompositionTests` 的三条用例钉住（含"点选的修饰键恰好也按着"这一边界）。

其余行为：

- **⌫ 先撤销一次点选**（后点的先撤），没有点选才 pop 一层，再没有才关面板。
- **芯片两种语义**：内联筛选开着的时候是"筛选"（不带的修饰键的行消失），否则是"合成"。同一个 ⌃⌥⇧⌘ 四种含义由模式决定，`OverlayView` 的 `ticked` 据此二选一。
- **下钻时清掉点选**：它已经折叠进这一击了，留着会对下一击再生效一次。
- **半条序列在以下时机丢弃**：关面板、Esc、hyper、打开内联筛选。
- **HUD 显示拼好的整条和弦**，不是裸键——否则用户没法确认点选有没有生效，而这正是这个交互的全部意义。

---

## 🎯 诉求三：收窄到一项时要透传（Cody 的根因分析）

这个特性此前**完全失效**，而且是三个独立缺陷叠加，每一个都足以让它失效：

| # | 缺陷 | 后果 |
| --- | --- | --- |
| 1 | `PrefixHit.id` 曾被改成 `item.id + "|" + nextKey` 的复合 id | 行点击 / Return / 复制 / 收藏 / 完成闪光全部静默失败——它们比较的是两个不同的命名空间 |
| 2 | `activate()` 用 `remainingSteps > 0` 判定下钻，而 chevron 用 `> 1` | 空前缀下 `⌘C` 的 `remainingSteps` 是 **1**（`remainingSteps(after:)` 把当前显示的这一击也算进去），于是点击 drilling 下去，该行随即从 `hits` 里消失——**面板把自己清空了** |
| 3 | `selectionIndex` 永远是 -1 | `performSelectedPanelRow` 在 `guard` 处静默返回；另有 `handleModifiers` / `toggleFavoritesFilter` / `setModifierFilter` 三处会把索引改回 -1 的有害写入 |

### 修法

- `PrefixHit.id` 回到 `item.id`（每一层每个绑定一行，绑定 id 在这里本就唯一）。
- `KeyChord.isFinalStroke(after:)` = `remainingSteps(after:) <= 1`，**唯一判据**；`PrefixResolver.shouldDescend` 与 `PrefixHit.isTerminal` 删除，chevron 与 `activate()` 从此用同一句话。
- 新增 `PanelSelection.resolved(previous:rowCount:)`：0 行 → -1，上次选择仍有效 → 保留，**恰好 1 行 → 0**，否则 -1。两条重建路径都走它；删掉三处 `= -1`。
- `RowKeyRouter.action(for:modifiers:held:run:copy:)` 增加剥掉 held 的四步顺序：① run(剥后) ② copy(原样) ③ copy(剥后) ④ run(原样)。修的是"收窄中 ⌘+↩ 匹配上 ⌘↩ 于是变成复制"——run 永远可达。
- 方向键改用 `modifiers.subtracting(panel.heldModifiers)` 判定，修的是"按住修饰键时方向键全死"。
- `updateKeyCapture` 同时注册 `spec.modifiers` 和 `spec.modifiers ∪ held`，修的是"面板处理了一个它从未吞掉的键"。
- `activate()` 成功时显示 HUD（`showExecutedHUD` 此前是死代码）。

---

## 🔍 复审新发现（主理人在 PR3 审查中发现并修掉）

PR3 的代码由 Cody 在两次 429 限流前写完，测试全绿、Release 构建零告警。逐行复审时发现两个会让诉求二"吃掉按键"的缺陷：

### 缺陷 A：tap 与引擎对同一个键的判断会不一致

`shouldSwallowComposed` 只问"这一击能不能合成一个绑定"，但 `handleKeyDown` 的前几个分支会先把**面板自己的键**吃掉：`/` 开筛选、Esc 关面板、方向键移动、`;`/`'` 翻页、行键执行选中行。

点选的修饰键**不在事件里**，所以这些键到达时携带的修饰键是空的——`⌥;` 于是是一个完全合法的绑定，合成层会把它当成 `⌥;` 的第一击吞掉，而引擎同时在翻页。**按键被吃掉，用户要的事情一件都没发生。**

修法：新增 `PanelKeyIntake.isConsumedBeforeComposition(...)`，把"引擎会当成面板自身消费掉的键"列成**一份**清单，tap 和 `handleKeyDown` 都读它。⌫ 故意不在清单上——它归引擎独有（有点选时它在撤销点选，必须吞；没有点选时它属于前台 App）。

### 缺陷 B：被吞的 key-down 与它的 key-up 不配对

`KeyboardMonitor` 的 key-up 路径靠"同一个 (keyCode, modifiers) 标识"来匹配被吞的按下。修饰键完全可能在两件事之间变化（⌘ 先松手），那时标识就不再匹配，前台 App 就拿到一个从未按下过的键。

合成路径让这件事**必然发生**：面板在 key-down 就把自己关掉了，点选随之清空，等到 key-up 时 `latchedModifiers` 已空，动态闭包直接返回 false——释放事件漏给前台 App。

修法：tap 记住被吞的 key-down 的**虚拟键码**，并吞掉它的释放。按键码匹配（物理键不释放不可能再按一次），这是安全的方向；代价是两台键盘无法区分，已记入"已知限制"。

---

## 🧪 测试（Tessa + 主理人）

| 文件 | 内容 |
| --- | --- |
| `PanelRowContractTests.swift` | 选择解析（0 行 / 1 行 / 陈旧索引 / 多行不抢首行）、三列布局不变量、下钻判定、行键路由、`ModifierSet.subtracting` 值语义 |
| `ChordSequenceTests.swift` | `PendingModifiers`（held/latched 分离、单独 ⇧ 规则、pop 顺序）、`ChordComposition`（合成 / 不合成 / 恰好也按着 / 最后一击 / 下钻 / noMatch / 吞键真值表）、收窄未被破坏（superset 规则）、`PanelKeyIntake` |

`testTitleFloorEngagesAtTheNarrowestSupportedRow` 这条值得单独说：它钉住 `max(60, …)` 这个下限**在哪一档真的生效**（单列 300pt + 右侧快捷键列，预留之和比行宽多约 3pt，行会溢出被裁），以及生效时溢出多少。把这个口子钉成"显式决策"——若将来改成降级式（放不下就让掉菜单路径列重算），这条要跟着翻。

---

## ✅ 验证记录

| 检查 | 结果 |
| --- | --- |
| `swift test --disable-sandbox` | **175 tests, 0 failures**（本轮开始是 148） |
| `scripts/build_swiftc.sh Release` | 零 error / 零 warning（`grep -c` 计数为 0） |
| 安装 | 签名 "KagiPeek Local"，`codesign --verify --strict` 通过，原子替换 `/Applications/KagiPeek.app`，保留 `.previous.app` |
| 截图 | 五张：`overlay`（三列对齐）、`overlay-held`（⌘ 按住收窄 + 点亮）、`overlay-chips`、`overlay-latch`（⌥⌘ 点选收窄 + 芯片蓝底）、`overlay-narrow`（300pt 单列，菜单路径列消失、chevron 落在尾部槽） |
| 芯片三态数值 | held：⌘ 平均亮度 94.9 vs 其余 82.5；ticked：⌥/⌘ 为 accent 蓝底药丸，⌃/⇧ 暗灰 |
| 设置还原 | 预览会改写 `settings.json`，已从 `/tmp/kagipeek-settings-backup3.json` 还原 |

**真机行为（点击芯片 → 按 C → 注入 ⌥⌘C）未能在此环境端到端验证**：事件 tap 需要 Accessibility 驱动的真实输入，且预览模式只搭建状态、不模拟按键。该路径由 `ChordCompositionTests` 覆盖合成与吞键判定，注入走的是与点击行完全相同的 `ShortcutInjector.post` 通路（已在此前版本验证）。

---

## ⚠️ 已知限制（新增）

| 项 | 说明 |
| --- | --- |
| 收窄中复制键有二义性 | ⌘ 按住时 `⌘↩` 就是 `⌘` + `↩`，两者无法区分，于是 `⌘↩` 答 run。复制要先松 ⌘、把复制键录到不用于收窄的修饰键上（⇧↩），或者**点选** ⌘ 而不是按住——点选不在事件里，`⌘↩` 就仍是复制 |
| tap 的 key-up 记忆按键码 | 见缺陷 B 的修法；两台键盘无法区分 |

---

## 📁 落地文件

**新增**：`Core/Pure/PendingModifiers.swift`、`Core/Pure/ChordComposition.swift`、`Core/Pure/PanelKeyIntake.swift`、`Core/Pure/PanelSelection.swift`、`Core/Pure/RowLayout.swift`、`Tests/.../ChordSequenceTests.swift`

**主要修改**：`Core/Engine/ShortcutEngine.swift`（+172 及后续）、`Core/Input/KeyboardMonitor.swift`、`Core/Pure/PanelState.swift`、`Core/Pure/KeyChord.swift`（`isFinalStroke`、`subtracting`）、`Core/Pure/PrefixResolver.swift`、`Core/Pure/PanelOrdering.swift`、`Core/Pure/KeyFormatter.swift`（`Segment`）、`UI/Overlay/OverlayView.swift`（三列 / 芯片三态 / chevron 入槽）、`docs/ARCHITECTURE.md`

> 本报告由工程保障团队协作产出，实现与验证由主线程执行；两位成员在 429 限流后由主理人接手完成剩余工作，关键结论请由人类工程负责人复核。
