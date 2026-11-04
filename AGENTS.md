# AGENTS.md

KagiPeek 是 macOS 菜单栏快捷键浏览器（Swift 6 / SwiftUI + AppKit）。纯逻辑在
`KagiPeek/Core/Pure`，由 SwiftPM 测试覆盖；UI/AX/Input 由 `scripts/build_swiftc.sh` 编译。

- 构建：`scripts/build_swiftc.sh Release`（本机 `xcodebuild` 不可用，见 STATUS 的环境坑）
- 测试：`swift test`

## git

每次都在新分支上修改代码，测试没问题之后merge入main，然后build重装app

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
