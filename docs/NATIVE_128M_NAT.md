# 128 MB NAT 小机器原生部署（HY2 / VLESS）

这套部署运行两个原生进程：本项目的 Adapter，以及 Hysteria 2 或 Xray。无需 Docker。安装脚本使用 `/bin/sh`，支持 **Alpine 3.21 的 OpenRC** 和 Debian / Ubuntu 的 systemd；需有 root 权限。128 MB 是机器内存，不是进程内存保证：能否稳定运行取决于系统本身、在线人数和代理负载。脚本将 Go GC 设为 `GOGC=50`，并把 Adapter / 代理的软堆目标设为 `32MiB` / `48MiB`；这不是进程 RSS 的硬上限。上线后观察两进程 RSS 和系统剩余内存，用户较多时需增加内存或调整目标。

Alpine 首次部署建议先执行 `apk add ca-certificates curl`，确保 Adapter、Hysteria 能访问 HTTPS 面板、Cloudflare 和证书颁发机构；安装 VLESS 时还需 `apk add jq`，用于校验 Xray JSON。`curl` 也用于重装前上报最后一段流量。

## 先确认面板和 NAT

沿用本项目现有的 SSPanel-UIM WebAPI：`SSPANEL_BASE_URL`、`SSPANEL_MU_KEY`、`SSPANEL_NODE_ID` 分别填写面板地址、MuKey、**该协议对应的节点 ID**。面板需已启用 `webAPI`；启用 `checkNodeIp` 时，面板记录的节点 IP 应是这台 NAT 机器访问面板时的出口 IP。Adapter 从 `/mod_mu/users` 取得有效用户，并向 `/mod_mu/users/traffic` 上报流量。

NAT 网关把一个**公网端口**转发到本机**内部监听端口**：

| 协议 | NAT 公网端口示例 | 本机配置位置 | 内部监听端口示例 |
| --- | ---: | --- | ---: |
| HY2 | 30001/UDP | `native/hy2/server.yaml` 的 `listen` | 8443/UDP |
| VLESS | 30002/TCP | `native/vless/server.json` 的 `inbounds[0].port` | 443/TCP |

面板 `custom_config.offset_port_user` 填客户端看到的**公网端口**。此原生方案的内部监听端口固定由代理配置文件决定，不会按面板 `offset_port_node` 自动切换；如面板要求此字段，也填公网端口，并确保 NAT 转发规则指向本机内部端口。若修改公网端口，先更新 NAT 转发、面板节点和订阅配置。无需因此重启代理。管理端口 `18080/18081`、HY2 统计端口 `19999` 和 Xray API 端口 `10085` 只监听 `127.0.0.1`，不应转发到公网。

## 在较大的构建机准备二进制

**不要在 128 MB 机器上执行 `go build`。** 在有 Go 1.23+ 的构建机上，按 NAT 机器架构编译 Adapter；以下为 Linux x86_64 示例，ARM64 将 `GOARCH=arm64`：

```bash
mkdir -p bin
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
  -o bin/sspanel-hy2-adapter-linux ./cmd/sspanel-hy2-adapter
```

从 [Hysteria 官方发布页](https://github.com/apernet/hysteria/releases) 或 [Xray 官方发布页](https://github.com/XTLS/Xray-core/releases) 取与目标 CPU/系统匹配的 Linux 二进制，并检查官方发布的校验值。分别放为 `bin/hysteria-linux` 或 `bin/xray-linux`，赋可执行权限。把本仓库、目标架构的 Adapter 和代理二进制复制到 NAT 机器；不需要复制 Go 工具链或 Docker 镜像。安装脚本默认从 `bin/` 读取，也可通过 `ADAPTER_BIN`、`PROXY_BIN` 指向其他路径。

安装命令统一通过 `/bin/sh` 运行，文件传输即使丢失执行权限也可使用。也可直接运行 `sh scripts/install-native.sh hy2` 或 `sh scripts/install-native.sh vless`。

## HY2

在 NAT 机器仓库目录执行：

```bash
test -f native/hy2/server.env || cp native/hy2/server.env.example native/hy2/server.env
test -f native/hy2/adapter.yaml || cp native/hy2/adapter.yaml.example native/hy2/adapter.yaml
test -f native/hy2/server.yaml || cp native/hy2/server.yaml.example native/hy2/server.yaml
chmod 600 native/hy2/server.env native/hy2/adapter.yaml native/hy2/server.yaml
```

编辑 `server.env`，填面板地址、MuKey、节点 ID 和两个随机密钥。`server.env` 使用简单的 `KEY=value` 格式；不要加 `export`，也不要把值写成 shell 表达式。把相同的 Adapter Token、Stats Secret 填入 `server.yaml`，设置 NAT 内部 UDP 端口。

在 `server.yaml` 的 `acme` 段填写客户端 SNI 使用的域名、ACME 联系邮箱、Cloudflare API Token。域名的权威 DNS 应由 Cloudflare 管理。建议给 Token 仅授予对应 Zone 的 **DNS Edit** 和 **Zone Read** 权限，并保持该文件只供 root 读取（安装后复制到 `/etc/sspanel-native/hy2/server.yaml`，权限为 `600`）。DNS-01 不要求 NAT 提供公网 TCP 80/443；NAT 仍须把客户端使用的公网 UDP 端口转发到 `listen` 端口。Hysteria 会在首次启动时申请证书并自动续期；ACME 账户和证书持久保存在 `/var/lib/sspanel-native/hy2/acme`，升级时不要删除。证书申请需要机器能访问 Cloudflare API 和 ACME CA，并能查询公网 DNS。[Hysteria 的 Cloudflare DNS-01 配置](https://v2.hysteria.network/docs/advanced/ACME-DNS-Config/)与[完整 ACME 配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)列出了对应字段。

如果已有使用静态 `tls.cert` / `tls.key` 的 `server.yaml`，先备份该文件，再参照 `.example` 把整个 `tls` 段替换成 `acme` 段；同一个服务配置不能同时保留 `tls` 和 `acme`。安装脚本仍接受旧静态证书配置，只有改成 `acme` 后才会自动申请和续期。

```bash
sh ./scripts/install-native-hy2.sh
```

Alpine 3.21（root shell）检查：

```sh
rc-service sspanel-native-hy2-hysteria status
rc-service sspanel-native-hy2-adapter status
tail -n 80 /var/log/sspanel-native/sspanel-native-hy2-hysteria*.log
wget -qO- http://127.0.0.1:18080/healthz
```

Debian / Ubuntu 可用 `sudo sh ./scripts/install-native-hy2.sh` 安装，并用 `systemctl status sspanel-native-hy2-hysteria sspanel-native-hy2-adapter` 检查。

HY2 客户端凭据使用面板用户 UUID（若节点 API 不返回 UUID，可将 `adapter.yaml` 的 `credential_fields` 改为 `[passwd]`）。客户端连接地址和端口使用 NAT 公网地址与公网 UDP 端口，SNI 使用证书覆盖的域名。

## VLESS + REALITY / Vision

```bash
cp native/vless/server.env.example native/vless/server.env
cp native/vless/adapter.yaml.example native/vless/adapter.yaml
cp native/vless/server.json.example native/vless/server.json
chmod 600 native/vless/server.env native/vless/adapter.yaml native/vless/server.json
```

编辑 `server.env` 的面板值。用 `bin/xray-linux x25519` 生成 REALITY 密钥对，用 `openssl rand -hex 8` 生成 short ID。在 `server.json` 中填私钥、short ID、可从 NAT 机器直连且支持 TLS 1.3 的 `target`/`serverNames`，并把 inbound `port` 改成 NAT 转发到的内部 TCP 端口。服务端仅保存私钥；客户端使用生成的公钥。

```bash
sh ./scripts/install-native-vless.sh
```

Alpine 上用 `rc-service sspanel-native-vless-xray status` 和 `rc-service sspanel-native-vless-adapter status` 检查；Debian / Ubuntu 用 `sudo sh ./scripts/install-native-vless.sh` 安装后执行 `systemctl status`。Adapter 健康接口为 `http://127.0.0.1:18081/healthz`。

客户端 UUID 必须是 SSPanel 用户 UUID；节点的 `/mod_mu/users` 响应必须包含 `uuid`（现有部署的 `sort=11` 用于取得该字段）。VLESS 初始用户列表为空，Adapter 启动后从面板拉取并通过本地 Xray API 安装有效用户。面板分支还需支持生成 `vless://` 订阅，否则手工分发链接；本项目只负责服务端鉴权和记账。

## 检查与维护

```bash
journalctl -u sspanel-native-hy2-adapter -u sspanel-native-hy2-hysteria -n 100 --no-pager
journalctl -u sspanel-native-vless-adapter -u sspanel-native-vless-xray -n 100 --no-pager
systemctl show -p MemoryCurrent sspanel-native-hy2-adapter sspanel-native-hy2-hysteria
```

上面的 `journalctl` / `systemctl` 命令仅用于 systemd。Alpine 用 `rc-service` 查看状态；OpenRC 的进程日志保存在 `/var/log/sspanel-native/`，可用 `tail` 查看，并应按磁盘容量配置日志轮转。仅查看已安装的协议对应的服务即可。配置或二进制变更后，可再次执行该协议的安装脚本。重装前脚本先请求 Adapter 采集并上报未结算流量；若采集失败，脚本停止而不重启代理。状态文件分别保存在 `/var/lib/sspanel-native/hy2/traffic-state.json` 和 `/var/lib/sspanel-native/vless/xray-traffic-state.json`，升级时不要删除。HY2 证书续期由运行中的 Hysteria 处理，不需要定时重装脚本。

同一节点不要让 Docker 版和原生版同时运行，否则端口冲突且可能重复上报。切换前先停止对应 Compose 服务。公网仅开放 NAT 分配的 HY2 UDP 或 VLESS TCP 端口。
