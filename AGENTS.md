# AGENTS.md

## 面向用户的说明怎么写
只管说明的写法；任务要求、操作授权、必要确认、产品规定的输出格式不变。
1. **先结论。** 第一句给结论、做法或判断；限定与免责紧跟其后，全文只说一次。
2. **不确定写成事实句，不留否定式尾巴。** 用陈述句写清未知与条件（“X 只有两个样本”“该结论依赖 Y 假设”“这块我没读到”），一条不漏；结论、来源、建议后面都不追加“不能证明”“不能认定”“不代表”“不等于”“不足以判断”“不能保证”“仅代表”“这不能说明”这类句子。
3. **不替用户立稻草人。** 没人提出的推论，不要先设想出来再逐条否定。
自检：删掉那句限定后，结论、依据、路径一样没少——那句在稀释答案，删。

## 本项目
Kaname 是 macOS 菜单栏快捷键浏览器：Swift 6（strict concurrency，新类型默认 MainActor 隔离）、macOS 14+、零第三方依赖。
只有 `Kaname/Core/Pure` 进 SwiftPM 与测试（`Tests/KanameCoreTests`），且只许 Foundation——不许 AppKit、SwiftUI、`NSWorkspace`；
其余源码只进 Xcode target。决策能脱离 AppKit 表达就放进 `Core/Pure`，只有那里测得到。日志只走 `Diag`，不用 `print`。
编译参数改动要同步三处：Xcode target（Debug 与 Release 各写一遍）、`scripts/build_swiftc.sh`、`Package.swift`。

## 构建、测试与验证
- 测试：`swift test --disable-sandbox`。沙箱内不加参数会直接报 `sandbox_apply: Operation not permitted`，不是卡住等结果。
- 构建/安装：`scripts/install.sh` → `scripts/build_release.sh`（xcodebuild），失败自动回退
  `scripts/build_swiftc.sh Release`。沙箱内 xcodebuild 可能失败并报假错（"malformed response" 等）；
  真伪看 `build_swiftc.sh` 输出里有没有 `error:`（install.sh 走到回退时才有这段输出），沙箱外前台跑可 `BUILD SUCCEEDED`。
- CI（`.github/workflows/ci.yml`）是最终门槛：macos-15/26 双 toolchain，Debug 与 Release 都在
  `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 下构建，跑 `swift test` 与 DMG 打包自检，`Core/Pure` 行覆盖低于 70% 直接失败。
- 代码改动就同步改对应的代码注释和文档（见文末「文档」），不留到「以后补」。

## git（多 agent 协作）

**拓扑**：主工作树 `/Users/suliveevil/Documents/GitHub/kaname` 固定在 `main`，只做集成、审查、发布；
**1 个 agent = 1 个 worktree = 1 条 branch**，纯只读调研也开 `--detach` worktree。

worktree 共享 refs、对象库、远端跟踪与 `refs/stash`，私有 `HEAD`、index、工作区文件。由此：
同一分支不能同时 checkout 在两个 worktree（**不用 `--force` 绕过**）；跨线只走 `commit → 集成者 merge`，
不用 `stash` 或未提交文件。

### 开工（集成者，在主工作树执行）

```sh
git worktree add -b agent/<topic> ../kp-<topic> main
git worktree lock ../kp-<topic> --reason "agent <name> 会话中"
git worktree list                       # 核对路径与分支
```

把 worktree 的**绝对路径**写进该 agent 的配置或提示词：WorkBuddy、Claude Code、Codex 的会话与上下文互不相通，
目录边界只能靠配置固定。

### agent 硬边界（原样写进每个 agent 的提示词）

- 只在自己的 worktree 内读写，不引用主工作树路径。
- 不 `checkout` / `merge` / `rebase` `main`，不 `push`，不跑 `scripts/install.sh`。
- 不改 `/Applications`、备份目录、签名钥匙串。
- `build/`、`DerivedData/` 各自一份：共享增量构建会把旧 `AppIcon.icns` 之类带进安装包。
- `AGENTS.md`、`scripts/`、图标资源、CI 是共享契约，只在主工作树改；`main` 推进后自己 `rebase main`。
- 只跑 `swift test --disable-sandbox` 与本地构建；按层切任务（`Core/Pure`、`Core/AX`、`Core/Engine`），
  分支短命、小步提交。

### 集成（唯一执行者，在主工作树）

顺序固定：**① 测试 → ② 合并 → ③ 清理 → ④ 重装**，四步同一个人做完，agent 不参与。

```sh
swift test --disable-sandbox            # ① 全绿才继续
git merge --ff-only agent/<topic>       # ② main 已推进则改 --no-ff
git -C ../kp-<topic> log main..HEAD     # ③ 先确认没有未合入的提交
git worktree unlock ../kp-<topic>
git worktree remove ../kp-<topic>       # 只拒未提交文件，不拦未合并提交
git branch -d agent/<topic>             # 用 -d 复核可达性，不用 -D
git worktree prune
```

④ 仅当合并含代码改动：`./scripts/install.sh`，沙箱外前台跑。纯文档、纯配置改动**不重装**。
安装和 `push` 只由集成者一人执行，因为 `install.sh` 会写 `/Applications`、轮转备份、读签名钥匙串，
多个 agent 同时跑会互相覆盖同一台机器上的同一个 app。分支删错从 `git reflog` 或 `backup/*` 分支找回；
清理前用 `git branch --merged main` 确认范围。

提交信息用 `type:` 前缀（`feat:`、`fix:`、`docs:`、`test:`、`chore:`），正文说改了什么、为什么；
用户可见的变更在同一次提交里进 `CHANGELOG.md`：按 [CONTRIBUTING](docs/zh-CN/CONTRIBUTING.md) 写进
`## [Unreleased]`，该段当前不存在，第一次用时补建——发布说明由提交历史生成。

> 理由与例外（单 agent、串行小改、3–5 个 worktree 的收益上限）见
> [CONTRIBUTING](docs/zh-CN/CONTRIBUTING.md) 的「并行代理与 worktree」。

## 安装、备份与签名

- 只走 `scripts/install.sh`（沙箱外前台）。脚本拒绝 ad-hoc 包：`/Applications/Kaname.app` 必须是
  `Kaname Local` 或 Developer ID 签名。
- ad-hoc 构建只用于临时目录里的 `codesign --verify --strict`（`--deep` 已被 Apple 弃用，改为逐项校验）。
  它没有稳定代码身份，每次构建 cdhash 都变，TCC 会当成新 app：权限反复授权、设置里堆僵尸条目。
- `/Applications` 下只放一份 `Kaname.app`；备份由 `scripts/backup_app.sh` 写进
  `~/Library/Application Support/Kaname/backups/`，不放进 `/Applications`。
- 签名私钥在独立钥匙串 `~/Library/Keychains/kaname-signing.keychain-db`，口令在
  `~/Library/Application Support/Kaname/signing/keychain-pass`（600，绝不入库）；两个构建脚本都自动解锁并显式
  传入该钥匙串。命名、迁移与回滚见 [RELEASING](docs/zh-CN/RELEASING.md) 的「签名钥匙串」与「备份与回滚」。
- 排障开关：`KANAME_SKIP_BUILD=1` 跳过构建（要求 `build/manual/Kaname.app` 已存在）、`KANAME_SKIP_DMG=1`
  跳过打包、`KANAME_INSTALL_PATH` 改安装位置（默认 `/Applications/Kaname.app`）。

## 文档

`docs/zh-CN/` 与 `docs/en/` 成对，`README.md` 与 `README.zh-CN.md` 成对：改一侧就在同一次提交里改另一侧。

- [STATUS](docs/zh-CN/STATUS.md) — 判断「某功能/某安装是否已验证」先读；带保鲜期，过期即失效。
- [CONTRIBUTING](docs/zh-CN/CONTRIBUTING.md) — 改设置项（六处）、加纯逻辑、开 worktree 的例外与上限前读。
- [ARCHITECTURE](docs/zh-CN/ARCHITECTURE.md) / [PERMISSIONS](docs/zh-CN/PERMISSIONS.md) / [TROUBLESHOOTING](docs/zh-CN/TROUBLESHOOTING.md) — 模块边界与数据流 / macOS 权限、TCC 与签名 / 构建与运行故障。
- [FAQ](docs/zh-CN/FAQ.md) / [RELEASING](docs/zh-CN/RELEASING.md) / [RELEASES](docs/zh-CN/RELEASES.md) / [PRIVACY](docs/zh-CN/PRIVACY.md) — 用户常见问题 / 发布与回滚 / 版本说明 / 隐私承诺。
