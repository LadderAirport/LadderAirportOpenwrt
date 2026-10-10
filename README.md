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

首期不包含 systemd 式远程升级助手与 BBR helper；升级请用 `opkg` 更新本 feed 中的包。

## 本地 / 固件集成

```bash
git clone --recurse-submodules https://github.com/LadderAirport/LadderAirportOpenwrt.git
# feeds.conf:
# src-link ladderairport /path/to/LadderAirportOpenwrt
./scripts/feeds update ladderairport
./scripts/feeds install ladder-agent
make package/ladder-agent/compile V=s
```

## CI

- **分支目标**：OpenWrt `24.10`（`.ipk`）
- **工具**：[`openwrt/gh-action-sdk@v11`](https://github.com/openwrt/gh-action-sdk)
- **源码**：checkout 本仓后 `git submodule update --init LadderAirport`，再 init `agent/frp`、`agent/sing-box`
- **包名 / feed 名**：`ladder-agent`、`luci-app-ladder-agent` / `ladderairport`
- **架构**：`aarch64_cortex-a53`、`aarch64_generic`、`arm_cortex-a7`、`arm_cortex-a9`、`mipsel_24kc` 与 `x86_64`，`fail-fast: false`，并发上限 8
- **触发**：push/PR → CI artifacts；推送 `v*` tag → 聚合 feed 并发布 GitHub Release
- **签名（可选）**：仓库 secret `KEY_BUILD`（usign）

构建 tags 与主仓一致：`with_quic,with_utls`；`GOTOOLCHAIN=auto` 以匹配主仓 `go 1.26.x`。

### 已知可能失败的架构

部分冷门架构若 Go 官方 toolchains 不支持，对应 CI job 会失败（不影响其它 arch）。若需排除，可在 package `DEPENDS` 中加 `@!arch` 限制。

## 目录

```text
.gitmodules
LadderAirport/                 # submodule → LadderAirport/LadderAirport
net/ladder-agent/              # 节点 daemon 包
luci-app-ladder-agent/         # LuCI 配置 + 状态
  htdocs/.../view/ladder-agent/{status,config}.js
  root/usr/share/luci/menu.d/
  root/usr/share/rpcd/acl.d/
  root/usr/libexec/ladder-agent/luci-status.sh
.github/workflows/
  ci.yml
  release.yml
```

## 许可证

包定义与脚本见本仓；Agent 运行时基于主仓及其 sing-box / frp 上游许可。
