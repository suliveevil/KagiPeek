# 发布流程

[English](../en/RELEASING.md) · [中文](RELEASING.md)


## 一次性设置

```sh
./scripts/setup_signing.sh
```

在独立钥匙串里创建稳定的自签名 `Kaname Local` 身份（见[签名钥匙串](#签名钥匙串)），不放在登录钥匙串。它的指定要求
（`identifier com.suliveevil.kaname and certificate root = …`）不随代码变化而变，因此辅助功能授权能跨重新构建保留——**限本机与这个钥匙串**。
要发布可下载版本，改用 Developer ID Application 证书（`KANAME_SIGN_IDENTITY`）与一个 `notarytool` 钥匙串配置（`KANAME_NOTARY_PROFILE`）。

## 签名钥匙串

`Kaname Local` 的私钥放在专用钥匙串里，这样 `codesign` 永远不必请求授权：

| 项 | 路径 | 权限 |
| --- | --- | --- |
| 钥匙串 | `~/Library/Keychains/kaname-signing.keychain-db` | `600` |
| 钥匙串口令 | `~/Library/Application Support/Kaname/signing/keychain-pass` | `600` |
| `.p12` 备份 | `~/Library/Application Support/Kaname/signing/Kaname-Local.p12` | `600` |
| `.p12` 口令 | `~/Library/Application Support/Kaname/signing/p12-pass` | `600` |

`signing/` 目录是 `700`。这里没有任何东西进仓库。`scripts/build_swiftc.sh` 读取口令、运行 `security unlock-keychain`、
并把 `--keychain` 传给 `codesign`；口令从不回显。钥匙串 12 小时后自动上锁（`-t 43200`），
这样无人值守的构建日不会撞上锁，同时文件在静态状态下保持加密。

**为什么不用登录钥匙串。** 那里的密钥对 `codesign` 可见，但 macOS 仍会弹出"想要使用你的密钥"对话框。
点**总是允许**对命令行签名不生效：真正有效的授权是该密钥的 ACL 与分区列表，而登录钥匙串按进程管理并重置它们。
用 `-A` 导入、再用 `set-key-partition-list` 配置的独立钥匙串可以无提示签名。

### 保留旧身份以便回滚

改名产生了新的证书与密钥对，因此指定要求变了，辅助功能必须重新授权。旧身份被原样留作回滚副本：

| 项 | 路径 |
| --- | --- |
| 旧钥匙串 | `~/Library/Keychains/kaname-signing.keychain-db` |
| 旧口令 | `~/Library/Application Support/Kaname/signing/keychain-pass` |

`scripts/setup_signing.sh` 把新钥匙串**追加**到用户搜索列表而不是替换它，所以旧钥匙串仍然可用。临时用它签名：

```sh
codesign --force --sign "Kaname Local" \
  --keychain "$HOME/Library/Keychains/kaname-signing.keychain-db" /tmp/some-binary-copy
```

只有在 Kaname 正常安装运行一段时间之后，才删除旧钥匙串与证书。旧备份（签名为 `Kaname Local`）仍在保留时就删掉它，
会让那些备份无法校验；两边都留着，直到旧备份过期出局。

### 新机器 / 恢复

运行 `./scripts/setup_signing.sh`。它会直接在专用钥匙串里创建身份、写入口令文件、设置分区列表与 12 小时锁，
并且在那个钥匙串之外已存在证书时拒绝再创建第二个。要从 `.p12` 备份恢复，按上面第 3 步操作，再用第 4 步校验。
证书必须是受信任的（`security add-trusted-cert -r trustRoot -k "$KC" cert.pem`，或用钥匙串访问），
`find-identity -v` 才会列出它；信任设置是全用户级的，密钥搬家也不失效。

## 步骤

1. **定版本。** 改 `Kaname.xcodeproj/project.pbxproj` 里的 `MARKETING_VERSION`（Debug 与 Release 两个配置都要），
   并确认 `CHANGELOG.md` 的条目写在 `[Unreleased]` 下。该文件是两条构建路径的唯一来源：Xcode 构建直接读它，
   兜底构建（`scripts/build_swiftc.sh`）则用 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 覆写拿到手的 plist 里的
   `CFBundleShortVersionString` / `CFBundleVersion`，两者不一致时打印模板里的值。只改 plist 的版本号，
   过去会产出一个自称上一个版本的兜底构建。
2. **测试。**

   ```sh
   swift test          # 或：swift test --disable-sandbox
   ```

3. **构建、签名、打包。**

   ```sh
   ./scripts/build_release.sh
   # build/Kaname-<version>.dmg、build/Kaname-<version>.dmg.sha256，以及签名后的 .app
   ```

   脚本从构建出的 bundle 读取版本，与工程文件不符就拒绝继续。它给 `.app` **和** `.dmg` 都签名，
   配置了公证配置时对两者都做公证并 stapling，最后写出 `build/Kaname-<version>.dmg.sha256`。

   它还会给构建打时间戳：`build/.release-stamp` 存一行 `<version> <HEAD>`，工作区有未提交改动时追加
   `-dirty`。`scripts/publish_release.sh` 会把这个戳与当前 `HEAD` 对比，不一致就重建，否则版本号没变的情况下
   会重新发布上一次检出留在 `build/` 里的东西——tag 与 DMG 里的代码可能已经不一致，而输出里一个字都不提。
   `-dirty` 的戳仍会发布，但带警告：那个 DMG 里的代码不属于任何提交。

4. **发布前校验。**

   ```sh
   codesign -dv --verbose=4 build/DerivedData/Build/Products/Release/Kaname.app
   codesign --verify --strict build/DerivedData/Build/Products/Release/Kaname.app
   spctl -a -vv build/DerivedData/Build/Products/Release/Kaname.app   # 仅 Developer ID
   xcrun stapler validate build/Kaname-<version>.dmg                  # 仅已公证
   lipo -info build/DerivedData/Build/Products/Release/Kaname.app/Contents/MacOS/Kaname
   ```

   用本地自签名身份时 `spctl` 与 `stapler` 会失败——那个构建是给本机的，不是用来分发的。那就按此标注这个发布，
   而不是假装它是可分发的。
5. **写说明。** GitHub release 的正文由发布脚本根据上一个 tag 以来的提交生成，所以唯一必须的输入是干净的提交历史。
   如果某次发布需要叙述文字——用户必须理解的行为变更、迁移步骤——写进 `docs/en/RELEASES.md` 的 **Highlights**、
   **Fixes worth knowing about** 或 **Upgrade notes** 下，并且引擎的行为要抄自代码，而不是抄自上一版说明。
   单次发布手写的正文仍可放在 `docs/zh-CN/releases/<tag>.md`；它的优先级高于生成的那份。

6. **发布。**

   ```sh
   ./scripts/publish_release.sh
   ```

7. **本地安装并冒烟测试。** `./scripts/install.sh`（它暂存 bundle、校验签名、把被替换的构建复制到
   `~/Library/Application Support/Kaname/backups/`，然后换入新的）。安装器拒绝 ad-hoc 构建：
   只有 `Kaname Local` 或 Developer ID 签名才允许放进 `/Applications`。然后过一遍短清单：
   唤出面板、用 ⌘ 收窄、执行一个菜单项、复制一个菜单项、用 `/` 打开搜索面板、切换它的 App 范围、
   导出 Markdown、搜索并按 Return、打开设置检查统计页与冲突页。

## 备份与回滚

每次安装保留一份备份，按日期、构建与它携带的身份命名：

```
Kaname-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app
```

它们放在 `~/Library/Application Support/Kaname/backups/`，从不放进 `/Applications`
（同一 bundle id 的第二份副本会被 LaunchServices 注册，而 ad-hoc 副本还会拿到自己独立的 TCC 身份）。
只保留最新的五份；更早的由 `scripts/backup_app.sh` 清理。用 `KANAME_BACKUP_KEEP` 调高或调低这个数量。

回滚到其中一份（直接复制粘贴；把 `<backup.app>` 换成完整路径）：

```sh
osascript -e 'tell application id "com.suliveevil.kaname" to quit'; sleep 2
rm -rf /Applications/Kaname.app.new && ditto "<backup.app>" /Applications/Kaname.app.new
rm -rf /Applications/Kaname.app && mv /Applications/Kaname.app.new /Applications/Kaname.app
open /Applications/Kaname.app
/usr/libexec/PlistBuddy -c "Print :KanameCommit" /Applications/Kaname.app/Contents/Info.plist
```

回滚到改名前的 App 是另一套动作：退出 `com.suliveevil.kaname`，把
`~/Library/Application Support/Kaname/backups/`（或旧的 `~/Library/Application Support/Kaname/backups/`）里
`Kaname-*.app` 备份复制到 `/Applications/Kaname.app`，然后用 `com.suliveevil.kaname` 启动。
先删掉 `/Applications/Kaname.app`，否则会有两个事件 tap 同时运行。

最后一条命令必须打印出备份名字里嵌入的提交号；在宣布回滚成功之前，把两者对比一下。备份携带的是它被安装时的签名，
所以 `local` 备份保留辅助功能授权，而恢复 `adhoc` 备份会要求重新授权。

发布坏了怎么办：删掉 GitHub release，并把 tag 标为撤回；DMG 是不可变的，所以发一个新的补丁版本，而不是替换那个资产。
