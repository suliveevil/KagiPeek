# 参与开发

[English](../en/CONTRIBUTING.md) · [中文](CONTRIBUTING.md)


## 构建环境

- macOS 14 或更高版本，完整的 **Xcode**（只有 Command Line Tools 无法展开 SwiftUI 宏）。
- 没有第三方依赖，没有任何东西要安装或锁定版本。

```sh
xcodebuild -project Kaname.xcodeproj -scheme Kaname -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

swift test        # 纯逻辑测试（KanameCore）
```

如果你的环境无法创建嵌套 sandbox——症状是两条命令都报
`sandbox-exec: sandbox_apply: Operation not permitted`——改用：

```sh
swift test --disable-sandbox
./scripts/build_swiftc.sh Debug     # 同一份源码，用 swiftc 编译
```

`swiftc` 需要显式加载宏插件，`build_swiftc.sh` 做的就是这件事：

```sh
swiftc … -load-plugin-library "$PLUG/libSwiftUIMacros.dylib" \
        -load-plugin-library "$PLUG/libSwiftMacros.dylib" \
        -load-plugin-library "$PLUG/libObservationMacros.dylib"
```

## 代码放在哪

| 层 | 路径 | 规则 |
| --- | --- | --- |
| 纯逻辑 | `Kaname/Core/Pure` | 只用 Foundation——不许 AppKit、SwiftUI、`NSWorkspace`。编译两次：一份进 App，一份进 `swift test` 运行的 `KanameCore` SwiftPM 目标。 |
| AX | `Kaname/Core/AX` | 辅助功能与 `NSWorkspace` 访问。 |
| Input | `Kaname/Core/Input` | 事件 tap、注入，以及 AppKit→纯逻辑的桥。 |
| Storage | `Kaname/Core/Storage` | 唯一碰磁盘的代码。 |
| Engine | `Kaname/Core/Engine` | `ShortcutEngine` 把各层接起来。 |
| UI | `Kaname/UI` | SwiftUI 视图与 `NSWindow` 控制器。 |

一个决策如果能不依赖 AppKit 表达，就放进 `Core/Pure` 并在那里测试。行契约、列表选中、面板行构建与标题栏布局
都因此搬了过去；`ShortcutEngine` 已经够大了。

## 增删一个设置项

改设置要动 **六处**。漏掉一处，正是本项目文档与测试发生漂移的方式：

1. `Core/Pure/AppSettingsModel.swift` —— 属性连同默认值、`CodingKeys` 里的分支，以及 `init(from:)` 里的一行
   `decodeIfPresent`。
2. `UI/Settings/SettingsView.swift` —— 控件，放在它所属的标签页。
3. `Core/Pure/L10n.swift` —— **两种语言**的标签。
4. `README.md` 与 `README.zh-CN.md` —— 两种语言的配置表（如果用户可见，功能表也要）。
   `docs/en/` 与 `docs/zh-CN/` 下的同一篇（例如 `docs/en/FAQ.md` 与 `docs/zh-CN/FAQ.md`）。
   每一对都靠手工同步：一次修改要在同一个提交里落到这一对的两半。
5. `Tests/KanameCoreTests` —— 一条默认值断言，以及一条解码测试（如果改动可能影响已有的 `settings.json`）。
6. `CHANGELOG.md` —— `## [Unreleased]` 下的一行，用用户的话写，不用类型的话写。

**删除**一个键不需要迁移步骤：`init(from:)` 只解码已知的键，所以旧数据能解码，键会在下一次保存时消失。
把 `AppSettingsSnapshot.currentSchemaVersion` 加一，把这次删除写进 `SettingsMigrator` 的注释，
再加一条测试证明旧数据仍能解码并在编码回去时不带这个键。

改动了文档所描述的行为？在同一个提交里改掉代码注释。曾有三处各自独立的注释写着"触发键不是前缀"，
而代码把它们推进了前缀——而文档是从注释写出来的。

## 测试

- `swift test` 必须通过。它只测纯逻辑。
- 新的纯逻辑需要测试；新的 AppKit 代码需要在 pull request 里写明你手工怎么验的。
- `Tests/KanameCoreTests` 是唯一的测试目标。没有 UI 测试目标，所以任何从 `KanameCore` 摸不到的东西
  按定义就是没被测过的——这是又一个把决策留在视图之外的理由。

## 风格

- Swift 6 语言模式、macOS 14 部署目标、零依赖。App 目标设置
  `SWIFT_VERSION = 6.0`、`SWIFT_STRICT_CONCURRENCY = complete` 与
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`；`Package.swift` 以
  Swift 6 模式加 `StrictConcurrency` 编译 `KanameCore`。所以新类型默认是主 actor 隔离的，除非它写了
  `nonisolated`——那个关键字是一份契约而不是装饰：`Diag`、
  `CrashReporter`、`KeyboardMonitor` 与 `Core/Pure` 里的类型正是靠它才能从
  事件 tap 线程或崩溃处理器里被调用。
- 注释解释**为什么**。只复述代码的注释是噪音；写着"这看起来不对，但出于 X 是故意的"那种才值钱。
- 通过 `Diag` 打日志，绝不用 `print`。一次调用同时写两个去处：
  `Diag.info(.tap, "event tap installed")`、`Diag.error(.inject, "…")`、`Diag.debug(.scan, "…")`。
  标签是 `DiagTag`：`start`、`perm`、`tap`、`scan`、`inject`、`net`、`run`、`settings`、
  `ui`、`crash`、`exit`、`export`。方法是 `verbose` / `debug` / `info` / `warning` /
  `error`，另有 `Diag.action(_:target:)` 供崩溃报告的动作环使用。注意
  `Diag` 是*唯一*的门面——曾经还有一个（`AppLog`），它产生的日志行从未进入文件；不要把它请回来。
  一个什么都不说的失败，就是你无法回答的 bug 报告。
- 正文用英式拼写（"behaviour"、"favourite"）——代码与标识符是英文，这条只关乎文档的一致性。

## 并行代理与 worktree

多个人和多个编码代理（WorkBuddy、Claude Code、Codex……）会同时在这个仓库里工作。
**权威规则是 [AGENTS.md](../../AGENTS.md) 的 git（多 agent 协作）**；本节解释其中的道理，
以及规则不值得那点代价的情形。

真正冲突的不是"同一个文件"，而是共享工作树里单一的 `HEAD`、单一索引和单一的未提交改动区。
链接工作树共享 refs、对象库、远程跟踪 ref 与 `refs/stash`，但保留自己的 `HEAD`、索引与文件。
由此有两个值得记住的后果：

- Git 拒绝在两个 worktree 里检出同一个分支。把它当成护栏而不是障碍——`--force` 会把两个代理塞回同一个共享 `HEAD`。
- `stash` 是**共享的**。一个代理的 `stash` 可能被另一个 pop 掉。要在两条线之间转移工作，只靠提交并让整合者合并；
  绝不能靠把未提交文件留在那里。

主工作树留在 `main` 上，只做整合、评审与发布。把两个概念配成对——`branch` 给历史一条平行线，`worktree` 给这条线自己的桌子：

```sh
# 整合者，在主工作树
git worktree add -b agent/pure-search ../kp-pure-search main
git worktree lock ../kp-pure-search --reason "agent A session"
git worktree list

# 测试通过后：合并（第 2 步），随即清理（第 3 步）。
# 第 4 步——./scripts/install.sh——在清理*之后*，且只针对代码改动。
git merge --ff-only agent/pure-search       # main 已前进时用 --no-ff
git worktree unlock ../kp-pure-search
git worktree remove ../kp-pure-search       # 仍有未提交文件时会拒绝
git branch -d agent/pure-search             # 用 -d，绝不用 -D
git worktree prune
```

把每个代理的 worktree 绝对路径写进该代理自己的配置或提示词里。它们的会话、任务清单与上下文都不共享，
而且每个都可能自己运行 git 命令，所以口头一句"请待在你的目录里"不是边界。全局副作用同理：
`scripts/install.sh` 会写 `/Applications`、轮转 `~/Library/Application Support/Kaname/backups/` 下的备份，
并读取签名钥匙串。三个代理同时安装会覆盖同一台机器上的同一个 App——worktree 隔离不了这个。
**一个整合者、一次安装，在 sandbox 之外跑。** `build/` 与 `DerivedData/` 也要按 worktree 分开：
曾有一次增量构建把一个过期的 `AppIcon.icns` 带进了 `/Applications`。

把 `AGENTS.md`、`scripts/`、图标资源与 CI 当成共享契约：在主工作树里改它们，再让其他 worktree `rebase main`。
按层分工（`Core/Pure`、`Core/AX`、`Core/Engine`），分支短命，勤合并。

单个代理、串行的一行改动，或只读调研，不值得这么做——那些场景切换分支就够了，不过一个分离的只读 worktree
仍然是查看日志又不碰共享树的干净办法。每个 worktree 都要重建自己的缓存（本项目 `build/` 下有几千个 `.pcm`
文件），所以**3–5 个并行 worktree** 是实际天花板；再往上，合并成本会压过并行收益。

## 提交与发布

工作的分支与合并按上文以及 [AGENTS.md](../../AGENTS.md) 执行：每次改动都从 `main` 开一个新的 worktree + 分支，
`swift test --disable-sandbox` 绿了之后由整合者合回，随后删掉 worktree。主工作树里不直接向 `main` 提交。
只有合并里包含**代码**改动时才用 `./scripts/install.sh` 重装——只改文档的合并不会让已安装的二进制变旧。

提交信息：`type:` 前缀（`feat:`、`fix:`、`docs:`、`test:`、`chore:`），正文说明改了什么、为什么。
`CHANGELOG.md` 的 `[Unreleased]` 条目与改动放在同一个提交里——发布步骤见 [RELEASING.md](RELEASING.md)。

## 报告 bug

请附上版本（**设置 → 关于**）、macOS 版本，以及从 **设置 → 通用 → 诊断** 导出的诊断包——
*导出诊断包…* 写出日志与崩溃目录的 `.zip`，*导出诊断报告…* 写出单个 `.json` 快照。两者都在通用页末尾那个
默认收起的诊断分组里；关于页没有导出按钮。诊断包含权限、监听状态、最近一次扫描结果、你的设置，
以及能打印出对应日志行的命令——没有文档、没有输入的文字，也不上传任何东西。
窗口本身就是坏掉的那部分时，`KANAME_EXPORT_DIAGNOSTICS=<path>` 可以在终端里做同样的事。
