# KagiPeek 可观测性架构设计

版本: v1.0 · 作者: Archi (System Architect) · 状态: Implemented（部分历史段落已标注）

> 本文前半是设计论证，后半是落地后的形状。标着「历史记录」的段落保留的是**当初**的取舍，
> 其中的调用点计数、行号和路线对比描述了写作当时的树；路径、类型名和行为以代码为准。

---

## 一、技术路线取舍（历史记录）

> 本节记录的是选型过程，结论已经落地：所有诊断埋点走**一个**门面 `Diag`，一次调用同时写
> 统一日志与文件 sink。文中提到的第二套门面 `AppLog`（43 个调用点）已并入 `Diag`；四个
> `Logger`（`scan` / `input` / `storage` / `ui`）现在是 `Diag` 镜像的私有细节，仓库里不再有
> `AppLog` 这个符号。下面的对比按原样保留，因为它解释了为什么会走到这一步。

### 路线 A: 纯 os.Logger + 导出时用 OSLogStore 抓取

沿用当时已有的 `os.Logger` 门面（所有调用点零改动），导出时用 `OSLogStore(scope: .currentProcessIdentifier)` 抓取。

**已核实的硬限制**（Apple Developer Forums，DTS 工程师确认，FB 反馈亦佐证）：

- `.currentProcessIdentifier` 只能读**当前进程**的条目；**上次启动的日志条目读不到**（"It doesn't even give you log entries for previous instances of the current program"）。崩溃重启后想抓崩溃前的日志——读不到。
- `debug` 级日志不落盘，只在内存环形缓冲中短暂存在（社区常说的"约 30 分钟窗口"即源于此缓冲，非文档化的精确承诺）；`info` 级也只保留到系统配额压缩/滚动为止。
- macOS 上 `OSLogStore.local()` 可读全系统日志，但**需要管理员权限**，分发场景不可用。
- `getEntries` 遍历慢（即使带 predicate），在主线程调用会卡顿。

**结论：否决。** 用户报障时机（重启后、数小时后）恰好落在该方案的能力空洞里；"按日期滚动 + 保留天数"在统一日志体系内无法自主控制。

### 路线 B: 自建轻量文件日志（采用）

结论只有一句：在 `os.Logger` 之外加一个文件 sink，所有埋点走同一个门面 `Diag`。

当初的这一节在比较两个变体：一条是把全部调用点改成自定义 Logger 类型（私有的
`.public` / `.private` 插值随之失效，需要机械改写并删掉标注），另一条是保留 `os.Logger`
不动、另起一处埋点门面。当时选了后者，理由是前一条要碰引擎核心文件、回归面大，而埋点清
单本身被认为足以兜住"可能漏节点"的风险。

保留下来的是原有的 `AppLog`，新加的是 `Diag`。这个组合后来暴露的正是当初判断失误的那一面：
两套门面在调用点长得一样，却只有一套会落盘，于是"键盘卡住但日志什么都没说"这种报告既真实
又无用。所以最终不是保留双轨，而是**合并**——`AppLog` 的调用点全部并进 `Diag`（其中与相邻
`Diag` 行重复的直接删掉），四个 `Logger` 降级为 `Diag` 镜像的私有实现。取舍的完整过程见 git
历史。

### 路线 C: 第三方 SDK（XCGLogger / CocoaLumberjack + PLCrashReporter）

| 维度 | 评估 |
|---|---|
| 依赖体积 | Lumberjack ~2MB 源码 + PLCrashReporter 二进制；KagiPeek 是轻量菜单栏工具，体积占比刺眼 |
| 架构侵入 | Lumberjack 要求自有 Logger 类型 → 所有调用点都要改写；且引入 fileLogFormatter/DDFileLogger 一整套心智模型 |
| 崩溃捕获 | PLCrashReporter 成熟（含信号处理、dwarf 符号化），是它唯一显著优势 |
| MainActor/Swift 并发 | ObjC 时代的库，Sendable 标注缺失，与现有 Swift 严格并发检查摩擦 |
| 维护方 | KagiPeek 单人项目，多一层依赖 = 多一层升级维护税 |

**结论：否决。** PLCrashReporter 的符号化优势，对"用户手动导出日志给自己看/发给作者"的场景收益很小——系统本身已生成崩溃报告（re-raise 即可拿到），我们要的是"自家时间线上的最小报告 + 上下文补全"，自研百行代码可覆盖。

---

## 二、最终架构

```
┌────────────────────────── KagiPeek 进程 ──────────────────────────┐
│                                                                    │
│  所有调用点（同一处门面，同一个调用）                                │
│        │ Diag.info(.tap, "...") / Diag.error(.inject, "...")       │
│        ▼                                                           │
│   Diag 门面 (enum, nonisolated, 自带 NSLock 的 static 状态)         │
│        ├─► os.Logger ×4 (scan/input/storage/ui) ──► 统一日志系统   │
│        │   (Console.app / log CLI 仍可用，开发期友好)               │
│        ├─► 级别门槛 LogLevelFilter（默认 info+，verbose 才记 D/V）  │
│        ▼                                                           │
│   Sanitizer(正则脱敏, 写前统一过)                                   │
│        ▼                                                           │
│   FileLogStore                                                      │
│   (串行 DispatchQueue, 按日文件, 32 行/200ms 批量落盘, 滚动+限额)   │
│                                │                                    │
│  ActionRecorder(RingBuffer,30 条) ──镜像──► logs/last-actions.json  │
│  CrashReporter(异常处理器 + 信号处理器 + 哨兵)                       │
│  DiagnosticsExporter(zip 打包, 用户手动触发)                        │
└────────────────────────────────────────────────────────────────────┘
          ▼ 文件落点 ~/Library/Application Support/KagiPeek/
             logs/    kagipeek-YYYY-MM-DD.log
             logs/    session.active           (意外退出哨兵)
             logs/    last-actions.json        (RingBuffer 磁盘镜像)
             crash/   kagipeek-crash-YYYYMMDD-HHMMSS-signal.partial   (信号现场)
             crash/   kagipeek-crash-YYYYMMDD-HHMMSS-SIGSEGV.json     (下次启动补全)
             crash/   kagipeek-crash-YYYYMMDD-HHMMSS-exception.json   (NSException 当场写)
```

### 模块职责

| 模块 | 类型 | 职责 |
|---|---|---|
| `Diag` | enum + static 方法 | 埋点唯一入口：`Diag.info(.tap, "event tap installed")`；方法 `verbose/debug/info/warning/error` 加 `action(_:target:)`；关键字枚举是 `DiagTag`（`start/perm/tap/scan/inject/net/run/settings/ui/crash/exit/export`）。`nonisolated`，可被 tap 线程与崩溃处理器调用 |
| `Sanitizer` | enum | 静态正则清单，`redact` / `prepare`；唯一应用位置是 FileLogStore 写入前 |
| `FileLogStore` | final class | 串行 `DispatchQueue(label:, qos: .utility)`；批量缓冲（32 行或 200ms 触发落盘）；按日切文件；滚动清理；限额兜底 |
| `RingBuffer` | final class + NSLock | 泛型环形缓冲；`ActionRecorder` 用它装 30 条 `ActionRecord`，崩溃时并入报告，并防抖镜像到磁盘 |
| `CrashReporter` | enum | `NSSetUncaughtExceptionHandler` + 六个信号处理器 + 哨兵机制 + 下次启动补全 |
| `DiagnosticsExporter` | enum | 组 zip、调保存面板；`nonisolated`，只读，无网络 |
| 设置字段 | `AppSettingsSnapshot` 已有 2 字段 | `diagnosticsEnabled`（默认 true）、`verboseDiagnostics`（默认 false）；当前 `currentSchemaVersion` 是 8 |

### 文件布局与命名

```
~/Library/Application Support/KagiPeek/
├── logs/
│   ├── kagipeek-2026-10-23.log               # 行格式见下
│   ├── session.active                        # 启动写、正常退出删；残留 = 意外退出
│   └── last-actions.json                     # ActionRecorder 的 30 条磁盘镜像
└── crash/
    ├── kagipeek-crash-20261023-141522-signal.partial      # 信号现场，handler 内 open/write
    ├── kagipeek-crash-20261023-141522-SIGSEGV.json        # 下次启动补全后，按信号名命名
    └── kagipeek-crash-20261023-141522-exception.json      # NSException 当场写，只有这一种
```

片段名里没有"崩溃种类"占位符：信号路径固定叫 `-signal.partial`，补全后的报告按信号名
命名（`-SIGABRT` / `-SIGSEGV` / `-SIGBUS` / `-SIGILL` / `-SIGFPE` / `-SIGTRAP`，取自
`CrashLogFormatter.signalName`）；NSException 路径直接写 `-exception.json`，不产生
`.partial`，也不存在 `-nsexception.json`。

日志行格式（单行、grep 友好）：

```
2026-10-23 14:15:22.123 I [tap] event tap installed
2026-10-23 14:15:23.004 E [inject] injection failed code=-25204 target=com.apple.Safari item="Save As…"
```

级别字符：`V/D/I/W/E`。

### 滚动与限额（默认值）

- 按自然日切文件；**保留 7 天**，**总上限 20 MB**（默认 `info+` 级别下，单日典型量 <1 MB）。
- 超总限：从最旧的日期文件开始删；当天文件自身超过 5 MB 时降级为只写 `W/E`（缓冲区直接丢弃更低级别，计数并每小时记一条 `dropped N lines`）。
- 清理在串行队列上做，每次滚动（跨日首写）时执行一次，平时零开销。
- `verboseDiagnostics = true` 时两个 sink 都收 `V/D/I/W/E` 全量；否则 `debug` / `verbose` 在**写统一日志之前**就被丢掉，只剩 `I/W/E`。也就是说这条开关键同时决定开发期 `log stream` 能看到多少——想看到 `D` 行，先把它打开。

---

## 三、崩溃捕获设计

### 3.1 未捕获 NSException（可自由用 Foundation）

```swift
NSSetUncaughtExceptionHandler { exception in
    // 仍在可分配内存的正常上下文：可以走 Foundation、可以分配
    CrashReporter.handleException(exception)
    //   → 过 Sanitizer、拼 CrashReport、写 kagipeek-crash-<ts>-exception.json
    //   → logs.flushNow(timeout: 0.3)（进程即将死亡）
}
```

`reason` 会和日志行走同一套脱敏：第三方断言可能把导致崩溃的用户数据塞进 reason，而这份
报告是要离开这台机器的。

报告内容：时间、App 版本、系统版本、设备型号（`HWModelStr`/sysctl hw.model）、前后台状态（accessory 应用恒为后台活跃态，仍如实记录 `NSApp.isActive`）、`exception.name/reason`、`callStackSymbols`、**RingBuffer 快照**（调用点同步读内存即可）。

### 3.2 致命信号（handler 内只能 async-signal-safe）

约束：不能 malloc、不能用 Foundation/Regex/Dispatch、不能拿锁（可能死锁在已损坏的堆上）。

实现上**启动时只预计算、不预打开 fd**：`prepareSignalFragment()` 在启动时把片段路径编码成
C 字符串、把上下文（`ver` / `build` / `os` / `model` / `pid`）预序列化成文本，并把每个信号
的前缀（`sig=11\ntime=` 之类）预先分配好；文件本身由 handler 在信号真的到来时才 `open`。
这样正常退出不会留下一个零字节、却和"崩溃但没写成"长得一样的 `*.partial`。

```c
// handler 内，只用 async-signal-safe 调用：
open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
write(context)  // 预序列化的上下文
write(signalPrefix)  // sig=<n>\ntime=
write(<epoch 秒，用 int 手工转十进制>)
write("\n")
close(fd)
```

然后**恢复默认处置并 re-raise**：

```c
signal(sig, SIG_DFL);
raise(sig);
```

这样系统仍会生成自家的完整崩溃报告（含符号化栈），我们的 `.partial` 只是"自家时间线上的标记"。处理信号：`SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP`。进程里同时有 NSException 与信号两条路径时，先到的那条写、后到的那条让位（两个标志位在 handler 里只读）。

**下次启动补全**：发现 `.partial` 文件 → 读取其中的信号号/时间 → 合并系统上下文（版本、型号、系统版本、`last-actions.json`、当天日志尾部 200 行）→ 写出 `.json` 完整报告 → 删 `.partial` → 记 `W [crash] recovered crash report …`。

### 3.3 意外退出哨兵

- 启动时 `CrashReporter.beginSession()` 写 `logs/session.active`，内容：pid、启动时间。
- `applicationWillTerminate` 中**先删哨兵**再 flush（删除是幂等且不可失败的，顺序上优先于任何可能阻塞的 flush）；同一步还会删掉本次会话的 `.partial` 和磁盘上的 `last-actions.json`——正常退出不该给下次启动留下"像是崩过"的痕迹。
- 下次启动的顺序是固定的，四步不能换位：
  1. `completePartialReports()`：把上次的 `-signal.partial` 补全成完整报告（见 3.2）。必须排在本次的片段路径准备好之前，否则会把一个空文件当成损坏的片段删掉；
  2. `reportPreviousSessionIfNeeded()`：哨兵还在 → 上次不是正常退出。带时间窗内崩溃报告的一条是 `W [exit] previous session ended unexpectedly (crash report: …)`，没有的则是 `(no crash report: killed, force quit or power loss)`。然后**直接删除**残留哨兵，不归档、不改名；
  3. `writeSentinel()`：写本次的哨兵；
  4. `prepareSignalFragment()`：编码本次的信号片段路径与上下文。
- 边界：selftest 模式（`KAGIPEEK_SELFTEST`）也走正常 `NSApp.terminate`，哨兵自然清理。
- 挂起/watchdog：明确不做（accessory 应用无 iOS 式 watchdog 语义），列为非目标。

---

## 四、脱敏设计（Sanitizer）

**唯一应用位置：FileLogStore 写入前**（含崩溃报告的 `W/E` 上下文行；`.partial` 由构造保证无用户数据，不过正则）。

统一日志一侧**不脱敏**，这是刻意的：它留在本机、只有管理员权限能读、存在的意义就是开发期可 grep。
`Diag.mirror` 把整行（`[tag] message`）作为**一个**已拼好的字符串以 `privacy: .public` 写出，
所以调用点不再有逐值的 `.public` / `.private` 标注——这条分界线现在只有一条：**离开本机的东西
（文件 sink、导出包）过 Sanitizer，留在本机的东西不过**。

正则清单（按序应用，先具体后泛化）：

| # | 目标 | 正则（示意） | 替换为 |
|---|---|---|---|
| 1 | URL 中的敏感 query 键 | `(?i)([?&](?:api[_-]?key\|token\|access[_-]?token\|secret\|password\|passwd\|signature\|sig\|client[_-]?secret\|session[_-]?id\|auth)=)[^&\s]*` | `$1<redacted>` |
| 2 | URL 其余 query 值 | `(\?[^\s]*=)[^&\s]{8,}` 的值段 | `<redacted>`（保守：仅对含 `?` 的片段整体替换为 `?<query>`，见权衡） |
| 3 | Bearer / Basic 凭据 | `(?i)(bearer\|basic)\s+[A-Za-z0-9._~+/=-]{8,}` | `$1 <redacted>` |
| 4 | 裸 key=value 对 | `(?i)\b((?:api[_-]?key\|token\|secret\|password\|credential)[a-z0-9_]*\s*[:=]\s*)\S+` | `$1<redacted>` |
| 5 | email | `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}` | `<email>` |
| 6 | 长 hex（≥32） | `\b[0-9a-fA-F]{32,}\b` | `<hex>` |
| 7 | 长 base64（≥40，含结尾 =） | `\b[A-Za-z0-9+/]{40,}={0,2}\b` | `<b64>` |

权衡说明：规则 2 若全量脱敏所有 query 值，GitHub releases API 的 URL 无 query 不受影响；当前唯一网络端点固定且干净，规则 1+3+4 已覆盖现实风险，规则 2 采用"整体替换 query 段"的保守形态防未来新增端点时的意外泄漏。规则 7 可能误伤连续 base64 的合法内容（如某些 bundle 路径哈希）——可接受，日志排障不依赖它们。

---

## 五、最近操作路径 RingBuffer

- **记什么**：`ActionRecord { ts: TimeInterval, action: String, target: String? }`（`ts` 是 1970 起的秒数，不是 `Date`，这样磁盘镜像、崩溃报告和 grep 里的同一个值含义一致）。`action` 是动作名字符串（`panel.run`、`search.run`、`panel.run.replay` 之类，由调用点给）；`target` 是目标 app 的 bundle id（如 `com.apple.Safari`）。**不记**菜单项内容、按键字符、用户输入文本。
- **容量 30 条**，环形覆盖旧的。
- **何时清空**：正常退出时 `clear()` 连磁盘镜像一起删；崩溃不清（正是要留着）。
- **崩溃时并入**：NSException 路径直接读内存写入报告；信号路径读不到内存 → 由**磁盘镜像**兜底：每次 append 后防抖 1 秒在串行队列上原子写 `logs/last-actions.json`（30 条 JSON，<2KB，开销可忽略）。下次启动补全时用 `ActionRecorder.loadMirror(at:)` 并入 `.json` 报告。
- 线程：append 来自 MainActor 引擎、tap 回调线程和崩溃处理器；环形缓冲用 `NSLock` 保护，镜像写入由一条私有串行队列独占。

---

## 六、导出设计

**位置**：`SettingsView` 自己的 **Diagnostics** 页（`diagnosticsTab`），不并进 About。页面上有：

1. Toggle：**诊断采集**（`diagnosticsEnabled`，默认开）——关闭后 `Diag` 在入口直接返回，两个 sink 都不再收新行；已写下的日志文件保留供导出。
2. Toggle：**详细日志**（`verboseDiagnostics`，默认关）——开启后 `D` / `V` 级不再被门槛丢弃，两个 sink 都收。
3. 日志目录路径 + **打开文件夹**。
4. Button：**Export diagnostics archive…**（zip）与 Button：**Export diagnostics report…**（单个 JSON）。两个按钮都在这一页，About 页没有导出入口。

**导出内容**（zip 内，注意顶层目录固定叫 `KagiPeek-diagnostics`，日期在 zip 的文件名里）：

```
KagiPeek-diagnostics/
├── session-info.json     # app 版本/构建号、macOS 版本、设备型号、本次运行时长、locale、
│                         # 两个权限的当前状态、两个诊断开关、
│                         # 关键设置摘要（modifierTriggerEnabled / hotkeyTriggerEnabled /
│                         # triggerGesture / triggerKey / panelPlacement 等非敏感枚举）、
│                         # 实际打包进去的日志与崩溃文件清单
├── logs/                 # logs 目录整体（已过 Sanitizer）
└── crash/                # crash 目录整体
```

**例外**：`logs/` 会跳过 `session.active`（属于正在导出的这次会话）、`last-actions.json`
（内容已经折进崩溃报告）和所有 `*.partial`（下次启动才补全的片段）；`crash/` 同样跳过
`*.partial`。被跳过的文件不静默消失——拷不动或读不到的文件会在 `session-info.json` 里留下
一句原因，归档缺文件这件事必须让收件人看得见。

**方式**：`DiagnosticsExporter.export(to:settings:)` 在后台队列组包（`ditto` 打 zip，主线程
只转菊花）→ `NSSavePanel` 选目的地，默认文件名 `KagiPeek-diagnostics-<yyyyMMdd-HHmmss>.zip`。

**明确无自动上传**：`DiagnosticsExporter` 无任何网络能力；`UpdateChecker` 仍是进程内唯一网络请求。导出动作本身记 `I [export] exporting diagnostics: N log files, M crash files`。

**设置字段落地**：两个字段已在 `AppSettingsSnapshot` 里（`decodeIfPresent` + 默认值，旧文件直接解码）。当前 `currentSchemaVersion` 是 8；这两个字段与 schema 版本无关，加它们没有单独的迁移步骤。

### 无 GUI 入口（两个环境变量）

窗口本身坏掉时，排障不能依赖窗口。`AppDelegate.applicationDidFinishLaunching` 里有两个
环境变量入口，位置不同是刻意的：

| 变量 | 位置 | 行为 |
|---|---|---|
| `KAGIPEEK_SELFTEST` | **单实例守卫之前** | 记 `I [start] selftest mode`，照常 `engine.start()`，3 秒后把 `engine.diagnosticsReport()` 写到 `NSTemporaryDirectory()/kagipeek-selftest.json`，再 `stop()` + flush 两个 store + `NSApp.terminate(nil)`。放在守卫之前，是因为要问的往往是**已经装着、正在运行**的那份拷贝"你看见了什么" |
| `KAGIPEEK_EXPORT_DIAGNOSTICS=<path>` | **单实例守卫之后** | 调 `DiagnosticsExporter.export(to:settings:)` 写 zip 到给定路径，然后 `NSApp.terminate(nil)`；失败把原因写到 stderr |

两者都走正常的 `NSApp.terminate`，所以哨兵照常清理、不会在日志里留下假的"意外退出"。
写入结果记 `I [ui] selftest written to <path>` 或 `E [ui] selftest failed: <reason>`。

---

## 七、埋点清单（关键字命名供 grep）

| 关键字 | 节点 | 级别 | 示例行 |
|---|---|---|---|
| `[start]` | 进程启动（版本/系统/型号）、单实例守卫触发、engine.start 完成（含耗时）、selftest 进入/写出 | I | `I [start] launch version=2.2.0 build=1234 macOS=14.5 model=Mac14,2` |
| `[perm]` | AX/Input Monitoring 状态翻转（旧→新）、Secure Input 进入/退出、权限请求发起、被拒后的轮询恢复 | I / W | `I [perm] accessibility revoked` |
| `[tap]` | tap 安装成功、安装失败（含错误域）、系统禁用后重启用、stop | I / E | `E [tap] run-loop source creation failed: the tap will never deliver events` |
| `[scan]` | 扫描开始（bundle id、cache hit/miss）、结果（条数、耗时）、空目录原因（权限/无菜单/被排除）、ScanState 变化 | I（结果 D） | `I [scan] menu ·History is a list of data (2500 children), reading 40, keeping shortcuts only` |
| `[inject]` | 注入失败（AX 错误码 + 目标 + 菜单项标题）、注入成功 | E（成功 D） | `E [inject] target pid 12345 is gone, nothing posted` |
| `[net]` | 请求摘要（仅 host+path）、响应状态+耗时、失败原因（超时/解码失败/HTTP 非200） | I / W | `I [net] update-check status=200 ms=412 latest=v2.2.0` |
| `[run]` | 行执行（动作 + 目标 bundle id；verbose 才记菜单项标题） | I / E | `I [run] Return key ignored: no row selected (index=-1, rows=0)` |
| `[settings]` | 设置变更：**只记键名** | I | `I [settings] changed: showAppleMenu, panelOrder` |
| `[ui]` | 菜单栏项被顶掉 / 重建、激活策略切换、登录项注册失败、selftest 写出 | I / W / E | `W [ui] menu bar item lost (…); rebuilding it` |
| `[crash]` | NSException 报告写出、信号 `.partial` 补全、崩溃恢复发现 | I / E / W | `E [crash] uncaught NSInvalidArgumentException: …` |
| `[exit]` | 正常退出（含 uptime）、意外退出哨兵发现 | I / W | `W [exit] previous session ended unexpectedly (no crash report: killed, force quit or power loss)` |
| `[export]` | 诊断包导出（文件数）、文件夹拷不全的原因 | I / W | `I [export] exporting diagnostics: 3 log files, 1 crash files` |

级别纪律：排障最小集（tap/perm/net/crash/exit 失败分支）恒为 `I/W/E`；高频成功路径（scan 结果、run）成功态在 `D`，摘要（次数/失败）在 `I`。`LogLevelFilter` 是唯一门槛，且在 `mirror` 之前判断，所以统一日志与文件 sink 一起被挡：`error/warning/info` 恒写，`debug/verbose` 只在 `verboseDiagnostics` 打开时写。

**埋点实际落在哪里**（按文件，不写行号——行号会随每一次重构过期）：

- `[start]`：`AppDelegate.applicationDidFinishLaunching`（launch 摘要、单实例、engine.start 耗时）与 `engine.start` 尾部。
- `[perm]`：`ShortcutEngine` 里权限状态翻转的两个分支；`PermissionCenter` 只提供布尔值，不埋点。
- `[tap]`：`KeyboardMonitor`（创建失败、run-loop source 失败、被系统禁用后的重启、watchdog 摘除与恢复、teardown 原因）与 `ShortcutTester`（测试 tap 被禁用）。
- `[scan]`：`MenuScanner`（未授权、无菜单栏属性、截断、空目录原因）、`CatalogLoader`（缓存命中/未命中、被更新的请求取代、扫描槽位超时）、`ShortcutEngine`（Space 切换触发的强制重扫）。
- `[inject]`：`ShortcutInjector`（空和弦、目标进程消失、按键事件构造失败、步骤被跳过）。
- `[net]`：`UpdateChecker.check`（请求摘要、状态码 + 耗时、失败原因）。
- `[run]`：`PanelSession`（无选中行、禁用行被忽略、重复触发被拒、下钻）与 `RowRunner`（AXPress 成功、无和弦可回放、回放失败）。
- `[crash]` / `[exit]`：`CrashReporter`（哨兵写入、上次会话的结果、补全）。
- `[export]`：`DiagnosticsExporter.export`。
- `[ui]`：`StatusItemController`（菜单栏项丢失/离屏）、`AppDelegate`（激活策略、selftest 写出）、`SettingsStore`（登录项失败）。

---

## 八、性能预算

| 项 | 预算 | 手段 |
|---|---|---|
| 启动路径新增 | **< 2ms**（目标 < 0.5ms） | 哨兵写入 + mkdir + 预编码信号片段路径与上下文文本 + 安装两个 handler，均为微秒级 syscalls；Sanitizer 正则惰性编译一次 |
| 运行时单条日志 | 内存 append ~µs 级；**tap 回调线程零磁盘 I/O** | Diag 只做字符串拼接 + `queue.async`（`.utility` QoS），串行队列批量 32 行/200ms 落盘 |
| 高频路径（scan/run） | 成功态默认 `D` 级、文件不落，仅计数 | 级别门槛在入队前判断，未启 verbose 时直接丢弃 |
| RingBuffer 镜像 | 1s 防抖 + 原子写 <2KB | `ActionRecorder` 自己的串行队列（与日志队列分开，避免日志积压拖住崩溃镜像） |
| 限额兜底 | 超限时丢行不丢进程 | 见二节滚动策略；写入失败静默计数（文件 sink 自身故障绝不能影响功能路径，Diag 失败即 no-op） |
| 内存 | 常驻 < 1MB | 缓冲区上限 256 行 + RingBuffer 30 条 + 正则缓存 |

---

## 九、风险与权衡

1. **埋点覆盖缺口（已识别的最大风险）**：某个失败分支没埋点，文件日志就看不到它——只剩统一日志里的一行，而统一日志恰恰是最容易读不到的那一侧。缓解：第七节清单 + code-reviewer 的静默分支盘点交叉核对；按实际排障缺口补埋点（纯增量，随时可加）。
2. **门面合并的历史包袱**：`AppLog` 并进 `Diag` 时，与相邻 `Diag` 行重复的调用被直接删掉，所以"某个分支原来有日志"不能从旧版本反推。判读老日志时按 `DiagTag` 关键字找，不要按旧代码位置找。
3. **信号 handler 的天花板**：`.partial` 只有信号号+时间戳，无栈。依赖 re-raise 后的系统崩溃报告补栈；用户不主动导出系统报告时，我们知道"何时崩于何信号+此前 30 个动作"，但不知道栈。对单人维护的菜单栏工具，这是成本/收益的正确取舍。
4. **Sanitizer 误伤**：长 base64/hex 正则可能吞掉排障者想看的哈希值。缓解：`[net]`/`[scan]` 摘要行在埋点时就不放原始哈希；误伤可接受。
5. **磁盘与隐私残留**：日志/崩溃文件在卸载重装后残留于 Application Support（与现有 settings.json 同宿命）。导出时已脱敏；不做自动清理（保留天数策略已兜底容量）。
6. **哨兵误报**：掉电/内核 panic 场景 `applicationWillTerminate` 不执行 → 下次启动误报 "unexpected exit"。可接受：这本来就是事实陈述（确实是意外退出），且 `W` 级不惊扰用户。
7. **main thread 上的 flush**：`applicationWillTerminate` 需同步 flush 尾部日志（保证 quit 前最后几条落盘）。串行队列 `sync` 等待上限设 500ms，超时放弃（退出路径不悬挂）。
8. **OSLogStore 路线复活条件**：若未来 macOS 放开 `.currentProcessIdentifier` 跨启动读取，且用户接受"日志在系统手里"，可重评路线 A。当前无迹象。

---

## 十、落地顺序建议（历史记录）

> 这五步是当初的施工顺序，已经全部落地。保留它是因为顺序本身有信息：为什么 tap/perm 的埋点
> 最先补。文中提到的 `schema v4` 属于当时，当前 schema 是 8。

1. `Diag` + `FileLogStore` + `Sanitizer`（含单测：滚动/限额/脱敏/级别门槛）
2. `RingBuffer` + 设置字段（schema v4）
3. `CrashReporter`（哨兵 → 异常 handler → 信号 handler → 启动补全）
4. `DiagnosticsExporter` + SettingsView 分区
5. 按第七节清单逐模块补埋点（tap/perm 先行——它们是"功能不生效"排障的最高频路径）
