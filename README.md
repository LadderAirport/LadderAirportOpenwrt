# LadderAirport OpenWrt

[LadderAirport](https://github.com/LadderAirport/LadderAirport) 节点 Agent 的 OpenWrt 软件源（feed）。用官方 SDK 为常见路由架构编译 `ladder-agent` `.ipk`，默认以 **uplink** 模式接入 Panel（NAT 友好，对齐 Android 节点）。

需要 Panel **支持 agent enroll / uplink** 的版本（与主仓文档一致）。

## 仓库关系（git submodule）

主仓通过 **Git submodule** 挂在本仓目录 `LadderAirport/`（GitHub 上该目录会显示为指向 `LadderAirport/LadderAirport` 的子模块，不是拷贝源码）：

```text
LadderAirportOpenwrt/
  .gitmodules              # LadderAirport → https://github.com/LadderAirport/LadderAirport.git
  LadderAirport/           # submodule（再含 agent/sing-box、agent/frp）
  net/ladder-agent/        # OpenWrt 包
```

克隆：

```bash
git clone --recurse-submodules https://github.com/LadderAirport/LadderAirportOpenwrt.git
# 或已 clone 后：
cd LadderAirportOpenwrt && make sync-submodule
# 等价于：git submodule update --init --recursive
# 构建只需主仓 + frp/sing-box；CI 不会拉 sing-box 的 android/apple 客户端子模块
```

升级主仓指针：进入 `LadderAirport/` 拉到目标 commit/tag，回到本仓提交 submodule 指针更新。

`make check-src` 校验 submodule 已就绪；包 Makefile 的 `LADDER_SRC` 默认指向 `./LadderAirport`。

## 安装（Release 软件源）

1. 在 [Releases](https://github.com/LadderAirport/LadderAirportOpenwrt/releases) 找到对应架构（路由器 `opkg print-architecture` 或看固件 arch）。
2. 添加自定义源（示例用完整 feed 归档解压后的 HTTP 目录，或单架构包 URL）：

```bash
# 查看本机架构
opkg print-architecture

# 示例：把 release 里的 <arch>.tar.gz 解到某 HTTP 目录后
# /etc/opkg/customfeeds.conf
src/gz ladderairport https://example.com/ladderairport/x86_64

opkg update
opkg install ladder-agent luci-app-ladder-agent
```

安装 LuCI 包后，在 **服务 → LadderAirport** 里配置节点并查看运行状态（需已安装 `luci`）。

未签名软件源时，按 OpenWrt 文档允许未校验安装（生产环境建议配置 `KEY_BUILD` 签名，见下方 CI）。

### 一条命令升级

路由器上已经有（或准备安装）`ladder-agent` 和 `luci-app-ladder-agent` 时，用 Release 里的 `ladder-update.sh`。它是 POSIX sh，OpenWrt 19.07 的 BusyBox ash 就能跑。脚本按 `opkg print-architecture` 选择架构包（例如 `aarch64_cortex-a55` / `cortex-a72` 会用 `aarch64_cortex-a53`），把每个 ipk 的 SHA256 和该架构 `Packages` 索引核对后再安装，先装 `ladder-agent`，再装 `luci-app-ladder-agent`。已有的 `/etc/config/ladder-agent` 不会被覆盖；opkg 另存的 `ladder-agent-opkg` 里多出来的选项名会列出来。

```sh
curl -fsSL https://github.com/LadderAirport/LadderAirportOpenwrt/releases/latest/download/ladder-update.sh | sh
```

路由器基础系统常常还没有 `curl`，可以用 `wget`（19.07 上一般是 `uclient-fetch`）：

```sh
wget -O - https://github.com/LadderAirport/LadderAirportOpenwrt/releases/latest/download/ladder-update.sh | sh
```

指定版本或架构：`sh -s -- v0.16.0-2`，或 `sh -s -- --arch aarch64_cortex-a53`。版本已经相同就跳过，要重装加 `--force`。看完新选项后删掉 `ladder-agent-opkg` 加 `--drop-opkg`。

访问不了 GitHub 时，把镜像前缀导出后再拉脚本（前缀会同时用在 API 和安装包下载上）：

```sh
export LADDER_GH_PREFIX=https://ghfast.top/
curl -fsSL "${LADDER_GH_PREFIX}https://github.com/LadderAirport/LadderAirportOpenwrt/releases/latest/download/ladder-update.sh" | sh
```

## LuCI

包 `luci-app-ladder-agent`（依赖 `ladder-agent` + `luci-base`）：

| 菜单 | 作用 |
|------|------|
| **服务 → LadderAirport → Status** | 进程是否在跑、版本、UCI 摘要、已下发配置 / 入站类型、持久化流量、启停 / 开机启用 |
| **服务 → LadderAirport → Configuration** | 编辑 `/etc/config/ladder-agent`；保存并应用后自动 `restart` |

状态数据来自本机脚本 `/usr/libexec/ladder-agent/luci-status.sh`（读 UCI、`pidof`、`current.json` / `traffic.json`），**不**把完整控制令牌显示在页面上。Panel 侧实时指标仍走 agent uplink/push。

## 配置与启动（命令行）

UCI 节 `ladder-agent.main`（文件 `/etc/config/ladder-agent`）：

| 选项 | 默认 | 说明 |
|------|------|------|
| `enabled` | `0` | `1` 启用 |
| `panel_url` | 空 | Panel HTTPS 根 URL |
| `node_id` | 空 | Panel 节点 ID |
| `token` | 空 | 长期控制令牌（`LADDER_TOKEN`） |
| `enroll_token` | 空 | 一次性注册令牌；启动时若 `token` 为空则调用 enroll 后清除 |
| `listen` | `0.0.0.0:50051` | gRPC 监听（默认 uplink 不对外服务） |
| `data_dir` | `/var/lib/ladder-agent` | 数据目录 |
| `uplink` | `1` | 默认 uplink |
| `uplink_serve_grpc` | `0` | uplink 下仍监听 gRPC |
| `uplink_ws` | `1` | WebSocket 实时通道 |
| `report_address` | 空 | 上报地址覆盖 |
| `egress_interface` | 空 | 本机出口逻辑接口（`wan` / `wwan` / `lan`）。空则跟随 Panel；非空时覆盖 Panel，并在下发前解析成当前 L3 设备 |
| `tls_sans` | 空 | 续签额外 SAN（push / serve_grpc） |
| `log_stderr` | `1` | procd 捕获 stderr |

在 Panel 创建 **uplink** 节点并复制注册信息后：

```bash
uci set ladder-agent.main.enabled='1'
uci set ladder-agent.main.panel_url='https://panel.example.com'
uci set ladder-agent.main.node_id='...'
uci set ladder-agent.main.enroll_token='...'   # 或直接 set token='...'
uci commit ladder-agent
/etc/init.d/ladder-agent enable
/etc/init.d/ladder-agent start
```

也可手动注册：

```bash
/usr/libexec/ladder-agent/enroll.sh
```

日志：`logread -e ladder-agent` 或 `logread -f`。

升级已安装的节点可以用上面的 `ladder-update.sh`，或继续用 `opkg` 更新本 feed 中的包。本仓库不附带 BBR helper。

## 本地 / 固件集成

```bash
git clone --recurse-submodules https://github.com/LadderAirport/LadderAirportOpenwrt.git
# feeds.conf:
# src-link ladderairport /path/to/LadderAirportOpenwrt
./scripts/feeds update ladderairport
./scripts/feeds install ladder-agent
make package/ladder-agent/compile V=s
```

## 版本

ipk 外壳版本和二进制里的核心版本分开注入，不再把去掉 `v` 的 `PKG_VERSION` 写进 `agent_version`。

| 上报字段 | `version` 包变量 | OpenWrt 取值 |
| --- | --- | --- |
| `agent_version`、`core_version` | `Version` | submodule `git describe --tags --always`，保留前缀 `v`。在标签上是 `vX.Y.Z`，否则是 `vX.Y.Z-N-gSHA`。不使用 `--abbrev=0` |
| `core_commit` | `Commit` | submodule 短 SHA（`git rev-parse --short`） |
| `client_type` | `ClientType` | `openwrt` |
| `client_version` | `ClientVersion` | `PKG_VERSION-rPKG_RELEASE`，例如 `0.15.12-r2` |
| `luci_version` | `LuciVersion` | 进程启动时读 `/usr/lib/opkg/info/luci-app-ladder-agent.control` 的 `Version`。文件不存在（未安装 LuCI）则留空，上报时省略 |

`PKG_VERSION` 仍是 submodule `git describe` 去掉 `v`（下划线改成连字符），ipk 文件名保持原样。`PKG_RELEASE` 只表示这个 feed 重新打包的次数。opkg 自己的版本字符串是 `0.15.12-2`；上报用的外壳版本多一个 `r`，写成 `0.15.12-r2`。

主仓 `agent/internal/version` 已经声明 `ClientType`、`ClientVersion`、`LuciVersion`，Ping、HTTP 和 WebSocket 上报会带上这些字段。本包只通过 ldflags 和进程启动时的 LuCI 读取赋值，不再在编译树里重复声明。若某个名字从 version 包消失，打包仍会补上同名变量，避免 ldflags 对空符号失败。空的 `LuciVersion` 由主仓在上报时省略。

## CI

- **分支目标**：OpenWrt `24.10`（`.ipk`）
- **工具**：[`openwrt/gh-action-sdk@v11`](https://github.com/openwrt/gh-action-sdk)
- **源码**：checkout 本仓后 `git submodule update --init LadderAirport`，再 init `agent/frp`、`agent/sing-box`
- **包名 / feed 名**：`ladder-agent`、`luci-app-ladder-agent` / `ladderairport`
- **架构**：`aarch64_cortex-a53`、`aarch64_generic`、`arm_cortex-a7`、`arm_cortex-a9`、`mipsel_24kc` 与 `x86_64`，`fail-fast: false`，并发上限 8
- **触发**：push/PR → CI artifacts；推送 `v*` tag → 聚合 feed 并发布 GitHub Release（feed 归档、各架构 `*.tar.gz`、`SHA256SUMS.txt`、`MANIFEST.txt`、`ladder-update.sh`）。`SHA256SUMS.txt` 含 feed 归档和每个架构包
- **上游跟踪**：[`bump-upstream.yml`](.github/workflows/bump-upstream.yml) 每天读取 [LadderAirport](https://github.com/LadderAirport/LadderAirport) 最新 Release。submodule 未到该 tag、且不是比该 tag 更新的提交时，自动开 bump PR。可选 secret `UPSTREAM_BUMP_TOKEN` 让这个 PR 直接触发 CI；未配置时工作流用默认 token 开 PR，并再 `workflow_dispatch` 一次 `ci.yml`（默认 token 创建的 PR 不会触发其它 workflow）
- **签名（可选）**：仓库 secret `KEY_BUILD`（usign）

构建 tags 与主仓一致：`with_quic,with_utls`；`GOTOOLCHAIN=auto` 以匹配主仓 `go 1.26.x`。

### 已知可能失败的架构

部分冷门架构若 Go 官方 toolchains 不支持，对应 CI job 会失败（不影响其它 arch）。若需排除，可在 package `DEPENDS` 中加 `@!arch` 限制。

## 目录

```text
.gitmodules
LadderAirport/                 # submodule → LadderAirport/LadderAirport
net/ladder-agent/              # 节点 daemon 包
  openwrtbind/                 # 逻辑接口 → L3 设备
  openwrtversion/              # 运行时读取 LuCI opkg control
  patches/openwrt-bind.patch   # 打进 agent 的两处调用
  scripts/core-identity.sh     # 核心版本（保留 v）和短 SHA
  files/version/openwrt_luci.go
luci-app-ladder-agent/         # LuCI 配置 + 状态
  htdocs/.../view/ladder-agent/{status,config}.js
  root/usr/share/luci/menu.d/
  root/usr/share/rpcd/acl.d/
  root/usr/lib/lua/luci/       # 仅 19.07（没有 menu.d 时）使用
  root/usr/libexec/ladder-agent/luci-status.sh
scripts/ladder-update.sh       # 路由器上一键安装 / 升级
.github/workflows/
  ci.yml
  release.yml
  bump-upstream.yml
```

## 出口接口

Panel 的「出口网卡」和本机 LuCI「Egress interface」最终都写成 sing-box 出站的 `bind_interface`（`SO_BINDTODEVICE`）。OpenWrt 上这个名字经常不是带着地址的那块网卡：UCI 的 `wan` 可能是 DSA 口，真正的三层设备是 `pppoe-wan`、`br-lan` 或 `wwan0`。Agent 在枚举和每次应用配置时读取 `ubus call network.interface dump`：

- 下拉列表用逻辑接口名，并带上该接口当前地址（地址在 `pppoe-wan` 上时，`wan` 这一行也能看到公网地址）。没有地址的下层口（`lan1`、仅链路本地地址的 DSA `wan`）不出现。L3 设备名和逻辑名不一样时，L3 名（例如 `pppoe-wan`）仍留在列表里，已经保存的值对得上。
- 已保存的 `wan` / `eth0.2` 会在 sing-box 启动前改写成当时的 `l3_device`。LuCI 里选了非空值时，用它覆盖 Panel 里的名字。
- 修改 `/etc/config/network`（例如 DHCP 改成 PPPoE）会重启 agent，下一次拉配置时重新解析。

不是 OpenWrt（没有 `ubus`）时这两步都不做，行为与上游 agent 相同。

## OpenWrt 19.07 / 19.06 与 AW1000 Ultra

没有官方 **19.06** 版本。19.x 的稳定版是 **19.07**（最后一版 19.07.10）。本 feed 的 CI 只打 **24.10** 的 `.ipk`（opkg，不是 25.12 起的 apk）。

两台容易被叫成 AW1000 的设备不是同一块板：

| 设备 | 硬件 | OpenWrt |
| --- | --- | --- |
| Arcadyan AW1000（官方支持） | Qualcomm IPQ8072A，目标 `qualcommax/ipq807x`，包架构 **`aarch64_cortex-a53`** | 23.05 起加入，24.10 / 25.12 有固件。架构已在本 feed 的 CI 矩阵里 |
| Arcadyan AW1000 Ultra（又名 5G Box Meteor） | MediaTek T750 或 T850 | 上游没有目标、没有架构。Linux 主线不支持这颗 SoC，**不能**靠本仓库打出一个能刷上的 19.06 包 |

因此 Ultra 刷着卖家提供的「OpenWrt 19.06」时，本仓库做不到对应目标的兼容构建：没有可交叉编译的 target，也没有 19.06 SDK。官方 AW1000 请用 23.05 或更新的系统，安装已有的 `aarch64_cortex-a53` 包。

在**真正的 19.07**（架构能对上，例如已有矩阵里的 `mipsel_24kc`、`arm_cortex-a7`）上，静态链接的 `ladder-agent`（`CGO_ENABLED=0`）不依赖 24.10 的 musl，init 使用的 procd / UCI / `ubus` 在 19.07 就有，包本身也不配防火墙，所以 fw3 和 fw4 的差别不挡住 uplink。LuCI 版本读的是 opkg 的 `/usr/lib/opkg/info/*.control`，19.07 和 24.10 都是这条路径。没做、也做不到的部分：

- 不在 CI 里用 19.07 SDK 重打 ipk，不能在这里证明 19.07 的 opkg 一定接受 24.10 打出来的包。
- 24.10 的 LuCI 页面是 `menu.d` + `'require view'` 的 JavaScript。19.07 的菜单来自 Lua `entry()`，不读 `menu.d`，也跑不了这套 JS。ipk 里另附了 Lua 控制器、CBI 和状态页，仅当系统里**没有** `/usr/share/luci/menu.d/luci-base.json` 时注册，避免和 21.02 及以后的菜单重复。这是配置回退，不是 Ultra 的固件移植。
- 没有为 19.07 单独改依赖名。`luci-base`、`ca-bundle`、`curl`、`jsonfilter` 在 19.07 沿用同样的包名；装不上时以 opkg 的报错为准。

## 许可证

包定义与脚本见本仓；Agent 运行时基于主仓及其 sing-box / frp 上游许可。
