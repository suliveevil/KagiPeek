# STATUS

[English](../en/STATUS.md) · [中文](STATUS.md)


as of **2026-11-06**（Asia/Shanghai）。

**过期即失效：这份文件只记录写下这一刻的事实。** 接手前先 `git log -1`、跑一次
`swift test`，再按下面「最后一次验证」的命令重跑；任何一项与当前输出不符，以当前输出为准，
并把本文件更新后再用。

## 当前代码状态

- 代码 HEAD：`b53c252`（`feat(trigger)`：面板打开时向 Karabiner 写 `kaname_panel`，让
  绑定在触发键上的规则让路），版本 **2.3.1 (build 231)**，本地已打 tag `v2.3.1`。其下
  `63b3bbb`（`docs(status)`）记录 2.3.0 的 Homebrew 安装，`bf79a82`（`fix(cask)`）与
  `87ebff4`（2.3.0 发布准备：改名、设置四页重构、设计评审修复、构建脚本加固）。
  `/Applications/Kaname.app` 于 2026-11-06 22:57 由 `63b3bbb-dirty` 构建安装，**功能已是
  新版，但 `KanameCommit` 是 `63b3bbb-dirty`、版本号仍是 2.3.0 (230)**；要让它显示 2.3.1
  得再跑一次 `./scripts/install.sh`。
- 标签：本地与远端都有 annotated tag `v2.3.0`（tag 对象 `014d4531`，指向 `87ebff4`）。
  改名前的 `v1.0.0` / `v1.1.0` / `v1.2.0` / `v2.0.0` / `v2.2.0` 已删除，只剩 `v2.1.0` 与
  `v2.3.0`；删除前已确认为 `main` 可达，未向远端补推历史 tag。
- 分支：`main` 已推送（`origin/main` = `bf79a82`）。本轮短命分支 `chore/cask-render`、
  `chore/homebrew-tap`、`fix/cask-app-stanza` 合并后删除。本地仍有开发分支
  `feature/panel-sections` 与旧历史备份 `backup/pre-squash-20261104-192838`。
- `swift test --disable-sandbox` 最后一次记录是 `b53c252` 的 850/0（含新增的
  `KarabinerPanelSignalTests` 五条）；`scripts/build_release.sh`（`KANAME_SKIP_DMG=1`，外部
  终端）在同一份代码上 `BUILD SUCCEEDED`，产物 plist 为 `2.3.1` / `231`。
- 设置 schema：11。v11 新增 `karabinerPanelSignalEnabled`（默认 `true`，无迁移步骤）；
  v10 的 `usageSortField`（默认 `shortcut`，删除 `sortMode`）、v9 的
  `showConfigToolsInPanel`（默认 `false`）与 `scanConfigFiles` 原值不变。

## 本轮完成

- **Karabiner 面板信号（方案 3，`b53c252`，tag `v2.3.1`）**：面板显示期间写 Karabiner 变量
  `kaname_panel=1`，关闭写 0，启动/退出也写 0（崩溃不会留下抑制用户规则的 1）。
  `Core/Pure/KarabinerPanelSignal` 只管变量名、payload 与「面板可见且开关开启」的决策；
  `Core/Services/KarabinerBridge` 是传输层：私有串行队列、合并去抖、`lastWritten` 去重、
  `Process` 调 `karabiner_cli --set-variables`（stdout/stderr 都进 `nullDevice`）、失败只记
  一条 `[settings]` 警告、`clearAndWait()` 在退出路径阻塞写 0。`ShortcutEngine` 在
  `start()` / `activatePanel()` / `dismissPanel()` / `stop()` / 开关变化时调
  `signalKarabiner()`。设置页新增「触发 → 面板打开时通知 Karabiner」开关与未安装提示，L10n 三条
  中英文案。用户侧还需给自己的规则加
  `conditions: [{"type": "variable_unless", "name": "kaname_panel", "value": 1}]`——用
  `variable_unless` 而不是 `variable_if`，后者只在面板打开时**生效**，方向正好相反。
  方案 1（录制式触发键）与方案 2（冲突检测覆盖裸修饰键规则）已由用户明确否决，不实施。

- **设置重构（四批改动；分支名与提交信息里的“四页”指四批，不是四个页面）**：通用页的「菜单不可用时使用内置
  快捷键」「扫描时包含 Apple 菜单」并入「忽略的菜单项」卡片；执行提示改称「执行后显示
  快捷键已触发提示」。触发页两个开关移到卡片标题左侧、删除「启用」行与「重新查看触发提示」。
  外观页两个数字改为可输入（6–60 / 8–80，回车或失焦提交，越界保留旧值并提示 3 秒），收藏
  两项单独成卡。统计页改为一行一个 `usageKey` 的扁平列表，快捷键置前、App 与功能描述作
  备注，可按快捷键 / App / 功能描述排序。新增 `UsageSorting`、`NumericSettingInput`、
  `UsageBreakdown.entries(records:known:)` 与 `EngineState.usageBreakdownAllCache`；删除
  `Ranker`、`UsageOrdering`、`RankMode`、`summariesByApp()` 及其测试。

- **配置工具区：逐工具折叠 + 默认隐藏**（`c696f0c`、`321cf2a`）：折叠状态由单个
  `toolSectionExpanded: Bool` 改为 `expandedTools: Set<ConfigTool>`，`PanelGroup.tool` 把
  工具身份带到卡片上，点击只切换被点的那张；`narrowing = !filter.isEmpty` 时
  `ToolSectionFold` 让所有工具卡临时展开，`expandedTools` 不被过滤写入，清空后恢复用户
  手动折叠。新增 `showConfigToolsInPanel`（默认 `false`，设置页在「冲突 → 配置文件」，文案
  「在提示面板与搜索面板显示配置工具」+「只影响显示：这些配置文件照旧扫描，冲突检测照常
  工作」）；关闭时面板不生成工具卡、不占行预算，面板内联过滤语料与搜索面板语料都不含工具
  行，combo answer 仍读 `configBindings`。`apply(settings:)` 同时失效
  `searchCorpus` / `panelFilterCorpus` / `rowBudgetCache`。新增 `ToolSectionFoldTests`、
  `PanelSectionsTests.testHiddenConfigToolsContributeNoRowsOrCards` 与 `SettingsDefaultsTests`
  的迁移用例；`swift test` 844 → 849。

- **面板修饰键 + 字母混合筛选**（`428c925`）：`Core/Pure/PanelFilter` 用有序 token 队列保存
  筛选条件——修饰键在按下边沿入队一次，字母键追加为小写 token；`⌫` 弹队尾（末尾是字母就删
  字母，末尾是修饰键就移除该修饰键），再按同一修饰键从队列任意位置移除，第三次按下作为新队尾
  入队（纯 toggle）。松开不翻转，按住只入队一次，条件保持（latched）；触发键那一次按下不入队。
  `Core/Pure/PanelFilterPlan.matchingIDs` 复用 `SearchCorpus.search`，查询串为
  `PanelFilter.query`（修饰键 glyph + 小写字母），不另建第二套匹配；空队列回全量、第一页，
  结果变小时 `panelPage` 把页码夹到最后一页。Shift 仍只做 `0–9` / `a–z` 提示层；`.active`
  之外（如搜索面板）字母留在输入框；方向键与四对翻页键不受影响，触发键不 narrow 的
  `PanelTriggerNarrow` 规则不变。新增 `PanelFilterTests`、`PanelFilterPlanTests`；
  `swift test` 726 → 741。
- **面板几何失效与 Space 重扫（G1–G4）**：`containedFrame` 先把尺寸夹到可见区，再按方向判断
  8pt `screenMargin` 是否放得下，放不下该方向取 0，整屏大小的帧不再被边距推出去（`80d5810`）。
  新增纯类型 `PanelAnchorCache`（`invalidate` / `beginRead(pid:)` / `apply`，陈旧 pid 的结果被
  丢弃）；`SurfacePanelController.hide()` 取消在途 `geometryTask`、复位 `isRefreshingGeometry`
  并清空快照，控制器自行观察 Space 与屏幕参数变化并清空快照，下次展示后台重读；无快照期间
  `OverlayPlacement.coverSize` 以整块可见区兜底，首帧就完整覆盖（`29f1f8f`）。新增
  `topInset(safeAreaTop:) = max(safeAreaTop, screenMargin)`、`fillScreenFrame`（只缩高度、原点
  不动）与 `clampedTop`；`.fillScreen` 避开顶部安全区，`.fixedSize` / `.coverWindow` 在
  `containedFrame` 后不再顶进菜单栏或刘海（`c28895e`）。新增 `SpaceRescanGate`（0.75s、按
  pid 去抖）与 `CatalogPublishPolicy`：切 Space 先 `dismissEverything()`，再强制重扫当前前台
  App，日志 `space changed → forced rescan <app>`；`CatalogCoordinator.reload` 的
  `preserveOnEmpty` 在空列表且无菜单栏时保留旧目录并复位加载状态（`bd2b6b0`）。新增
  `PanelAnchorCacheTests`、`SpaceRescanGateTests` 与 `OverlayGeometryTests`；`swift test`
  708 → 726。
- **面板可读性、设置窗口与材质收口**（基线 `553fcca`，本轮三组提交）：选中菜单项左侧加
  3pt 高亮竖条、标题提亮，VoiceOver 暴露 `.isSelected`，朗读顺序「菜单项名 → 快捷键 →
  状态」，行容器由 `.ignore` 改为 `.contain`，装饰元素 `accessibilityHidden`；不可用菜单项
  行尾加 `lock.slash`，右键菜单首行「该菜单项当前不可用」，点击弹 HUD 解释，`DisabledNoticeGate`
  （纯类型）限制同一菜单项 3 秒内只提示一次。新增 `PanelEmptyKind`（纯枚举），统一四种空态并
  按「权限未就绪 > 扫描中 > 无匹配」定优先级，权限态带「打开权限向导」。`maxItemsPerPage`
  明确为上限，实际取 `min(设置值, 几何容量)`；设置文案改为「每个分组最多显示 N 个菜单项 /
  Max menu items per group」；组标题只在「按菜单栏分组」时绘制且单独计入高度。快捷键列改
  等宽字体、固定列宽、默认右对齐，无快捷键留空；纯选中只写 `panelSelectionIndex` 不重建面板，
  选中态 0.1s 过渡，`MenuTrigger.press` 以 `@concurrent` 与 250ms 超时离开主线程。切换
  面板排序时只闪一行 HUD，不常驻标签。首次启动用一次 `KanameTriggerTipShown`
  提示，触发页可重看。设置窗口 `styleMask` 去掉 `.miniaturizable`，权限向导在设置可见时以
  sheet 依附。材质改为浅色 `.popover`、深色 `.hudWindow`，外边距 16、内容内边距 8/10、
  圆角 12。新增 `DisabledNoticeGateTests`、`PanelEmptyKindTests`；`swift test` 693 → 708。
- **页脚不再遮挡菜单项**（`fix/panel-footer-clearance`）：`OverlayMetrics` 把标题栏 54pt、
  分隔线 1pt、页脚 32pt、列表内边距 18pt 合成 `chromeHeight`，SwiftUI 三个固定高度也读同一组
  常量，页脚是内容区的兄弟而不是叠层。新增 `rowsPerColumn` / `fittedPageSize`：每页行数取
  `min(设置值, 几何容量)`，720pt 两卡窗口里 60 行降到 36 行；整数取整带 1e-4 容差，恰好的
  N 行不会被缩放算成 N−1；连一行都放不下时仍保证一行。`OverlayPlacement.containedFrame`
  把贴近屏幕底部的面板整体上移，不再裁掉最后几行。删除内容区底部的 18pt 渐隐——它会盖住
  最后一行。`swift test` 684 → 693。
- **前后翻页键可配置（`feature/paging-key-pair`，已并入 main）**：新增
  `Core/Pure/PagingKeyPlan`，四对键（`,`/`.`、`[`/`]`、`-`/`=`、`;`/`'`）按实际产生的
  字符判定，物理键码只在事件没有解码字符时兜底；设置 → 通用 → 菜单项操作下改为四个勾选项，
  可同时启用多对或一对都不勾，默认只勾 `;`/`'`（原来写死的那一对）；←/→ 永久生效且不在
  设置组里。搜索框有焦点时八个字符全部作为输入透传；Shift 提示层激活时 `+`（Shift+=）
  既不是翻页键也不是 `0-9/a-z` 提示标签，按普通输入落到前台。设置 schema 7→8，
  缺字段→默认 `;`/`'`，集合内未知值丢弃而不整份回退；`apply(settings:)` 与
  `logSettingsDelta` 同步集合字段。`swift test` 768 → 789。
- **面板定位修正**（提交见 `git log`）：提示面板的 `coverWindow` 高度不再被内容高度整段替换，
  改为取覆盖高度与内容高度的较大者并夹在可见区内；横向仍按屏幕可见区中心对称计算。
  搜索面板从「屏幕居中 + 距顶 140pt 的 680×460」改为「前台窗口居中」：宽度固定 680，
  高度至少等于前台窗口高度（夹在可见区内），帧以窗口中心为基准并夹回可见区，无窗口帧时
  回退屏幕中心；前台 pid 在 `NSApp.activate()` 之前读取。新增 `Core/Pure/OverlayPlacement`
  承接这套几何，`swift test` 672 → 682；再补两条全屏边界断言（前台窗口铺满屏幕时
  `visibleFrame == screen.frame`，24pt 余量被裁、提示面板恰好等于屏幕，搜索面板高度取到屏高）
  后为 684。
- **前台 app 切换后的首帧覆盖**：`SurfacePanelController` 里窗口帧是异步读的，切到新 app 后
  第一次按住修饰键时 `anchorWindowFrame` 还是 nil，面板按 0.8×0.7 的兜底尺寸画出，之后
  `refreshGeometry` 只移动位置、沿用兜底尺寸，所以要到松开修饰键、`presentPanel` 再跑一次
  才覆盖。现在兜底尺寸取整个可见区（任何窗口都在其中），几何到达后按与 `presentPanel` 相同的
  规则重算尺寸再落位，首帧起就完整覆盖。
- **设置页文案与触发卡片**（`d4321ea`）：`rankingModeHint` 改为「面板顺序在外观页设置，搜索面板按匹配度
  排序」；删除触发页误用的面板提示脚注。触发页拆成两张卡片「修饰键触发 / Modifier trigger」
  与「快捷键触发 / Shortcut trigger」，各自带启用开关。
- **预设快捷键可删除**（`d4321ea`）：五个绑定槽（面板/搜索/切换三个全局快捷键，以及行执行/复制）改为
  `HotkeySpec?`，`nil` 表示未设置；`L10n` 增加「未设置/删除/启用」。设置页每行有删除按钮，
  清除后路由与吞键规则跳过该槽，面板脚注按剩余按键降级；JSON 里写 `null`，字段缺失仍回退
  默认值，schema 仍为 7。`swift test` 保持 672。
- **签名密钥迁到独立钥匙串**（`a0b1401`）：新增 `~/Library/Keychains/kaname-signing.keychain-db`，
  口令 `~/Library/Application Support/Kaname/signing/keychain-pass`（600，目录 700）；
  `.p12` 备份与口令同目录（600）。身份仍是原证书（SHA-1 `6c0ac5…a929`），登录钥匙串中的
  副本已删除；`security find-identity -v -p codesigning` 只剩一条。`build_swiftc.sh`
  自动解锁并显式 `--keychain`；`setup_signing.sh` 改为直接在新钥匙串建身份。
- **未推送历史整理**：把 `origin/main` 之上的 72 个提交（59 个普通提交 + 13 个 merge）
  squash 成 1 个；代码内容零丢失，只顺带清理了 STATUS、ARCHITECTURE 与设计草稿里过期的
  测试数和 commit 示例。旧历史保留在本地 `backup/pre-squash-20261104-192838`（tag 与
  branch，均未推送）；重写后的 `main` 已用 `--force-with-lease` 推到 `origin/main`。
- **引擎协作模块拆分（R-3）**：`ShortcutEngine` 从 2761 行 / 139 个函数降到 1541 行 / 103
  个函数；新增 `BindingEditor`、`RowRunner`、`CatalogCoordinator`、`SearchSession`、
  `LiveTestCoordinator`、`DiagnosticsReporter`、`PanelSession`，并把录制规则与搜索 scope
  切换下沉为 `Core/Pure/RecordingPolicy`、`Core/Pure/SearchScopePlan`。InputRouter 按计划
  永久留在引擎里。详见 `outputs/refactor-engine.md`。
- **面板翻页闭环**：`Core/Pure/PaginationPlan` 实现首尾循环与页码夹取；单页时两键不动作、
  不重建、不闪。页码语义未变；按键来源后来改由 `PagingKeyPlan` 提供（见本轮条目）。
- **设置页诊断合并**：把「关于」页的诊断区（辅助功能、输入监控、监听状态、菜单项数、
  导出诊断报告、说明）整段并入「诊断」页，排在日志目录之后、隐私说明之前；`关于` 页只留
  图标/版本、系统版本、更新检查、数据目录、仓库与许可证。`exportDiagnostics()` 移到诊断区，
  功能与文件名（`kaname-diagnostics.json`）未变。
- **备份与签名约定落地（只改脚本与文档，未构建、未安装）**：新增
  `scripts/backup_app.sh`（备份到 `~/Library/Application Support/Kaname/backups/`，
  命名 `Kaname-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app`，默认保留 5 份）；
  `scripts/install.sh` 改为调用它、拒绝安装 ad-hoc 包、回滚改为从 backups 恢复。
- **面板排序可切换（`feature/panel-sort`，fast-forward 合回 main）**：外观页在「键位位置」
  后新增「面板排序 / Panel order」分段控件，两项互斥：`按修饰键 / By modifier`（默认，
  与旧行为完全一致）与 `按菜单栏分组 / By menu group`。新增 `Core/Pure/PanelSortOrder`：
  按菜单栏分组以 `axPath` 第一段（菜单栏索引）为组序，同一顶层菜单的菜单项连续出现，组内
  仍按快捷键；没有 `axPath` 的组排在有索引的组之后，空组最后。Shift 提示层的 `0-9/a-z`
  每次重建都按屏幕上的显示序列分配，换顺序后同一个键指向新位置上的菜单项，不绑死条目。
  设置 schema 5→6：v5 文件缺 `panelOrder` 时按默认 `按修饰键` 迁移，手写旧 JSON 与损坏
  文件回退都走同一条 `decodeIfPresent` 路径；`apply(settings:)` 与 `logSettingsDelta` 同步
  新增字段，排序缓存键（`OrderedHitsKey`）加入 `panelOrder`，已打开的面板立即重排。
- `swift test`：656 → 666（新增 10 项，覆盖两种顺序、分组连续性、组序来源、无组/空组
  兜底、Shift 标签随顺序、默认值与 schema 5→6 迁移、编码与往返、损坏 JSON）。
- **连按两次改为自动窗口（`feature/auto-double-tap`，fast-forward 合回 main）**：删除
  设置页的「双击间隔」滑杆与 `doubleTapWindow` 字段；新增 `Core/Pure/DoubleTapTiming`，
  窗口跟随系统「双击速度」（`NSEvent.doubleClickInterval`）并限制在 0.25–0.6 秒。判定
  改为「两次干净按压，中间没有其他键，只计两次之间的间隔」：慢按仍算一次，第二次按久
  也会在松开时完成；按了别的键仍取消。设置 schema 6→7，旧字段被忽略并在下次保存时丢弃；
  诊断页只读显示当前生效窗口。`swift test` 666 → 672。
- **术语统一为「菜单项」**（提交 `05c775f`）：对象本体统一叫「菜单项 / menu item」，
  「快捷键」只指菜单项的键盘捷径（没有时留空，不再写「无快捷键」），「行 / row」只用于
  布局；数量表达统一为「菜单项数」。改的是 `L10n` 中英两列、`PanelSession` 的无快捷键
  渲染，以及 README、ARCHITECTURE、FAQ、TROUBLESHOOTING、RELEASING、PERMISSIONS、STATUS
  和设计草稿；代码标识符（`RowID`、`rowKey`、`RowRunner` 等）一律未动。
- **`install.sh` 签名门禁修复**（提交 `a31044d`、`05e424e`）：`codesign -dv` 读不到
  `Authority`，改用 `-dvvv`；随后发现 `pipefail` 下 `codesign | grep -q` 会因 SIGPIPE
  误判，改为捕获输出后用 `case` 匹配。稳定签名包不再被误拒。

## 最后一次验证

以下都是实际跑过的命令与输出，不是推断。

| 命令 | 结果 |
| --- | --- |
| `swift test`（本次安装前） | `Executed 684 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（本轮 UI 批次提交前） | `Executed 708 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（G1–G4 代码批次） | `Executed 726 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（面板筛选提交 `428c925`） | `Executed 741 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（面板三来源分区 + 受限动作） | `Executed 768 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（合并翻页键 `feature/paging-key-pair` 后） | `Executed 789 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（逐工具折叠 `c696f0c`） | `Executed 844 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（显示开关 `321cf2a`，2026-11-06） | `Executed 849 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `swift test`（改名 B5–B7 后，2026-11-06） | `Executed 855 tests, with 0 failures (0 unexpected)`；退出码 0 |
| `scripts/build_swiftc.sh Release`（2026-11-06 09:28） | `==> Signing with Kaname Local`；`codesign --verify --strict` 通过 |
| `security find-identity ... kaname-signing.keychain-db` | 仅 `E40CFAA44DE724347FA66BB0BF84E2D58953C17E "Kaname Local"` |
| `codesign -d -r- /Applications/Kaname.app` | `identifier "com.suliveevil.kaname" and certificate root = H"e40cfaa4…c17e"` |
| `codesign -dvvv /Applications/Kaname.app` | `Authority=Kaname Local`；`Identifier=com.suliveevil.kaname`；`flags=0x10000(runtime)` |
| `scripts/install.sh`（`KANAME_SKIP_BUILD=1`，2026-11-06 09:29） | `Kaname Local` 签名；旧 `Kaname.app` 备份到新目录后移除 |
| `KanameCommit` / 版本串 | `00cc7bf` / `2.2.0 (220)` |
| `pgrep -lf Kaname.app/Contents/MacOS` | `74955 /Applications/Kaname.app/Contents/MacOS/Kaname`（单实例） |
| `scripts/build_release.sh`（外部终端，2026-11-06） | exit 0；`Kaname-2.3.0.dmg` 5,923,984 字节；sha256 `0cdcc82c…938d` |
| `gh release create v2.3.0` | 资产 `Kaname-2.3.0.dmg`（digest `sha256:0cdcc82c…938d`）与 `Kaname-2.3.0.dmg.sha256` |
| `brew install --cask kaname`（外部终端） | exit 0；`kaname was successfully installed!` |
| 安装后 Info.plist | `com.suliveevil.kaname` / `2.3.0` / `230` / `KanameCommit=87ebff4` |
| `codesign --verify --strict /Applications/Kaname.app` | 通过；`Authority=Kaname Local`；`TeamIdentifier=not set` |
| `pgrep -lf Kaname.app/Contents/MacOS` | 单实例（PID 10769） |
| `spctl -a -vv /Applications/Kaname.app` | `rejected`（未公证，预期结果） |
| `brew list --cask kaname` | `2.3.0`（`/opt/homebrew/Caskroom/kaname/2.3.0/Kaname.app`） |

当前安装的 Info.plist 提交戳为 `87ebff4`，即 2.3.0 的发布提交。构建走
`scripts/build_release.sh`（xcodebuild Release，产物 universal x86_64 + arm64），在外部
终端执行以避开工具沙箱；签名用 `kaname-signing.keychain-db` 的 `Kaname Local`。

签名说明：改名同时换了 bundle id 与证书，designated requirement 已变为
`identifier "com.suliveevil.kaname" and certificate root = H"e40cfaa4…c17e"`。因此这次覆盖安装
**必须重新授权辅助功能**；旧证书 `Kaname Local` 与旧钥匙串保留，作为回滚。

**ad-hoc 只作验证**：`scripts/build_swiftc.sh` 在没有稳定身份时会 ad-hoc 签名，这种包只能
在临时目录做 `codesign --verify --deep --strict`；`scripts/install.sh` 会直接拒绝安装 ad-hoc
包。装进 `/Applications/Kaname.app` 的包必须是 `Kaname Local`（或将来的 Developer ID）。

## 已安装构建

- 路径：`/Applications/Kaname.app`（`/Applications` 下只有这一份，无旧 `KagiPeek.app`）
- 版本串原文：`v2.3.0 (87ebff4)`
- `CFBundleIdentifier`：`com.suliveevil.kaname`
- `CFBundleName` / `CFBundleExecutable`：`Kaname` / `Kaname`
- `CFBundleShortVersionString` / `CFBundleVersion`：`2.3.0` / `230`
- `KanameCommit`（Info.plist）：`87ebff4`
- 安装方式：Homebrew cask，tap `suliveevil/tap`，`brew install --cask kaname`；
  `brew list --cask kaname` 显示 `2.3.0`，Caskroom 路径
  `/opt/homebrew/Caskroom/kaname/2.3.0/Kaname.app`
- 签名：`Authority=Kaname Local`；`flags=0x10000(runtime)`；`TeamIdentifier=not set`；
  designated requirement 根哈希 `e40cfaa4…c17e`，私钥只在 `kaname-signing.keychain-db`
- 运行中进程：单实例（`pgrep -lf Kaname.app/Contents/MacOS` 一条，PID 10769）
- `spctl -a -vv`：`rejected`（未公证，预期结果）
- 旧包备份：覆盖前由 `scripts/backup_app.sh` 备份到
  `~/Library/Application Support/Kaname/backups/`
- 数据目录：`~/Library/Application Support/Kaname/`；日志、菜单缓存与用量照旧
- 迁移结果：`settings.json`、`usage.json`、`conflicts-cache.json`、`menu-cache/`、`logs/`、
  `crash/`、`signing/` 已复制；日志文件名由 `kaname-*.log` 取代；
  `backups/` 178 MB，异步复制完成并写入标记
- 旧日志、旧崩溃报告与旧备份文件名保留在原目录，未做删除

## 已知环境坑

1. **`xcodebuild` 在本机不稳定。** 构建系统给每次编译套 `sandbox-exec`，嵌套沙盒有时被
   拒绝：`sandbox-exec: sandbox_apply: Operation not permitted`。这不是代码问题。本轮
   2026-11-04 22:54 的 `install.sh` 中 xcodebuild 一次通过；22:50 那次先报
   `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`
   与一串 `'self' is immutable` 派生错，重跑即恢复，属于构建缓存问题而不是源码问题。
   失败时仍可回退到
   `scripts/build_swiftc.sh Release|Debug`，它用同一套源码与同一组 Swift 6 编译参数，
   显式加载 SwiftUI 宏插件。
2. **`agent-desktop` 抓不到 `LSUIElement` 应用的窗口。** App 默认没有 Dock 图标和主窗口；
   要先让面板/设置窗口真正弹出，才能在辅助功能树里看到可抓取的窗口。
3. **屏幕录制权限影响截图。** 没有授权时系统截图能拿到画面，但部分自动化截图/窗口捕获路径
   会返回空图；这与 App 自身权限无关。
4. **Git 操作的沙盒提示。** 本机工具会把 `.git/*.lock` 之类临时文件报告为「已移入回收站」，
   但提交、切分支、合并本身成功；不要因此去回收站手动恢复。
5. **`Kaname Local` 私钥的钥匙串授权无法脚本化。** `codesign` 首次使用私钥会弹
   SecurityAgent 对话框（始终允许/拒绝/允许），该弹框受系统保护，AppleScript 的 `click`
   返回成功但不生效，`codesign` 会一直停在 0% CPU。2026-11-04 已由用户手动点「始终允许」，
   之后试签可正常返回；换机或重建钥匙串后仍会遇到。构建前可先试签一个临时文件确认。
6. **工具沙箱里 `diskutil unmount` 对任何 DMG 都失败。** `brew install --cask` 解包后会调用
   `diskutil eject`；在工具沙箱内它返回「至少有一个卷无法卸载」，随后 `Dir.mktmpdir` 清理
   挂载点时抛 `Read-only file system @ apply2files`。同一命令在外部终端里正常。安装类
   cask 操作一律用 `open -a Terminal` 跑脚本，不要因此去改 DMG。
7. **Homebrew 7 要求第三方 tap 显式信任。** 未信任时安装报
   `Refusing to load formula/cask from untrusted tap`；用
   `brew trust --cask suliveevil/tap/kaname`（只信任这一个 cask），不要整 tap 信任。
8. **Homebrew 7 移除了 `--no-quarantine`。** cask 下载与升级都会打 quarantine，首次启动只能
   在系统设置里放行，或对已安装副本 `xattr -dr com.apple.quarantine`。
9. **cask 的 `app` 参数要带扩展名。** `app "Kaname"` 会被解释成名为 `Kaname` 的条目，
   安装时报 `App source '…/Caskroom/kaname/2.3.0/Kaname' is not there`；必须是
   `app "Kaname.app"`。

## 未完成 / 下一步

最多 5 条，每条从「第一动作」开始：

1. **发布链路已走完，下一步是公证**：`main`、`v2.3.0`、GitHub release 与
   `suliveevil/homebrew-tap` 都已上线，安装走 brew cask。要让用户免掉 Gatekeeper 首次放行，
   需要 Developer ID 证书与 `KANAME_NOTARY_PROFILE`，届时 `build_release.sh` 会自动
   notarize 并 staple。没有证书前不要假装支持。
2. **`ShortcutEngine` 拆分已做一轮（R-3）**：七个协作模块与两个 Pure 策略已落地，InputRouter
   按计划留在引擎里。若继续瘦身，下一刀是 `CatalogQuery` 参数对象（架构报告 H1/M1）；不要
   把 InputRouter 硬拆走。
3. **面板 VoiceOver 可达性**（HIG 报告 H2）：本轮已补选中态 `.isSelected`、行的 `.contain`
   容器、装饰元素隐藏与「菜单项名 → 快捷键 → 状态」朗读顺序；剩余是根容器与行内按钮的实机
   VoiceOver 验收。
4. **设置页信息架构**（HIG 报告 M4 / §7.1）：先画 8 段→侧边栏的交互稿并确认窗口尺寸，再动
   `SettingsView`；本轮明确不做。
5. **菜单栏 extras 的 HIG 行为**（HIG 报告 H3）：先确认左键开面板、右键开菜单是否产品意图，
   再改 `NSStatusItem` 的 `sendAction(on:)`。

## 已知未修问题

按审查报告编号列出本轮**明确降级或未处理**的条目（修复说明见
`/Users/suliveevil/.trae-cn/assistant/2026-11-04/kaname-code-review-2/outputs/fix-round2.md`）：

- **设置页缩略面板实时预览（「按下试试」测试区）未实现**：复用 `OverlayView` 需要先把
  engine 解耦，风险高，本轮降级，文档不宣称它存在。
- 并发报告：M1（注入任务取消后仍可能发键）、M2（两条延迟 Task 无人持有）、M3
  （`ShortcutTester` tap 未拆）、M5（缓存/崩溃报告无淘汰）、M6（日志含菜单标题）、M7
  （退出路径主线程写盘）、M8（预览态 loading 不复位）、L1–L5。
- 架构报告：H1（上帝对象）已由 R-3 拆成七个协作模块，引擎仍有 InputRouter 与生命周期；
  H2（菜单项执行两套实现）由 `RowRunner` 统一入口，但搜索面的入口差异保留；H3（设置字段清单
  写两遍）、H4（业务决策留在引擎）、M1–M10、L2–L9 未处理。此前只做了 L1（删 13 个死 L10n key）。
- HIG 报告：H2（VoiceOver）、H3（菜单栏 extras）、H4 的「先问保存路径再做数据」（本轮只
  修了成功反馈与失败提示）、M3 的黄星与权限状态色、M4、M5（Slider/Stepper 可访问名称）、
  M6 的键盘删除（只改了与实现不符的文案）、M7 的 Continue 禁用解释/Esc/详情截断、M8 的
  橙色失败文字对比度、M9–M11、L1（版本号双 `v`）、L2（裸 ✓/— 无替代文本）、L5/L6
  （硬编码英文）、L7（本轮只改了提示文案）。

## 待用户决策

- **排除的 App 列表是否要实现键盘删除**（HIG M6）：本轮只把「按 −」的文案改成「点击 −」，
  没有加 `onDeleteCommand`。要做的话是独立交互改动。
- **收藏开关的措辞方向**（HIG §6 `favoritesFilterable`）：报告建议的 “Include hidden
  favourites” 与当前实现（开关打开 = 收藏可被过滤隐藏）语义相反；本轮按实现改为
  “Let filters hide favorites / 允许搜索和过滤隐藏收藏”。若想反转行为，需要先改
  `FavoritesPolicy`。
- **术语与句式统一**：对象本体已定为「菜单项 / menu item」（提交 `05c775f`），
  「行 / row」只保留给布局；执行/运行/Run、面板/窗口/Panel 等纯风格项仍未统一。

## 不要动的地方

以下实现被审查报告判定为「看着危险但其实没问题」或「不建议改」，本轮没有碰，后续也不要
顺手重构：

- 并发报告 §「看着危险但其实没问题」1–12：`CatalogLoader.Reply` 的 resume-once、`InputMailbox`
  丢弃策略、`KeyboardMonitor` 的专用 tap 线程、`ShortcutTester` 的 `.listenOnly`、面板关闭
  后的 press guard、`Diag` 的锁盒、`RingBuffer`、`ConflictDetector` 分桶、搜索语料缓存、
  `ResolvedAXElement` 隔离、崩溃信号处理、`MainActor.assumeIsolated` 的回调前提。
- 架构报告 §「不建议改的地方」1–10：`KANAME_PREVIEW` 后门与 `beginPreview()`、`Diag` 静态
  外观、`CatalogLoader` 的 `@unchecked Sendable` + 双队列 + 信号量、`KeyboardMonitor` 的 tap
  时序与看门狗、`enterNextLevel`/`descend` 不合并、`triggerMode`/`LegacyKeys`、双层菜单缓存、
  `Core/Pure` 依赖 `CoreGraphics`、`EngineState` 单一 ObservableObject、两个 HUD 窗口各自建
  `NSWindow`。
- HIG 报告 §「建议但先别动」1–8（已并入上面的下一步，不单改）。
