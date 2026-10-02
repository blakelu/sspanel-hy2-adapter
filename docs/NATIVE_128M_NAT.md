# 128 MB NAT 小机器原生部署（HY2 / VLESS）

这套部署运行两个原生进程：本项目的 Adapter，以及 Hysteria 2 或 Xray。无需 Docker。安装脚本使用 `/bin/sh`，支持 **Ubuntu / Debian 的 systemd** 和 **Alpine 3.21 的 OpenRC**；需有 root 权限。128 MB 是机器内存，不是进程内存保证：能否稳定运行取决于系统本身、在线人数和代理负载。Ubuntu 的系统基础内存占用可能使 128 MB 机器无法稳定运行，应先用 `free -m` 检查可用内存。脚本将 Go GC 设为 `GOGC=50`，并把 Adapter / 代理的软堆目标设为 `32MiB` / `48MiB`；这不是进程 RSS 的硬上限。上线后观察两进程 RSS 和系统剩余内存，用户较多时需增加内存或调整目标。

## 交互式安装和管理（推荐）

当前仓库的预编译文件支持 **Linux x86_64（`uname -m` 为 `x86_64`）**。Ubuntu / Debian 需使用已运行 systemd 的普通服务器或 VPS；容器内若没有 systemd，安装器无法创建服务。先在 Ubuntu / Debian 的终端执行：

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl wget
curl -fL https://raw.githubusercontent.com/blakelu/sspanel-hy2-adapter/main/scripts/native-manager.sh \
  -o /tmp/sspanel-native-manager.sh
sudo sh /tmp/sspanel-native-manager.sh
```

安装 VLESS 时，管理脚本会通过 `apt-get` 安装缺少的 `jq`；也可预先运行 `sudo apt-get install -y jq`。首次运行需要联网访问 Ubuntu 软件源和本项目 GitHub Raw。Alpine 3.21 的 root shell 使用：

```sh
wget -O /tmp/sspanel-native-manager.sh \
  https://raw.githubusercontent.com/blakelu/sspanel-hy2-adapter/main/scripts/native-manager.sh && \
  sh /tmp/sspanel-native-manager.sh
```

菜单命令 `1` 安装、`2` 卸载全部项目服务和数据、`3` 重启、`4` 修改配置并重启、`0` 退出。也可直接传入命令，例如 Ubuntu 上运行 `sudo sh /tmp/sspanel-native-manager.sh 1`。安装完成后会创建 `/usr/local/sbin/sspanel-native-manager`，以后在 Ubuntu 上运行 `sudo sspanel-native-manager`，在 Alpine root shell 中直接运行即可。

安装时选择 HY2 或 VLESS；VLESS 再选择 REALITY 或 WebSocket + TLS（Cloudflare 橙云），修改配置时默认保留当前传输方式。依次填写 SSPanel 地址、MuKey、节点 ID、公网端口和 NAT 转发到本机的端口。**两项 NAT 端口默认相同**；若 NAT 是 `23008/UDP → 23008/UDP`，本机监听端口也应填 `23008`。WS 模式的公网端口是 Cloudflare 回源端口，客户端使用域名的 `443`，详见下方橙云部署章节。HY2 还需选择面板用户密码字段（`uuid` 或 `passwd`）、填写证书域名、ACME 邮箱、Cloudflare DNS API Token；REALITY 需目标域名和 SNI；WS/TLS 需橙云域名、WS 路径，再选择自动申请证书（邮箱、CF Token、Zone ID）或手动证书路径。Adapter Token、HY2 统计密钥、REALITY 私钥和 Short ID 直接回车即自动生成；修改配置时回车保留已有值，输入 `new` 重新生成。Cloudflare Token 和 MuKey 必须自行提供，不能随机生成。

脚本从本项目 GitHub `main` 的 `bin/` 下载 Adapter、Hysteria 或 Xray，依据仓库的 `bin/SHA256SUMS` 校验，再调用现有原生安装器创建服务并设置开机自启。若仓库是私有的或文件尚未推送，GitHub Raw 会返回 404，下载会停止且不会安装 404 文本。可用 `NATIVE_REPO_RAW_BASE` 指向同结构的可信镜像。配置和生成的密钥保存在 `/etc/sspanel-native/` 与 `/opt/sspanel-native/`，权限为 root 可读；HY2 证书和流量状态在 `/var/lib/sspanel-native/`。

命令 `2` 会停止并移除 HY2/VLESS 服务、项目二进制、配置、项目目录内的证书、流量状态、日志和管理器本身；不会删除现有 Git 仓库，也不会卸载系统共享的 `curl`、`jq` 等软件包。外部路径上的 WS/TLS 证书和私钥不由脚本删除。卸载前脚本尝试上报最后一段流量，失败时需要明确输入 `FORCE` 才会继续。REALITY 安装结束会显示 Public Key 和 Short ID；WS/TLS 会显示域名、路径、客户端参数和链接模板；本项目不会修改 SSPanel 的订阅生成器。

Alpine 首次部署建议先执行 `apk add ca-certificates curl`，确保 Adapter、Hysteria 能访问 HTTPS 面板、Cloudflare 和证书颁发机构；安装 VLESS 时还需 `apk add jq`，用于校验 Xray JSON。Ubuntu / Debian 对应的软件包为 `ca-certificates curl jq`（上面的交互安装会补齐缺少的包）。`curl` 也用于重装前上报最后一段流量。

## 先确认面板和 NAT

沿用本项目现有的 SSPanel-UIM WebAPI：`SSPANEL_BASE_URL`、`SSPANEL_MU_KEY`、`SSPANEL_NODE_ID` 分别填写面板地址、MuKey、**该协议对应的节点 ID**。面板需已启用 `webAPI`；启用 `checkNodeIp` 时，面板记录的节点 IP 应是这台 NAT 机器访问面板时的出口 IP。Adapter 从 `/mod_mu/users` 取得有效用户，并向 `/mod_mu/users/traffic` 上报流量。

NAT 网关把一个**公网端口**转发到本机**内部监听端口**：

| 协议 | NAT 公网端口示例 | 本机配置位置 | 内部监听端口示例 |
| --- | ---: | --- | ---: |
| HY2 | 30001/UDP | `native/hy2/server.yaml` 的 `listen` | 8443/UDP |
| VLESS | 30002/TCP | `native/vless/server.json` 的 `inbounds[0].port` | 443/TCP |

HY2 / REALITY 直连模式的面板 `custom_config.offset_port_user` 填客户端看到的**公网端口**；WS/TLS 橙云模式填 Cloudflare 入口端口 `443`。此原生方案的内部监听端口固定由代理配置文件决定，不会按面板 `offset_port_node` 自动切换；直连模式如面板要求此字段，也填公网端口，并确保 NAT 转发规则指向本机内部端口。若修改公网端口，先更新 NAT 转发，直连模式更新面板节点和订阅，橙云模式更新 Cloudflare 回源端口规则。无需因此重启代理。管理端口 `18080/18081`、HY2 统计端口 `19999` 和 Xray API 端口 `10085` 只监听 `127.0.0.1`，不应转发到公网。

Ubuntu 若已启用 UFW，还需放行**本机内部监听端口**，例如上表中的 HY2 用 `sudo ufw allow 8443/udp`，VLESS 用 `sudo ufw allow 443/tcp`；端口以实际配置为准。不要为了此部署开放本地管理端口，也无需仅为此步骤启用 UFW。

## 在较大的构建机准备二进制

不使用交互管理器时，按下面步骤手工部署。Ubuntu / Debian 先运行 `sudo apt-get update` 和 `sudo apt-get install -y ca-certificates curl`；VLESS 还需 `sudo apt-get install -y jq openssl`。

**不要在 128 MB 机器上执行 `go build`。** 在有 Go 1.23+ 的构建机上，按 NAT 机器架构编译 Adapter；以下为 Linux x86_64 示例，ARM64 将 `GOARCH=arm64`（ARM64 需手工部署，交互管理器只提供 x86_64 预编译文件）：

```bash
mkdir -p bin
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
  -o bin/sspanel-hy2-adapter-linux ./cmd/sspanel-hy2-adapter
```

从 [Hysteria 官方发布页](https://github.com/apernet/hysteria/releases) 或 [Xray 官方发布页](https://github.com/XTLS/Xray-core/releases) 取与目标 CPU/系统匹配的 Linux 二进制，并检查官方发布的校验值。分别放为 `bin/hysteria-linux` 或 `bin/xray-linux`，赋可执行权限。把本仓库、目标架构的 Adapter 和代理二进制复制到 NAT 机器；不需要复制 Go 工具链或 Docker 镜像。安装脚本默认从 `bin/` 读取，也可通过 `ADAPTER_BIN`、`PROXY_BIN` 指向其他路径。

安装命令统一通过 `/bin/sh` 运行，文件传输即使丢失执行权限也可使用。也可直接运行 `sh scripts/install-native.sh hy2` 或 `sh scripts/install-native.sh vless`。

## HY2

手工部署时，在 NAT 机器仓库目录执行（Ubuntu 需让当前用户能写入仓库中的 `native/`，安装命令再使用 `sudo`）：

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
sudo sh ./scripts/install-native-hy2.sh
```

Ubuntu / Debian 检查 systemd 服务、日志与本地健康接口：

```sh
sudo systemctl status sspanel-native-hy2-hysteria.service sspanel-native-hy2-adapter.service
sudo journalctl -u sspanel-native-hy2-hysteria -u sspanel-native-hy2-adapter -n 80 --no-pager
curl -fsS http://127.0.0.1:18080/healthz
```

Alpine 3.21 在 root shell 中改用 `sh ./scripts/install-native-hy2.sh` 安装，并运行：

```sh
rc-service sspanel-native-hy2-hysteria status
rc-service sspanel-native-hy2-adapter status
tail -n 80 /var/log/sspanel-native/sspanel-native-hy2-hysteria*.log
wget -qO- http://127.0.0.1:18080/healthz
```

HY2 客户端凭据使用面板用户 UUID（若节点 API 不返回 UUID，可将 `adapter.yaml` 的 `credential_fields` 改为 `[passwd]`）。客户端连接地址和端口使用 NAT 公网地址与公网 UDP 端口，SNI 使用证书覆盖的域名。

## VLESS + WebSocket + TLS（Cloudflare 橙云）

交互管理器选择 `1 安装 → 2 VLESS → 2 WebSocket + TLS`。已有 VLESS 使用 `4 修改配置并重启 → 2 VLESS` 切换传输方式；回车保留当前方式。REALITY 与 WS/TLS 共用 VLESS 服务，切换会替换该服务配置；HY2 不受影响。

填写开启橙云的域名、WebSocket 路径（默认 `/vless`），然后选择证书管理方式：

- `1 自动申请并续期`：填写 ACME 邮箱、Cloudflare DNS API Token 和 **Zone ID**（域名概览页）。建议 Token 仅授予目标 Zone 的 **DNS Edit / Zone Read** 权限。脚本通过 acme.sh 的 `dns_cf` 做 DNS-01 验证，申请 **Let’s Encrypt** 证书，无需开放公网 80，也无需关闭橙云。Token、Zone ID 和邮箱会保存为 root 可读的配置用于续期。[acme.sh 的 Cloudflare DNS API 说明](https://github.com/acmesh-official/acme.sh/wiki/dnsapi#1-cloudflare-option)。
- `2 手动指定路径`：填写覆盖该域名的 PEM 源站证书和私钥的绝对路径，可使用 Cloudflare Origin CA 或公开受信任证书；文件须预先放到服务器可读的位置。此模式不负责申请或续期外部证书。

新安装默认自动模式；已使用手动证书的旧配置默认保留手动方式。自动模式会下载并校验固定版本 acme.sh 3.1.4 及 Cloudflare DNS 插件，补齐 `openssl`，将证书和 ACME 状态保存在 `/opt/sspanel-native/acme-vless/<域名>/`（随 `NATIVE_MANAGED_DIR` 调整）。切换为手动方式或 REALITY 后，管理器删除专用续期任务；卸载全部时一并清理项目证书和 ACME 状态，不删除外部路径证书。

systemd 创建 `sspanel-native-vless-cert.timer`，每日检查并补跑关机期间错过的任务；Alpine OpenRC 在 `/etc/periodic/daily/` 安装专用脚本并启用 `crond`。acme.sh 根据证书的续期时间决定是否申请，不会每天强制重签。Xray 使用 `oneTimeLoading: false`，续期后的文件由 Xray 每小时自动热重载，无需重启代理或中断现有连接。[Xray 证书热重载说明](https://xtls.github.io/config/transports/tls.html#certificateobject)。

可手动运行 `sudo sspanel-native-manager --renew-vless-cert` 检查续期；不需要输入，尚未到续期时间会正常跳过。systemd 用 `journalctl -u sspanel-native-vless-cert.service` 查看结果，OpenRC 查看 `/var/log/sspanel-native/vless-cert-renew.log`。申请或续期需要服务器能访问 GitHub Raw（首次下载）、Cloudflare API、Let’s Encrypt 和公网 DNS；Token 到期或被撤销后需用菜单 `4` 更新。自动申请失败会停止配置流程，定时续期失败会保留现有证书并在下次重试。

Cloudflare 的 SSL/TLS 模式使用 **Full (strict)**，并开启 WebSockets。自动模式取得的是 Let’s Encrypt 证书；手动方式也可使用 Cloudflare Origin CA 证书。[Origin CA 配置说明](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)。

端口分三层：客户端始终连接 **橙云域名:443**；脚本询问的 NAT 公网端口是 **Cloudflare 回源端口**；本机端口是 NAT 转发到 Xray 的监听端口。例如 `客户端 → Cloudflare:443 → NAT:30002 → Xray:8443`。回源公网端口不是 `443` 时，必须在 Cloudflare 配置匹配该域名的 Origin Rule，将 destination port 改为该 NAT 公网端口；NAT、防火墙也须允许 Cloudflare 回源。[Cloudflare 回源端口规则](https://developers.cloudflare.com/rules/origin-rules/features/#destination-port)。

客户端及面板订阅配置：地址使用橙云域名，`offset_port_user=443`，传输 `ws`，TLS 开启，SNI 与 WS Host 均为该域名，路径与服务端一致，**flow 留空**，UUID 使用 SSPanel 用户 UUID。不要沿用 REALITY 的 flow、公钥或 Short ID。安装结束会显示可替换 `USER_UUID` 的链接模板；本项目不会修改面板订阅生成器。

WS 模式生成 `inbound_tag: vless-ws` 和 `xray.flow: ""`，Adapter 继续同步用户并统计流量。旧配置不填写 `xray.flow` 时仍默认 `xtls-rprx-vision`。切换 WS 时，管理器会更新不支持该配置的旧 Adapter，并在停止服务前校验；下载源必须同时发布新版脚本、Adapter 二进制和 SHA256SUMS。

## VLESS + REALITY / Vision

```bash
test -f native/vless/server.env || cp native/vless/server.env.example native/vless/server.env
test -f native/vless/adapter.yaml || cp native/vless/adapter.yaml.example native/vless/adapter.yaml
test -f native/vless/server.json || cp native/vless/server.json.example native/vless/server.json
chmod 600 native/vless/server.env native/vless/adapter.yaml native/vless/server.json
```

编辑 `server.env` 的面板值。用 `bin/xray-linux x25519` 生成 REALITY 密钥对，用 `openssl rand -hex 8` 生成 short ID。在 `server.json` 中填私钥、short ID、可从 NAT 机器直连且支持 TLS 1.3 的 `target`/`serverNames`，并把 inbound `port` 改成 NAT 转发到的内部 TCP 端口。服务端仅保存私钥；客户端使用生成的公钥。

```bash
sudo sh ./scripts/install-native-vless.sh
```

Ubuntu / Debian 用 `sudo systemctl status sspanel-native-vless-xray.service sspanel-native-vless-adapter.service` 和 `curl -fsS http://127.0.0.1:18081/healthz` 检查。Alpine 在 root shell 中改用 `sh ./scripts/install-native-vless.sh` 安装，再用 `rc-service sspanel-native-vless-xray status` 和 `rc-service sspanel-native-vless-adapter status` 检查。

客户端 UUID 必须是 SSPanel 用户 UUID；节点的 `/mod_mu/users` 响应必须包含 `uuid`（现有部署的 `sort=11` 用于取得该字段）。VLESS 初始用户列表为空，Adapter 启动后从面板拉取并通过本地 Xray API 安装有效用户。面板分支还需支持生成 `vless://` 订阅，否则手工分发链接；本项目只负责服务端鉴权和记账。

## 检查与维护

```bash
journalctl -u sspanel-native-hy2-adapter -u sspanel-native-hy2-hysteria -n 100 --no-pager
journalctl -u sspanel-native-vless-adapter -u sspanel-native-vless-xray -n 100 --no-pager
systemctl show -p MemoryCurrent sspanel-native-hy2-adapter sspanel-native-hy2-hysteria
```

上面的 `journalctl` / `systemctl` 命令用于 Ubuntu / Debian 的 systemd。Ubuntu 上查看实时日志可运行 `sudo journalctl -fu sspanel-native-hy2-adapter`（VLESS 则将服务名改为 `sspanel-native-vless-adapter`）。Alpine 用 `rc-service` 查看状态；OpenRC 的进程日志保存在 `/var/log/sspanel-native/`，可用 `tail` 查看，并应按磁盘容量配置日志轮转。仅查看已安装的协议对应的服务即可。配置或二进制变更后，可再次执行该协议的安装脚本。重装前脚本先请求 Adapter 采集并上报未结算流量；若采集失败，脚本停止而不重启代理。状态文件分别保存在 `/var/lib/sspanel-native/hy2/traffic-state.json` 和 `/var/lib/sspanel-native/vless/xray-traffic-state.json`，升级时不要删除。HY2 证书续期由运行中的 Hysteria 处理，不需要定时重装脚本。

同一节点不要让 Docker 版和原生版同时运行，否则端口冲突且可能重复上报。切换前先停止对应 Compose 服务。公网仅开放 NAT 分配的 HY2 UDP 或 VLESS TCP 端口。

Ubuntu / Alpine 日志若出现 `Exec format error`，先检查 `uname -m` 和 `sha256sum bin/hysteria-linux /usr/local/bin/hysteria`。本项目提供的 Linux amd64 Hysteria v2.12.3 的 SHA-256 为 `8c7a68a906998b747a0db87586e364f995fbfddb95693ae6e2fdb68a6e920d3e`。两处文件应一致；不一致时，重新解压匹配架构的交付包，并从 `bin/hysteria-linux` 重新安装。

OpenRC 的 `status: started` 只说明监督进程在运行。若 `wget -qO- http://127.0.0.1:18080/healthz` 仍提示 `Connection refused`，检查 `/var/log/sspanel-native/sspanel-native-hy2-adapter.err.log` 和 `.log`。Adapter 在首次成功读取面板用户之前不会开始监听，因此面板 URL、MuKey、节点 ID、DNS、TLS 或网络错误都可能使它反复启动失败。修正配置后先执行 `rc-service sspanel-native-hy2-adapter restart`，无需重启 Hysteria。

Ubuntu 上若健康接口无法连接，用 `sudo systemctl status sspanel-native-hy2-adapter.service` 和 `sudo journalctl -u sspanel-native-hy2-adapter -n 100 --no-pager` 查看失败原因；确认面板连接恢复后，再运行 `sudo systemctl restart sspanel-native-hy2-adapter.service`。VLESS 则将服务名改为 `sspanel-native-vless-adapter`。
