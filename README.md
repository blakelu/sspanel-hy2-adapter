# SSPanel-UIM HY2 / VLESS Adapter

一个独立的 Go 服务，用 SSPanel-UIM 用户数据为 Hysteria 2 提供 HTTP Auth，或通过 Xray gRPC API 动态管理 VLESS + REALITY / XTLS Vision 用户，并把两种协议的用户流量增量上报到 SSPanel-UIM WebAPI。

## 工作方式

```text
HY2 客户端 ──auth──> Hysteria 2 ──POST /auth──> Adapter ──> SSPanel API 或 MySQL
                                      │
                                      └── GET HY2 /traffic ──增量──> SSPanel /users/traffic

VLESS 客户端 ──REALITY/Vision──> Xray <──gRPC 用户同步── Adapter ──> SSPanel API 或 MySQL
                                  │
                                  └── gRPC 用户统计 ──增量──> SSPanel /users/traffic
```

- API 认证模式：从 `GET /mod_mu/users` 同步可用用户，支持 ETag 和最大缓存陈旧时间；面板不可达超过 `max_stale` 后 fail-closed。
- 数据库认证模式：认证时实时查询 SSPanel-UIM 的 `user` 与 `node` 表，校验节点启用/额度、用户封禁、等级到期、节点等级/分组和用户流量额度。
- 数据库认证模式仍会按 `panel.heartbeat_interval` 调用带 ETag 的用户接口，因为 SSPanel-UIM 只在该接口中更新节点心跳。
- 流量上报：读取不清零的 `GET /traffic` 累计值，计算 checkpoint 差分；只有 SSPanel-UIM 接受完整批次后才推进 checkpoint。
- HY2 返回的客户端 ID 固定为 SSPanel 用户数字 ID，因此 stats 结果可以直接映射到 `user_id`。
- HY2 `tx` 对应客户端上传，写入 SSPanel `u`；`rx` 对应客户端下载，写入 `d`。
- VLESS 使用 SSPanel 用户 UUID 认证；适配器将 Xray 用户 `email` 固定为用户数字 ID，用它关联 Xray 统计与 SSPanel 用户。
- VLESS 用户列表以面板为准定期全量对账：新增用户动态加入，过期、封禁、流量耗尽或被删除的用户动态移除；重复 UUID 会全部拒绝。
- HY2 与 Xray 可以单独启用，也可以同时启用；两者使用独立 checkpoint 后合并上报到同一个节点。

流量始终通过 SSPanel-UIM WebAPI 上报，即使认证使用数据库模式也是如此。这样由面板统一处理节点倍率、动态倍率、小时统计和节点总流量，避免直接写库破坏面板记账逻辑。

## 前置配置

### SSPanel-UIM

在面板 `config/.config.php` 中启用 WebAPI：

```php
$_ENV['webAPI'] = true;
$_ENV['webAPIUrl'] = 'https://panel.example.com';
$_ENV['muKey'] = '使用随机长密钥';
$_ENV['checkNodeIp'] = true;
```

创建并启用一个节点，记录节点 ID。启用 `checkNodeIp` 时，适配器请求面板时使用的出口 IP 必须是面板节点表中的 IPv4/IPv6。`panel.base_url` 必须与 `webAPIUrl` 的协议和主机一致。

推荐用 `uuid` 作为 HY2 凭据。API 返回哪些凭据字段由节点 `sort` 决定；若当前逻辑节点不返回 UUID，可将 `credential_fields` 改成 `passwd`。凭据必须随机且全局唯一，重复凭据会被适配器拒绝。

> 此项目负责节点认证、VLESS 用户同步和流量记账，不修改 SSPanel-UIM 的订阅生成器。要自动下发 `hysteria2://` 或 `vless://` 链接，仍需在面板侧增加对应订阅输出。

## Hysteria 2 Docker 部署

使用 [docker-compose.hy2.yaml](docker-compose.hy2.yaml) 同时启动 Adapter、独立 HY2 和端口同步服务：

```bash
cp config.docker-hy2.example.yaml config.docker-hy2.yaml
cp hysteria.docker.example.yaml hysteria.docker.yaml
cp .env.example .env                 # 已有 .env 时不要覆盖
chmod 644 config.docker-hy2.yaml
chmod 600 hysteria.docker.yaml .env
```

部署前需要完成：

1. 填写 `.env` 的面板地址、`SSPANEL_NODE_ID`、Adapter 和 Stats 密钥。
2. 确认 `config.docker-hy2.yaml` 的 `panel.node_id` 为 `${SSPANEL_NODE_ID}`。
3. 将 `hysteria.docker.yaml` 中的域名、ACME 邮箱、Cloudflare API Token、`REPLACE_ADAPTER_AUTH_TOKEN` 和 `REPLACE_HY2_STATS_SECRET` 替换为实际值。
4. 在防火墙和云安全组开放 `${HY2_PUBLIC_PORT:-8443}/UDP`。

Cloudflare API Token 建议仅授予目标 Zone 的 `Zone:Read` 和 `DNS:Edit`
权限。Hysteria 使用 DNS-01 申请和续期证书，不需要对公网开放 TCP 80/443。
HY2 域名的 A/AAAA 记录必须指向节点服务器；未使用 Cloudflare Spectrum 时，
该记录应设为“仅 DNS”，不要开启普通橙云代理。

Hysteria 内置的 CertMagic 会每 10 分钟检查托管证书，证书进入有效期的
最后三分之一时开始自动续签。续签失败后后台会继续定期尝试；容器启动时
如果证书缺失、即将过期或已过期，也会在服务启动前申请新证书。
ACME 账户和证书保存在 `hysteria-acme` 持久卷中，不需要另外配置 cron。

启动：

```bash
docker compose -f docker-compose.hy2.yaml up -d --build
docker compose -f docker-compose.hy2.yaml logs -f adapter hysteria port-sync
```

这套部署中，HY2 通过 `adapter:8080` 调用认证，Adapter 通过 `hysteria:9999` 读取统计；`8080` 和 `9999` 不对公网开放。宿主机调试地址分别为 `127.0.0.1:18080` 和 `127.0.0.1:19999`，公网客户端连接端口默认为 `8443/UDP`。

### 重启与重建

重启全部 Compose 服务：

```bash
docker compose -f docker-compose.hy2.yaml restart
```

只重启单个服务：

```bash
docker compose -f docker-compose.hy2.yaml restart adapter
docker compose -f docker-compose.hy2.yaml restart hysteria
docker compose -f docker-compose.hy2.yaml restart port-sync
```

普通 `restart` 不会重新构建镜像，也不会让容器重新读取 Compose 中的环境变量。
修改代码、Dockerfile、`.env`、Compose 配置或 `HOST_PROJECT_DIR` 后，使用：

```bash
docker compose -f docker-compose.hy2.yaml up -d --build --force-recreate
```

重建后检查状态和日志：

```bash
docker compose -f docker-compose.hy2.yaml ps
docker compose -f docker-compose.hy2.yaml logs --tail=100 adapter hysteria port-sync
```

只有 Docker Engine 本身异常时才重启宿主机 Docker；该操作会短暂影响服务器上的其他
Docker 容器：

```bash
sudo systemctl restart docker
sudo systemctl status docker --no-pager
docker compose -f docker-compose.hy2.yaml up -d
```

### 从面板自动同步 Docker 对外端口

Docker 发布端口不能热更新，因此 Compose 中包含常驻的 `port-sync` 服务。它每隔
`PORT_SYNC_INTERVAL` 秒运行 [scripts/sync-panel-port.sh](scripts/sync-panel-port.sh)，读取节点
`custom_config.offset_port_node`，原子更新 `.env` 的 `HY2_PUBLIC_PORT`，并且只重建
`hysteria` 服务。重建前脚本会通过 Adapter 的受保护接口强制采集一次 HY2 流量；
采集失败时不会切换端口。Adapter、流量 checkpoint 和 ACME 数据卷不会被重建。
Compose 已将 `HYSTERIA_ACME_DIR=/acme` 挂载到 `hysteria-acme` 持久卷，避免每次端口
变化都重新申请证书。

面板节点配置示例：

```json
{
  "offset_port_user": 8443,
  "offset_port_node": 8443,
  "sni": "korea.hy2.example.com",
  "allow_insecure": false
}
```

没有额外端口转发时，`offset_port_user` 与 `offset_port_node` 应保持一致：前者用于订阅下发，后者驱动 Docker 宿主机 UDP 端口。

`.env` 必须配置服务器上的项目绝对路径、与 Adapter 相同的节点 ID，并建议限定允许
端口范围：

```dotenv
HOST_PROJECT_DIR=/home/ubuntu/sspanel-hy2-adapter
PORT_SYNC_INTERVAL=30
SSPANEL_NODE_ID=11
HY2_ALLOWED_PORT_MIN=10000
HY2_ALLOWED_PORT_MAX=20000
```

`HOST_PROJECT_DIR` 必须是绝对路径。`port-sync` 会把该目录挂载到容器中的相同路径，
供容器内的 Compose 正确解析 `hysteria.docker.yaml` 等绑定挂载。

执行同步前，Adapter 和 Hysteria 必须已启动。`ADAPTER_DEBUG_PORT` 仅绑定
`127.0.0.1`，不要将该管理入口暴露到公网。同步接口需要等待 stats 采集和面板上报，
请将 `config.docker-hy2.yaml` 的 `server.write_timeout` 设置为至少 `15s`。

`port-sync` 镜像已包含 Docker CLI、Compose、`curl`、`flock` 和 `jq`，宿主机不再需要
安装同步脚本依赖。启动并查看日志：

```bash
docker compose -f docker-compose.hy2.yaml up -d --build port-sync
docker compose -f docker-compose.hy2.yaml logs -f port-sync
```

从旧 systemd 定时器迁移时，先停用并删除旧服务，避免两个调度器同时工作：

```bash
sudo systemctl disable --now sspanel-hy2-port-sync.timer
sudo rm -f /etc/systemd/system/sspanel-hy2-port-sync.service \
  /etc/systemd/system/sspanel-hy2-port-sync.timer
sudo systemctl daemon-reload
```

修改 `.env` 中的节点、密钥或端口参数后无需重建 `port-sync`，下一轮会重新读取文件；
需要立即同步时执行 `docker compose -f docker-compose.hy2.yaml restart port-sync`。
修改 `HOST_PROJECT_DIR` 或 `PORT_SYNC_INTERVAL` 后则需要重新创建该容器。端口变化会
短暂中断现有 HY2 连接。系统防火墙和云安全组必须预先允许 `HY2_ALLOWED_PORT_MIN` 到
`HY2_ALLOWED_PORT_MAX` 的 UDP 范围，否则 Docker 已切换但公网仍不可达。

安全边界：`port-sync` 挂载了 `/var/run/docker.sock`，因此具备控制宿主机 Docker 的
高权限。不要向该镜像加入不受信任的代码，也不要将 Docker API 暴露到网络。

健康检查：

```bash
curl http://127.0.0.1:8080/healthz
```

认证验证：

```bash
curl -sS 'http://127.0.0.1:8080/auth?token=ADAPTER_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"addr":"127.0.0.1:12345","auth":"USER_UUID","tx":10485760}'
```

成功响应为 `{"ok":true,"id":"用户数字ID"}`。

## Hysteria 2 通用链式中转

需要让入口机负责 SSPanel 鉴权与用户流量上报、由另一台机器提供最终公网出口时，可
使用项目内的通用链式中转部署：

```text
用户 ──> 入口 HY2 + Adapter ──> WireGuard ──> 落地机 NAT ──> Internet
```

入口机使用 [docker-compose.hy2-relay.yaml](docker-compose.hy2-relay.yaml)，落地机使用
[docker-compose.wireguard-landing.yaml](docker-compose.wireguard-landing.yaml)。Hysteria
的 direct outbound 绑定 WireGuard 隧道地址，落地机只负责转发和 NAT，不连接面板，
因此只由入口节点完成用户校验和流量记账。该方案不需要 SOCKS5 或第二层 HY2，使用通用的
`relay` / `landing` 命名，不与具体国家、地区或线路绑定。

完整的配置文件、端口规划、面板设置、启动命令和验证方法见
[docs/HY2_RELAY.md](docs/HY2_RELAY.md)。

## VLESS + REALITY / XTLS Vision Docker 部署

这套部署使用官方 `ghcr.io/xtls/xray-core:26.2.6` 镜像。Xray 的 VLESS inbound 初始用户列表为空，Adapter 启动后通过仅在 Docker 内网开放的 gRPC API 安装面板当前授权用户，不需要重启 Xray。

准备配置：

```bash
cp config.docker-vless-reality.example.yaml config.docker-vless-reality.yaml
cp xray.docker.example.json xray.docker.json
cp .env.example .env                 # 已有 .env 时不要覆盖
chmod 644 config.docker-vless-reality.yaml xray.docker.json
```

生成 REALITY X25519 密钥对和 short ID：

```bash
docker run --rm ghcr.io/xtls/xray-core:26.2.6 x25519
openssl rand -hex 8
```

编辑 `xray.docker.json`，替换以下值：

- `REPLACE_PRIVATE_KEY`：`x25519` 输出的 `PrivateKey`，只保存在服务端。
- `REPLACE_SHORT_ID`：上面生成的 16 位十六进制 short ID。
- `REPLACE_TARGET_HOST` 和 `REPLACE_SERVER_NAME`：可从节点直接访问、支持 TLS 1.3 且证书覆盖该 SNI 的伪装站点；两者通常相同。

REALITY 会把认证失败的连接转发到 `target`。不要随意选择可能使节点成为公共 CDN 转发器的目标；上线前可在节点上执行 `xray tls ping 目标域名` 检查握手兼容性。

#### REALITY 在目标站证书阶段中断

伪装目标支持 TLS 1.3 并不代表一定适合 REALITY。目标站的证书链可能随时变化；如果
TLS Certificate 握手记录超过当前 REALITY 实现的 8192 字节缓冲区，客户端会在完成
TCP 连接后立即断开。2026 年 7 月实际排查中，`www.microsoft.com` 返回了 8273 字节的
Certificate 记录，触发了这个问题，因此不要把该域名视为始终可用的固定默认值。

典型调试日志如下：

```text
hs.c.conn == conn: true
Certificate: 8273
hs.c.isHandshakeComplete.Load(): false
REALITY: processed invalid connection: handshake did not complete successfully
```

其中 `hs.c.conn == conn: true` 表示 REALITY 公钥、short ID、客户端时间和版本等认证条件
已经通过；此时继续更换 UUID 或密钥不能解决目标站 TLS 握手记录过大的问题。临时把
`log.loglevel` 改为 `debug`、把 `realitySettings.show` 改为 `true`，重建 Xray 后才能看到
上述明细。使用 `xray tls ping 候选域名` 检查新目标，并选择从 VPS 可直连、支持 TLS 1.3
且证书握手兼容的站点，例如先测试 `www.apple.com`。更换时必须同时更新：

- 服务端 `realitySettings.target`；
- 服务端 `realitySettings.serverNames`；
- 面板或客户端配置中的 `sni`。

三处域名通常保持一致。更换伪装目标不需要重新生成 UUID、REALITY 密钥或 short ID。
排查完成后应把 `show` 和日志级别恢复为 `false`、`warning`，避免长期输出握手调试信息。

在 `.env` 中至少设置：

```dotenv
SSPANEL_BASE_URL=https://panel.example.com
SSPANEL_MU_KEY=使用随机长密钥
SSPANEL_NODE_ID=12
ADAPTER_AUTH_TOKEN=另一个随机长密钥
VLESS_PUBLIC_PORT=443
HOST_PROJECT_DIR=/opt/sspanel-hy2-adapter
PORT_SYNC_INTERVAL=30
VLESS_ALLOWED_PORT_MIN=1024
VLESS_ALLOWED_PORT_MAX=65535
VLESS_ADAPTER_DEBUG_PORT=18081
```

`HOST_PROJECT_DIR` 必须是服务器上本项目的绝对路径。建议把允许端口范围收紧到防火墙和云安全组已经放行的 TCP 范围。

面板节点的 `custom_config` 至少设置：

```json
{
  "offset_port_user": 443,
  "offset_port_node": 443
}
```

没有额外端口转发时，两者应保持一致：`offset_port_node` 驱动 Docker 实际发布端口，`offset_port_user` 用于客户端订阅链接。

启动并检查：

```bash
docker compose -f docker-compose.vless-reality.yaml up -d --build
docker compose -f docker-compose.vless-reality.yaml ps
docker compose -f docker-compose.vless-reality.yaml logs -f adapter xray port-sync
```

只需对公网开放 `${VLESS_PUBLIC_PORT:-443}/TCP`。Xray gRPC API `10085` 不映射到宿主机，VLESS Adapter 调试端口默认只绑定 `127.0.0.1:18081`，避免与 HY2 默认使用的 `18080` 冲突。

### 从面板自动切换 VLESS TCP 端口

Compose 中的 `port-sync` 每隔 `PORT_SYNC_INTERVAL` 秒读取面板 `custom_config.offset_port_node`。发现变化后会按以下顺序处理：

1. 调用 Adapter 的受保护接口采集并上报尚未结算的 Xray 流量。
2. 原子更新 `.env` 中的 `VLESS_PUBLIC_PORT`。
3. 只重建 `xray` 服务，Adapter 和流量 checkpoint 不会重建。
4. 调用 `/admin/sync-users` 立即把面板有效用户重新加入空的 Xray inbound。

如果第四步暂时失败，端口同步器会保留 `.vless-sync-required` 标记，并在下一轮继续恢复用户，不会反复重建已经切换成功的 Xray。端口变化会短暂断开现有 VLESS 连接，因此必须提前放行 `VLESS_ALLOWED_PORT_MIN` 到 `VLESS_ALLOWED_PORT_MAX` 的 TCP 范围。

`port-sync` 挂载了 `/var/run/docker.sock`，具备控制宿主机 Docker 的高权限；不要向该镜像加入不受信任代码，也不要暴露 Docker API。

客户端链接模板如下，其中 `pbk` 是当前 Xray `x25519` 输出的 `Password`（旧版本输出标签为 Public key），绝不能填服务端 `PrivateKey`：

```text
vless://USER_UUID@NODE_HOST:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=SERVER_NAME&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp#NODE_NAME
```

### SSPanel-UIM 订阅边界

SSPanel-UIM 官方当前的节点类型中没有原生 VLESS + REALITY 订阅输出；`sort=11` 会让 `/mod_mu/users` 返回 UUID，但其内置订阅仍生成 VMess。此仓库已经完成服务端用户授权和记账，自动下发上述 `vless://` 链接仍需在你的面板分支中增加订阅生成逻辑，或先手工分发链接。客户端 UUID 必须与 SSPanel 用户 UUID 一致。

## 可靠性与边界

- `hy2.state_file` 必须持久化。面板上报失败时不会推进 checkpoint，下次会重试同一增量。
- `xray.state_file` 也必须持久化，并且不能与 HY2 共用同一路径。
- HY2 重启导致计数变小后，适配器会把新计数视为重启后的增量。
- 单个 HY2 stats API 只能由一个适配器实例采集；多实例会重复记账。
- SSPanel WebAPI 没有幂等键。若进程在“面板已记账、checkpoint 尚未落盘”的极小窗口崩溃，重启后可能重复上报该批流量；不会因为普通网络失败而主动丢弃流量。
- 不要让其他程序调用 `/traffic?clear=1`，否则被清除但尚未采集的流量无法恢复。
- Xray API 必须只放在可信内网。它没有在此方案中增加额外认证，暴露后可被用于修改代理用户。
- `/admin/collect` 和 `/admin/sync-users` 都要求 `ADAPTER_AUTH_TOKEN`；调试端口必须保持仅绑定回环地址。
- 移除失效 VLESS 用户前会先采集一次流量；若采集失败，授权回收优先，适配器仍会移除用户并记录错误。
- HY2 HTTP Auth 只能返回允许/拒绝，无法下发 SSPanel 的每用户限速。当前版本也不维护 SSPanel `aliveip`，因此不提供精确的 HY2 在线 IP/设备数限制。
- `server.auth_token` 是纵深防护。最佳部署仍是 Adapter Auth 与 HY2 stats 都只监听回环地址，并通过防火墙阻止外部访问。

## 开发验证

```bash
go test ./...
go vet ./...
```

协议参考：[Hysteria 2 HTTP authentication](https://v2.hysteria.network/docs/advanced/Full-Server-Config/#http-authentication)、[Hysteria 2 Traffic Stats API](https://v2.hysteria.network/docs/advanced/Traffic-Stats-API/)、[Xray VLESS](https://xtls.github.io/config/inbounds/vless.html)、[Xray REALITY](https://xtls.github.io/config/transports/reality.html)、[Xray API](https://xtls.github.io/config/api.html)、[Xray Statistics](https://xtls.github.io/config/stats.html)、[SSPanel-UIM](https://github.com/Anankke/SSPanel-UIM)。
