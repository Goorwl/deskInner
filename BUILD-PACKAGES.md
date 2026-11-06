# 安装包构建可行性与执行方案（macOS M4 + Windows）

> 生成时间：2026-11-06
> 对象：本工作区 `rustdesk-master`（RustDesk 1.5.1，**已做纯内网定制改造，19 文件 / 51 处 `[LAN-ONLY]` 标记 / 33 项改动**）
> 性质：环境实测 + 代码静态审计。**本轮没有编译、没有产出任何安装包**。

---

## 0. 一句话结论

**这台 Windows 机器现在编译不了这两个安装包，macOS M4 的 `.dmg` 在任何 Windows 上都编译不出来。**

- Windows 包：缺整套工具链（Rust / Flutter / MSVC C++ / vcpkg / LLVM / NASM / bridge 生成文件），补齐后可在本机编译。
- macOS arm64 包：官方流水线要求 `macos-14` runner + Xcode + `codesign` + `create-dmg`（`flutter-build.yml:927-945, 1139`），Windows 无 macOS SDK、无 Apple 签名工具，**不存在可用的交叉编译路径**。
- 唯一现实解法：**把改造后的源码推到 GitHub，用仓库自带的官方流水线出两个包**；或分别在 Windows 机器和 Mac 机器上本地构建。

---

## 1. 本机环境实测（不是推测）

### 1.1 工具链

| 工具 | 状态 | 备注 |
|---|---|---|
| `cargo` / `rustc` / `rustup` | ❌ 缺失 | `~/.cargo`、`~/.rustup` 均不存在 |
| `dart` / `flutter` | ❌ 缺失 | 无 Flutter SDK 残留目录 |
| `vcpkg` | ❌ 缺失 | `vcpkg.json` 依赖 aom / libvpx / libyuv / opus / libjpeg-turbo / ffmpeg / mfx-dispatch，需编译 |
| MSVC C++ 工具集 | ❌ 缺失 | 有 `C:\Program Files\Microsoft Visual Studio\2022\`，但只有 `Installer`、`Shared`，**无 `VC\Tools\MSVC`**，`cl.exe` 不在 PATH |
| Windows SDK | ✅ 部分有 | `10.0.19041.0`、`10.0.26100.0` |
| `cmake` | ✅ 有 | MinGW 附带的 cmake |
| `clang` / `LLVM` / `nasm` / NSIS / 7z | ❌ 缺失 | CI 要求 LLVM 15.0.6（`flutter-build.yml:29`） |
| `git` | ✅ 2.55.0 | 但工作区**不是 git 仓库**（无 `.git`） |
| Python | ✅ 3.13.14 | `build.py` 可用 |
| 磁盘 C: | ✅ 232 GB 可用 | 空间不是瓶颈 |
| 已有构建产物 | ❌ 无 | 无 `target/`，无 `flutter/build/` |

### 1.2 源码完整性

| 项 | 状态 | 证据 |
|---|---|---|
| `libs/hbb_common/` | ❌ **空目录（0 文件）** | `.gitmodules` 指向 `https://github.com/rustdesk/hbb_common`，未拉取 |
| `flutter/lib/generated_bridge.dart` | ❌ 缺失 | gitignored，CI 由 `bridge.yml` 的 `generate_bridge` job 生成 |
| `src/bridge_generated.rs` | ❌ 缺失 | 同上 |
| `src/bridge_generated.io.rs` | ❌ 缺失 | 同上 |
| `flutter/lib/web/bridge.dart` | ✅ 存在 2098 行 | Web 桥接是提交的 |
| `libs/portable/generate.py` | ✅ 存在 | Windows 自解压安装包生成器 |
| `Cargo.toml` git 依赖 | ⚠️ 20 个 | `:67-107` 全是 `github.com/rustdesk-org/*` fork |

**bridge 缺失是硬阻塞**：`AGENTS.md` 明确要求不要本地跑 `flutter_rust_bridge_codegen`，官方做法是 CI 生成后作为 artifact 下载（`flutter-build.yml:197-201`）。

### 1.3 网络实测（关键，有解法）

| 目标 | 直连 / 默认 | 结论 |
|---|---|---|
| `github.com` | HTTP 000（超时） | 不通 |
| `codeload.github.com` | HTTP 000 | 不通 |
| `raw.githubusercontent.com` | HTTP 000 | 不通 |
| `static.rust-lang.org` | HTTP 200 | 通 |
| `index.crates.io/config.json` | HTTP 200 | 通 |
| `storage.googleapis.com` | HTTP 400（域名根路径正常响应） | 通 |
| `gitee.com` | HTTP 200 | 通 |

**可用的代理配置（已实测成功）**：

- shell 里被 WorkBuddy 的本地代理 `http://127.0.0.1:56268` 覆盖，该代理不放行 GitHub；
- Windows 系统代理是 `192.168.3.100:20185`（出口 IP `104.28.158.97`），走它 + 关闭证书吊销检查即可访问 GitHub：

```bash
# curl：--ssl-no-revoke 是关键，否则 schannel 报 CRYPT_E_REVOCATION_OFFLINE
curl --ssl-no-revoke --proxy http://192.168.3.100:20185 https://github.com   # HTTP 200

# git：必须切 openssl 后端，schannel 后端仍会报吊销检查失败
git -c http.sslBackend=openssl \
    -c http.proxy=http://192.168.3.100:20185 \
    -c https.proxy=http://192.168.3.100:20185 \
    ls-remote https://github.com/rustdesk/hbb_common HEAD
# 实测返回：fae47e024dd83cef6aaecde0aa7d11731df11649  HEAD
```

> 结论：**依赖拉取这一环可以打通**，瓶颈不在网络，在工具链和 macOS 平台限制。

---

## 2. 两个平台各自的阻塞矩阵

| 阻塞项 | Windows x64 `.exe` | macOS M4 `.dmg` |
|---|---|---|
| 本机缺 Rust / Flutter / vcpkg / MSVC | 阻塞 | 阻塞 |
| `hbb_common` 空、bridge 三文件缺失 | 阻塞 | 阻塞 |
| 目标平台 SDK | Windows SDK 已有 | ❌ **必须 macOS + Xcode**，Windows 无法提供 |
| 打包工具 | `libs/portable/generate.py` + 签名模板（可本地跑） | `create-dmg`、`codesign`、公证 `rcodesign`（仅 macOS） |
| 官方 CI runner | `windows-2022`（`flutter-build.yml:168-186`） | `macos-14` / `aarch64-apple-darwin`（`:934-945`） |
| 结论 | 本机补齐工具链后可做 | **本机不可能，必须 Mac 或 CI** |

---

## 3. 官方流水线给出的精确配方（代码证据）

### 3.1 版本矩阵（`flutter-build.yml:24-46`）

| 变量 | 值 |
|---|---|
| `RUST_VERSION` / `SCITER_RUST_VERSION` | `1.75` |
| `MAC_RUST_VERSION` | `1.81`（macOS 必需，cidre 依赖） |
| `FLUTTER_VERSION` | `3.24.5`（Windows x64 / macOS x86_64） |
| `FLUTTER_MACOS_ARM_VERSION` | `3.44.9`（**M 系列专用**，3.24.5 的引擎在 arm64 macOS 上有 bug） |
| `LLVM_VERSION` | `15.0.6` |
| `VERSION` | `1.5.1` |
| `VCPKG_COMMIT_ID` | `9e593bb18ea69cc5095e012465dcd675a822ed0d` |
| `FLUTTER_RUST_BRIDGE_VERSION` | `1.80.1`（`bridge.yml:11`），用 Flutter `3.22.3` / `3.44.8` 各生成一份 bridge |

### 3.2 Windows x64 安装包

```bash
# flutter-build.yml:338
python3 .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram
# flutter-build.yml:473 / build.py:969-998 生成本地一键产物
cd libs/portable && python3 ./generate.py -f ../../flutter/build/windows/x64/runner/Release/ -o . -e ...
```

- `build.py:969-998` 链路：`cargo build --locked --features ... --lib --release` → `flutter build windows --release` → `generate.py` → **`rustdesk-1.5.1-install.exe`**
- CI 产物名：`rustdesk-1.5.1-x86_64.exe`（自解压安装包，`:476`）
- 另有 MSI 工程 `res/msi/`（WiX + MSBuild，CI `:485-524`），需要 `setup-msbuild` 与签名模板。

### 3.3 macOS M4 (arm64) 安装包

```bash
# flutter-build.yml:1105-1113（arm64 专用）
MIN_MACOS_VERSION=12.3   # sed 改 build.py / Podfile / Cargo.toml / project.pbxproj
./build.py --flutter --hwcodec --unix-file-copy-paste --screencapturekit

# flutter-build.yml:1139
create-dmg --icon "RustDesk.app" 200 190 ... rustdesk-1.5.1-aarch64.dmg \
    ./flutter/build/macos/Build/Products/Release/RustDesk.app
```

- `build.py:948-952` 内部：`FLUTTER_XCODE_ARCHS=arm64 flutter build macos --release` → 拷 `service` → `create-dmg`
- 目标：`aarch64-apple-darwin`，`vcpkg-triplet: arm64-osx`，`--screencapturekit` 必带
- 签名/公证（`:1173-1175`）需要 `MACOS_P12_BASE64` + Apple 开发者账号；**无证书只能出未签名 dmg**，安装时需手动「仍要打开」/ `xattr -dr com.apple.quarantine`

### 3.4 bridge 是必须先解决的一步

`flutter-build.yml:197-201` 的 Windows job 明确 `needs: [generate-bridge]` 并下载 artifact：
- x64 Windows → `bridge-artifact`（Flutter 3.22.3 生成）
- arm64 macOS → `bridge-artifact-flutter-3.44`（Flutter 3.44.8 生成）

---

## 4. 三条可执行路径

### 路径 A（推荐）：GitHub Actions 一次出两个包

唯一能同时拿到 M4 dmg 和 Windows exe、且不用自己装几十 GB 工具链的方案。

1. 补齐 `hbb_common` 子模块（用上面实测可用的 git + openssl 代理命令），把**改造后的源码**作为一个完整仓库推到你的 GitHub（建议 fork `rustdesk/rustdesk` 后覆盖，保留 `.github/workflows/`）。
2. 在 Actions 里手动触发 **`Flutter Nightly Build`**（`flutter-nightly.yml` 有 `workflow_dispatch`），它会调用 `flutter-build.yml` 并传 `upload-artifact: true`。
3. 从 run 的 Artifacts 下载：
   - `rustdesk-1.5.1-x86_64.exe`（Windows 自解压安装包）
   - `rustdesk-1.5.1-aarch64.dmg`（macOS M4，未签名）
4. 无 secrets 时，签名/公证步骤会自动跳过（`if: env.MACOS_P12_BASE64 != null`、`:1173`），不影响出 unsigned 包。

**代价**：公开仓库免费；私有仓库消耗 Actions 额度；全流水线会连带跑 Android/Linux 等 job，耗时较长。

### 路径 B：本机只做 Windows 包

需要按顺序装（**约 10–30 GB 下载、数小时编译**）：

| # | 组件 | 说明 |
|---|---|---|
| 1 | Visual Studio 2022 Build Tools | 勾「使用 C++ 的桌面开发」+ Windows 11 SDK + MSVC v143；当前只有空壳 |
| 2 | Rust 1.75 | `rustup toolchain install 1.75` + `x86_64-pc-windows-msvc` |
| 3 | Flutter 3.24.5 | 解压后 PATH，`flutter config --enable-windows-desktop` |
| 4 | vcpkg @ `9e593bb` | `VCPKG_DEFAULT_HOST_TRIPLET=x64-windows-static`，install `vcpkg.json` 全部依赖（ffmpeg 最慢） |
| 5 | LLVM 15.0.6 / NASM 2.16 | bridge 与 aom 汇编需要 |
| 6 | bridge 文件 | 需 `flutter_rust_bridge_codegen 1.80.1` + `cargo-expand 1.0.95`，或直接从 CI artifact 下载 |
| 7 | `hbb_common` | 按实测代理命令 clone 到 `libs/hbb_common/` |
| 8 | 构建 | `python build.py --portable --flutter --hwcodec --vram` → `rustdesk-1.5.1-install.exe` |

> 第 6 步是本机最麻烦的一环（`AGENTS.md` 明确不建议本地生成 bridge）。**路径 A 会自动帮你做掉。**

### 路径 C：Mac 本机做 M4 包

在一台 Apple Silicon Mac 上：装 Xcode、Rust 1.81、Flutter 3.44.9、`brew install llvm create-dmg pkg-config`、NASM 2.16.03、vcpkg `arm64-osx`，然后按 3.3 的命令构建。产物 `rustdesk-1.5.1-aarch64.dmg`。

---

## 5. 最高风险：先过编译关，别先打包

**33 项内网改造从没编译过**（`LAN-ONLY-FEASIBILITY.md` 第 7/10/11 节反复标注：无 `cargo`、无 `dart`、`hbb_common` 为空，全部是静态审计）。推到 CI 或装完工具链后，**第一次构建大概率因改造引入的编译错误失败**，典型风险点：

| 改动 | 潜在编译问题 |
|---|---|
| `rendezvous_mediator.rs` 重写 `start_all()` + 清理 import | 删掉 `join_all` / `Instant` / `RwLock` 后是否有残留引用；`#[allow(unreachable_code)]` 用法 |
| `common.rs` 加模块级 `#![allow(dead_code, unused_imports)]` | 掩盖真实错误，且 `bail!` 早退后类型是否仍匹配 |
| `client.rs` `hc_connection` / `test_ipv6` 早退 | `return None;` 后原实现不可达，返回类型一致性 |
| `peer_model.dart` 加 `String ip` | 所有 `Peer(...)` 构造点是否都给了默认值 |
| `peers_view.dart` `_startCheckOnlines()` 置空 | 局部变量 `p` / `_queryInterval` 是否变成未使用警告导致 `dart analyze` 失败 |

**建议顺序**：`cargo check --features flutter,hwcodec` → `dart analyze` → 再打包。这比直接构建安装包省大量时间。

---

## 6. 本轮实际改动清单（诚实区分）

| # | 项 | 状态 |
|---|---|---|
| 1 | 实测工具链、网络、代理、磁盘、源码完整性 | ✅ 已落实 |
| 2 | 定位官方 CI 两平台配方与精确版本、产物名 | ✅ 已落实 |
| 3 | 找到 GitHub 可达的代理配置（curl / git 双验证） | ✅ 已落实 |
| 4 | 落盘本文件 `BUILD-PACKAGES.md` | ✅ 已落实 |
| 5 | 追加工作区记忆日志 | ✅ 已落实 |
| 6 | 编译出 Windows 安装包 | ❌ **未落实**（工具链缺失，未擅自安装） |
| 7 | 编译出 macOS M4 安装包 | ❌ **未落实**（Windows 平台不可能，需 Mac / CI） |
| 8 | 补齐 `hbb_common` 子模块（选定路径 A 后执行） | ✅ 已落实，见第 8 节 |
| 9 | 建立可推送本地仓库（977 文件 + 正确 gitlink） | ✅ 已落实 |
| 10 | 配置仓库级 GitHub 代理 / 行尾策略 / 排除内部文档 | ✅ 已落实 |
| 11 | 追加第 8 节「路径 A 执行细则」 | ✅ 已落实 |
| 12 | 推送到 GitHub 并触发 CI | ❌ **未落实**（需要你的仓库地址与推送凭据） |
| 13 | 编译出 Windows / macOS 安装包 | ❌ **未落实**（必须由 CI 产出） |
| 14 | 源码编译验证 `cargo check` / `dart analyze` | ❌ 未落实 |

**本轮源码 0 改动**（未改任何 `.rs` / `.dart`），未产生任何 `.exe` / `.dmg` / `.msi` 产物。

---

## 7. 未验证项

- 所有结论基于静态审计与网络探测，**未实际执行任何构建命令**。
- `flutter-build.yml` 是 `workflow_call` 型，fork 仓库无 secrets 时各 job 的跳过条件未在真实 CI 跑过验证。
- 未签名 macOS dmg 在 M4 上的实际安装行为未实测（Apple Gatekeeper 需手动放行）。
- 代理 `192.168.3.100:20185` 的稳定性、以及 Cargo 的 libgit2 是否能复用该 openssl 代理配置，未验证。
- 本机安装 VS Build Tools 需管理员权限并可能要求重启，未执行。

---

## 8. 路径 A 执行细则（2026-11-06 追加）

用户已选定「GitHub Actions 一次出两个包」，本节记录**已完成的本地准备**与**剩余待你执行的 3 步**。

### 8.1 已完成（本地，可直接推送）

| 项 | 结果 |
|---|---|
| 子模块版本 | 通过 GitHub API 查 `refs/tags/1.5.1` 得到 `hbb_common` commit = `fae47e024dd83cef6aaecde0aa7d11731df11649`，克隆后 `HEAD` 与之一致 |
| 克隆方式 | 首次 clone 被代理中途掐断（SSL EOF），改用 `http.version=HTTP/1.1` + `--filter=blob:none --depth 1` 成功，33 个文件 |
| 本地仓库 | `git init -b main`，commit `0b1a060`，**977 个文件**，工作区干净 |
| 子模块形态 | `git ls-files -s libs/hbb_common` = `160000 fae47e0... 0`，是**正确 gitlink**，CI 的 `submodules: recursive` 会拉到 |
| bridge 文件 | 三个缺失文件保持 gitignore（根 `.gitignore:22-23,46`、`flutter/.gitignore:44-45`），由 CI 的 `generate-bridge` job 生成，符合 `AGENTS.md` 约定 |
| 不推送的内容 | `.git/info/exclude` 排除 `.workbuddy/`、`LAN-ONLY-FEASIBILITY.md`、`BUILD-PACKAGES.md`。**本地生效、不进版本库**，避免内网信息与工作区记忆外泄 |
| 行尾保护 | 全局 `core.autocrlf=true` 会在下次 checkout 时把工作区批量转成 CRLF，已设仓库级 `core.autocrlf=false`；`.gitattributes` 的 `* text=auto` 仍保证入库为 LF |
| 推送代理 | 仓库级已配 `http.sslBackend=openssl`、`http.proxy`/`https.proxy`=`192.168.3.100:20185`、`http.version=HTTP/1.1`，**推送时无需再带 `-c` 参数** |
| 改造完整性 | `git grep -c "LAN-ONLY" -- '*.rs' '*.dart'` 命中 19 个文件，与第 3 节清单一致 |

> 这些配置只写在 `.git/config` 和 `.git/info/exclude`，不会随 push 上传。

### 8.2 你需要执行的 3 步

**① 建空仓库**：在 GitHub 新建一个**空**仓库（不要勾 README / License / .gitignore，避免推送冲突）。公开仓库 Actions 免费；私有仓库消耗额度。

**② 绑定远端并推送**（代理已配好）：

```bash
cd /c/Users/wule/Downloads/rustdesk-master
git remote add origin https://github.com/<你的账号>/<仓库名>.git
git push -u origin main
```

认证用 GitHub PAT 或 Git Credential Manager；**不要把 token 拼进 remote URL**（会明文留在 `.git/config` 和 shell 历史）。

**③ 触发构建**：仓库 → `Actions` → 左侧 **Flutter Nightly Build** → `Run workflow`（分支 `main`）。它调用 `flutter-build.yml` 并传 `upload-artifact: true`（`flutter-nightly.yml:11-16`）。公开仓库可跑约 1–2 小时。

### 8.3 取包位置

在 run 页面底部 `Artifacts`：

| 产物 | 来源 job |
|---|---|
| `rustdesk-1.5.1-x86_64.exe` | `x86_64-pc-windows-msvc`（`flutter-build.yml:561`） |
| `rustdesk-1.5.1-aarch64.dmg` | `aarch64-apple-darwin`（`flutter-build.yml:1194`） |

全流水线会连带跑 Android / iOS / Linux 等 job，其中依赖签名 secrets 的可能报红 —— **这些失败不影响上面两个 artifact**，只看对应两个 job 是否绿。

### 8.4 未签名 dmg 在 M4 上怎么用

没有 Apple Developer ID 证书，签名与公证步骤会自动跳过（`flutter-build.yml:1173-1175` 的 `if` 条件），产物是 unsigned dmg。在 Mac 上：

```bash
xattr -dr com.apple.quarantine /Applications/RustDesk.app
# 或：系统设置 → 隐私与安全性 → 「仍要打开」
```

### 8.5 首次 CI 大概率会失败（提前说明）

33 项 `[LAN-ONLY]` 改造**从没编译过**。第一个容易挂的是 `generate-bridge` job —— 它要对改造后的 Rust 源码做 `cargo expand`，语法/类型错误会在这里先暴露。

**处理方式**：把失败 job 的日志贴给我，我按真实报错修（不改方案、不回退终稿决策），再提交新 commit 重跑。这属于正常迭代，不是路径 A 不可行。

### 8.6 如需撤销本地准备

```bash
git remote remove origin
git config --unset http.proxy
git config --unset https.proxy
```

`.git/info/exclude` 里删掉三行即可让分析文档重新进入待提交列表。
