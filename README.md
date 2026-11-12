<p align="center">
  <img src="res/logo-header.svg" alt="RustDesk"><br>
  <b>deskInner · 纯局域网远程桌面（RustDesk 私人分支）</b>
</p>

> 当前版本 **1.5.10**｜仅 **macOS Apple Silicon（M1–M4）** 与 **Windows x64**｜不依赖任何公网注册 / 中继服务器，连接只走内网 IP。
>
> 这是自用分支的说明。上游 RustDesk 的「自建服务器 / 9 位 ID / 账号 / 公网下载」在这里**全部不适用**。

**最短路径**：两台设备在同一子网 → 装包 → Mac 端清 Gatekeeper 隔离并重建录屏授权 → Windows 端输 Mac 的 IP 连接。

内容：① 与上游的区别 ② 下载安装包 ③ 快速开始 ④ **macOS 安装与授权（重点）** ⑤ 局域网连接规则 ⑥ 常见问题 ⑦ 编译与发布 ⑧ 代码结构 ⑨ 使用边界与许可

---

## 1. 与上游 RustDesk 的区别

| 项 | 本分支行为 | 依据 |
|---|---|---|
| 服务启动 | 启动即无条件监听直连 TCP 与局域网发现 UDP，不需要任何配置；`enable-direct-ip-access` / `enable-lan-discovery` / `stop-service` 一律忽略 | `src/rendezvous_mediator.rs:289-305`、`:1296-1306` |
| 公网服务器 | 不注册、不打洞、不走中继；`start_all()` 只启动 `direct_server()` 和 `lan::start_listening()` | `src/rendezvous_mediator.rs:289-305` |
| 出站 HTTP | 所有公网 API / 账号 / OIDC 调用在统一入口直接拒绝 | `src/common.rs:1569-1570`、`:1598-1599`、`:1857-1858` |
| 更新与探测 | 版本检查、自动更新、hbbs 心跳、会话记录上传、NAT / STUN 探测全部停用 | `src/common.rs:1005`、`:2648`；`src/updater.rs:478`；`src/hbbs_http/sync.rs:29` |
| 连接方式 | **只接受 IP 或 `host:port`**；输入 9 位 RustDesk ID 会被直接拒绝 | `src/client.rs:390-394` |
| 首页 tab | 默认只保留 Recent / Favorites / **Discovered**；地址簿、可访问设备（需登录）已移除 | `flutter/lib/models/peer_tab_model.dart:40-52` |
| 固定密码 | 已移除复杂度限制：任意非空、两次输入一致即可，长度上限 128 | `flutter/lib/desktop/pages/desktop_home_page.dart:903-929`、`libs/hbb_common/src/config/permanent_password.rs:15` |
| 局域网发现 | **没有后台自动扫描**；只在 Discovered tab 点刷新时发一次 ping，3 秒扫描窗口 | `flutter/lib/common/widgets/peer_tab_page.dart:45`、`:64-73` |
| ping 响应 | 无条件回 `pong`，即使拿不到本机网卡 IP / MAC 也响应，MAC 可为空 | `src/lan.rs:36-68` |

保留的能力：画面、键鼠、剪贴板、文件传输、系统音频、Flutter 桌面 UI、固定密码。

---

## 2. 下载安装包

所有包在同一个滚动 Release：[`nightly`](https://github.com/Goorwl/deskInner/releases/tag/nightly)。每次编译成功只保留当前版本的三个安装包，旧版本自动清理。

| 文件 | 平台 | 大小 | 下载 |
|---|---|---|---|
| `rustdesk-1.5.10-aarch64.dmg` | macOS Apple Silicon | 26.5 MiB | [dmg](https://github.com/Goorwl/deskInner/releases/download/nightly/rustdesk-1.5.10-aarch64.dmg) |
| `rustdesk-1.5.10-x86_64.exe` | Windows x64（自解压安装） | 24.6 MiB | [exe](https://github.com/Goorwl/deskInner/releases/download/nightly/rustdesk-1.5.10-x86_64.exe) |
| `rustdesk-1.5.10-x86_64.msi` | Windows x64（MSI） | 25.1 MiB | [msi](https://github.com/Goorwl/deskInner/releases/download/nightly/rustdesk-1.5.10-x86_64.msi) |

> 三个包都**没有 Apple Developer ID / Authenticode 签名**，macOS 端是 ad-hoc 重签。这是自用取舍：不需要证书、不需要公证、不需要任何 GitHub Secret，代价见第 4 章。

---

## 3. 快速开始

### Windows 端

1. 安装 `exe` 或 `msi`（SmartScreen 会提示「未知发布者」→ 更多信息 → 仍要运行）。
2. 若这台机器要**被控**：首页 →「设置密码」，任意非空密码即可。
3. 连接框输入对端 IP（如 `192.168.3.170`），或在 **Discovered** tab 点右上角刷新等 3 秒后双击设备。

### macOS 端

Mac 作**被控端**时必须做完第 4 章的授权，否则 Windows 连上后只会一直显示「正在等待画面传输」。只作控制端时，装包 + 清隔离即可。

---

## 4. macOS 安装与授权（重点）

适用：Apple Silicon Mac，被控端。当前 App 的 bundle id 是 **`com.goorwl.destinner`**。

> ⚠️ **每次换包都要重做一次授权。** ad-hoc 签名的 TCC 授权绑定 `cdhash`，重新编译出的包 `cdhash` 一定变，旧授权必然失效。这是放弃证书签名换来的代价，接受它，不要再折腾证书。
>
> ⚠️ **不要在本地执行 `codesign --force --sign -`。** 1.5.7 时代用本地重签修闪退的老办法已经作废（CI 已去掉 Hardened Runtime）；现在本地重签只会把 `cdhash` 改掉，让刚做好的授权再次失效。

### Step 1 · 安装 + 清 Gatekeeper 隔离

```bash
osascript -e 'quit app "RustDesk"' 2>/dev/null || true
# Finder 里把旧版拖到废纸篓，再把 dmg 中的 RustDesk 拖进 /Applications
sudo xattr -dr com.apple.quarantine /Applications/RustDesk.app
open -a RustDesk          # 必须走 LaunchServices
```

`xattr` 每台新 Mac / 每次重新下载都要做一次；它与 TCC 授权是两回事，互不替代。**不要**从终端直接执行 `Contents/MacOS/RustDesk`（TCC 会把授权记到 Terminal 名下）。

### Step 2 · 看一眼签名（只作确认，不要改它）

```bash
codesign -dvvv /Applications/RustDesk.app 2>&1 | grep -E 'Identifier=|Signature=|CDHash='
codesign -d -r-  /Applications/RustDesk.app 2>&1 | grep '# designated'
```

结果里 `Signature=adhoc`、`Identifier=com.goorwl.destinner`、designated requirement 出现 `cdhash H"…"` —— **全部是预期结果**，不是签名失败，不用回查 CI，也不用配任何证书。

### Step 3 · 重建 TCC 授权

先完全退出并清空这个 App 的旧权限记录：

```bash
osascript -e 'quit app "RustDesk"' 2>/dev/null || true
sleep 2
pgrep -fl 'MacOS/RustDesk|RustDesk.app' || true     # 有残留进程就先在活动监视器里退干净
tccutil reset All com.goorwl.destinner
tccutil reset All com.carriez.rustdesk 2>/dev/null || true   # 顺手清旧包名残留
open -a RustDesk
```

> `tccutil` 若报 `Operation not permitted`，先给「终端」完全磁盘访问权限再重试。

然后在 UI 上按顺序做完：

1. 首页 `Permissions` 卡片点 **Configure** → 弹窗点「允许」。macOS 每个 App 只主动弹一次；**优先让 App 自己请求**，这样 TCC 记录的 `csreq` 才对应当前这个二进制。
2. 系统设置 → 隐私与安全性，检查三个面板：**屏幕录制与系统录音**（录屏 + 系统音频）、**辅助功能**、**输入监控**。麦克风按需开启。
3. 如果面板里没有 RustDesk，或同时出现新旧两个同名条目：用「`−`」删掉，再「`+`」重新选 `/Applications/RustDesk.app`。**只拨一下旧开关没用**，会保留绑着旧签名的 `csreq`；只给新条目授权，旧条目删掉。
4. **二次完全退出并重启** —— 屏幕录制授权不是热生效的：

    ```bash
    osascript -e 'quit app "RustDesk"'; sleep 2; open -a RustDesk
    ```

> 本机工作区里有个辅助脚本 `.workbuddy/fix-perm.command`，但它**未随仓库提交**（clone 后没有）。上面的命令就是它的等价手工步骤，照做即可。

### Step 4 · 设置被控密码

Mac 首页 →「设置密码」。任意非空、两次一致即可，长度上限 128。局域网自用建议设一个短的固定密码。

### Step 5 · 连接并验收

从 Windows 端连接这台 Mac 的当前 IP。**唯一可靠的成功判据是 Windows 端出画面**；首页粉色权限卡片消不消失都不算数（它只在 `initState` 判一次，判定时机不可靠）。

辅助判据 —— Mac 本机日志：

```bash
F=$(ls -t "$HOME"/Library/Logs/RustDesk/RustDesk_r*.log | head -1); echo "LOG=$F"
grep -a -c 'direct access from' "$F"          # 应 >= 1，确有远端连入
grep -a -c 'new video service' "$F"           # 应 >= 1，抓屏服务已起
grep -a -c 'Failed to create capturer' "$F"   # 应 = 0
```

`direct access from` 为 0 说明根本没连进来，日志判不出任何结论，先确认 Windows 端填的是这台 Mac 的当前 IP。

### Step 6 · 以后升级

退出 App → 覆盖安装新包 → `xattr -dr com.apple.quarantine` → **重做一次 Step 3**。每次换包都重授权，没有例外。

---

## 5. 局域网连接规则

| 项 | 规则 |
|---|---|
| 可填地址 | `192.168.3.170`、`192.168.3.170:21118`、或 `host:port` |
| 不可填 | 9 位 RustDesk ID —— 会被 `src/client.rs:390-394` 直接拒绝 |
| 直连 | **TCP 21118**（默认 `RENDEZVOUS_PORT + 2`，可用 `direct-access-port` 选项改） |
| 发现 | **UDP 21119** 广播（`RENDEZVOUS_PORT + 3`），ping / pong |
| 扫描入口 | 首页 **Discovered** tab → 右上角刷新按钮；约 3 秒窗口。**无后台自动发现** |
| 网络要求 | 两端同子网、UDP 广播可达；跨 VLAN / AP 客户端隔离会扫不到，但 IP 直连仍可能通 |
| 防火墙 | macOS 应用防火墙、Windows 防火墙需放行 TCP 21118 与 UDP 21119 |

服务随启动无条件监听，不需要在设置里打开「允许 IP 直接访问」。

---

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 双击无反应 / 闪退无提示 | quarantine 未清，或签名被本地改动破坏 | `sudo xattr -dr com.apple.quarantine /Applications/RustDesk.app`；仍不行就重新下载 dmg，别再改 App 内容 |
| 「已损坏，无法打开」 | 签名结构被改 | 重新下载，不要本地 `codesign` 重签 |
| 「已连接，正在等待画面传输」 | 录屏授权未生效，这是等第一帧的占位框而非错误 | 回第 4 章 Step 3；重点确认二次重启、没直接跑二进制、面板里是「− 删 + 加」而非拨开关 |
| 系统设置里两个 RustDesk | 新旧 bundle id 各一条 | 只给 `com.goorwl.destinner` 授权，旧条目用「−」删除 |
| 授权后卡片仍不消失 | `CGPreflightScreenCaptureAccess()` 判定时机问题 | 以画面和日志为准，别反复拨开关 |
| 键鼠控制不了 | 辅助功能 / 输入监控未开 | 三个面板都要开，然后完全退出重启 |
| Discovered tab 一直空 | 没点刷新 / 广播不通 | 点刷新按钮；确认同子网与 UDP 21119；必要时直接输 IP |
| 换了新包后画面又出不来 | `cdhash` 变化导致旧 TCC 授权失效 | 重做第 4 章 Step 3 |
| Windows 安装被 SmartScreen 拦 | 未签名 | 更多信息 → 仍要运行 |

---

## 7. 编译与发布

唯一入口：GitHub → **Actions** → `LAN Desktop Packages (macOS arm64 + Windows x64)` → **Run workflow**（`workflow_dispatch`，定时构建已停用）。

- 只构建 macOS arm64 dmg 与 Windows x64 exe/msi，Android / iOS / Linux / Sciter 全部跳过；一次约 30 分钟。
- 成功后由 `publish-lan-release` 上传到 `nightly` Release，并删除其它版本的 `.dmg` / `.exe` / `.msi`（`rustdesk.sbom.json` 等非安装包保留）。
- macOS 产物在 CI 里 ad-hoc 重签（`.github/scripts/sign-macos-app.sh`），**不使用 Hardened Runtime、不读取任何签名证书或 Secret**。
- 版本号在 `.github/workflows/flutter-build.yml:62` 的 `VERSION`；升版本需同步 13 处（含 `Cargo.lock` 两条目、`flutter/pubspec.yaml`），并同步第 2 章的下载文件名与体积。
- 本地构建需 Rust / Flutter / vcpkg，版本以 `.github/workflows/flutter-build.yml` 的 `env` 为准（macOS arm64 为 Flutter 3.44.9 + Rust 1.81），不再使用已废弃的 Sciter 方式。

| 文件 | 作用 |
|---|---|
| `.github/workflows/flutter-nightly.yml` | 手动触发入口，`desktop-only: true`、tag `nightly` |
| `.github/workflows/flutter-build.yml` | 构建矩阵与 `publish-lan-release` 发布逻辑 |
| `.github/scripts/sign-macos-app.sh` | 单一 ad-hoc 重签模式 |

---

## 8. 代码结构

| 路径 | 说明 |
|---|---|
| `src/rendezvous_mediator.rs` | **不再与服务器通信**；只启动直连 TCP 服务与局域网发现 |
| `src/lan.rs` | UDP 发现：ping / pong，无条件应答，写入 `LanPeers` |
| `src/client.rs` | 发起连接，纯 LAN 地址守卫 |
| `src/common.rs` | 公网 HTTP API 统一拒绝点，版本检查 / NAT / STUN 停用 |
| `src/server/` | 音频、剪贴板、输入、视频、网络服务 |
| `src/ui_interface.rs` | `get_lan_peers()` 等供 Flutter 调用的接口 |
| `flutter/lib/common/widgets/peer_tab_page.dart` | **Discovered** tab 手动扫描入口 |
| `flutter/lib/models/peer_tab_model.dart` | tab 裁剪 |
| `flutter/lib/desktop/pages/desktop_home_page.dart` | 首页、固定密码设置 |
| `flutter/macos/Runner/Info.plist` | bundle id 与录屏 / 系统音频用途描述 |
| `libs/hbb_common/` | 上游共享库（git submodule） |
| `AGENTS.md` | 本仓库的开发规范 |

---

## 9. 使用边界与许可

仅供在**自己拥有或获授权的设备**之间、在可信局域网内使用；未经授权访问、控制他人设备或侵犯隐私一律禁止，作者不承担滥用责任。

基于 [RustDesk](https://github.com/rustdesk/rustdesk)，沿用 [AGPL-3.0](LICENCE)。本分支只做减法与自用适配，不提供公网服务、不提供签名证书、不提供技术支持。
