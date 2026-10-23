# KagiPeek 可观测性架构设计

版本: v1.0 · 作者: Archi (System Architect) · 状态: Proposed

---

## 一、技术路线取舍

### 路线 A: 纯 os.Logger + 导出时用 OSLogStore 抓取

沿用现有 `AppLog`（44 处调用点零改动），导出时用 `OSLogStore(scope: .currentProcessIdentifier)` 抓取。

**已核实的硬限制**（Apple Developer Forums，DTS 工程师确认，FB 反馈亦佐证）：

- `.currentProcessIdentifier` 只能读**当前进程**的条目；**上次启动的日志条目读不到**（"It doesn't even give you log entries for previous instances of the current program"）。崩溃重启后想抓崩溃前的日志——读不到。
- `debug` 级日志不落盘，只在内存环形缓冲中短暂存在（社区常说的"约 30 分钟窗口"即源于此缓冲，非文档化的精确承诺）；`info` 级也只保留到系统配额压缩/滚动为止。
- macOS 上 `OSLogStore.local()` 可读全系统日志，但**需要管理员权限**，分发场景不可用。
- `getEntries` 遍历慢（即使带 predicate），在主线程调用会卡顿。

**结论：否决。** 用户报障时机（重启后、数小时后）恰好落在该方案的能力空洞里；"按日期滚动 + 保留天数"在统一日志体系内无法自主控制。

### 路线 B: 自建轻量文件日志（推荐，双轨变体）

保留 `os.Logger` 入口语义不动，新增一个独立文件 sink 门面（`Diag`），只在关键节点埋点。

关键事实：`\(x, privacy: .public)` 插值是**编译器魔法，仅作用于 os.Logger 的方法参数**。若把 `AppLog.scan` 从 `Logger` 换成自定义类型，44 处调用点的插值语法必须全部改写（机械替换可行，但要动 ShortcutEngine 等 12 个文件）。

两个子方案：

| | B1: 统一双写（改 44 处调用点） | B2: 双轨（os.Logger 保留 + 新增 Diag 埋点） |
|---|---|---|
| 调用点改动 | 44 处全改（`privacy:` 语法失效需删除） | 0 处改动，新增约 40 处 Diag 埋点 |
| 覆盖面 | 全量双写，无遗漏 | 埋点清单驱动，理论上可能漏节点 |
| 回归风险 | 中（触碰 2600 行 MainActor 引擎、tap 回调线程） | 低（纯增量，失败也不影响功能路径） |
| 隐私语义 | 丢失 `.public/.private` 编译期标注，统一依赖运行时 Sanitizer | os.Logger 语义保留；文件侧统一过 Sanitizer |
| 工作量/可回滚性 | 大，且不可分段回滚 | 小，逐模块落地可回滚 |

**决策：B2 双轨。** 理由：
1. 硬约束"不破坏现有架构"优先级最高，B1 需要动引擎核心文件，回归面大。
2. 隐私标注本就靠 `.public` 显式声明，文件侧本来就要统一 Sanitizer，B1 的编译期标注价值有限。
3. 埋点清单（第七节）穷举了排障所需节点，B2 的"可能漏"由清单评审兜底；code-reviewer 同步审查静默分支，可交叉校验。
4. B2 落地后若想要全量双写，可作为后续独立重构（44 处替换届时是纯机械工作），本方案不为它设障碍。

### 路线 C: 第三方 SDK（XCGLogger / CocoaLumberjack + PLCrashReporter）

| 维度 | 评估 |
|---|---|
| 依赖体积 | Lumberjack ~2MB 源码 + PLCrashReporter 二进制；KagiPeek 是轻量菜单栏工具，体积占比刺眼 |
| 架构侵入 | Lumberjack 要求自有 Logger 类型 → 同样面临 44 处调用点改写；且引入 fileLogFormatter/DDFileLogger 一整套心智模型 |
| 崩溃捕获 | PLCrashReporter 成熟（含信号处理、dwarf 符号化），是它唯一显著优势 |
| MainActor/Swift 并发 | ObjC 时代的库，Sendable 标注缺失，与现有 Swift 严格并发检查摩擦 |
| 维护方 | KagiPeek 单人项目，多一层依赖 = 多一层升级维护税 |

**结论：否决。** PLCrashReporter 的符号化优势，对"用户手动导出日志给自己看/发给作者"的场景收益很小——系统本身已生成崩溃报告（re-raise 即可拿到），我们要的是"自家时间线上的最小报告 + 上下文补全"，自研百行代码可覆盖。

---

## 二、最终架构

```
┌────────────────────────── KagiPeek 进程 ──────────────────────────┐
│                                                                    │
│  现有调用点(44处, 不动)          新增埋点(约40处)                    │
│        │ AppLog.scan/input/...          │ Diag.info(.tap, "...")  │
│        ▼                                 ▼                         │
│   os.Logger ──► 统一日志系统       Diag 门面 (enum, Sendable)      │
│   (Console.app/log CLI        │                                     │
│    仍可用，开发期友好)          ├─► Sanitizer(正则脱敏, 写前统一过)  │
│                                ▼                                     │
│                          FileLogStore                                │
│                          (串行 DispatchQueue, 按日文件,             │
│                           批量落盘, 滚动+限额)                       │
│                                │                                     │
│  RingBuffer(30条) ──镜像──► crash/last-actions.json (防抖写)       │
│  CrashReporter(异常处理器+信号处理器+哨兵)                           │
│  DiagnosticsExporter(zip 打包, 用户手动触发)                        │
└────────────────────────────────────────────────────────────────────┘
          ▼ 文件落点 ~/Library/Application Support/KagiPeek/
             logs/    kagipeek-YYYY-MM-DD.log
             logs/    session.active        (意外退出哨兵)
             crash/   kagipeek-crash-YYYYMMDD-HHMMSS-<kind>.partial
             crash/   kagipeek-crash-YYYYMMDD-HHMMSS-<kind>.json
             crash/   last-actions.json     (RingBuffer 磁盘镜像)
```

### 模块职责

| 模块 | 类型 | 职责 |
|---|---|---|
| `Diag` | enum + static 方法 | 埋点唯一入口：`Diag.info(.tap, "event tap installed")`；级别 `verbose/debug/info/warn/error`；含 `Tag` 枚举（关键字）。线程安全：内部只做字符串拼接后 `queue.async` |
| `Sanitizer` | struct | 静态正则清单，`sanitize(String) -> String`；唯一应用位置是 FileLogStore 写入前 |
| `FileLogStore` | final class | 串行 `DispatchQueue(label:, qos: .utility)`；批量缓冲（32 行或 200ms 触发落盘）；按日切文件；滚动清理；限额兜底 |
| `RingBuffer` | struct + NSLock | 容量 30 条 `ActionRecord`；崩溃时并入报告；防抖镜像到磁盘 |
| `CrashReporter` | enum/final class | NSSetUncaughtExceptionHandler + 信号处理器 + 哨兵机制 + 下次启动补全 |
| `DiagnosticsExporter` | final class | 组 zip、调分享/保存面板；只读，无网络 |
| 设置字段 | `AppSettingsSnapshot` 新增 2 字段 | `diagnosticsEnabled`（默认 true）、`verboseDiagnostics`（默认 false） |

### 文件布局与命名

```
~/Library/Application Support/KagiPeek/
├── logs/
│   ├── kagipeek-2026-10-23.log      # 行格式见下
│   └── session.active               # 启动写、正常退出删；残留 = 意外退出
└── crash/
    ├── kagipeek-crash-20261023-141522-nsexception.partial
    ├── kagipeek-crash-20261023-141522-sigsegv.partial
    ├── kagipeek-crash-20261023-141522-sigsegv.json     # 下次启动补全后
    └── last-actions.json
```

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
- `verboseDiagnostics = true` 时文件记录 `V/D/I/W/E` 全量；否则只记 `I/W/E`。os.Logger 一侧级别不受影响（开发期仍可 `log stream --level debug`）。

---

## 三、崩溃捕获设计

### 3.1 未捕获 NSException（可自由用 Foundation）

```swift
NSSetUncaughtExceptionHandler { exception in
    // 仍在可分配内存的正常上下文：走 FileLogStore 完整路径
    CrashReporter.writeExceptionReport(exception)   // 同步 flush（进程即将死亡）
}
```

报告内容：时间、App 版本、系统版本、设备型号（`HWModelStr`/sysctl hw.model）、前后台状态（accessory 应用恒为后台活跃态，仍如实记录 `NSApp.isActive`）、`exception.name/reason`、`callStackSymbols`、**RingBuffer 快照**（调用点同步读内存即可）。

### 3.2 致命信号（handler 内只能 async-signal-safe）

约束：不能 malloc、不能用 Foundation/Regex/Dispatch、不能拿锁（可能死锁在已损坏的堆上）。

设计——**启动时预打开 fd**：

```swift
// 启动时（CrashReporter.install()）:
let fd = open(path, O_CREAT|O_WRONLY|O_APPEND, 0o600)   // 预打开，存 static
// 同时预序列化好一行上下文并缓存 C 字符串:
// "ver=1.2.3 os=14.5 model=Mac14,2\n"
```

handler 内只做：`write(fd, buf, len)` 拼接「预缓存上下文 + 信号号 + `time()` 时间戳 + 换行」。然后**恢复默认处置并 re-raise**：

```c
signal(sig, SIG_DFL);
raise(sig);
```

这样系统仍会生成自家的完整崩溃报告（含符号化栈），我们的 `.partial` 只是"自家时间线上的标记"。处理信号：`SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP`。

**下次启动补全**：发现 `.partial` 文件 → 读取其中的信号号/时间 → 合并系统上下文（版本、型号、系统版本、`last-actions.json`、当天日志尾部 200 行）→ 写出 `.json` 完整报告 → 删 `.partial` → 记 `W [crash] recovered crash report …`。

### 3.3 意外退出哨兵

- 启动早期（`engine.start()` 之前）写 `logs/session.active`，内容：pid、启动时间。
- `applicationWillTerminate` 中**先删哨兵**再 flush（删除是幂等且不可失败的，顺序上优先于任何可能阻塞的 flush）。
- 下次启动发现哨兵残留：
  - 有对应时间窗的 `.partial` → 崩溃，走 3.2 补全；
  - 无 `.partial` → **意外退出**（kill/强退/注销/掉电），记 `W [exit] unexpected exit detected at <上次启动时间>, uptime=<…>`，把残留哨兵改名归档进 crash 目录再重写。
- 边界：selftest 模式（`KAGIPEEK_SELFTEST`）也走正常 `NSApp.terminate`，哨兵自然清理。
- 挂起/watchdog：明确不做（accessory 应用无 iOS 式 watchdog 语义），列为非目标。

---

## 四、脱敏设计（Sanitizer）

**唯一应用位置：FileLogStore 写入前**（含崩溃报告的 `W/E` 上下文行；`.partial` 由构造保证无用户数据，不过正则）。os.Logger 侧维持现有 `.public` 显式标注。

正则清单（按序应用，先具体后泛化）：

| # | 目标 | 正则（示意） | 替换为 |
|---|---|---|---|
| 1 | URL 中的敏感 query 键 | `(?i)([?&](?:api[_-]?key|token|access[_-]?token|secret|password|passwd|signature|sig|client[_-]?secret|session[_-]?id|auth)=)[^&\s]*` | `$1<redacted>` |
| 2 | URL 其余 query 值 | `(\?[^\s]*=)[^&\s]{8,}` 的值段 | `<redacted>`（保守：仅对含 `?` 的片段整体替换为 `?<query>`，见权衡） |
| 3 | Bearer / Basic 凭据 | `(?i)(bearer\|basic)\s+[A-Za-z0-9._~+/=-]{8,}` | `$1 <redacted>` |
| 4 | 裸 key=value 对 | `(?i)\b((?:api[_-]?key|token|secret|password|credential)[a-z0-9_]*\s*[:=]\s*)\S+` | `$1<redacted>` |
| 5 | email | `[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}` | `<email>` |
| 6 | 长 hex（≥32） | `\b[0-9a-fA-F]{32,}\b` | `<hex>` |
| 7 | 长 base64（≥40，含结尾 =） | `\b[A-Za-z0-9+/]{40,}={0,2}\b` | `<b64>` |

权衡说明：规则 2 若全量脱敏所有 query 值，GitHub releases API 的 URL 无 query 不受影响；当前唯一网络端点固定且干净，规则 1+3+4 已覆盖现实风险，规则 2 采用"整体替换 query 段"的保守形态防未来新增端点时的意外泄漏。规则 7 可能误伤连续 base64 的合法内容（如某些 bundle 路径哈希）——可接受，日志排障不依赖它们。

---

## 五、最近操作路径 RingBuffer

- **记什么**：`ActionRecord { ts: Date, action: String, target: String? }`。`action` 是动作名枚举字符串（`panel-open / panel-dismiss / row-execute / row-copy / trigger-hold / trigger-hotkey / settings-open …`）；`target` 是目标 app 的 bundle id（如 `com.apple.Safari`）。**不记**菜单项内容、按键字符、用户输入文本。
- **容量 30 条**，环形覆盖旧的。
- **何时清空**：正常退出时随哨兵删除磁盘镜像；崩溃不清（正是要留着）。
- **崩溃时并入**：NSException 路径直接读内存写入报告；信号路径读不到内存 → 由**磁盘镜像**兜底：每次 append 后防抖 1 秒在串行队列上原子写 `crash/last-actions.json`（30 条 JSON，<2KB，开销可忽略）。下次启动补全时并入 `.json` 报告。
- 线程：append 来自 MainActor 引擎与 tap 回调线程，`NSLock` 保护（现有 KeyboardMonitor 同款模式，团队熟悉）。

---

## 六、导出设计

**位置**：SettingsView 新增 `diagnosticsTab`（或并入 aboutTab 底部 Section——建议独立 tab，字段有 3 个交互件）。内容：

1. Toggle：**诊断采集**（`diagnosticsEnabled`，默认开）——关闭后 FileLogStore/CrashReporter 停写（哨兵机制保留，因其无隐私内容且成本为零），日志文件保留供导出。
2. Toggle：**详细日志**（`verboseDiagnostics`，默认关）——开启后文件记 V/D 级。
3. Button：**导出诊断包**。

**导出内容**（zip 内）：

```
KagiPeek-diagnostics-20261023-141522/
├── session-info.json     # app 版本/构建号、macOS 版本、设备型号、本次运行时长、
│                         # 关键设置摘要（triggerMode 等非敏感项）、权限当前状态
├── logs/                 # logs 目录整体（已过 Sanitizer）
└── crash/                # crash 目录整体
```

**方式**：串行队列上组包（读文件 + zip，主线程只转菊花）→ 完成后 `NSSavePanel`（默认文件名 `KagiPeek-diagnostics-<date>.zip`，存到用户选择处）或直接 `NSSharingServicePicker` 弹分享。二选一：推荐 NSSavePanel 为主 + 分享服务为快捷动作（分享面板对菜单栏应用更顺手）。

**明确无自动上传**：DiagnosticsExporter 无任何网络能力；UpdateChecker 仍是进程内唯一网络请求。导出动作本身记 `I [export] diagnostics exported (files=N, size=…) `。

**设置字段落地**：`AppSettingsSnapshot` 新增两字段 + `decodeIfPresent` 回退默认 + `currentSchemaVersion` 3→4（纯新增字段，旧文件可直接解码，按现有 SettingsMigrator 模式处理）。

---

## 七、埋点清单（关键字命名供 grep）

| 关键字 | 节点 | 级别 | 示例行 |
|---|---|---|---|
| `[start]` | 进程启动（版本/系统/型号）、单实例守卫触发、engine.start 完成（含耗时）、selftest 进入/写出 | I | `I [start] launch v1.2.3 on macOS 14.5 (Mac14,2)` |
| `[perm]` | AX/Input Monitoring 状态翻转（旧→新）、Secure Input 进入/退出、权限请求发起、被拒后的轮询恢复 | I / W | `W [perm] accessibility revoked true→false` |
| `[tap]` | tap 安装成功、安装失败（含错误域）、系统禁用后重启用、stop | I / E | `E [tap] create failed: tapCreationFailed` |
| `[scan]` | 扫描开始（bundle id、cache hit/miss）、结果（条数、耗时）、空目录原因（权限/无菜单/被排除）、ScanState 变化 | I（结果 D） | `I [scan] com.apple.Safari 48 items 213ms (disk-cache)` |
| `[inject]` | 注入失败（AX 错误码 + 目标 + 菜单项标题）、注入成功 | E（成功 D） | `E [inject] failed -25204 target=com.apple.Safari` |
| `[net]` | 请求摘要（仅 host+path）、响应状态+耗时、失败原因（超时/解码失败/HTTP 非200） | I / W | `I [net] GET api.github.com/repos/…/latest → 200 412ms` |
| `[run]` | 行执行（动作 + 目标 bundle id；verbose 才记菜单项标题） | I | `I [run] row-execute → com.apple.Safari` |
| `[settings]` | 设置变更：**只记键名 + 新值是否非默认**（`I [settings] changed key=showAppleMenu`） | I | |
| `[crash]` | NSException 报告写出、信号 `.partial` 补全、崩溃恢复发现 | E / W | `E [crash] uncaught NSInvalidArgumentException: …` |
| `[exit]` | 正常退出（含 uptime）、意外退出哨兵发现 | I / W | `W [exit] unexpected exit, uptime=2h13m` |
| `[export]` | 诊断包导出 | I | |

级别纪律：排障最小集（tap/perm/net/crash/exit 失败分支）恒为 `I/W/E`；高频成功路径（scan 结果、run）成功态在 `D`，摘要（次数/失败）在 `I`。设置开关只影响文件 sink 的级别门槛，不影响埋点代码。

**埋点位置对照现有代码**：
- `[start]`：AppDelegate.applicationDidFinishLaunching（守卫前后各一条）+ engine.start 尾部。
- `[perm]`：ShortcutEngine.permissionStateChanged()（356 行区域）翻转发；PermissionCenter 无需改（状态由引擎观测）。
- `[tap]`：startMonitor()（433-450 行区域）成功/失败两分支（对应现有 444/448 两行 AppLog，Diag 并排加一条）；KeyboardMonitor 的 `tapDisabledByTimeout` 分支（272 行）加 `W [tap] disabled by system, re-enabled`。
- `[scan]`：reloadCatalog 与 catalogLoader 回调（1585/1770-1830 区域的空目录/异常分支）。
- `[inject]`：ShortcutInjector 的 AX 错误分支（2362-2410 区域）。
- `[net]`：UpdateChecker.handle 的成功/失败分支（state → .failed 处必须带原因）。
- `[run]`：行执行路径（1950-2000 区域）。

---

## 八、性能预算

| 项 | 预算 | 手段 |
|---|---|---|
| 启动路径新增 | **< 2ms**（目标 < 0.5ms） | 哨兵写入 + mkdir + 预打开 crash fd + 安装两个 handler，均为微秒级 syscalls；Sanitizer 正则惰性编译一次 |
| 运行时单条日志 | 内存 append ~µs 级；**tap 回调线程零磁盘 I/O** | Diag 只做字符串拼接 + `queue.async`（`.utility` QoS），串行队列批量 32 行/200ms 落盘 |
| 高频路径（scan/run） | 成功态默认 `D` 级、文件不落，仅计数 | 级别门槛在入队前判断，未启 verbose 时直接丢弃 |
| RingBuffer 镜像 | 1s 防抖 + 原子写 <2KB | 串行队列，与日志共用 |
| 限额兜底 | 超限时丢行不丢进程 | 见二节滚动策略；写入失败静默计数（文件 sink 自身故障绝不能影响功能路径，Diag 失败即 no-op） |
| 内存 | 常驻 < 1MB | 缓冲区上限 256 行 + RingBuffer 30 条 + 正则缓存 |

---

## 九、风险与权衡

1. **双轨覆盖缺口（已识别的最大风险）**：44 处现有 AppLog 调用中未加 Diag 埋点的分支，文件日志看不到（只在统一日志里）。缓解：第七节清单 + code-reviewer 的静默分支盘点交叉核对；上线后按实际排障缺口补埋点（纯增量，随时可加）。
2. **统一双写的迁移债**：B2 推迟了 44 处调用点改写。当前不构成问题；若未来想要全量双写，机械替换即可，本架构不为迁移设障（Diag 门面 API 形状刻意与 Logger.info/debug/error 对齐）。
3. **信号 handler 的天花板**：`.partial` 只有信号号+时间戳，无栈。依赖 re-raise 后的系统崩溃报告补栈；用户不主动导出系统报告时，我们知道"何时崩于何信号+此前 30 个动作"，但不知道栈。对单人维护的菜单栏工具，这是成本/收益的正确取舍。
4. **Sanitizer 误伤**：长 base64/hex 正则可能吞掉排障者想看的哈希值。缓解：`[net]`/`[scan]` 摘要行在埋点时就不放原始哈希；误伤可接受。
5. **磁盘与隐私残留**：日志/崩溃文件在卸载重装后残留于 Application Support（与现有 settings.json 同宿命）。导出时已脱敏；不做自动清理（保留天数策略已兜底容量）。
6. **哨兵误报**：掉电/内核 panic 场景 `applicationWillTerminate` 不执行 → 下次启动误报 "unexpected exit"。可接受：这本来就是事实陈述（确实是意外退出），且 `W` 级不惊扰用户。
7. **main thread 上的 flush**：`applicationWillTerminate` 需同步 flush 尾部日志（保证 quit 前最后几条落盘）。串行队列 `sync` 等待上限设 500ms，超时放弃（退出路径不悬挂）。
8. **OSLogStore 路线复活条件**：若未来 macOS 放开 `.currentProcessIdentifier` 跨启动读取，且用户接受"日志在系统手里"，可重评路线 A。当前无迹象。

---

## 十、落地顺序建议（供实施参考）

1. `Diag` + `FileLogStore` + `Sanitizer`（含单测：滚动/限额/脱敏/级别门槛）
2. `RingBuffer` + 设置字段（schema v4）
3. `CrashReporter`（哨兵 → 异常 handler → 信号 handler → 启动补全）
4. `DiagnosticsExporter` + SettingsView 分区
5. 按第七节清单逐模块补埋点（tap/perm 先行——它们是"功能不生效"排障的最高频路径）
