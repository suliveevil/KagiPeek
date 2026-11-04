# STATUS

as of **2026-11-04 23:03**（Asia/Shanghai）。

**过期即失效：这份文件只记录写下这一刻的事实。** 接手前先 `git log -1`、跑一次
`swift test`，再按下面「最后一次验证」的命令重跑；任何一项与当前输出不符，以当前输出为准，
并把本文件更新后再用。

## 当前代码状态

- 代码 HEAD：`1c1eee5`（`test(placement): 锁定全屏时 visibleFrame 等于整屏的边界`），其上还有
  一条未提交的「前台 app 切换后面板首帧覆盖」修复。
- 工作区：干净（提交前只剩本文件）。设置页改动在 `d4321ea`，签名钥匙串迁移在 `a0b1401`。
- 未合并分支：无，当前在 `main`。
- 远端同步：`origin/main` 停在 `8549e42`；本地 `main` 未推送（用户未要求 push）。
- **squash / push 未执行**：用户明确说 squash/push 仍待确认，本轮只改工作区，未建 tag、
  未 reset、未强推。旧历史保留在本地 `backup/pre-squash-20261104-192838`。

## 本轮完成

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
- **签名密钥迁到独立钥匙串**（`a0b1401`）：新增 `~/Library/Keychains/kagipeek-signing.keychain-db`，
  口令 `~/Library/Application Support/KagiPeek/signing/keychain-pass`（600，目录 700）；
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
  不重建、不闪。面板路由、按键语义未变（仍是 ←/→ 与 `;`/`'`）。
- **设置页诊断合并**：把「关于」页的诊断区（辅助功能、输入监控、监听状态、菜单项数、
  导出诊断报告、说明）整段并入「诊断」页，排在日志目录之后、隐私说明之前；`关于` 页只留
  图标/版本、系统版本、更新检查、数据目录、仓库与许可证。`exportDiagnostics()` 移到诊断区，
  功能与文件名（`kagipeek-diagnostics.json`）未变。
- **备份与签名约定落地（只改脚本与文档，未构建、未安装）**：新增
  `scripts/backup_app.sh`（备份到 `~/Library/Application Support/KagiPeek/backups/`，
  命名 `KagiPeek-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app`，默认保留 5 份）；
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
| `scripts/build_swiftc.sh Release`（迁移后） | `==> Signing with KagiPeek Local`；无钥匙串弹窗；`codesign --verify` 通过 |
| 临时文件试签 `codesign --sign ... --keychain <KC>` | 无弹窗、无 `errSecInternalComponent`；`Authority=KagiPeek Local` |
| `security find-identity -v -p codesigning` | 仅 `6C0AC543654BC3CBA8EDB95F8F16E1647905A929 "KagiPeek Local"` |
| `codesign -d -r-`（安装包 vs 上一份备份） | 两行都是 `certificate root = H"6c0ac5…a929"`，TCC designated requirement 未变 |
| `codesign -dvvv /Applications/KagiPeek.app` | `Authority=KagiPeek Local`；`flags=0x10000(runtime)` |
| `codesign --verify --deep --strict /Applications/KagiPeek.app` | `valid on disk` / `satisfies its Designated Requirement` |
| `KagiPeekCommit` / 版本串 | `1c1eee5-dirty` / `v2.2.0 (1c1eee5-dirty)` |
| `pgrep -x KagiPeek` | `12554`（单实例） |
| `scripts/install.sh` | 成功；`xcodebuild` BUILD SUCCEEDED；已装包替换前备份 `KagiPeek-2026-11-04-230313-3e4532a-dirty-local.app`，按命名保留最近 5 份 |
| 辅助功能未被重问的证据 | 近 15 分钟 `tccd` 无 `voltline` 记录；`certificate root = H"6c0ac5…a929"` 与旧包一致 |

本次安装标记为 `1c1eee5-dirty`：面板首帧覆盖的修复与这份 STATUS 的更新在构建时都还没提交。
签名走独立钥匙串，构建与安装过程没有出现钥匙串授权弹窗。

签名说明：密钥已从登录钥匙串迁到独立钥匙串。`Always Allow` 在 CLI 签名里不持久，所以之前
的授权框会反复出现；新钥匙串用 `-A` 导入并设置 partition list，`codesign` 不再弹窗。证书
与 designated requirement 未变，覆盖安装不会让辅助功能重新授权（DR 根哈希对比见上表）。

**ad-hoc 只作验证**：`scripts/build_swiftc.sh` 在没有稳定身份时会 ad-hoc 签名，这种包只能
在临时目录做 `codesign --verify --deep --strict`；`scripts/install.sh` 现在会直接拒绝安装
ad-hoc 包。理由：ad-hoc 没有稳定代码身份，每次构建 cdhash 都变，TCC 会把每次构建当成新
app，导致权限反复授权、系统设置里堆僵尸条目。装进 `/Applications/KagiPeek.app` 的包必须是
`KagiPeek Local`（或将来的 Developer ID）。详见 `docs/ARCHITECTURE.md` 与
`docs/RELEASING.md`。

## 已安装构建

- 路径：`/Applications/KagiPeek.app`
- 版本串原文：`v2.2.0 (1c1eee5-dirty)`
- `CFBundleShortVersionString`：`2.2.0`
- `CFBundleVersion`：`220`
- `KagiPeekCommit`（Info.plist）：`1c1eee5-dirty`（安装时的 main HEAD + 尚未提交的首帧修复）
- 签名：`Authority=KagiPeek Local`；`flags=0x10000(runtime)`；`TeamIdentifier=not set`。
  designated requirement 锚定在该证书（`certificate root = H"6c0ac5…a929"`），重新构建后
  辅助功能授权保持；私钥只在独立钥匙串中
- 运行中 PID：`12554`（`pgrep -x KagiPeek`，单实例）
- 升级前备份：`~/Library/Application Support/KagiPeek/backups/` 下按命名
  `KagiPeek-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app` 保留最近 5 份；
  本次为 `KagiPeek-2026-11-04-230313-3e4532a-dirty-local.app`。
  - `/Applications` 下只有 `KagiPeek.app` 一份，历史 ad-hoc 副本已在废纸篓。
- 用户设置未被覆盖：`~/Library/Application Support/KagiPeek/settings.json` 仍在，
  非默认值保留（`maxItemsPerPage=60`、`showDisabledItems=true`、`holdDelay=0.5`、
  `maxDescriptionLength=80`、`columnCount=3`、`panelPlacement=coverWindow`、
  `launchAtLogin=true`、`keyStyle=symbols`、`panelOrder=byModifier`）；
  `runRowKey`/`copyRowKey` 保持用户当前选择，删除后落盘为 `null`。schema 仍为 7。

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
5. **`KagiPeek Local` 私钥的钥匙串授权无法脚本化。** `codesign` 首次使用私钥会弹
   SecurityAgent 对话框（始终允许/拒绝/允许），该弹框受系统保护，AppleScript 的 `click`
   返回成功但不生效，`codesign` 会一直停在 0% CPU。2026-11-04 已由用户手动点「始终允许」，
   之后试签可正常返回；换机或重建钥匙串后仍会遇到。构建前可先试签一个临时文件确认。

## 未完成 / 下一步

最多 5 条，每条从「第一动作」开始：

1. **第二轮 squash 待确认**：用户给的起点 `aa23786` 不是 HEAD（详见「当前代码状态」）。
   确认范围后按 `270febe..HEAD` 建安全网、`reset --soft`、单提交、`--force-with-lease`
   推送；在确认前不要执行。术语统一与 squash 必须分开提交。
2. **`ShortcutEngine` 拆分已做一轮（R-3）**：七个协作模块与两个 Pure 策略已落地，InputRouter
   按计划留在引擎里。若继续瘦身，下一刀是 `CatalogQuery` 参数对象（架构报告 H1/M1）；不要
   把 InputRouter 硬拆走。
3. **面板 VoiceOver 可达性**（HIG 报告 H2）：先给面板根视图加 `.accessibilityElement` 容器
   与行级标签，再处理行内按钮；需要实机开 VoiceOver 验收。
4. **设置页信息架构**（HIG 报告 M4 / §7.1）：先画 8 段→侧边栏的交互稿并确认窗口尺寸，再动
   `SettingsView`；本轮明确不做。
5. **菜单栏 extras 的 HIG 行为**（HIG 报告 H3）：先确认左键开面板、右键开菜单是否产品意图，
   再改 `NSStatusItem` 的 `sendAction(on:)`。

## 已知未修问题

按审查报告编号列出本轮**明确降级或未处理**的条目（修复说明见
`/Users/suliveevil/.trae-cn/assistant/2026-11-04/kagipeek-code-review-2/outputs/fix-round2.md`）：

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
- 架构报告 §「不建议改的地方」1–10：`KAGIPEEK_PREVIEW` 后门与 `beginPreview()`、`Diag` 静态
  外观、`CatalogLoader` 的 `@unchecked Sendable` + 双队列 + 信号量、`KeyboardMonitor` 的 tap
  时序与看门狗、`enterNextLevel`/`descend` 不合并、`triggerMode`/`LegacyKeys`、双层菜单缓存、
  `Core/Pure` 依赖 `CoreGraphics`、`EngineState` 单一 ObservableObject、两个 HUD 窗口各自建
  `NSWindow`。
- HIG 报告 §「建议但先别动」1–8（已并入上面的下一步，不单改）。
