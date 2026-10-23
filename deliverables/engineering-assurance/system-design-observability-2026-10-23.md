# KagiPeek 可观测性能力建设 · 系统设计与实施报告

**日期**：2026-10-23
**工作流**：工作流 2（系统设计）+ 实施 + 独立验证
**参与成员**：Archi（架构师）、Cody（代码审查师）、Tessa（测试专家）、Zhen（工程督导，编排与实施接力）

---

## 📌 TL;DR（执行摘要，3-5 行）

- 整体结论：可观测性能力已完整落地并通过运行时验证——日志分级落盘、崩溃/信号捕获、失效原因追踪、脱敏导出、排查手册五条需求全部满足。
- 技术路线：否决"纯 os.Logger + OSLogStore 导出"与"三方 SDK"，采用**双轨自建**（os.Logger 零改动 + `Diag` 文件门面），现有 44 处日志调用点一处未改。
- 严重度分布：🔴严重 0 项 / 🟠高 0 项 / 🟡中 1 项（启动耗时无改造前基线）/ 🟢低 3 项
- 阻塞 / 非阻塞：无阻塞项；独立复核提出的 3 项必修已全部修复并复验；`swift test` 326 通过（新增 48），Debug/Release 均编译通过
- 实测证据：SIGSEGV → 分片 → 重启补全报告 → 日志留痕，全链路已跑通；提交 `6f5e42d`

---

## 🎯 核心结论卡片

| 项目 | 内容 |
|------|------|
| 整体评级 | 🟢 通过 |
| 阻塞项数量 | 0 |
| 关键行动项 | 5 条 |
| 建议下一步 | 合入后在真实用户环境中跑一周，用 `[scan] cache-miss` 与 `[inject]` 的分布校准默认级别 |

---

## 需求与目标

用户诉求：**用户反馈问题时，能快速判定"是应用自身 Bug"还是"外部环境/系统限制/权限/网络/三方不可用"**，且实现轻量、不破坏现有架构。

| # | 需求 | 落点 |
|---|------|------|
| 1 | 分级日志 + 覆盖启动/业务节点/网络/堆栈 + 按日滚动 + 限额 | `Diag`（V/D/I/W/E）+ `FileLogStore`（按日切、7 天、20MB、单日 5MB 降级） |
| 2 | 崩溃与异常报告（时间/版本/系统/机型/前后台/最近操作） | `CrashReporter`（NSException + 6 个致命信号 + 哨兵 + 下次启动补全） |
| 3 | 功能不生效可追踪 | 15 个静默分支全部补日志（权限、secure input、tap、扫描、缓存、注入、网络） |
| 4 | 导出与隐私 + 采集开关 | 设置页 Diagnostics tab + `DiagnosticsExporter`（ditto 打包）+ `Sanitizer`（7 条正则）+ 两个开关 |
| 5 | 排查支持 | `docs/TROUBLESHOOTING.md` 新增「诊断存放位置」与「关键字 → 问题类型」对照表 |

---

## 高层设计

```
调用点（引擎 / 事件 tap / 扫描 / 网络 / 存储）
        │  Diag.info(.tap, "…")   ← @autoclosure，先过级别闸门再求值
        ├─────────────► os.Logger（scan/input/storage/ui，Console.app 与 log show 全量）
        └─────────────► FileLogStore（串行队列、32 行/200ms 批量、按日切、限额裁剪）
                              │ Sanitizer.prepare（控制字符 + 家目录 ~ + 7 条脱敏）
                              ▼
             ~/Library/Application Support/KagiPeek/logs/kagipeek-YYYY-MM-DD.log

崩溃路径：AppDelegate.init 首行 → CrashReporter.install()
   ├─ NSException：NSSetUncaughtExceptionHandler → 完整 JSON（含栈 + 最近 30 动作）
   └─ 信号 SIGABRT/SEGV/BUS/ILL/FPE/TRAP：预开 fd + 预序列化上下文 → handler 只 write()
        「ver/build/os/model/pid + sig + epoch」→ re-raise（系统崩溃报告保留符号化栈）
   哨兵 logs/session.active：启动写、正常退出先删；下次启动区分「崩溃」与「强退/掉电」
```

模块划分：**纯逻辑**（`Core/Pure`，进 SPM 目标，48 个单测覆盖）与 **IO/门面**（`Core/Services`，仅 App 目标）严格分离，沿用项目既有的 `MenuCachePolicy`（纯）/`MenuScanCache`（IO）先例。

---

## 关键决策记录（ADR）

### ADR-1 日志后端：否掉 os.Logger-only 与三方 SDK

| 路线 | 结论 | 依据 |
|------|------|------|
| A 纯 os.Logger + OSLogStore | 否决 | `OSLogStore(scope: .currentProcessIdentifier)` 只覆盖**本次启动**（Apple DTS 确认），崩溃重启后拿不到崩溃前日志；debug 级不落盘；无法自主控制滚动与保留天数 |
| C 三方 SDK（Lumberjack + PLCrashReporter） | 否决 | 依赖体积与轻量定位冲突；同样要求替换自有 Logger；PLCrashReporter 的符号化收益在"用户手动导出"场景很小 |
| **B2 双轨自建** | **采纳** | 现有 44 处 `AppLog.*` 调用点**零改动**，纯增量、可逐模块回滚；`Diag` 的方法形状刻意与 `Logger` 对齐，将来若要全量统一双写不留障碍 |

代价：理论覆盖缺口（少数既有 os.Logger 行未同步到文件）。兜底：Cody 的 15 条静默分支清单逐条补埋点，失败类分支全部进文件日志。

### ADR-2 文件按本地日历日滚动

初版按 UTC 命名，UTC+8 用户会在早上 08:00 看到"换日"，与直觉相悖。改为 `TimeZone.current` 并保留时区注入参数（测试固定 UTC），保留天数按整日计算，未来时间戳的文件不判过期但计入总量。

### ADR-3 信号处理器只做 async-signal-safe 操作

handler 内禁止 Swift 分配/String/锁/os.Logger。实现：安装期预开 fd（`FileHandle` 取 descriptor，避开 Swift 变参 `open` 的静默失败）、预序列化上下文 C 字符串、预编码每个信号的 `sig=N\ntime=` 前缀；handler 只 `write()` + 手写十进制秒数（预分配栈外缓冲）+ `signal(SIG_DFL); raise()`。

### ADR-4 分片时序：先补全旧报告，再武装本次

实测踩到的真实缺陷：`install()` 先创建分片，`beginSession()` 的补全逻辑扫到它、解析失败后删除文件（fd 悬空在已 unlink 的 inode 上），导致崩溃报告永远为空。修正为 `install()` 只装 handler，分片在补全扫描**之后**创建。

### ADR-5 分片格式一行一键值

`os=Version 15.1 (Build 24B83)` 含空格，空格分隔的格式会被切碎。改为一行一键值，解析按行 split。

### ADR-6 `ActionRecord.ts` 用 epoch 秒而非 `Date`

首版用 `Date`，在崩溃报告里被默认策略编码成 2001 基准相对秒（`814440109`），读者无法解读。改为 `TimeInterval`，镜像、报告、grep 三处语义一致。

---

## 可运维性（排查支持）

**日志位置**：`~/Library/Application Support/KagiPeek/logs/`，设置页 Diagnostics tab 可一键打开。
**崩溃报告**：`~/Library/Application Support/KagiPeek/crash/kagipeek-crash-<date>-<kind>.json`。
**无 GUI 导出**：`KAGIPEEK_EXPORT_DIAGNOSTICS=/tmp/kagipeek.zip /Applications/KagiPeek.app/Contents/MacOS/KagiPeek`。

关键日志关键字（`[start] [perm] [tap] [scan] [inject] [net] [run] [settings] [crash] [exit] [export]`）与问题类型的完整对照表见 `docs/TROUBLESHOOTING.md`。

| 症状 | 关键字 | 判定 |
|------|--------|------|
| 完全没反应 | `[tap]` | `installed` vs `failed`；`disabled by the system` = 系统收回了 tap 并已重新武装 |
| 密码框后全失效 | `[perm] secure input` | 系统限制，非 Bug |
| 昨天还好用 | `[perm] accessibility` | 授权被撤销（重装换签名最常见） |
| 列表空/内置 | `[scan]` | `state=noMenus` / `permissionDenied` / `menu-bar attribute missing` / `truncated` |
| 每次都慢 | `[scan] cache-miss` | `control/fingerprint/entryFingerprint/expired/decode` |
| 某行点了没反应 | `[inject]` | `ax-press failed err=<AXError>` + 是否还有和弦可回放 |
| 检查更新失败 | `[net]` | `reason=error/parse/no-tag/url` + HTTP 状态 + 耗时 |
| App 自己消失 | `[exit]` + `[crash]` | `clean exit` / `ended unexpectedly (crash report: …)` / `no crash report: killed, force quit or power loss` |

---

## 测试策略

- **纯逻辑单测（48 例，全绿）**：`Sanitizer` 13（含幂等、家目录归一化、短十六进制不误伤）、`LogRotationPolicy` 11（跨日、保留边界、未来时间戳、超限按最旧删、恰好等于限额、当天文件永不删）、`RingBuffer` 5、`LogLevelFilter` 7、`SentinelState` 5、`CrashLogFormatter` 7（含分片解析与拒绝损坏分片）。
- **集成/手动（已实测）**：真实 SIGSEGV 链路、正常退出清哨兵、headless 导出、设置页 Diagnostics tab 渲染（截图确认）。
- 全量回归：`swift test` 326 例通过（0 失败）。
- 编译：`./scripts/build_swiftc.sh Debug` 与 `Release` 均通过。

---

## 独立复核与修复（Cody · 第二轮，新眼睛）

复核结论「需修复后提交」，列出 3 项必修 + 8 项建议。**全部 11 项已处理**，修复后复验通过。

| # | 严重度 | 问题 | 处置 |
|---|--------|------|------|
| 1 | 必修 | 导出在 SwiftUI 按钮回调（主线程）里同步 `waitUntilExit()`，目标在无响应卷上会冻住窗口 | 导出移到全局队列；`ditto` 改 `terminationHandler` + 20s 看门狗，超时 `terminate()` 并报错 |
| 2 | 必修 | 崩溃 JSON 的 `exceptionReason` 未过 Sanitizer，与「写入前一律脱敏」的声明矛盾 | `handleException` 里对 reason 走 `Sanitizer.prepare`（含家目录归一化） |
| 3 | 必修 | 信号 handler 忽略 `write()` 返回值，短写 → 分片损坏 → 真实崩溃被报成「无崩溃报告」 | 新增 `writeAll()` 循环写剩余部分，遇 `EINTR` 重试；失败才放弃 |
| 4 | 建议 | `signalEntryForHandler` 用 Array+闭包查表，不在 async-signal-safe 清单内 | 改为 6 个静态变量 + `switch`，可证明无分配 |
| 5 | 建议 | handler `close(fd)` 后未复位描述符，重入时可能误关复用的 fd | close 后置 `partialDescriptor = -1` |
| 6 | 建议 | 分片在哨兵之前创建，微秒级窗口内会丢叙事 | 顺序改为哨兵 → 分片 |
| 7 | 建议 | `SentinelState` 是死代码（生产代码从未调用），5 个测试在为无人调用的函数背书 | 真正接进 `reportPreviousSessionIfNeeded` 与 `markCleanExit` |
| 8 | 建议 | `Diag.mirror` 未脱敏写统一日志，与 UI 文案不符 | 文案收窄为「写入日志文件前脱敏」，并在 `mirror` 注释说明统一日志有意保留原文（开发期可检索、仅本机可读） |
| 9 | 建议 | `\(app.bundleID)` 对 Optional 插值，日志写成 `Optional("…")` 且编译告警 | 改 `app.bundleID ?? "?"`，告警清零 |
| 10 | 建议 | `openFile` 失败后每条日志都重试打开，磁盘故障时放大 IO | 失败后 60s 内不再重试 |
| 11 | 建议 | 导出包混入 `last-actions.json`，文档未声明 | 加入排除清单（内容已并入崩溃报告） |

复核同时确认的通过项：tap 线程无同步磁盘 IO、开关关闭时不求值字符串、`ActionRecorder` 结构上不含内容字段、`FileLogStore` 双层防护不删正在写的文件、`completePartialReports` 先于 `prepareSignalFragment` 的承重顺序、`cleanupPartial` 走 FileHandle 而非裸 `close`。

---

## 文档结构

- `docs/observability-architecture.md` — 架构决策全文（Archi）
- `docs/TROUBLESHOOTING.md` — 新增「诊断存放位置」「关键字 → 问题类型」两节，并更新导出入口描述
- 本报告 — 设计、实施、验证与风险

---

## 风险与权衡

| 风险 | 等级 | 处理 |
|------|------|------|
| 双轨覆盖缺口（既有 os.Logger 行未同步文件） | 🟡 中 | 15 条静默分支已补；失败路径恒落盘；缺口可纯增量补 |
| 启动耗时无量化基线 | 🟡 中 | 新增启动工作为微秒级 syscall + 一次目录扫描；实测 engine.start 60–92ms（Debug），未取改造前基线 |
| xcodebuild 在 SwiftUI 宏插件上的环境性失败 | 🟡 中 | 与代码无关（同源文件经 swiftc + 显式宏插件编译通过）；`scripts/install.sh` 已有回退 |
| signal handler 无栈 | 🟢 低 | 依赖 re-raise 后的系统崩溃报告提供符号化栈；我们保「何时崩于何信号 + 此前 30 动作 + 当日日志尾」 |
| Sanitizer 误伤长哈希 | 🟢 低 | 摘要行本就不放原始哈希；误伤只损失细节 |
| 掉电/内核 panic 下哨兵"误报"意外退出 | 🟢 低 | 措辞为事实陈述（"未正常退出"），W 级，不惊扰用户 |

---

## ✅ 行动清单

| # | 行动 | 负责角色 | 紧急度 | 预期完成 |
|---|------|---------|--------|---------|
| 1 | 合入本批改动并在真实使用中观察一周，收集 `[scan] cache-miss` / `[inject]` 分布 | 维护者 | P0 | 1 周内 |
| 2 | 用同一台机器在改造前后各测一次冷启动耗时，补齐性能基线 | 维护者 | P1 | 下次发版前 |
| 3 | 为 FileLogStore 的滚动/裁剪补一个注入时钟的集成冒烟测试（现仅纯策略单测） | Tessa | P2 | 下个迭代 |
| 4 | 若后续要统一双写，按文件机械替换 44 处 `AppLog.*`（`Diag` API 形状已对齐） | 维护者 | P3 | 按需 |
| 5 | 观察日志体积一周后，按实际量调整 7 天/20MB/5MB 三个默认值 | 维护者 | P3 | 1 周内 |

---

## ⚠️ 待完善 / 已知局限

- 启动耗时未取改造前基线；新增启动工作为微秒级 syscall + 一次目录扫描，实测 engine.start 60–92ms（Debug 构建）。
- 崩溃时最多丢 32 行日志（批量窗口），所以报告里的 `logTail` 末尾可能缺最后几十行——信号路径无法 flush，这是硬约束。
- 导出 UI 的 `NSSavePanel` 交互分支需人工点验；headless 分支（`KAGIPEEK_EXPORT_DIAGNOSTICS`）与打包内容已实测。
- FileLogStore 的 IO 半层未进 SPM 测试目标（依赖 App 层类型），滚动/裁剪目前由纯策略单测覆盖。
- 崩溃报告不含符号化栈（信号路径）；符号化依赖系统 `/Library/Logs/DiagnosticReports`。
- 未接入 MetricKit / 挂起 watchdog（明确列为非目标）。
- `KAGIPEEK_PREVIEW` 会改写 `settings.json`（既有行为，验证时已备份恢复）。

---

## 📚 数据来源 & 成员产出索引

- **Archi（架构师）**：`docs/observability-architecture.md` — 三路线取舍、模块划分、崩溃捕获设计、脱敏清单、性能预算
- **Cody（代码审查师）**：可观测性就绪度审查 — 15 个静默分支、3 处隐私直写缺陷（剪贴板文本 / 按键明文 / 窗口标题）、44 处调用点分布、signal handler 与主线程 tap 约束
- **Tessa（测试专家）**：测试策略 — 纯逻辑/IO 分层、48 个用例设计、时间注入方案、手动验证清单
- **实测记录**：`~/Library/Application Support/KagiPeek/logs/`（真实运行日志）、`crash/kagipeek-crash-20261023-172414-SIGSEGV.json`（补全后的报告）、`/tmp/kagipeek-diag.zip`（导出包）、`/tmp/kagipeek-diagtab.png`（设置页截图）

---

> 本报告由工程保障团队 AI 协作生成，关键决策请由人类工程负责人复核。
