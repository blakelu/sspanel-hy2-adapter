# Hysteria 2 + WireGuard 链式中转：Debian 13 落地机

本文是 [HY2_RELAY.md](HY2_RELAY.md) 的 Debian 13 落地机专项说明。入口机仍运行项目提供的
Docker Compose 服务，落地机运行 Debian 13（trixie）原生 `wg-quick`，不在落地机运行
Hysteria、Adapter 或 SSPanel 组件。

```text
用户 ── HY2 ──> 入口机（Adapter 鉴权/统计）
                         │
                         └── direct outbound（源地址 10.77.0.1）
                                      │
                                  WireGuard
                                      │
                         Debian 13 落地机转发 + NAT
                                      │
                                  Internet
```

入口机的面板配置、Hysteria 配置和 Compose 启动方式不因落地机使用 Debian 13 而改变。
本文只展开 Debian 13 落地机相关操作，其余步骤直接引用通用文档。

## 前提和默认值

- 落地机是 Debian 13，使用 systemd，操作用户具有 `sudo` 权限；
- 落地机具有可访问的公网 IPv4；
- 云防火墙允许入口机公网 IP 访问落地 WireGuard UDP 端口；
- 入口机已经按项目要求安装 Docker Engine 和 Docker Compose 插件；
- 两台机器的系统时间正确。

本文示例沿用以下默认值：

| 用途 | 默认值 |
| --- | --- |
| 入口 WireGuard 接口 | `wg-relay` |
| 落地 WireGuard 接口 | `wg-landing` |
| 入口隧道地址 | `10.77.0.1/32` |
| 落地隧道地址 | `10.77.0.2/24` |
| 落地 WireGuard 端口 | 自定义，例如 `20230/UDP` |
| WireGuard MTU | `1420` |
| 入口策略路由表 | `51845` |

## 1. 生成 WireGuard 密钥

### 入口机

在项目目录执行：

```bash
mkdir -p wireguard-relay/keys wireguard-relay/wg_confs

docker run --rm --entrypoint /bin/sh \
  -v "$PWD/wireguard-relay/keys:/keys" \
  lscr.io/linuxserver/wireguard:latest \
  -c 'umask 077; wg genkey | tee /keys/privatekey | wg pubkey > /keys/publickey; wg genpsk > /keys/presharedkey'
```

### Debian 13 落地机

安装 Debian 13 的 WireGuard 工具和 iptables 兼容前端：

```bash
sudo apt-get update
sudo apt-get install -y wireguard-tools iptables
```

`wireguard-tools` 包已经包含 `wg`、`wg-quick` 和 `wg-quick@.service`，无需另建 systemd
服务。生成落地机密钥：

```bash
sudo install -d -m 700 /etc/wireguard
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/landing-private.key; wg pubkey < /etc/wireguard/landing-private.key > /etc/wireguard/landing-public.key'
```

双方只需交换：

- 入口机的 `wireguard-relay/keys/publickey`；
- 落地机的 `/etc/wireguard/landing-public.key`；
- 入口机生成的 `wireguard-relay/keys/presharedkey`。

不要复制或发送任何一方的私钥。预共享密钥也应通过安全渠道传递。

## 2. 配置 Debian 13 落地机

### 全新部署

把项目中的 `wireguard.landing.example.conf` 放在落地机项目目录，然后安装为
`wg-quick` 配置：

```bash
sudo install -m 600 wireguard.landing.example.conf /etc/wireguard/wg-landing.conf
sudoedit /etc/wireguard/wg-landing.conf
```

查看默认公网网卡：

```bash
ip -4 route show default
```

输出中的 `dev` 后面是公网网卡名，例如 `eth0`、`ens3` 或 `enp0s6`。编辑
`/etc/wireguard/wg-landing.conf`，替换以下占位符：

- `REPLACE_LANDING_PRIVATE_KEY`：`/etc/wireguard/landing-private.key` 的内容；
- `REPLACE_RELAY_PUBLIC_KEY`：入口机公钥；
- `REPLACE_PRESHARED_KEY`：双方相同的预共享密钥；
- `REPLACE_LANDING_PORT`：落地机监听的 UDP 端口，例如 `20230`；
- `REPLACE_RELAY_PUBLIC_IP`：入口机公网 IPv4；
- `REPLACE_PUBLIC_INTERFACE`：落地机默认公网网卡。

模板中已经限定 WireGuard 对端地址为 `10.77.0.1/32`，并通过 `PostUp`/`PostDown`
管理 INPUT、FORWARD 和 MASQUERADE 规则。不要把 `AllowedIPs` 改成 `0.0.0.0/0`。

### 从旧 Docker 落地迁移

如果落地机以前运行 LinuxServer WireGuard 容器，先在旧项目目录正常停止容器，让旧配置的
`PostDown` 清理防火墙规则：

```bash
docker compose --env-file .env.wireguard-landing \
  -p wireguard-landing \
  -f docker-compose.wireguard-landing.yaml \
  down

ip link show wg-landing 2>/dev/null || true
```

如果最后一条仍显示接口，再删除残留接口：

```bash
sudo ip link delete wg-landing
```

安装工具并复用原配置：

```bash
sudo apt-get update
sudo apt-get install -y wireguard-tools iptables
sudo install -d -m 700 /etc/wireguard
sudo install -m 600 \
  wireguard-landing/wg_confs/wg-landing.conf \
  /etc/wireguard/wg-landing.conf
sudoedit /etc/wireguard/wg-landing.conf
```

确认 `ListenPort`、入口机公网 IP 和公网网卡仍然正确。如果旧配置没有当前模板中的 INPUT
放行规则，请按 `wireguard.landing.example.conf` 更新 `PostUp` 和 `PostDown`。复用原配置和
密钥时，不需要重新交换公钥或预共享密钥。

## 3. 开启 IPv4 转发

Debian 13 的 `systemd-sysctl` 不再读取 `/etc/sysctl.conf`，本地配置应写入
`/etc/sysctl.d/`：

```bash
printf 'net.ipv4.ip_forward=1\n' | sudo tee /etc/sysctl.d/99-hy2-wireguard-landing.conf
sudo sysctl --system
sysctl net.ipv4.ip_forward
```

最后一条应输出：

```text
net.ipv4.ip_forward = 1
```

## 4. 启动落地 WireGuard

启动 `wg-landing` 并设置开机自动启动：

```bash
sudo systemctl enable --now wg-quick@wg-landing
sudo systemctl status wg-quick@wg-landing --no-pager
sudo wg show wg-landing
sudo ss -lunp | grep ':20230'
```

把 `20230` 换成实际的 `ListenPort`。同时在云服务商防火墙中仅允许入口机公网 IP 访问该
UDP 端口。模板内的 INPUT 规则不能替代云防火墙规则。

若服务启动失败，查看完整日志：

```bash
sudo journalctl -u wg-quick@wg-landing -e --no-pager
```

常见原因包括配置中仍有 `REPLACE_...` 占位符、私钥格式错误、公网网卡名写错、端口已被
占用，或旧容器留下同名 WireGuard 接口。

## 5. 配置入口机和 SSPanel

落地机启动后，入口机按通用文档继续操作：

1. [配置入口机 WireGuard](HY2_RELAY.md#3-配置入口机-wireguard)；
2. [在 SSPanel 新建入口节点](HY2_RELAY.md#4-在-sspanel-新建入口节点)；
3. [配置并启动入口 Hysteria](HY2_RELAY.md#5-配置并启动入口-hysteria)。

入口配置中的 `REPLACE_LANDING_DOMAIN` 和 `REPLACE_LANDING_PORT` 必须指向 Debian 13
落地机；`REPLACE_LANDING_PUBLIC_KEY` 必须使用该落地机的公钥。Hysteria 的
`bindIPv4` 继续保持 `10.77.0.1`。

## 6. 验证

先在入口机检查 WireGuard 握手和隧道：

```bash
docker compose --env-file .env.hy2-relay \
  -p hy2-relay \
  -f docker-compose.hy2-relay.yaml \
  exec wireguard wg show wg-relay

docker compose --env-file .env.hy2-relay \
  -p hy2-relay \
  -f docker-compose.hy2-relay.yaml \
  exec wireguard ping -I 10.77.0.1 -c 3 10.77.0.2
```

再在 Debian 13 落地机检查：

```bash
sudo wg show wg-landing
sudo iptables -S INPUT
sudo iptables -S FORWARD
sudo iptables -t nat -S POSTROUTING
```

入口客户端连接 HY2 节点后应满足：

1. 访问 `https://api.ipify.org` 显示 Debian 13 落地机公网 IP；
2. 两端 `wg show` 的发送和接收字节持续增长；
3. Adapter 日志出现用户认证和流量采集；
4. SSPanel 只增加入口节点的用户流量。

HY2 代理 TCP 和 UDP，不代理 ICMP。客户端不能用公网 `ping` 判断 HY2 是否可用。

## 7. 服务管理和清理

查看、重启或停止 Debian 13 落地服务：

```bash
sudo systemctl status wg-quick@wg-landing --no-pager
sudo systemctl restart wg-quick@wg-landing
sudo systemctl stop wg-quick@wg-landing
```

停止服务会执行配置中的 `PostDown`，删除该配置添加的 INPUT、FORWARD 和 NAT 规则。
如需同时取消开机启动：

```bash
sudo systemctl disable --now wg-quick@wg-landing
```

这不会删除 `/etc/wireguard/wg-landing.conf` 或密钥。入口机的停止和数据清理注意事项见
[通用文档的“停止与清理”](HY2_RELAY.md#停止与清理)。

参考：[Debian 13 发布说明](https://www.debian.org/releases/trixie/releasenotes)、
[Debian 13 wireguard-tools 文件列表](https://packages.debian.org/trixie/amd64/wireguard-tools/filelist)、
[WireGuard Quick Start](https://www.wireguard.com/quickstart/)。
