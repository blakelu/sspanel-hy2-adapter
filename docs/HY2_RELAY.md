# Hysteria 2 + WireGuard 通用链式中转

该部署把“面板鉴权和记账”与“最终公网出口”分离：

```text
用户 ── HY2 ──> 入口机（Adapter 鉴权/统计）
                         │
                         └── direct outbound（源地址 10.77.0.1）
                                      │
                                  WireGuard
                                      │
                               落地机转发 + NAT
                                      │
                                  Internet
```

入口 Hysteria 的 `direct` outbound 固定绑定 WireGuard 地址 `10.77.0.1`。入口机上的源
地址策略路由只把 `10.77.0.1` 发起的连接送进 WireGuard，因此不会改变宿主机默认路由，
也不会把 HY2 面向公网客户端的 QUIC 回包错误地送到落地机。

落地机不运行 Hysteria、不连接 SSPanel，只负责 WireGuard 解封装、IP 转发和 NAT。
SSPanel 因而只收到入口节点的用户流量。整个转发路径支持 IPv4 TCP 和 UDP，不需要
GOST、SOCKS5 或第二层 HY2。

## 前提和默认规划

这套 Compose 使用 host 网络创建 WireGuard 接口，只适用于 Linux Docker 主机。需要：

- 入口机域名解析到入口机公网 IP；
- 落地机具有可访问的公网 IPv4；
- 两台机器的宿主机内核支持 WireGuard；
- 落地机放行 `51820/UDP`，来源限制为入口机公网 IP；
- 入口机放行客户端使用的 HY2 UDP 端口。

模板默认值：

| 用途 | 默认值 |
| --- | --- |
| 入口 WireGuard 接口 | `wg-relay` |
| 落地 WireGuard 接口 | `wg-landing` |
| 入口隧道地址 | `10.77.0.1/32` |
| 落地隧道地址 | `10.77.0.2/24` |
| 落地 WireGuard 端口 | `51820/UDP` |
| 入口策略路由表 | `51845` |
| Adapter 管理地址 | `127.0.0.1:18082` |
| Hysteria Stats 地址 | `127.0.0.1:19998` |

如果这些接口、地址、端口或路由表与现有服务冲突，应在两个 WireGuard 配置、Hysteria
`bindIPv4` 和 Compose 健康检查中同步修改。

## 1. 生成 WireGuard 密钥

私钥只保存在生成它的机器上。双方只交换公钥；预共享密钥由任意一方生成一次，再通过
安全渠道交给另一方。

入口机项目目录：

```bash
mkdir -p wireguard-relay/keys wireguard-relay/wg_confs

docker run --rm \
  -v "$PWD/wireguard-relay/keys:/keys" \
  lscr.io/linuxserver/wireguard:latest \
  sh -c 'umask 077; wg genkey | tee /keys/privatekey | wg pubkey > /keys/publickey; wg genpsk > /keys/presharedkey'
```

落地机项目目录：

```bash
mkdir -p wireguard-landing/keys wireguard-landing/wg_confs

docker run --rm \
  -v "$PWD/wireguard-landing/keys:/keys" \
  lscr.io/linuxserver/wireguard:latest \
  sh -c 'umask 077; wg genkey | tee /keys/privatekey | wg pubkey > /keys/publickey'
```

需要交换：

- 入口机的 `wireguard-relay/keys/publickey`；
- 落地机的 `wireguard-landing/keys/publickey`；
- 入口机生成的 `wireguard-relay/keys/presharedkey`。

不要复制或发送任何一方的 `privatekey`。

## 2. 配置并启动落地机

复制模板：

```bash
cp .env.wireguard-landing.example .env.wireguard-landing
cp wireguard.landing.example.conf wireguard-landing/wg_confs/wg-landing.conf
chmod 600 .env.wireguard-landing wireguard-landing/wg_confs/wg-landing.conf
```

查找落地机默认公网网卡：

```bash
ip route show default
```

编辑 `wireguard-landing/wg_confs/wg-landing.conf`，替换：

- `REPLACE_LANDING_PRIVATE_KEY`：落地机私钥；
- `REPLACE_RELAY_PUBLIC_KEY`：入口机公钥；
- `REPLACE_PRESHARED_KEY`：双方相同的预共享密钥；
- `REPLACE_PUBLIC_INTERFACE`：上一步得到的默认公网网卡，例如 `eth0`、`ens3` 或
  `enp0s6`。

开启并持久化 IPv4 转发：

```bash
sudo sysctl -w net.ipv4.ip_forward=1
printf 'net.ipv4.ip_forward=1\n' | sudo tee /etc/sysctl.d/99-hy2-wireguard-landing.conf
```

启动：

```bash
docker compose --env-file .env.wireguard-landing \
  -p wireguard-landing \
  -f docker-compose.wireguard-landing.yaml \
  up -d

docker compose --env-file .env.wireguard-landing \
  -p wireguard-landing \
  -f docker-compose.wireguard-landing.yaml \
  logs -f wireguard
```

云防火墙只允许入口机公网 IP 访问 `51820/UDP`。如果宿主机 INPUT 链末尾有统一
REJECT/DROP，还需要在它之前放行入口机：

```bash
sudo iptables -I INPUT 1 -p udp -s REPLACE_RELAY_PUBLIC_IP --dport 51820 -j ACCEPT
```

WireGuard 配置中的 `PostUp` 会在容器启动时把严格限定到 `10.77.0.1/32` 的 FORWARD
规则插入到链首，并添加 MASQUERADE；因此不会被 Docker 或系统已有的末尾 REJECT 抢先
拦截。容器正常停止时 `PostDown` 会删除这些规则，不需要另外持久化。

## 3. 配置入口机 WireGuard

复制模板：

```bash
cp wireguard.relay.example.conf wireguard-relay/wg_confs/wg-relay.conf
chmod 600 wireguard-relay/wg_confs/wg-relay.conf
```

编辑 `wireguard-relay/wg_confs/wg-relay.conf`，替换：

- `REPLACE_RELAY_PRIVATE_KEY`：入口机私钥；
- `REPLACE_LANDING_PUBLIC_KEY`：落地机公钥；
- `REPLACE_PRESHARED_KEY`：双方相同的预共享密钥；
- `REPLACE_LANDING_DOMAIN`：落地机域名或公网 IP。

入口机使用宽松反向路径检查，避免 WireGuard 返回流量被严格 `rp_filter` 丢弃：

```bash
sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
sudo sysctl -w net.ipv4.conf.default.rp_filter=2

printf '%s\n' \
  'net.ipv4.conf.all.src_valid_mark=1' \
  'net.ipv4.conf.all.rp_filter=2' \
  'net.ipv4.conf.default.rp_filter=2' |
  sudo tee /etc/sysctl.d/99-hy2-wireguard-relay.conf
```

先只启动 WireGuard：

```bash
docker compose --env-file .env.hy2-relay \
  -p hy2-relay \
  -f docker-compose.hy2-relay.yaml \
  up -d wireguard
```

检查握手、策略路由和落地出口：

```bash
docker compose --env-file .env.hy2-relay \
  -p hy2-relay \
  -f docker-compose.hy2-relay.yaml \
  exec wireguard wg show wg-relay

ip rule show | grep 'from 10.77.0.1'
ip route show table 51845
ping -I 10.77.0.1 -c 3 10.77.0.2
curl -4 --interface 10.77.0.1 https://api.ipify.org
```

最后一条命令必须显示落地机公网出口 IP。若不正确，暂时不要启动 Hysteria，先检查
WireGuard 握手、落地机 IP 转发、FORWARD 和 NAT 规则。

## 4. 在 SSPanel 新建入口节点

节点连接地址和 SNI 都使用入口域名。下面以入口端口 `18445` 为例：

```json
{
  "offset_port_user": 18445,
  "offset_port_node": 18445,
  "sni": "relay.example.com",
  "allow_insecure": false,
  "obfs": "",
  "obfs_password": "",
  "up_mbps": 0,
  "down_mbps": 0
}
```

记录新节点 ID。启用面板 `checkNodeIp` 时，节点地址解析出的 IP 必须是入口机调用面板
时使用的出口 IP。这里的 SNI 是入口域名，不是落地机域名。

## 5. 配置并启动入口 Hysteria

复制模板：

```bash
cp .env.hy2-relay.example .env.hy2-relay
cp config.docker-hy2-relay.example.yaml config.docker-hy2-relay.yaml
cp hysteria.relay-server.example.yaml hysteria.relay-server.yaml
chmod 600 .env.hy2-relay hysteria.relay-server.yaml
chmod 644 config.docker-hy2-relay.yaml
```

填写 `.env.hy2-relay` 的面板地址、MuKey、新入口节点 ID、Adapter Token 和 Stats Secret。

编辑 `hysteria.relay-server.yaml`：

- `listen` 改成面板入口端口，例如 `:18445`；
- `REPLACE_RELAY_DOMAIN` 使用入口域名；
- 填写入口域名对应的 ACME 邮箱和 Cloudflare Token；
- Adapter Token 和 Stats Secret 必须与 `.env.hy2-relay` 一致；
- 保持 `bindIPv4: 10.77.0.1`，它是只让业务出站进入 WireGuard 的关键配置。

向公网放行入口 HY2 UDP 端口。如果 INPUT 链末尾有统一 REJECT/DROP：

```bash
sudo iptables -I INPUT 1 -p udp --dport 18445 -j ACCEPT
```

启动全部入口服务：

```bash
docker compose --env-file .env.hy2-relay \
  -p hy2-relay \
  -f docker-compose.hy2-relay.yaml \
  up -d --build

docker compose --env-file .env.hy2-relay \
  -p hy2-relay \
  -f docker-compose.hy2-relay.yaml \
  ps
```

该 Compose 使用 host 网络，`18082` 和 `19998` 都明确只监听 `127.0.0.1`。入口端口直接
由 `hysteria.relay-server.yaml` 的 `listen` 决定，不包含 `port-sync`；修改端口时需要同步
更新面板配置和 Hysteria 配置。

## 6. 验证流量与记账

查看日志：

```bash
docker compose --env-file .env.hy2-relay \
  -p hy2-relay \
  -f docker-compose.hy2-relay.yaml \
  logs -f adapter wireguard hysteria
```

使用面板订阅连接入口节点后：

1. 访问 `https://api.ipify.org`，结果应为落地机公网 IP；
2. `wg show wg-relay` 的发送和接收字节应增长；
3. Adapter 日志应出现用户认证和周期性流量采集；
4. SSPanel 只应增加入口节点的用户流量。

HY2 代理用户的 TCP/UDP，但不代理 ICMP。`ping 10.77.0.2` 只用于检查服务器之间的
WireGuard 隧道；不能通过客户端 `ping` 公网地址来判断 HY2 是否可用。

## 停止与清理

正常停止 Compose 会执行 WireGuard `PostDown`，清除策略路由和 NAT：

```bash
docker compose --env-file .env.hy2-relay \
  -p hy2-relay -f docker-compose.hy2-relay.yaml down

docker compose --env-file .env.wireguard-landing \
  -p wireguard-landing -f docker-compose.wireguard-landing.yaml down
```

如果入口容器被强制终止导致策略规则残留，可以执行：

```bash
sudo ip rule del from 10.77.0.1/32 table 51845 priority 10000 2>/dev/null || true
sudo ip route flush table 51845
sudo ip link delete wg-relay 2>/dev/null || true
```

不要使用 `down -v`，除非明确要删除 Adapter 流量 checkpoint 和 ACME 账户/证书数据。

## 多个落地机

同一 WireGuard 接口不能把相同的 `0.0.0.0/0` 同时交给多个 peer。要同时使用多个落地
机，需要为每个落地分别创建 WireGuard 接口、隧道源地址和策略路由表，并在 Hysteria
中增加对应的 direct outbound，再通过 ACL 选择。只切换单个默认落地时，修改 `wg-relay`
的 peer 后重启 WireGuard 即可。

协议参考：[Hysteria 2 direct outbound](https://v2.hysteria.network/docs/advanced/Full-Server-Config/#customizing-direct-outbound)、
[WireGuard Quick Start](https://www.wireguard.com/quickstart/)、
[LinuxServer WireGuard Docker](https://docs.linuxserver.io/images/docker-wireguard/)。
