# 故障排查

[English](../en/TROUBLESHOOTING.md) · [中文](TROUBLESHOOTING.md)


出问题时从这里开始。每一节都写明该看哪个日志分类；
`log show --last 10m --predicate 'subsystem == "com.suliveevil.kaname"'` 会打印全部日志，
**设置 → 通用 → 诊断 → 导出诊断包…** 会写出一个可以附在 bug 报告里的 zip。

## 诊断数据在哪

Kaname 记录的一切都留在本机，不上传。

| 内容 | 路径 |
|------|------|
| 每日日志（保留 7 天，合计 20 MB） | `~/Library/Application Support/Kaname/logs/kaname-YYYY-MM-DD.log` |
| 崩溃报告 | `~/Library/Application Support/Kaname/crash/kaname-crash-<date>-<kind>.json` |
| 最近 30 条用户动作（用于崩溃上下文） | `~/Library/Application Support/Kaname/logs/last-actions.json` |
| 会话哨兵（区分崩溃与正常退出） | `~/Library/Application Support/Kaname/logs/session.active` |

可以从 **设置 → 通用 → 诊断 → 打开日志目录** 打开该目录，或运行

```sh
open "$HOME/Library/Application Support/Kaname/logs"
```

不依赖窗口也能生成同一份诊断包，这在"坏掉的正是那个窗口"时很有用：

```sh
KANAME_EXPORT_DIAGNOSTICS=/tmp/kaname.zip /Applications/Kaname.app/Contents/MacOS/Kaname
```

一行日志长这样 `2026-10-23 17:24:11.070 I [tap] event tap installed (accessibility granted)`：
时间戳、级别（`V`/`D`/`I`/`W`/`E`）、以及你要 grep 的标签。除非打开 **设置 → 通用 → 诊断 → 包含详细日志**，
否则调试与详细行不入日志；失败（`I`/`W`/`E`）总会写入。

## 哪个关键词回答哪个问题

| 症状 | Grep | 这行告诉了你什么 |
|---------|------|------------------------|
| 菜单栏图标不见了 | `[ui]` | `menu bar item on screen at x=…` 表示它存在且就在栏里；`lost (…); rebuilding it` 表示该条目的窗口消失了、App 重建了它 |
| 完全没反应 | `[tap]` | `event tap installed` 对 `failed`；`disabled by the system` 表示 macOS 撤掉了 tap，App 已重新挂上 |
| 经过密码框后快捷键全失效 | `[perm] secure input` | 安全输入开启时系统会隐藏按键事件——这不是 Kaname 的 bug |
| "昨天还好好的" | `[perm] accessibility` | 授权被撤销了，通常是换了签名重装导致 |
| 面板是空的 / 显示"内置" | `[scan]` | `state=noMenus`、`state=permissionDenied`、`menu-bar attribute missing`、`truncated at maxItems` |
| 面板显示"上次扫描" | `[scan] menu bar unreadable` | `menu-bar attribute missing` 加上 `standing in a scan from <n>s ago`——菜单栏被隐藏（全屏、自动隐藏、调度中心）或该 App 读超时，面板用的是它上一份扫描；带组合键的行仍可回放执行 |
| 面板每次都很慢 | `[scan] cache-miss` | 落盘缓存为什么没命中：`control`、`fingerprint`、`entryFingerprint`、`expired`、`decode` |
| 某个菜单项点了没反应 | `[inject]` | `ax-press failed err=<AXError>`，以及当时是否还有组合键可回放 |
| 执行键没反应 | `[run]` | `no row selected`，或被执行的那个菜单项以及它的去向 |
| "检查更新"失败 | `[net]` | `reason=error/parse/no-tag/url` 与 HTTP 状态 |
| App 消失了 / "它自己退出了" | `[exit]` + `[crash]` | `clean exit` 对 `ended unexpectedly (crash report: …)` 对 `no crash report: killed, force quit or power loss` |
| 设置没有保存住 | `[settings] changed:` | 哪些键变了，按名字列出 |

一份崩溃报告带 App 版本、macOS 版本、机型、前台状态、最近 30 条动作，以及当天日志的尾部——足够区分是 App 的 bug 还是系统限制，不必再请用户复现。

## 面板从不出现

1. **触发开关开了吗？** **设置 → 触发**有两个独立开关：**修饰键手势**与**全局快捷键**。两个都关就是不触发——那是暂停状态。
2. **辅助功能授权了吗？** **设置 → 权限**会显示两项授权。缺少辅助功能授权会让按键 tap 完全失效。
3. **处于安全输入吗？** 密码框、登录窗口和部分终端会对所有 App 隐藏按键事件，此时 Kaname 会隐藏。离开该输入框再试。
4. **前台 App 被排除了吗？** **设置 → 通用 → 排除的 App** 列出面板被抑制的 bundle identifier。按设计 `UsageStore`/`ShortcutEngine` 在这里不写日志；请检查该列表。
5. **按键 tap 在跑吗？** **设置 → 通用 → 诊断**里有一行**状态**，说明监听是否在活动。若不在，退出并重启；若在已授权辅助功能的情况下仍然是关的，再授予输入监控——有些系统把按键投递挡在它后面。

日志分类：`input`（event tap installed / failed）、`ui`（权限状态）。

## 面板出现了，但列表是空的或显示"内置目录"

- **该 App 没有菜单栏。** 游戏、使用自绘窗口的 Electron 应用和部分工具延迟构建菜单：先把该 App 的菜单栏打开一次，再唤出面板。
- **扫描失败了。** 日志分类 `scan` 会记录 App 标识、条目数与是否找到菜单栏。`no menu bar exposed and no fallback allowed` 表示 **设置 → 通用 → 使用内置目录…** 是关的。
- **Kaname 扫到了自己。** 在 v2.2.0 之前，打开搜索面板或设置会激活本 App，于是它自己的（空）菜单栏替换了目录。这已修复；如果你在旧版本上看到，请更新。

## 按执行键没反应

1. **被禁用的菜单项会被忽略。** 菜单项变灰是有原因的。
2. **App 什么都没收到。** 在面板里，Kaname 通过辅助功能按压菜单项；只有按压失败时才回放组合键，因此由自绘视图处理（背后没有菜单项）的快捷键无法用这种方式运行。在搜索面板里，会先激活范围内的 App，等它来到前台后再触发菜单项，所以激活慢的 App 可能错过。按压失败、改为发出组合键时，`[run]` 会记录 `ax-press refused, replaying …`；已经没人可发时，`[inject]` 会记录 `target not frontmost (…)`、`target pid … is gone, nothing posted` 或 `target changed during the wait: …`。
3. **组合键不完整。** 还有后续步骤的菜单项会进入下一层而不是执行；面包屑会告诉你当前在哪一层。

## 面板打开时按修饰键，效果跑到别处

Karabiner-Elements 在 Kaname 的事件 tap **下方**改写键盘，所以绑定在该键上的规则（带 `to_if_alone` 的 `left_command`、Caps Lock 映射、Hyper 映射）会先触发，面板收到的是规则的输出。面板显示期间，**设置 → 触发 → 面板打开时通知 Karabiner** 会写入变量 `kaname_panel`；给那条规则加上 `conditions: [{"type": "variable_unless", "name": "kaname_panel", "value": 1}]`，它就只在面板关闭时生效。写入失败或找不到 CLI 时，`[settings]` 会记录一次 `Karabiner panel signal not sent: …`。完整解释与 JSON 见 [FAQ.md](FAQ.md)。

## 搜索框里打不了中文

输入法正在组字时，窗口级按键监听会退让，于是 ↑↓ 用于移动候选窗、Return 用于上屏。如果候选窗打开时 ↑↓ 仍在移动列表，说明获得焦点的并不是你以为的那个界面——先点一下搜索框。日志分类：`input`（组字期间不写日志，这是设计如此）。

## 每次重新构建后打开 App 都要重新授权

辅助功能授权绑定在代码签名上。ad-hoc 签名的构建每次构建都会得到新签名，于是 macOS 把每一个都当成新 App。运行一次 `./scripts/setup_signing.sh` 会创建稳定的 `Kaname Local` 身份；此后即使代码变化，指定要求（`identifier com.suliveevil.kaname and certificate root = …`）也不变。授权因此能跨重新构建保留——**限同一台机器与同一个钥匙串**。

## 构建不起来，或 `swift test` 立刻失败

`sandbox-exec: sandbox_apply: Operation not permitted` 表示环境无法创建嵌套 sandbox，于是 `xcodebuild` 的逐文件编译失败、`swift test` 的清单构建失败。两个绕法：

```sh
swift test --disable-sandbox           # 纯逻辑测试
./scripts/build_swiftc.sh Release      # 用 swiftc + 显式宏插件编译 App
```

`xcodebuild` 失败时，`./scripts/install.sh` 会自动退回到 swiftc 构建。

## 重启后设置被还原

某次写入失败了。v2.2.0 之前这是静默的；现在 `log show --predicate 'subsystem ==
"com.suliveevil.kaname" AND category == "storage"'` 会写着 `could not write settings.json: …`。
常见原因是宗卷只读或已满，或 `~/Library/Application Support/Kaname` 的权限被改。无法解码的文件会保留为
`settings.corrupt-<timestamp>.json`，所以内容没丢——可以检查或恢复。

## 某个快捷键标着 ⚠︎

另一条绑定占用了同一组合键：可能是某个 App 的菜单项，也可能是已启用的 macOS 系统快捷键（聚焦搜索、调度中心……）。谁生效由 macOS 决定，Kaname 只负责报告；**设置 → 冲突**会列出双方，并给出类型与可能的胜者。

## 菜单栏图标不见了

先看日志：`[ui]` 会告诉你是两种截然不同情况中的哪一种。

| 日志行 | 含义 |
|----------|---------|
| `menu bar item on screen at x=… w=…` | 条目存在且在菜单栏里。如果你看不到，是有东西盖住了它或把它折叠了。 |
| `menu bar item is off-screen (x=… w=…)` | 某个菜单栏管理工具把它移出了栏——它在该工具的隐藏区里。 |
| `menu bar item lost (…); rebuilding it` | 该条目的窗口曾消失；App 移除了它并申请了一个新的。 |
| 什么都没有 | App 还没走到创建条目那一步——先找 `[start] launch`。 |

**菜单栏管理工具是有意接管条目的。** Thaw、Ice 与 Bartender 会捕获每个状态条目并自行排布。开启 Thaw 的 *Ice Bar*（`useIceBar`）并关掉 *总是显示隐藏项* 时，新出现的条目会落在 `•••` 图标后面的折叠区。把 Kaname 从该区拖出来一次，布局会记住。

**留意过期的身份记录。** 这类工具按 `bundle id:item title` 给条目做键。Kaname 的 bundle id 曾改过一次大小写（`com.suliveevil.kaname` → `com.suliveevil.kaname`），于是管理工具可能为同一个 App 留着两条记录，把当前这条当成新的。删掉旧记录即可；过期的那条就是运行中的 App 已不再产生的那一项。

**App 在权限范围内自卫。** 该条目是 App 自有的 `NSStatusItem`，有稳定的 autosave 名与固定的辅助功能标签，窗口消失时会重建。它做不到的是强迫管理工具显示它。

**第二扇门。** **设置 → 通用 → 同时在 Dock 显示图标** 可把 Dock 图标打开；点击它会打开设置。快捷键本身从不依赖这个图标。

## 让 Kaname 在后台常驻

已经具备的机制，以及每一部分的作用：

| 机制 | 换来什么 |
|-----------|--------------|
| `LSUIElement` + `.accessory` 激活策略 | 没有 Dock 图标、没有需要关闭的窗口：只要你不退出，进程就一直在 |
| **设置 → 通用 → 登录时启动**（`SMAppService`） | 重启后 App 就在，不需要登录项脚本 |
| `beginActivity(.userInitiatedAllowingIdleSystemSleep)` | 空闲时 App Nap 无法节流它——事件 tap 保持响应。系统空闲睡眠是刻意**不**禁止的：快捷键助手没有理由让 Mac 一直醒着 |
| `[tap] woke from sleep: re-asserting the event tap` | 睡眠会丢掉事件 tap，也可能改变权限。唤醒后 App 重新检查权限、重新挂上 tap、刷新目录 |
| `[exit] clean exit` / `ended unexpectedly` | 每一次停止都有记录，所以"它消失了"永远可以回答 |

刻意**未**实现的是：一个在崩溃或强制退出后把 App 拉起来的 `KeepAlive` 启动代理。它能扛住一切，代价是多一个 bundle 条目、系统设置里多一次批准，以及一个从你让它离开的状态里又回来的 App。崩溃报告会说明它为什么死；要不要重启是一个决定，不是一个默认。
