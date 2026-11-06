# PERMISSIONS

macOS 权限、签名与运行环境的事实说明。写于 2026-11-04，2026-11-05 复核，依据是本仓库的代码、
`scripts/Info.plist`、`scripts/build_swiftc.sh` 与 `codesign` 实测输出——不是泛泛的 macOS
常识。代码变更后请重新核对，尤其是 tap 类型与签名配置。文中链接都是仓库相对路径 + 符号名，
不写行号：行号会随改动漂移，符号名不会。

## 1. 这个 App 真正需要的系统权限

| 权限 | 是否必需 | 代码依据 | 用户在哪里开 | 没开时的表现 |
| --- | --- | --- | --- | --- |
| 辅助功能（Accessibility） | **必需** | [KeyboardMonitor.swift](../Kaname/Core/Input/KeyboardMonitor.swift) 的 `start()` 创建 `.cgSessionEventTap`、`.defaultTap`（可吞事件的会话级 tap）；[CatalogLoader.swift](../Kaname/Core/AX/CatalogLoader.swift) 用 `AXUIElementCreateApplication` 读菜单；[MenuTrigger.swift](../Kaname/Core/AX/MenuTrigger.swift) 跨进程 `AXUIElementPerformAction` | 系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Kaname | 面板不弹出；事件 tap 创建失败；菜单扫描为空；运行菜单项时 press 失败。设置页把该权限标为「未授权」并给出「打开系统设置」入口 |
| 输入监控（Input Monitoring） | **可选兜底** | [PermissionCenter.swift](../Kaname/Core/AX/PermissionCenter.swift) 用 `CGPreflightListenEventAccess()` 检查；只在辅助功能之外作为第二道判定 | 系统设置 → 隐私与安全性 → 输入监控 → 勾选 Kaname | 没有它 App 仍能工作（辅助功能已覆盖会话级 tap）；只影响少数按「输入监控」而非「辅助功能」判定的系统版本 |
| 屏幕录制（Screen Recording） | **不需要** | 全仓库没有 `CGWindowListCreateImage`、`SCShareableContent` 或任何截图 API；面板定位只用 AX 窗口 frame（[WindowGeometry.swift](../Kaname/Core/AX/WindowGeometry.swift)） | — | 与本 App 无关。截图/窗口捕获属于外部工具（见 STATUS 的环境坑） |
| 自动化 / Apple Events | **不需要** | 没有 `NSAppleEventsUsageDescription`，没有 `AEDeterminePermissionToAutomateTarget`；跨 App 动作全部走 AX | — | — |
| 完全磁盘访问 | **不需要** | 只读 `~/Library/Application Support/Kaname` 与用户显式选择的导出路径 | — | — |

补充事实：

- **tap 是会话级的、可吞事件的**：`CGEvent.tapCreate(tap: .cgSessionEventTap, ..., options:
  .defaultTap)`，不是 HID 级（`.cghidEventTap`），也不是 `.listenOnly`。因此它既能观察也能
  拦下按键，这也是为什么辅助功能是硬性前提。
- **注入走 HID 层**：[ShortcutInjector.swift](../Kaname/Core/Input/ShortcutInjector.swift) 的
  `postKey(keyCode:flags:)` 用 `CGEventSource(stateID: .hidSystemState)` 造键，再
  `post(tap: .cghidEventTap)` 发送按下/抬起。代码没有另外标记私有事件来源，`KeyboardMonitor`
  也不按来源过滤事件；注入只发生在表面已经关闭、tap 不再捕获按键的时候。
- **测试用的 tap 是 `.listenOnly`**：[ShortcutTester.swift](../Kaname/Core/Input/ShortcutTester.swift)
  的 `installTaps()` 建 head 与 tail 两个 `.listenOnly` tap，只观察、不拦，测试失败最坏是
  「没观察到按键」，不会冻结输入。

## 2. 签名与 TCC 授权的关系

macOS 把授权记录绑在 App 的 **designated requirement** 上，而不只是路径。换签名 =
  换身份 = 旧授权不再匹配，表现为「系统设置里勾着，但 App 仍说没权限」。

| 签名方式 | 本轮实际状态 | 对 TCC 的影响 | 适用场景 |
| --- | --- | --- | --- |
| ad-hoc（`codesign -s -`） | 构建脚本在没有证书时的兜底 | 指纹随每次构建的代码内容变化；**每次重新构建都可能要重授** | 仅本机临时构建 |
| `Kaname Local`（自签名证书） | **当前安装使用**；`codesign -dv` 显示 `Authority=Kaname Local` | 只要证书不变、bundle id 不变，重装后授权通常保留 | 本机日常使用 |
| Developer ID | 未使用（无 `TeamIdentifier`） | 对外分发；公证后 Gatekeeper 不拦，TCC 同样绑定签名身份 | 发布版 |

**换签名后最快恢复**：先确认系统设置里旧的 Kaname 条目已移除（必要时点 `−`），再启动
App 让它重新请求；仍不生效时退出 App，执行
`tccutil reset Accessibility com.suliveevil.kaname`（会清掉该 App 的所有辅助功能授权，
需要重新勾选），然后重新打开 App。不要删除 `~/Library/Application Support/Kaname`，那会
丢失设置与统计。改名前的旧记录可用 `tccutil reset Accessibility com.suliveevil.kaname`
清理。

保持授权稳定的做法：固定 bundle id（`com.suliveevil.kaname`）、固定签名证书（`Kaname
Local`）、不要每次构建都改 `CFBundleVersion` 以外的身份字段。

## 3. entitlements 与运行环境

- **没有 entitlements 文件**：仓库里不存在 `*.entitlements`，构建脚本也没有
  `--entitlements` 参数。因此没有 `com.apple.security.app-sandbox`，也没有任何
  `com.apple.security.*` 例外。
- **不能沙盒**，原因都在代码里：
  1. 会话级、可吞事件的全局 tap 在沙盒里不可用；
  2. 需要跨进程读 AX 菜单树并 `AXPress`（[CatalogLoader.swift](../Kaname/Core/AX/CatalogLoader.swift)、[MenuTrigger.swift](../Kaname/Core/AX/MenuTrigger.swift)）；
  3. 读取容器外的第三方配置（Karabiner/ Hammerspoon 等，见 `ConfigScanner`）；
  4. 面板需要覆盖在其他 App 之上并按 AX 坐标定位。
- **Hardened Runtime 已开启**：构建脚本用 `codesign --force --options runtime`，实测
  `flags=0x10000(runtime)`。没有额外 entitlement，因此 hardened runtime 的默认限制
  （如 JIT、任意 dylib 注入）保持启用；本 App 不依赖这些能力。
- **`LSUIElement = true`**：菜单栏常驻、默认无 Dock 图标、无主窗口。设置里可以打开
  「显示 Dock 图标」，那是运行期切换 `NSApp.setActivationPolicy(.regular)`，不改
  Info.plist。因为没有主窗口，`agent-desktop` 之类的辅助工具在面板弹出前抓不到窗口
  （见 STATUS 的环境坑）。

## 4. 一行自查

```
codesign -dv --verbose=4 /Applications/Kaname.app && ls "$HOME/Library/Application Support/Kaname/logs"
```

- `Authority=Kaname Local`、`flags=0x10000(runtime)`、`TeamIdentifier=not set` 是本轮安装
  的预期值；若变成 `Signature=adhoc`，说明用了兜底签名，TCC 授权可能已失效。
- 日志在 `~/Library/Application Support/Kaname/logs/kaname-YYYY-MM-DD.log`；在设置 → 诊断
  里打开「将诊断写入本地」后，辅助功能/tap 的判定会写进 `input` 与 `ui` 分类。
- 辅助功能是否通过的权威来源是 App 自己在 **设置 → 权限** 里显示的状态，以及系统设置 →
  隐私与安全性 → 辅助功能里的开关；不要只看 `AXIsProcessTrusted()` 的一次性返回值（它有缓存）。

## 5. 已知的文档与代码不一致（本轮核对发现）

- 本文旧版本写过「打开 Execute menu commands 才有注入」，但当前代码已删除
  `allowPanelExecute` / `allowSearchExecute` 两个开关（`AppSettingsModel` 的迁移注释：
  version 2/3 把它们删掉了）。现在的语义是：面板与搜索这两类表面都接管键盘，执行菜单项时先关闭
  表面，再通过辅助功能直接按那个菜单项；只有没有菜单项可按、或按压被拒时才回放原快捷键。
  没有需要用户额外打开的「执行」开关。
- 旧版本笼统写「tap 创建失败」；实际有两层：`.cgSessionEventTap` 创建失败（权限/环境）与
  本地 run loop source 创建失败（代码内已回滚，见 `KeyboardMonitor` 的 tap 恢复路径）。
