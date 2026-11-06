# 隐私

[English](../en/PRIVACY.md) · [中文](PRIVACY.md)


Kaname 会读取其他 App 的菜单栏，也会监听键盘，所以"它到底拿这两样东西做了什么"值得一个准确的答案。本页就是完整清单。

## 读取的内容

| 内容 | 用途 | 去向 |
| --- | --- | --- |
| 前台 App 的菜单栏（标题、快捷键、启用状态） | 显示它的快捷键 | 内存，按 App 缓存 20 秒；另有一份落盘缓存，按 App 保留最多 10 分钟（见下文） |
| 按键事件（键码、修饰键，以及某个界面正在读取时输入的字符） | 识别热键、驱动面板、向搜索面板输入 | 仅内存，且只在事件处理期间存在 |
| 已启用的 macOS 系统快捷键（Carbon） | 冲突检测 | 仅内存 |
| 配置扫描开启时的第三方快捷键配置文件，**以只读方式打开**：`~/.config/karabiner/karabiner.json`、`~/.config/skhd/skhdrc`（或 `~/.skhdrc`）、`~/Library/Application Support/Keyboard Maestro/Keyboard Maestro Macros.plist`、`~/Library/Application Support/BetterTouchTool/` 下最新的 `btt_data_store.version_*`、`~/.hammerspoon/init.lua`，以及 `Alfred.alfredpreferences/workflows/*` 里的 `info.plist` | 找出菜单扫描看不到的快捷键 | 仅内存：组合键、标题、所属工具。其中任何内容都不落盘 |
| 前台窗口的位置与尺寸 | 把面板放在它旁边或覆盖它 | 仅内存 |
| 运行中的 App 列表 | 搜索面板的 App 范围 | 仅内存 |

它不读取文档、输入框、窗口内容、剪贴板或你的浏览记录。检测到安全输入（密码框、登录窗口）时，面板会隐藏。

配置文件以**只读**方式打开——BetterTouchTool 的 SQLite 数据库也带着 SQLite 的只读标志——读取发生在启动时和你手动要求重扫时，从不写入、复制或上传。关掉 **设置 → 冲突 → 配置文件来源** 会丢弃已找到的内容，并且不再打开其中任何一个。

## 写入的内容

`~/Library/Application Support/Kaname/` 下的两个 JSON 文件：

- `settings.json` —— 你的设置，包括录制的热键与行操作键。
- `usage.json` —— 每条 `bundleID|chord` 的按压次数与最近使用时间（最多 800 条），以及你收藏的快捷键。没有原始按键事件，没有输入的文字，没有查询内容。

两者都以原子方式写入；无法解码的文件会被保留为 `*.corrupt-<timestamp>.json` 而不是被丢弃。搜索查询只留在内存里。

其余写入物都是派生数据或诊断数据，不属于个人数据：

- `conflicts-cache.json` —— 最近一次跨 App 冲突扫描的结果，这样打开冲突页时不必再走一遍所有 App 的菜单。每条结论只记组合键、标题与所属层。
- `menu-cache/` —— 每个 App 标识一份菜单扫描缓存（`menus-<identity>.json`），外加一个很小的 `control.json`，记录这些条目是在哪些设置下写入的。它保存的正是扫描本来就读到的东西（菜单标题、菜单路径、快捷键、启用状态），所以再次为同一个 App 打开面板、或重启 Kaname，都不必重新遍历菜单栏。条目最多保留 10 分钟，并且在影响扫描的设置发生变化或你按下"恢复默认"时被丢弃。无法解码的条目会被丢弃而不是保留——与设置和统计不同，它重新扫一遍就能得到。
- `logs/` 与 `crash/` —— 每日诊断日志、最近 30 条动作的**名称**（从不记录菜单文字、输入的字符或查询），以及每次崩溃一个 JSON 文件。它们存在的目的是解释 bug；日志可在 **设置 → 通用 → 诊断** 里关闭；删掉这个目录只会损失一次重扫和一段历史。

这些内容从不离开本机。

## 发送的内容

什么都不发，除了你自己触发的检查更新：它读取公开的 GitHub release 文档一次。没有遥测、没有分析、没有账号、没有崩溃上报端点。

## 注入的内容

按下执行键、点击某一行，或在搜索面板里按 Return，都会关闭界面并触发**那一行对应的菜单项**——通过辅助功能按压它。只有在没有菜单项可压、或按压被拒绝时，才会发出那一个组合键（`CGEvent`，HID 事件 tap），而且只发一次。这样设计是为了让你不必伸手去菜单栏也能运行菜单命令。

- 浏览面板不注入任何东西。
- 复制键不注入任何东西，它只写剪贴板。
- Kaname 从不回放你输入的内容，也从不注入超过那一条组合键。

## 拦截的按键

全局按键 tap 是*活动*的，因此它可以吞掉一个键而不是放行。它吞掉的键是：

- 你录制的热键（面板、搜索、切换）；
- 面板打开期间：方向键、`;` / `'`、⌃F/⌃B/⌃N/⌃P、Esc、两个录制的行操作键，以及导航多段组合键时的 ⌫；
- 搜索面板获得焦点期间：你输入到搜索框里的内容，由文本框自己读取。

其余按键原样送达前台 App，包括用来完成某一行的快捷键：面板关闭、事件继续，命令只运行一次。

## 日志

App 写入统一日志，子系统为 `com.suliveevil.kaname`，分四类：`scan`、`input`、`storage`、`ui`。条目会写正在扫描的 App、是否发出过组合键以及发往哪个 bundle identifier、某次文件写入是否失败。它们不包含你输入的文字或文档内容，并且留在你的机器上，除非你选择把它们附进 bug 报告——**设置 → 通用 → 诊断 → 导出诊断包…** 正是为此写出一个 zip，发给谁由你决定。

## 权限

辅助功能是必需的（读取菜单栏与按键 tap）。输入监控是可选兜底项，用于仅靠辅助功能收不到按键事件的系统。没有其他授权；Kaname 从不请求完全磁盘访问、屏幕录制或自动化。详见 [PERMISSIONS.md](PERMISSIONS.md)。

## 如何自行验证

源码是 GPL-2.0。相关文件都不大，容易审计：

- `Kaname/Core/Input/KeyboardMonitor.swift` —— 观察了什么、吞掉了什么；
- `Kaname/Core/Input/ShortcutInjector.swift`（`postKey`）—— 唯一发出事件的代码；
- `Kaname/Core/Storage/`、`Kaname/Core/Services/`（`FileLogStore`、`ActionRecorder`、`CrashReporter`、`ConflictCache`）与 `Kaname/Core/AX/MenuScanCache.swift` —— 所有写入 Application Support 的代码；
- `Kaname/Core/Services/UpdateChecker.swift` —— 唯一的联网代码。
