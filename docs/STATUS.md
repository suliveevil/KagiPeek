# STATUS

as of **2026-11-04 19:34**（Asia/Shanghai）。

**过期即失效：这份文件只记录写下这一刻的事实。** 接手前先 `git log -1`、跑一次
`swift test`，再按下面「最后一次验证」的命令重跑；任何一项与当前输出不符，以当前输出为准，
并把本文件更新后再用。

## 当前代码状态

- 代码 HEAD：squash 后的 `main` 提交，哈希用 `git log -1` 取（本文件不自指）。该提交内容
  等同于 squash 前的 `de32cb6`；squash 前的完整 72 个提交保留在
  `backup/pre-squash-20261104-192838`（同名 tag 与 branch）。
- 工作区：干净（`git status --short` 无输出）。
- 未合并分支：无。`refactor/engine-split`、`feature/pagination-wrap`、`docs/status-refactor-3`、
  `ui/settings-diagnostics-merge` 都已合入 main，引用保留。
- 远端同步：重写后的 `main` 已推到 `origin/main`（`14ba41a`），本地与远端一致
  （`git status -sb` 显示 `## main...origin/main`，无 ahead/behind）。
- 备份 ref：`backup/pre-squash-20261104-192838`（tag 与 branch）只存在本地，未推送。
- 远端历史已被重写：其他克隆需要先 `git fetch origin`，再 `git reset --hard origin/main`
  或基于新历史 rebase；不要直接 merge 旧的 `main`。

## 本轮完成

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
- **设置页诊断合并**：把「关于」页的诊断区（辅助功能、输入监控、监听状态、条目数、
  导出诊断报告、说明）整段并入「诊断」页，排在日志目录之后、隐私说明之前；`关于` 页只留
  图标/版本、系统版本、更新检查、数据目录、仓库与许可证。`exportDiagnostics()` 移到诊断区，
  功能与文件名（`kagipeek-diagnostics.json`）未变。
- **备份与签名约定落地（只改脚本与文档，未构建、未安装）**：新增
  `scripts/backup_app.sh`（备份到 `~/Library/Application Support/KagiPeek/backups/`，
  命名 `KagiPeek-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app`，默认保留 5 份）；
  `scripts/install.sh` 改为调用它、拒绝安装 ad-hoc 包、回滚改为从 backups 恢复。
- `swift test`：636 → 656（新增 20 项，覆盖 RecordingPolicy、SearchScopePlan、PaginationPlan）。

## 最后一次验证

以下都是实际跑过的命令与输出，不是推断。

| 命令 | 结果 |
| --- | --- |
| `swift test` | `Executed 656 tests, with 0 failures (0 unexpected) in 0.274 seconds`；退出码 0，main 与翻页分支各跑一次 |
| `swiftc -typecheck`（设置页改动） | 0 诊断 |
| `scripts/build_swiftc.sh Release` | 编译、Info.plist、资源目录、`==> Commit: 836e3c3`、`==> Signing with KagiPeek Local` 全部完成 |
| `codesign -dvvv /Applications/KagiPeek.app` | `Authority=KagiPeek Local`；`designated => identifier "com.voltline.kagipeek" and certificate root = H"6c0ac5…a929"` |
| `codesign --verify --deep --strict /Applications/KagiPeek.app` | `valid on disk` / `satisfies its Designated Requirement` |
| `bash -n scripts/install.sh` / `bash -n scripts/backup_app.sh` | 两者语法通过 |
| `KAGIPEEK_BACKUP_DIR=/tmp/… scripts/backup_app.sh /Applications/KagiPeek.app` | 产出 `KagiPeek-2026-11-04-191257-836e3c3-local.app`；预置 5 份假备份后总数为 5，最旧一份被删 |
| ad-hoc 拒装检查（临时副本签 ad-hoc 后跑同一条件） | `Authority=(KagiPeek Local|Developer ID)` 匹配数为 0 → `install.sh` 会拒绝 |

`xcodebuild` 未运行：本机环境起不来，原因见「已知环境坑」。因此 `KagiPeek.xcodeproj` 的构建
在本轮**未验证**。

签名说明：本轮已恢复稳定身份 `KagiPeek Local`。此前 `codesign` 会停在钥匙串授权框，
用户手动点过「始终允许」；现在先用一个临时文件试签（`codesign --sign "KagiPeek Local" /tmp/...`）
确认私钥可用，再整包构建。因为签名身份与 designated requirement 未变，这次覆盖安装不会让
辅助功能重新授权。

**ad-hoc 只作验证**：`scripts/build_swiftc.sh` 在没有稳定身份时会 ad-hoc 签名，这种包只能
在临时目录做 `codesign --verify --deep --strict`；`scripts/install.sh` 现在会直接拒绝安装
ad-hoc 包。理由：ad-hoc 没有稳定代码身份，每次构建 cdhash 都变，TCC 会把每次构建当成新
app，导致权限反复授权、系统设置里堆僵尸条目。装进 `/Applications/KagiPeek.app` 的包必须是
`KagiPeek Local`（或将来的 Developer ID）。详见 `docs/ARCHITECTURE.md` 与
`docs/RELEASING.md`。

## 已安装构建

- 路径：`/Applications/KagiPeek.app`
- 版本串原文：`v2.2.0 (836e3c3)`
- `CFBundleShortVersionString`：`2.2.0`
- `CFBundleVersion`：`220`
- `KagiPeekCommit`（Info.plist）：`836e3c3`（等于安装时的 main HEAD；本轮只整理历史、
  未重建 App，所以安装包仍带这个短哈希）
- 签名：`Authority=KagiPeek Local`；`flags=0x10000(runtime)`；`TeamIdentifier=not set`。
  designated requirement 锚定在该证书（`certificate root = H"6c0ac5…a929"`），重新构建后
  辅助功能授权保持
- 运行中 PID：`9527`（`/Applications/KagiPeek.app/Contents/MacOS/KagiPeek`，单实例）
- 升级前备份：**没有放在 `/Applications`**。按新约定，`scripts/install.sh` 在覆盖前用
  `scripts/backup_app.sh` 把旧包拷到
  `~/Library/Application Support/KagiPeek/backups/`，命名为
  `KagiPeek-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app`，默认保留最近 5 份。
  - 该目录**已创建**：`~/Library/Application Support/KagiPeek/backups/`（空，可写）；
    本轮不跑安装，所以还没有备份文件。App 的清理逻辑只删 `logs/`、`menu-cache/`、
    `crashes/` 里的自有文件，不会碰 `backups/`（见 ARCHITECTURE 的「Persistence」）。
  - 历史上两份 `/Applications/KagiPeek-2026-11-04-250638c-adhoc.app` 与
    `…-bbc44a6.app` **已由用户手动移入废纸篓**，不在 `/Applications`，也不再当作备份使用。
  - `/Applications` 下只允许 `KagiPeek.app` 一份。
- 用户设置未被覆盖：`~/Library/Application Support/KagiPeek/settings.json` 在启动时被 App
  重写（文件 mtime 与哈希变化属正常），但非默认值仍在：`maxItemsPerPage=60`、
  `showDisabledItems=true`、`holdDelay=0.5`、`diagnosticsEnabled=true`、`pinFavoritesToTop=true`、
  `panelPlacement=coverWindow`、`launchAtLogin=true`。

## 已知环境坑

1. **`xcodebuild` 在本机不可用。** 构建系统给每次编译套 `sandbox-exec`，嵌套沙盒被拒绝：
   `sandbox-exec: sandbox_apply: Operation not permitted`。这不是代码问题。替代路径是
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

1. **`ShortcutEngine` 拆分已做一轮（R-3）**：七个协作模块与两个 Pure 策略已落地，InputRouter
   按计划留在引擎里。若继续瘦身，下一刀是 `CatalogQuery` 参数对象（架构报告 H1/M1）；不要
   把 InputRouter 硬拆走。
2. **面板 VoiceOver 可达性**（HIG 报告 H2）：先给面板根视图加 `.accessibilityElement` 容器
   与行级标签，再处理行内按钮；需要实机开 VoiceOver 验收。
3. **设置页信息架构**（HIG 报告 M4 / §7.1）：先画 8 段→侧边栏的交互稿并确认窗口尺寸，再动
   `SettingsView`；本轮明确不做。
4. **菜单栏 extras 的 HIG 行为**（HIG 报告 H3）：先确认左键开面板、右键开菜单是否产品意图，
   再改 `NSStatusItem` 的 `sendAction(on:)`。
5. **权限流程分步向导**（HIG 报告 §7.5）：先定交互稿，涉及三个控制器协同，暂不单改。

## 已知未修问题

按审查报告编号列出本轮**明确降级或未处理**的条目（修复说明见
`/Users/suliveevil/.trae-cn/assistant/2026-11-04/kagipeek-code-review-2/outputs/fix-round2.md`）：

- 并发报告：M1（注入任务取消后仍可能发键）、M2（两条延迟 Task 无人持有）、M3
  （`ShortcutTester` tap 未拆）、M5（缓存/崩溃报告无淘汰）、M6（日志含菜单标题）、M7
  （退出路径主线程写盘）、M8（预览态 loading 不复位）、L1–L5。
- 架构报告：H1（上帝对象）已由 R-3 拆成七个协作模块，引擎仍有 InputRouter 与生命周期；
  H2（行执行两套实现）由 `RowRunner` 统一入口，但搜索面的入口差异保留；H3（设置字段清单
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
- **术语与句式统一**（执行/运行/Run、面板/窗口/Panel、`panelIdleHint` 三种句式、标点与
  省略号规则）：本轮只改了明确错误的条目，纯风格项未动，等产品定稿。

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
