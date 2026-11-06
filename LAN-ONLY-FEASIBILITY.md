# RustDesk 1.5.1 · 纯内网定制版（LAN-ONLY）实施说明

- 工作区：`C:\Users\wule\Downloads\rustdesk-master`，版本 `1.5.1`（`Cargo.toml:3`）
- 本轮性质：**源码改造已落盘**（不再是「配置规避」方案）
- 日期：2026-11-05
- 方式：静态代码审计 + 最小 diff 改动；**未编译、未运行、未实测**（见第 7 节）
- 改动标记：**19 个文件、51 处** `[LAN-ONLY]` 注释，覆盖全部改动处；`grep -rn "LAN-ONLY" src/ flutter/lib/` 可完整定位
- 第 11 节为**第二轮全量复核**（从零重扫，不复用前述结论），新增 2 项加固与若干未落实项

---

## 0. 本轮结论

用户要求：**「全部移除，启动就默认是内网逻辑，不然还会连接外网服务器；把其他相对应的功能也移除了吧，只保留局域网相关服务」**。

已从「靠配置绕开公网」升级为「源码层面启动即纯内网」。

| 目标 | 状态 | 实现方式 |
|---|---|---|
| 启动后不主动连任何公网服务器 | ✅ 已落实 | 删除注册循环 / NAT 探测 / 心跳 / 更新调度，HTTP 出口加总闸 |
| 无需任何配置就能被内网连上 | ✅ 已落实 | `direct_server`(21118) 与 LAN 发现(21119) 无条件启动，忽略开关 |
| 用 IP 发现并一键连接 | ✅ 已落实 | 发现结果补 `ip` 字段，卡片按 IP 连接（原方案 2 已落盘） |
| 加密 / 白名单要求全部移除 | ✅ 已落实 | 直连路径本就不执行加密；白名单空值空转；UI 相关项已删 |
| 只保留局域网相关服务 | ⚠️ 部分落实 | 运行时功能已封闭；部分死代码与云端 UI 入口未物理删除（见第 4 节） |
| 编译验证 | ❌ 未落实 | 本副本缺 `hbb_common` 子模块，且本机 `cargo` / `dart` 均不可用 |

> 关键转变：原报告的「坑 1/2/5」（发现列表连不上、stop-service 关掉直连、两个开关默认值相反）**已被代码改动消除**，不再需要用户手动规避。

---

## 1. 目的 → 减法：保留什么 / 移除什么

| 类别 | 保留（局域网相关） | 移除（公网/服务器相关） |
|---|---|---|
| 被控端服务 | `direct_server` TCP 21118、`server::create_tcp_connection`、视频/输入/剪贴板服务 | 注册 hbbs、打洞（UDP/TCP/IPv6）、中继 hbbr、WebRTC answerer |
| 发现 | `lan::start_listening` UDP 21119、WoL、发现列表 | 在线状态查询（连 public online server） |
| 客户端 | `Client::start` 的 IP / `host:port` 直连分支（`client.rs:440-467`） | 9 位 ID → `get_rendezvous_server()` → 打洞/中继整条路径 |
| 网络出口 | 无 | NAT 探测、服务器测速、hbbs heartbeat/sysinfo 上传、会话录制上传、自动更新、API/账号/地址簿/组/OIDC/2FA-bot 全部 HTTP |
| UI | 主页、连接页、安全页（密码、直连端口）、显示页、关于页 | 网络设置页、账号页、更新检查、Deny LAN discovery、Enable direct IP access、IP/ID 白名单 |

**设计取舍**：所有公网功能通过「删除启动入口 + 总闸早退」禁用，而不是物理删除整条实现链。原因：这些私有函数与 TLS 缓存、TCP 代理、编解码等模块共享，本副本**无法编译验证**，整链删除会引入悬空引用风险。所有被保留的实现都已不可达。

---

## 2. 启动后的默认行为

```
start_server() → RendezvousMediator::start_all()      [rendezvous_mediator.rs:289]
   ├─ check_zombie() / new_server()                  本地
   ├─ tokio::spawn(direct_server)                   TCP 21118 无条件监听
   ├─ thread::spawn(lan::start_listening)           UDP 21119 无条件回应
   ├─ scrap::codec::test_av1()                      本地
   └─ loop { sleep(3600s) }                         保活，不再有任何注册循环

主控端输 IP → Client::start() 守卫通过 → _start() 的 IP 分支直连 21118
主控端输 9 位 ID → Client::start() 直接 bail，不会碰 rendezvous
UI 点任何云端按钮 → get_api_server()="" / post_request()&http_request_sync() bail
```

---

## 3. 实际改动清单（19 个文件、33 项，逐项可核对）

### A. 启动入口（核心）

| # | 文件:行号 | 改动 | 状态 |
|---|---|---|---|
| 1 | `src/rendezvous_mediator.rs:289-309` | **重写 `start_all()`**：删除 `test_nat_type`、`is_outgoing_only` 早退、`hbbs_http::sync::start`、`updater::start_auto_update`、服务器测速、以及整个 rendezvous 注册/重试循环（原 283-363 共 81 行 → 现 21 行）；改为无条件启动直连服务与 LAN 发现 + 保活 loop | ✅ |
| 2 | `src/main.rs:14` | 删除 flutter 入口的 `test_rendezvous_server()` / `test_nat_type()` | ✅ |
| 3 | `src/flutter_ffi.rs:69,1078` | 删除 Android/iOS 启动探测、配置变更时的 mediator restart + 服务器测速 | ✅ |
| 4 | `src/ui.rs:105` | 删除 Sciter UI 启动时的 `check_software_update()` | ✅ |
| 5 | `src/ipc.rs:1157` | `Data::TestRendezvousServer` → 空 arm | ✅ |

### B. 公网出口总闸

| # | 文件:行号 | 改动 | 状态 |
|---|---|---|---|
| 6 | `src/common.rs:703,841,844` | `test_nat_type` / `test_rendezvous_server` / `refresh_rendezvous_server` → 空函数 | ✅ |
| 7 | `src/common.rs:1006,1117` | `check_software_update` → 空；`do_check_software_update` → `Ok(())`（不再请求 `api.rustdesk.com`） | ✅ |
| 8 | `src/common.rs:1169` | `get_api_server()` → 恒返回 `""`，一次性切断地址簿/登录/组/心跳/审计/OIDC/2FA-bot 的 URL | ✅ |
| 9 | `src/common.rs:1568,1593` | `post_request` / `post_request_with_status` → `bail!`，覆盖所有 HTTP POST | ✅ |
| 10 | `src/common.rs:1851` | `http_request_sync` → `bail!`，**补漏**：这是绕过 post_request 的独立出口（`main_http_request` / OIDC / account） | ✅ |
| 11 | `src/hbbs_http/sync.rs:29,38` | `start()` 空；`start_hbbs_sync()` 不再 spawn heartbeat/sysinfo 上传线程 | ✅ |
| 12 | `src/hbbs_http/record_upload.rs:23` | `is_enable()` → `false`，会话录制上传线程永不启动 | ✅ |
| 13 | `src/updater.rs:149,478` | `start_auto_update_check()` 不再 spawn 调度线程；`start_auto_update_macos()` 早退 | ✅ |
| 14 | `src/flutter_ffi.rs:1823` / `flutter/lib/main.dart:136,178` / `flutter/lib/common.dart:4108` | 三端一起移除更新检查（Rust FFI 置空、Dart 调用与函数删除） | ✅ |

### C. 客户端连接与 LAN 发现

| # | 文件:行号 | 改动 | 状态 |
|---|---|---|---|
| 15 | `src/client.rs:390-394` | `Client::start` 加守卫：非 IP / 非 `host:port` 直接 `bail!`，ID 路径永不可达 | ✅ |
| 16 | `src/client.rs:5381-5382` | `create_online_stream()` → `bail!`，在线状态查询不开 socket（第 32 项加固后行号 +5） | ✅ |
| 17 | `src/server.rs:408-409` | `create_relay_connection_()` 早退 `bail!`，永不外拨中继 | ✅ |
| 18 | `src/rendezvous_mediator.rs:1300` | `direct_server` 的 `disabled = false`，忽略 `direct-server` 与 `stop-service` 开关 | ✅ |
| 19 | `src/lan.rs:38` | 删除 `enable-lan-discovery` 判断，无条件回应 ping | ✅ |
| 20 | `src/ui_interface.rs:870-895` | `get_lan_peers()` 增加 `ip` 字段，从 `ip_mac.keys()` 过滤 127./169.254./IPv6 后取第一个 | ✅ |
| 21 | `flutter/lib/models/peer_model.dart:16,42,61,107,161` | `Peer` 增加 `String ip`，fromJson / toJson / 构造函数 / copy 全链路贯通 | ✅ |
| 22 | `flutter/lib/common/widgets/peer_card.dart:71,77,1599` | 三处连接改传 `peer.ip.isNotEmpty ? peer.ip : peer.id`；`peer.id` 保持不动（WoL/删除仍可用） | ✅ |
| 23 | `flutter/lib/common/widgets/peers_view.dart:315-318` | `_startCheckOnlines()` → 空，停止定时在线轮询 | ✅ |
| 24 | `src/ui_interface.rs:1601` | `change_id_shared_` 的 `rendezvous_servers` 置空，改 ID 变纯本地操作，不再连服务器查重 | ✅ |
| 25 | `src/ui_interface.rs:366` | `test_if_valid_server()` 不再探测远程主机 | ✅ |

### D. UI 与状态

| # | 文件:行号 | 改动 | 状态 |
|---|---|---|---|
| 26 | `flutter/lib/desktop/pages/desktop_setting_page.dart:74` | `tabKeys` 移除「网络」「账号」两个设置页 | ✅ |
| 27 | 同文件 `:1457` | 删除「Deny LAN discovery」「IP 白名单」「ID 白名单」三个安全项 | ✅ |
| 28 | 同文件 `:1504` | 删除「Enable direct IP access」开关；保留端口输入框（`direct-access-port` 仍可改） | ✅ |
| 29 | `src/ui_interface.rs:637` | `get_connect_status()` 强制 `status_num = 1`，否则无注册循环会让主页永远显示「连接中」 | ✅ |
| 30 | `src/flutter_ffi.rs:1197-1199` | `main_is_using_public_server()` → `false`，隐藏「使用公网服务器」引导（该引导会打开 rustdesk.com/pricing） | ✅ |
| 31 | `src/common.rs:1` | 模块级 `#![allow(dead_code, unused_imports)]`（原因见第 1 节）；`rendezvous_mediator.rs` / `client.rs` 清理了明确未使用的 import | ✅ |

### E. 第二轮全量复核补强（本轮新增，详见第 11 节）

| # | 文件:行号 | 改动 | 状态 |
|---|---|---|---|
| 32 | `src/client.rs:5271-5280` | `hc_connection()` 开头 `return None;` + `#[allow(unreachable_code)]`：健康检查长连接原本靠 `_start` 返回 `(0, "")` 隐式短路，现改为物理短路，会话 / 端口转发 / RDP 三个调用点都不可能再拨 hbbs | ✅ |
| 33 | `src/common.rs:2646-2651` | `test_ipv6()` 开头 `return None;` + 同上属性：禁用会向公网 STUN 服务器发 UDP 包的 IPv6 探测（`stun_ipv6_test` / `default_stun_servers`） | ✅ |

> 两项均**不是**修复现存公网外连（复核确认原路径在纯 IP 直连下已不可达），而是把「靠间接条件保证」升级为「物理移除」，与用户「全部移除、只保留局域网」的终稿要求对齐。原实现保留在 `return` 之后以便回退。

---

## 4. 已落实 / 未落实（诚实区分）

### ✅ 已落实
- 启动零公网出站（注册、探测、心跳、更新、上传、在线查询全部禁用）
- 被控端零配置可连（21118 / 21119 无条件启动）
- 内置「发现」列表按 IP 一键连接
- 9 位 ID 连接被显式拒绝，杜绝任何走 rendezvous 的可能
- 加密 / 白名单相关的要求、配置项、UI 项全部移除
- 所有改动带 `[LAN-ONLY]` 标记，可逐条回溯

### ❌ 未落实（明确列出，不是遗漏就是有意保留）

| 项 | 原因 / 影响 |
|---|---|
| 物理删除不可达的私有实现链（`post_request_` / `http_request_http` / `test_nat_type_` / `test_rendezvous_server_` / 版本检查解析函数 / mediator 的 `start_udp`/`start_tcp`/打洞/WebRTC 等，约 1500+ 行） | 与 TLS 缓存 / TCP 代理 / 编解码模块共享，**当前无法编译验证**，整链删除有悬空引用风险。功能上已不可达（所有 pub 出口已封） |
| 主界面「地址簿 / 组 / 登录」等云端 tab、移动端设置页的 ID/Relay 项 | UI 入口保留。Rust 层 `get_api_server()=""` + HTTP 总闸已让它们全部失效（点了会报错），但入口未隐藏 |
| `whitelist()` / `idWhitelist()` 两个 Dart 函数定义 | 调用已删，定义保留为未引用代码 |
| 加密握手 `identity_handshake` / `check_whitelist` 的 Rust 实现 | 按上一轮核查：直连 `secure=false` 本就不执行密钥交换、白名单空值空转，属「本就不生效」，未物理删除 |
| Web 端 `flutter/lib/web/bridge.dart` 的 `mainLoadLanPeers`（`UnimplementedError`） | Web 目标本就不支持 LAN 发现，未兜底 |
| 编译 / 运行 / 实测 | 见第 7 节 |

---

## 5. 使用方法（Windows + 192.168.3.x）

> 前提：先能构建（见第 7 节）。**不需要任何服务器、任何配置向导。**

1. 两端安装并启动；被控端 **21118 自动监听**，LAN 发现自动回应，无需勾选任何开关
2. 被控端设置**固定密码**（认证必需：`src/server/connection.rs:2536` 空密码返回 false；无人值守必须设）
3. 防火墙入站放行 **TCP 21118**（必需）、**UDP 21119**（发现，可选）
4. 主控端二选一：
   - ID 框直接输 `192.168.3.x`（也可 `192.168.3.x:21118` / `pc1:21118`）
   - 或点「发现」列表里的设备 —— 现在自动按 IP 连接
5. 连过一次 IP 会原样存入「最近连接」，以后一键重连
6. 输 9 位 ID 会提示 `[LAN-ONLY] only direct IP or host:port is allowed`，属预期行为
7. 不要开「仅允许出站连接」等模式；设置页已无 ID/中继服务器项

### 端口清单（改造后）

| 端口 | 协议 | 用途 | 状态 |
|---|---|---|---|
| 21118 | TCP 入站 | Direct IP Access 直连 | **保留，必需** |
| 21119 | UDP 广播 | LAN 发现 | **保留，可选** |
| 21115 / 21116 / 21117 / 21114 | TCP/UDP/HTTP | hbbs / hbbr / NAT 探测 / API | **不再使用** |

---

## 6. 验证清单（构建后自测）

| 检查项 | 期望 |
|---|---|
| 直连监听 | 日志 `Direct server listening on: ...21118`（`rendezvous_mediator.rs:1310`） |
| LAN 监听 | 日志 `lan discovery listener started`（`src/lan.rs:31`） |
| 无公网行为 | 日志中**不出现** `Testing nat`、`rendezvous mediator error`、`Software update`；`netstat -ano` 无对外 2111x 连接 |
| 抓包 | Wireshark 过滤 `ip.dst != 192.168.3.0/24`，应无 RustDesk 出站 |
| 发现列表 | 点列表项能连通（验证 `ip` 字段 Rust→Dart 全链路） |
| ID 输入 | 明确报错且不产生任何外连 |
| 状态灯 | 显示「就绪」（已强制 ready，见第 8 节注意） |

---

## 7. 编译与验证状态（重要）

| 项 | 状态 |
|---|---|
| `cargo` | ❌ 本机不可用（`command -v cargo` 无输出） |
| `dart` / `flutter` | ❌ 本机不可用 |
| `libs/hbb_common/` | ❌ **目录为空**，git 子模块未拉取，且本副本非 git 仓库，`cargo build` 必然失败 |
| 编译验证 | ❌ 未做 |
| 静态检查 | ✅ 对 19 个改动文件做了括号平衡粗检、逐段人工复核改动块结构；粗检因 Rust 生命周期/Dart 字符串插值会产生误报，不作为编译通过的证据 |
| 运行实测 | ❌ 未做（防火墙、跨 VLAN、真机连接、发现列表点击均未验证） |

**要构建必须先做**：`git clone --recurse-submodules` 补齐 `hbb_common` → 安装 vcpkg 依赖（libvpx / libyuv / opus / aom）→ `cargo check` → `flutter pub get` + `dart analyze`。建议在能编译的环境里先跑这两条命令，再按第 6 节自测。

---

## 8. 风险与已知影响

| 风险 | 说明 |
|---|---|
| **未编译验证（最高）** | 所有改动是静态审计结果。虽逐段检查了结构，但类型错误 / cfg 分支错误 / Dart 分析错误仍可能存在，必须实机编译 |
| 状态灯恒绿 | `get_connect_status()` 强制 ready，即使服务异常也不会显示错误状态 |
| 云端入口点击报错 | 地址簿 / 组 / 登录等 UI 仍可点，但 HTTP 被拒，会返回错误而非静默 |
| `--config` CLI / 2FA Telegram / 全部 HTTP API | 因 `post_request` / `http_request_sync` 总闸一并通过 `bail!` 拒绝，属预期但影响面较广 |
| 直连无传输加密 | `secure=false`（`rendezvous_mediator.rs` 的 `create_tcp_connection(..., false, ...)`），用户已明确不需要；仍需可信内网 + 固定密码 |
| LAN 广播不跨 VLAN | `255.255.255.255:21119` 只在同二层广播域；跨网段需手动输 IP 或用主机名 |
| 绿色版行为变化 | 原来 LAN 监听只在 `platform::is_installed()` 时启动，现在无条件启动；端口 21118/21119 冲突风险略增 |
| `common.rs` 模块级 allow | `#![allow(dead_code, unused_imports)]` 会抑制该模块全部同类警告，可能掩盖未来真实问题；如后续补齐编译环境，建议改为逐个函数 `#[allow(dead_code)]` |
| 与标准客户端互通 | 协议未改，标准 RustDesk 客户端仍可用 IP 直连本定制版；但本定制版无法再通过 ID 连接任何标准客户端 |

---

## 9. 回退 / 定位方式

- 全部改动统一标记 `[LAN-ONLY]`：`grep -rn "LAN-ONLY" src/ flutter/lib/`
- 本副本**非 git 仓库**，无法 `git diff` / `git checkout`；回退需按第 3 节清单逐项手工还原
- 若只需恢复「公网版行为」，最小还原点是 `src/rendezvous_mediator.rs:289-309`（`start_all`）与 `src/common.rs:1169/1568/1593/1851`（四个出口），其余多为 no-op
- 建议下次改动前先对 `src/` 与 `flutter/lib/` 做一次目录备份

---

## 9.1 关键代码事实（改造后仍成立）

| 事实 | 证据 |
|---|---|
| IP 直连发生在 `get_rendezvous_server()` 之前 | `src/client.rs:440-467`，命中后直接 `return` |
| 直连端口两端一致 | 被控端 `RENDEZVOUS_PORT+2=21118`（`rendezvous_mediator.rs:1285-1291` `get_direct_port()`），主控端 `RELAY_PORT+1=21118`（`client.rs:443`） |
| 直连 accept 用 `secure=false` | `rendezvous_mediator.rs:1345-1351` `create_tcp_connection(server, stream, addr, false, ...)`（`false` 在 `:1349`） |
| 白名单空值空转 | `src/server/connection.rs:1423-1449` `whitelist.is_empty()` → `return true` |
| 空密码不可连 | `src/server/connection.rs:2536-2539` `validate_password_plain` |
| IP 存在发现结果里 | `src/lan.rs:273-275` `ip_mac: HashMap::from([(addr.ip().to_string(), ...)])` |

---

## 10. 独立复核补记（文档落盘后二次核查）

上一轮写文档时因服务中断未收尾，本轮重新对**实际落盘代码**逐项核对，结论如下。**本轮源码仅补 3 处 `[LAN-ONLY]` 标记注释（纯注释、无逻辑改动）**，其余为文档修正。

### 10.1 疑似绕过总闸的四个点，逐一排除

| 疑点 | 实际代码 | 结论 |
|---|---|---|
| `ui_interface.rs:1123 pub fn get_api_server()` 会不会是另一条公网 URL 出口？ | `:1124` 转发 `crate::get_api_server(...)`，即 `common.rs:1169` 已封函数 | ✅ 已被总闸封死，返回 `""`；`core_main.rs:616`、`sync.rs:352`、`connection.rs:1526` 等调用点均拿到空 URL |
| `common.rs:1697 post_request_sync()` 是不是漏封的第四个 HTTP 出口？ | `:1698` 函数体只有 `post_request(url, body, header).await`，而 `post_request` 在 `:1568` 已 `bail!` | ✅ **已间接封闭，无需改动**。初判为遗漏，复核后纠正；`auth_2fa.rs:168`、`ui_interface.rs:963,1177`、`hbbs_http/account.rs:175` 全部走这条链 |
| `common.rs:1612,1712` 仍直调 `create_http_client_async`？ | 分别属于私有 `post_request_` / `get_http_response_async`，仅由 `post_request_http` / `http_request_http` 调用，而这两个只被已 `bail!` 的 pub 出口引用 | ✅ 不可达死代码，不发请求 |
| `hbbs_http/downloader.rs:71 download_file()` 会不会自动下载？ | 唯一触发点 `flutter_ffi.rs:2919`，由用户点击下载/更新按钮驱动 | ⚠️ **启动不触发，但手动点会连公网**。URL 来自 `get_download_data` 的更新包地址；设置页「网络/账号」tab 已隐藏，但关于页若仍有「检查更新」按钮，点击可能走到这里。属已知残留，见第 4 节「云端入口点击报错」 |

### 10.2 全局出口清点（复核后）

`common.rs` 中所有 pub HTTP 函数：`check_software_update:1006`（空）、`do_check_software_update:1117`（`Ok(())`）、`get_api_server:1169`（`""`）、`post_request:1568`（bail）、`post_request_with_status:1593`（bail）、`post_request_sync:1697`（间接 bail）、`http_request_sync:1851`（bail）。`ui_interface.rs:931,960` 与 `flutter_ffi.rs:1231` 均为这三条的封装。**未发现仍可达的自动公网 HTTP 路径。**

### 10.3 本轮文档修正（9 处，均为行号校准，非内容变更）

| 位置 | 原值 | 修正为 |
|---|---|---|
| 清单 #16 | `client.rs:5377` | `client.rs:5376-5377`（第二轮加固后移至 `:5381-5382`，见 11.1） |
| 清单 #21 | `peer_model.dart:15,42,61,107,160` | `:16,42,61,107,161` |
| 清单 #23 | `peers_view.dart:315` | `:315-318` |
| 清单 #30 | `flutter_ffi.rs:1197` | `:1197-1199` |
| 第 6 节直连日志 | `rendezvous_mediator.rs:1309` | `:1310` |
| 附表直连端口 | `rendezvous_mediator.rs:1288` | `:1285-1291`（`get_direct_port()`） |
| 附表 secure | `:1345 附近` | `:1345-1351`（`false` 在 `:1349`） |
| 附表 ip_mac | `lan.rs:276` | `lan.rs:273-275` |
| 附表 secure 结论 | 无 | 补精确实参位置 |

复核手段：`grep -rn "LAN-ONLY" src/ flutter/lib/` 取全部标记行号；逐个 `grep -n` 核对函数定义；`sed -n` 读取关键改动块；与文档清单逐条比对。`#1-15`、`#17-20`、`#22`、`#24-29`、`#31` 的行号经核对无误。

复核还发现一处**标记缺失**（非逻辑 bug）：`flutter/lib/common/widgets/peer_card.dart:71,77,1599` 三处连接改动原本没有 `[LAN-ONLY]` 注释，导致 `grep` 只能定位到 18 个文件、46 处，而文档声称「全部改动可定位」。已补行尾注释，当轮为 **19 文件 / 49 处**；第二轮加固（#32/#33）后为 **19 文件 / 51 处**，见 11.1。

### 10.4 括号平衡粗检（改进版）

对 19 个改动文件用「去注释、去字符串字面量、Rust 不误判生命周期 `'a`」的脚本重跑：

| 结果 | 文件 |
|---|---|
| ✅ 平衡（13 个） | `src/main.rs`、`src/rendezvous_mediator.rs`、`src/lan.rs`、`src/ui_interface.rs`、`src/server.rs`、`src/ipc.rs`、`src/updater.rs`、`src/hbbs_http/sync.rs`、`src/hbbs_http/record_upload.rs`；Dart 的 `peer_model.dart`、**`peer_card.dart`**、`peers_view.dart`、`main.dart` |
| ⚠️ 计数偏差（6 个） | `src/common.rs`、`src/client.rs`、`src/flutter_ffi.rs`、`src/ui.rs`、`flutter/lib/common.dart`、`flutter/lib/desktop/pages/desktop_setting_page.dart` |

偏差来源已逐一定位，均为**脚本词法能力不足**，不是改动引入的语法错误：`common.rs:1187` 的 `'['` 字符字面量、`client.rs:5147-5148` 的 `Key::Chr('[' as _)`、Dart 字符串插值 `${...}` 内嵌双引号导致正则提前截断（`common.dart:699`、`desktop_setting_page.dart:830` 等）。**被重写的核心函数 `start_all()`（`rendezvous_mediator.rs:289-309`）括号完整、结构正确**（已人工逐行核对）。

> 首版脚本把 Rust 生命周期 `'a` 误当字符字面量，曾对 8 个文件误报；改进后收敛到 6 个，且核心改动文件全部通过。

### 10.5 仍未消除的验证缺口

与第 7 节一致，**未编译、未运行**：本机无 `cargo` / `dart` / `flutter`，`libs/hbb_common/` 子模块为空。括号平衡粗检**不等于编译通过**；本轮所有结论仍是静态代码审计，不构成可运行保证。

---

## 11. 第二轮全量复核（从零重扫，不复用前述结论）

用户要求「重新完整梳理一遍，看看是否还有遗漏」。本轮**不使用第 10 节的结论**，改按两条独立线索重扫：① 所有可能出站的代码路径是否可达；② 已落盘的改动是否引入新问题。

**结论先行：没有发现「启动后仍会自动连公网」的遗漏。** 但发现了 **2 条隐式公网防线**（已物理加固）、**7 项功能/UI 残留**、**5 项改动副作用**（均未落实，列在下方），以及若干需要澄清的文档表述。

### 11.1 新发现 A：两条「隐式防线」—— 已加固（清单 #32 / #33）

这两处**当前确实不会外连**，但安全性依赖别的函数恰好返回空值/提前 return，而不是代码本身被移除。按「全部移除、只保留局域网」的终稿要求，属于没删干净。

| 路径 | 会做什么 | 当前为何不外连 | 加固 |
|---|---|---|---|
| `hc_connection()` `src/client.rs:5272` → `connect_tcp` 到 rendezvous_server（`:5302`）、`secure_tcp`、发 `HealthCheck` 长连接 | 会话建立后向公网 hbbs 建健康检查长连 | 三个调用点 `client/io_loop.rs:287`、`port_forward.rs:193,442` 的实参来自 `Client::start` 第二项 `(feedback, rendezvous_server)`；IP 直连在 `_start:446-458` 返回 `(0, "".to_owned())` → 原 `:5276` 的 `feedback == 0 \|\| ...is_empty()` 短路 | ✅ `:5280` 开头 `return None;`，加 `#[allow(unreachable_code)]` |
| `test_ipv6()` `src/common.rs:2647` → `Some(tokio::spawn(...))` 内 `default_stun_servers()` + `stun_ipv6_test()`（`:2600-2618` 的 `StunClient::query_external_address_async`） | 向公网 STUN 服务器发 UDP 查询包 | 触发点 ①`client.rs:501`（IP 直连已在 `:446` return，不可达）②`rendezvous_mediator.rs:1396` 的 `start_ipv6`（只被不可达的 `Self::start()` 消息循环调用）③`test_ipv6_sync:2854`（无调用者） | ✅ `:2651` 开头 `return None;`，加 `#[allow(unreachable_code)]` |

> 另：`test_bind_ipv6()` 的 `socket.connect(2001:4860:4860::8888:53)` 按源码注释只让内核选路由、**不发包**，不属于出站；加固后连这一步也不再执行。
> 加固使 `client.rs` 后半段行号 +5，清单 #16 已从 `:5376-5377` 同步为 `:5381-5382`；`common.rs` 的文档引用均在 `:2646` 之前，不受影响。

### 11.2 新发现 B：功能 / UI 残留 —— 未落实（建议按需清理）

| # | 项 | 证据 | 影响 |
|---|---|---|---|
| B1 | 多网卡 IP 选择不稳定 | `ui_interface.rs:875-886` 用 `HashMap.keys().find(...)` 取第一个；`lan.rs:326` 会累积多个 IP | **影响功能的真实风险**：多网卡机器可能选中 Docker 网桥 / VPN 虚拟网卡地址，发现列表点不通；且 HashMap 无序，每次刷新可能返回不同 IP。文档原仅写「取第一个」，未标注后果 |
| B2 | 云端外链仍在 | `common.dart:3781`（rustdesk.com）、`desktop_setting_page.dart:2615,2623`（隐私/官网）、`update_progress.dart:185`、`desktop_home_page.dart:438` | 均为 `onTap`/`onPressed` 手动触发，不自动出站；但属「相对应的功能」残留。`buildHelpCards` 依赖的 `updateUrl` 因删了 `checkUpdate()` 已恒空 |
| B3 | 移动端 ID/Relay 设置项 | `mobile/pages/settings_page.dart` | 第 4 节已列为未落实，本轮确认仍在 |
| B4 | `queryOnlines` 仍被调用 | `autocomplete.dart:236`、`connection_page.dart:436`、`peers_view.dart:320` → `flutter.rs:2399` → `query_online_states_` | `create_online_stream()` 已 bail → 返回「全部离线」，**无外连**，但每次输入/加载都打 debug 日志 |
| B5 | `RendezvousMediator::restart()` 9 处调用 | `flutter_ffi.rs:2201,2210,3109`、`ipc.rs:832,928,1161`、`ui_interface.rs:568,1209`、`rendezvous_mediator.rs:1692` | `restart()` 现只设原子标志 + 打 `"server restart"` 日志；`start_all` 已无 `wait_for_retry`，**无实际效果**，属死逻辑残留 |
| B6 | `--no-server` 启动参数 | `core_main.rs:90` → `start_server(false, true)` → `server.rs:725-762` else 分支不调 `start_all` | 用户主动传参才触发，被控端不监听。非默认行为，但文档「安装即监听」未标注此例外 |
| B7 | `hbbs_http/downloader.rs` | `flutter_ffi.rs:2919` | 第 10 节已述：手动点更新才下载，启动不触发 |

### 11.3 新发现 C：改动自身引入的副作用 —— 未落实

| # | 项 | 证据 | 影响 |
|---|---|---|---|
| C1 | **状态显示与服务实际状态矛盾** | `ui_interface.rs:637-645` 强制 `status_num=1`；`stop-service` 仍可由 `flutter_ffi.rs:2200,2208,3107` 及平台代码设置；`connection_page.dart:37` 用 `_svcStopped` 显示「启动服务」 | 用户点「停止服务」后 UI 显示已停，但 `direct_server:1300` 忽略该开关仍在监听 21118，状态灯又恒绿 → 三者不一致 |
| C2 | 守卫误伤端口转发 / RDP | `port_forward.rs:178,425` 调 `Client::start(id, ...)` | 传 9 位 ID 会被 `client.rs:393` bail。纯 IP 场景不受影响，但旧的地址簿 ID 记录不可用 |
| C3 | 历史 ID 记录连接报英文错 | `peer_card.dart` 回退 `peer.id`；`peer_model.dart:107` 的 `ip` 默认 `''` | 最近连接/地址簿里的 9 位 ID 会报 `[LAN-ONLY] only direct IP or host:port is allowed` |
| C4 | 错误文案硬编码英文 | `client.rs:394` | 未走 `translate()`，中文界面下突兀 |
| C5 | `get_lan_peers()` 过滤不完整 | `ui_interface.rs:880-884` | 只排 `127.` / `169.254.` / IPv6，未排其他保留段，也未优先选与本机同网段地址（与 B1 同源） |

### 11.4 全量排除清单（扫过且确认安全，带证据）

| 疑点 | 判定依据 |
|---|---|
| `start_all()` 会不会在桌面端根本不执行？ | `server.rs:724` 只在 `is_server=true` 分支；`core_main.rs:219` 传 `false`，但 `server.rs:750-758` 的 else 分支在 IPC 连不上时自动 `start_server(true, false)` → 仍会执行。**链条通** |
| 服务端打洞 / 中继 / IPv6 punch 是否可达 | `Self::start()` 消息循环（`:492`）、`start_udp`(`:610`)、`handle_request_relay`(`:693`→`create_relay_connection:server.rs:369`)、`handle_intranet`(`:706`)、`handle_punch_hole`(`:995`)、`start_ipv6`(`:1378`，调用点 `:723/:1054`) —— 全部只在已不再启动的 `Self::start()` 内，不可达。`create_relay_connection_` 的 bail 不会误伤直连 |
| 直连 accept 是否走加密/中继路径 | `direct_server:1345-1351` 传 `secure=false` 直接 `create_tcp_connection`；`:1439/:1620/:1639` 的 `true` 全在打洞路径 |
| 客户端其余 `connect_tcp` | `:832/840/890`（`_start` ID 路径，守卫已拦）、`:1812/:1872`（`request_relay`/`create_relay`，ID 路径）、`:5297`（`hc_connection_`，已加固） |
| 在线状态查询 | `query_online_states_`(`:5385`) 的 `create_online_stream()` bail → `Ok((vec![], ids))`，**不开 socket** |
| HTTP 出口 | `post_request_sync:1697` 调已封 `post_request`；`ui_interface:1123` 转发已封 `get_api_server`；`common.rs` 7 个 pub HTTP 函数全封闭（第 10.2 节）；`create_http_client_async` 两处直调属不可达私有实现 |
| Dart 独立网络 | 无 `HttpClient` / `package:http` / `Dio`；`dart:io` 仅用于 Platform/File。`sentry`/`FirebaseAnalytics` 全是注释（`main.dart:375,482,516`）；`url_launcher` 无自动触发 |
| DNS / 测试代码 | `lookup_host` 仅 `common.rs:2606`（不可达 STUN）与 `lan.rs:144`（本地）；`common.rs:3195+` 是 `#[cfg(test)]` |
| 端口修改是否需重启 | **不需要**：`direct_server:1305-1332` 循环内每次读 `get_direct_port()`，变化即重建监听。上一轮担心不成立 |
| `Peer.ip` 字段是否造成 Dart 编译缺口 | `fromJson:42`、构造默认 `:107`、`toJson:61`、`copy:161` 全覆盖；`Peer.loading()` 因默认值无需传参 → 完整 |

### 11.5 清单与统计核对

- 原 31 项**逐条比对属实**，无虚报；新增 #32/#33 → **33 项**。
- 标记数 **19 文件 / 51 处**（本轮 +2）；`grep -rn "LAN-ONLY" src/ flutter/lib/` 可完整定位。
- 括号粗检：`client.rs` / `common.rs` 加固前后计数完全一致，未引入新结构偏差（两文件原有的计数偏差仍为字符字面量误报，见 10.4）。
- 行号漂移：仅 `client.rs:5271` 之后的引用受影响，已同步 #16 与记忆日志。

### 11.6 复核后结论与优先级建议

**已彻底确认**：启动零公网出站；IP 直连、LAN 发现、按 IP 一键连三条链路完整；无遗漏的自动外连路径。

**仍建议处理（本轮未执行，等用户确认）**，按优先级：

1. **B1/C5 多网卡 IP 选择**：改为「优先与本机同网段 + 稳定排序」，否则 Docker/VPN 环境下发现列表可能点不通 —— 这是唯一可能影响实际可用性的项。
2. **C1 状态一致性**：要么在 UI 隐藏 `stop-service` 相关控件，要么让 `get_connect_status()` 读取该选项，避免"显示已停但服务在跑"。
3. **B2 云端外链 / B3 移动端设置项**：若要求界面也彻底局域网化，需逐项隐藏。
4. **C3/C4 英文报错**：改为中文 i18n 或明确提示「本版本仅支持 IP 直连」。
5. **B5 `restart()` 死逻辑**：可留（无害），也可清理调用点。

**最高风险仍是第 7 节**：全部改动未编译、未运行、未实测。建议在补齐 `hbb_common` 子模块后先跑 `cargo check` + `dart analyze`，再按第 6 节自测。
