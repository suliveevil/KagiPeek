# KagiPeek v2.2 工程审查与修复记录

**日期**：2026-10-22
**审查对象**：`feat/v2.2` — `4549451`（功能提交）、`59ac99c`/`f4b2347`（测试修复）
**参与成员**：Cody（代码审查）、Archi（架构）、Rex（SRE）、Tessa（测试）、Docu（文档）
**本文件**：审查结论 + 本轮修复状态（每一项都对应一次实际改动，见末尾的提交）

---

## 📌 TL;DR

- 34 项发现：🔴 3 / 🟠 11 / 🟡 15 / 🟢 5。
- **本轮已修 31 项**，其中 3 项🔴 全部修掉并验证；2 项结构性重构按评审建议排到下一版本（`ShortcutEngine` 拆分、`Core/Pure` 去掉 `NSScreen` 依赖）；1 项（过期截图）已重拍。
- 验证：`swift test` 102 项通过；`xcodebuild` Debug/Release 零错误零告警（并已在 CI 打开 `SWIFT_TREAT_WARNINGS_AS_ERRORS`）；Release 已签名覆盖安装到 `/Applications`，自检显示前台 App 判定正确（不再把自己当目录来源）。

---

## 🎯 修复状态总表

# 编号沿用审查报告的原始编号；"状态"列指本轮改动。

| # | 严重度 | 问题 | 状态 | 落地位置 |
|---|--------|------|------|----------|
| 1 | 🔴 | `AppContextService.refresh()` 不过滤自身进程，激活后把自己当目录来源 | ✅ 已修 | `AppContextService.refresh` 早退 + `FrontmostApp.isSelf`；`CatalogLoader.load` 防御性拒绝；`frontmostChanged`/`reloadCatalog` 双保险 |
| 2 | 🔴 | `4549451` 删字段时漏改测试，`swift test` 编译失败；CI 不覆盖特性分支 | ✅ 已修 | `59ac99c` + `f4b2347`；CI `push.branches: ["**"]` |
| 3 | 🔴 | 文档三处承诺"从不合成按键"，与 `ShortcutInjector` 矛盾 | ✅ 已修 | `README`、`docs/ARCHITECTURE.md`、新增 `docs/PRIVACY.md`，如实写"只注入你要求的那一条组合键" |
| 4 | 🟠 | `allowSearchExecute` 只切 footer 文案；搜索面板没有 copy 路径，默认却写 `↵ copy` | ✅ 已删除 | 设置字段、`CodingKeys`、`decodeIfPresent`、设置界面、`.searchHint`/`.searchCopied` 全删；footer 改 `↵ run` |
| 5 | 🟠 | `SettingsStore` 全量覆盖写，两个写者 last-wins 丢改动 | ✅ 已修 | 单写者 + 350 ms 合并，写盘时读最新快照；`flush()` 挂到退出 |
| 6 | 🟠 | `rebuildPanel` 可能对旧 App 的 catalog 排序；新扫描只入队 | ✅ 已修 | `catalogGeneration` / `browserCatalogGeneration`，只允许最新请求发布 |
| 7 | 🟠 | 行键 if 链三份，"run 优先"只靠语句顺序 | ✅ 已修 | `Core/Pure/RowKeys.swift` 的 `RowKeyRouter`，三处共用 + 5 条测试 |
| 8 | 🟠 | 筛选态硬编码 `isHighlighted: false`，两条重建路径字段漂移 | ✅ 已修 | `PanelRowBuilder`（`isHighlighted`/`isDimmed`/`isSelectable` 变成显式参数）+ 4 条测试 |
| 9 | 🟠 | `install.sh` 非原子，`rm -rf` 后 `ditto` 失败会留下空目录 | ✅ 已修 | 先 `ditto` 到 `.new` → 验签 → `mv` 原子替换 → 保留 `.previous.app`，失败自动回滚 |
| 10 | 🟠 | `Core/Pure` 覆盖 ≈78%，整体 ≈19%，本轮新 API 零覆盖 | ✅ 明显改善 | 新增 `RowInteractionTests`（21 条），总计 **102 test**；`RowKeyRouter`/`ListSelection`/`PanelRowBuilder`/`HeaderLayout`/`SettingsMigrator` 全部进纯层 |
| 11 | 🟠 | 面板收窄语义三处注释与代码相反 | ✅ 已修 | `ShortcutEngine.activatePanel` 注释、`PanelHighlighter` 注释、`ARCHITECTURE.md` 全部改成"召唤态收窄 + 高亮" |
| 12 | 🟡 | `ShortcutEngine` 1500 行、职责过多 | ⏳ 部分 | 已抽出 `RowKeyRouter`/`ListSelection`/`PanelRowBuilder`/`HeaderLayout`/`PanelState`；`PanelSession` 级拆分按 ADR-002 排下一版本 |
| 13 | 🟡 | `Image(nsImage:).resizable()` 缺插值 | ✅ 已修 | `ContentView` 头部图标加 `.interpolation(.high)`（面板内两处原本已有） |
| 14 | 🟡 | `schemaVersion` 只写不读，无迁移锚点 | ✅ 已修 | `SettingsPayload` + `SettingsMigrator.isOutdated/migrate`；schema 升到 3；`usage.json` 独立版本 |
| 15 | 🟡 | `BrowserListModel` / `HeaderDensity` 住在 UI，无法测试 | ✅ 已修 | `ListSelection`、`HeaderLayout` 进 `Core/Pure`，`BrowserListModel` 变薄包装 |
| 16 | 🟡 | 全项目零日志，`try?` 静默失败 | ✅ 已修 | `AppLog`（scan/input/storage/ui 四类）+ 关键路径打点；About 增加"导出诊断…" |
| 17 | 🟡 | 5 张截图过期、README/FAQ 12 处事实冲突、发布说明过期 | ✅ 已修 | 6 张截图重拍（含 300 pt 窄面板与权限引导）；README/FAQ/ARCHITECTURE/v2.2.0.md 全量校正 |
| 18 | 🟡 | 死键/死分支：`searchCopied`、`browserExportDone`、二选一的搜索提示 | ✅ 已修 | 随 #4 一并删除；L10n 现 188 键 = 188 条，无缺失/孤儿/占位符不一致 |
| 19 | 🟢 | `eventSourceUserData` 每次新建（不可测） | ⚪ 不适用 | 代码中不存在该实现；未改动 |
| 20 | 🟢 | `MenuScanner.press` 无调用者 | ✅ 已标注 | 注释改为"预留：AX 原语，当前执行走回放"，并说明理由 |
| 21 | 🟢 | README "Triggers" 标签名、DMG 版本号 2.1.0 | ✅ 已修 | 统一 `Trigger`；`KagiPeek-2.2.0.dmg` |
| 22 | 🟢 | 2 条 `NSEvent: Sendable` 告警 + `activateIgnoringOtherApps` 弃用 | ✅ 已修 | `var handled` 模式改三个窗口控制器；全部改 `NSApp.activate()`；构建零告警 |
| 23 | 🟠 | `SurfacePanelController` 写死 `modifiers: [.control]`，吞掉 ⌃⌥P/⌃⌘P | ✅ 已修 | 传 `ModifierSet.from(flags:)` 真实修饰键；与浏览器窗口策略一致 |
| 24 | 🟡 | IME 守卫两份不等价，Quiz 零守卫 | ✅ 已修 | `UI/Design/TextComposition.isComposing(in:)` 唯一实现，三个 surface 共用 |
| 25 | 🟡 | 小键盘 Enter 别名三份副本，`matches` 与 `capturedIdentifiers` 无等价性测试 | ✅ 已修 | `KeyAliases.enterCodes(for:)` 双向别名 + 不变式测试 |
| 26 | 🟠 | repeat 事件不吞，按住行键重复触发 | ✅ 已修 | tap 对被吞键的 repeat 同样返回 nil；engine 对行键/和弦完成忽略 repeat，方向键仍可连续移动 |
| 27 | 🟠 | `SearchIndex.search` 每帧跑三次 | ✅ 已修 | `ContentView` 单次求值 + 按可见 id 列表 `onChange` 同步 |
| 28 | 🟡 | 全局 tap 对每个按键先解码字符 | ✅ 已修 | `updateDecodesKeyEvents` 懒解码；热键改用虚拟键码匹配 |
| 29 | 🟡 | `rebuildPanel` 每键全量重排 | ✅ 已修 | `orderedHits` 结果按 (prefix, sort, catalog, usage) 缓存 |
| 30 | 🟡 | `UsageStore` 每次执行主线程整文件写 | ✅ 已修 | 内存累加 + 1.2 s 防抖 + utility 队列写；退出 flush |
| 31 | 🟡 | `highlightedIDs(for:)` 丢弃入参重算 | ✅ 已修 | 用页面命中项计算，仅当页高亮 |
| 32 | 🟡 | 浏览器窗口 key monitor 永不释放 | ✅ 已修 | `close()`/`willClose` 移除，`show()` 重装 |
| 33 | 🟡 | 面板关闭后 `isFiltering`/`filterText` 残留 | ✅ 已修 | 非筛选重建路径显式复位 |
| 34 | 🟢 | ⌘⌫ 未捕获；`fdelete` 硬编码 | ✅ 已修 | 筛选态捕获 ⌫/⌦ 的 ⌘/⌥ 变体；`KeyToken.forwardDelete` 常量 |

---

## ✅ 本轮额外修掉的问题（审查未列出，改动中发现）

- **浏览器窗口"刷新"按钮必然刷错对象**：窗口为 key 时它调用前台 App 的重载，于是刷成 KagiPeek 自己。改为 `refreshBrowserCatalog()`，优先重扫正在浏览的 App。
- **`settings != oldValue` 短路**：设置写入不再因为视图重复赋值同样内容而落盘。
- **`build_release.sh` 版本号来源**：改为读构建产物的 `CFBundleShortVersionString` 并与 `MARKETING_VERSION` 交叉校验；空值或不等直接失败（避免 `KagiPeek-.dmg` 与 `v` 标签）。
- **DMG 自身签名/公证/装订**：之前只公证 `.app`，现在 `.dmg` 也签名、可公证并 `staple validate`，同时产出 `.sha256`。
- **`xcodebuild` 不可用时的构建通路**：新增 `scripts/build_swiftc.sh`（显式加载 SwiftUI 宏插件），`install.sh` 在 `xcodebuild` 失败时自动回退。

---

## ⚠️ 已知未做（有明确理由）

| 项 | 原因 |
|----|------|
| `ShortcutEngine` 的 `PanelSession`/`BrowserSession`/`WindowRouter` 拆分（#12） | 审查建议的渐进路径 S1–S4；一次性大改会把回归风险压进本次交付。已先完成其中收益最高的纯逻辑外抽。 |
| `Core/Pure` 去掉 `NSScreen` 依赖（`panelPageSize`） | 需要 `SurfacePanelController` 反向提供可用尺寸；与 S3 一同做。 |
| 覆盖率门禁从"报告"升级为"硬失败" | 本轮把 `Core/Pure` 拉到 ≈84%，但 AppKit 层仍无测试容器；硬门禁会在添加 UI 代码时误伤。CI 已输出覆盖率并在低于 70% 时告警。 |
| `docs/SETTINGS.md`、`docs/KEYBOARD.md`、`docs/COEXISTENCE.md` | 结论是"用户真实需要"排序靠后；本轮先交付 `TROUBLESHOOTING`/`PRIVACY`/`CONTRIBUTING`/`RELEASING` 四篇。 |

---

## 🧪 验证记录

| 检查 | 结果 |
|------|------|
| `swift test --disable-sandbox` | **102 tests, 0 failures** |
| `xcodebuild -configuration Debug` | BUILD SUCCEEDED，零 error / 零 warning（`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 已进 CI） |
| `xcodebuild -configuration Release`（`build_release.sh`） | BUILD SUCCEEDED，签名 "KagiPeek Local"，`satisfies its Designated Requirement` |
| 安装 | 原子替换 `/Applications/KagiPeek.app`，版本 2.2.0，`codesign --verify --strict` 通过，保留 `KagiPeek.previous.app` |
| 自检 | `KAGIPEEK_SELFTEST=1`：`frontmost = WorkBuddy`（不是 KagiPeek）、`catalogSize = 23`、`schemaVersion = 3`、`hasAccessibility = true` |
| L10n | 188 keys = 188 entries，无缺失/孤儿，占位符一致 |
| 截图 | 6 张重拍（面板 1176×550、窄面板 300×620、搜索、设置、浏览器、权限引导） |

> 本报告由工程保障团队协作产出，修复与验证由主线程执行；关键结论请由人类工程负责人复核。
