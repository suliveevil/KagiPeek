# AGENTS.md

KagiPeek 是 macOS 菜单栏快捷键浏览器（Swift 6 / SwiftUI + AppKit）。纯逻辑在
`KagiPeek/Core/Pure`，由 SwiftPM 测试覆盖；UI/AX/Input 由 Xcode target 编译，
`scripts/build_swiftc.sh` 是同源码的回退路径。

- 构建/安装：`scripts/install.sh` 先跑 `scripts/build_release.sh`（xcodebuild），
  失败自动回退 `scripts/build_swiftc.sh Release`。沙箱内 xcodebuild 会因嵌套沙盒
  报 `@State` 宏的 "malformed response" 假错，沙箱外前台可 `BUILD SUCCEEDED`。
- 测试：`swift test --disable-sandbox`（沙箱内 `swift test` 的 manifest 构建会失败）。
- 改编译参数要同步三条构建路径：Xcode target、`build_swiftc.sh`、`Package.swift`。

## git（多 agent 协作）

**拓扑**：主工作树 `/Users/suliveevil/Documents/GitHub/KagiPeek` 固定在 `main`，
只做集成、审查、发布，不在里面直接写代码。**1 个 agent = 1 个 worktree = 1 条 branch**。
纯只读调研也开一个 `--detach` worktree，不占共享工作树。

worktree 之间共享 refs、对象库、远端跟踪和 `refs/stash`；私有的只有 `HEAD`、
index 与工作区文件。因此：同一分支不能被两个 worktree 同时 checkout（git 自带防呆，
**不要用 `--force` 绕过**）；也**不要**用 `stash` 或未提交文件在两条线之间传改动——
跨线只能靠 `commit → 集成者 merge`。

### 开工（集成者，在主工作树执行）

```sh
git worktree add -b agent/<topic> ../kp-<topic> main
git worktree lock ../kp-<topic> --reason "agent <name> 会话中"
git worktree list                       # 核对每个 agent 的路径与分支
```

把该 worktree 的**绝对路径**写进对应 agent 的配置或提示词。多个软件（WorkBuddy、
Claude Code、Codex 等）的会话、任务列表与上下文互不相通，目录边界只能靠配置固定，
不能靠口头约定。

### 给每个 agent 的硬边界（必须写进它自己的提示词）

- 只在自己的 worktree 目录内读写；不得引用主工作树路径。
- 不得 `checkout` / `merge` / `rebase` `main`，不得 `push`，不得 `stash`。
- 不得运行 `scripts/install.sh`，不得改 `/Applications`、备份目录或签名钥匙串。
- `build/` 与 `DerivedData/` 各自一份，不共享（增量构建会留下陈旧产物，例如旧
  `AppIcon.icns` 曾被装进 `/Applications`）。
- 共享契约文件（`AGENTS.md`、`scripts/`、图标资源、CI）只在主工作树改；`main` 推进后
  各 worktree 自行 `rebase main` 同步，否则三份各自修改必然冲突。
- 只跑 `swift test --disable-sandbox` 与本地构建。按模块切任务边界
  （`Core/Pure`、`Core/AX`、`Core/Engine` 各一条线），短命分支、小步提交。

### 集成（唯一执行者，在主工作树）

顺序固定：**① 测试通过 → ② 并入 main → ③ 删除 worktree 与分支 → ④ build 重装**。
四步都由同一个人完成，agent 不参与；每步都在主工作树执行。

**① 测试 + ② 合并**

```sh
swift test --disable-sandbox                       # ① 全绿才继续
git merge --ff-only agent/<topic>                  # ② main 已推进则改 --no-ff
```

**③ 收尾（合并后立即执行）**

```sh
git -C ../kp-<topic> log main..HEAD       # 确认没有未合入的提交
git worktree unlock ../kp-<topic>
git worktree remove ../kp-<topic>         # 有未提交文件会自己拒绝，正好当保险
git branch -d agent/<topic>               # 用 -d，不用 -D；git 会复核可达性
git worktree prune
```

删分支指针不等于删提交；要找回已删分支的 tip，从 `git reflog` 或仍在的
`backup/*` 分支找。清理前一律先 `git branch --merged main` 确认范围。

**④ 安装（仅当合并含代码改动）**

```sh
./scripts/install.sh        # 沙箱外前台运行；脚本里的 mv/rm 在沙箱内会被拒
```

纯文档、纯配置改动**不重装**。安装只能由一人一次完成：脚本写 `/Applications`、
轮换备份、读签名钥匙串，多个 agent 同时跑会互相覆盖同一台机器上的同一个 app——
worktree 隔离不了这一层。`push` 也由集成者单独决定，不由 agent 执行。

> 理由与例外（单 agent、串行小改、3–5 个 worktree 的收益上限）见
> [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) 的「Parallel agents and worktrees」。

## 安装、备份与签名

- 安装：`scripts/install.sh`。它拒绝 ad-hoc 包；`/Applications/KagiPeek.app` 必须是
  `KagiPeek Local`（或 Developer ID）签名。
- 备份：覆盖前由 `scripts/backup_app.sh` 拷到
  `~/Library/Application Support/KagiPeek/backups/`，命名
  `KagiPeek-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app`，保留最近 5 份
  （`KAGIPEEK_BACKUP_KEEP` 可调）。
- `/Applications` 下**只放一份** `KagiPeek.app`；备份不放 `/Applications`，也不放废纸篓。
- ad-hoc 包只用于临时目录里的 `codesign --verify --deep --strict`。ad-hoc 没有稳定代码
  身份，每次构建 cdhash 都变，TCC 会当成新 app：权限反复授权、设置里堆僵尸条目。
- 签名密钥**不在登录钥匙串**：`~/Library/Keychains/kagipeek-signing.keychain-db`，口令在
  `~/Library/Application Support/KagiPeek/signing/keychain-pass`（600，绝不入库）。
  `scripts/build_swiftc.sh` 自动解锁并显式指定该钥匙串；迁移与换机器步骤见
  [docs/RELEASING.md](docs/RELEASING.md) 的「Signing keychain」。
- 回滚命令见 [docs/RELEASING.md](docs/RELEASING.md) 的「Backups and rollback」。

## 文档索引

- [docs/STATUS.md](docs/STATUS.md) — 当前代码/安装/验证状态快照（**带保鲜期，过期即失效**）
- [docs/PERMISSIONS.md](docs/PERMISSIONS.md) — macOS 权限、TCC 与签名事实
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 模块边界与数据流
- [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) — 开发与提交流程
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 常见故障
- [docs/RELEASING.md](docs/RELEASING.md) — 发布与签名
