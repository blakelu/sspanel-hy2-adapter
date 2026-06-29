# SSPanel-UIM Hysteria 2 Adapter

一个独立的 Go 服务，用 SSPanel-UIM 用户数据为 Hysteria 2 提供 HTTP Auth，并将 Hysteria 2 Traffic Stats API 的用户流量增量上报到 SSPanel-UIM WebAPI。

## 工作方式

```text
HY2 客户端 ──auth──> Hysteria 2 ──POST /auth──> Adapter ──> SSPanel API 或 MySQL
                                      │
                                      └── GET HY2 /traffic ──增量──> SSPanel /users/traffic
```

- API 认证模式：从 `GET /mod_mu/users` 同步可用用户，支持 ETag 和最大缓存陈旧时间；面板不可达超过 `max_stale` 后 fail-closed。
- 数据库认证模式：认证时实时查询 SSPanel-UIM 的 `user` 与 `node` 表，校验节点启用/额度、用户封禁、等级到期、节点等级/分组和用户流量额度。
- 数据库认证模式仍会按 `panel.heartbeat_interval` 调用带 ETag 的用户接口，因为 SSPanel-UIM 只在该接口中更新节点心跳。
- 流量上报：读取不清零的 `GET /traffic` 累计值，计算 checkpoint 差分；只有 SSPanel-UIM 接受完整批次后才推进 checkpoint。
- HY2 返回的客户端 ID 固定为 SSPanel 用户数字 ID，因此 stats 结果可以直接映射到 `user_id`。
- HY2 `tx` 对应客户端上传，写入 SSPanel `u`；`rx` 对应客户端下载，写入 `d`。

流量始终通过 SSPanel-UIM WebAPI 上报，即使认证使用数据库模式也是如此。这样由面板统一处理节点倍率、动态倍率、小时统计和节点总流量，避免直接写库破坏面板记账逻辑。

## 前置配置

### 1. SSPanel-UIM

在面板 `config/.config.php` 中启用 WebAPI：

```php
$_ENV['webAPI'] = true;
$_ENV['webAPIUrl'] = 'https://panel.example.com';
$_ENV['muKey'] = '使用随机长密钥';
$_ENV['checkNodeIp'] = true;
```

创建并启用一个节点，记录节点 ID。启用 `checkNodeIp` 时，适配器请求面板时使用的出口 IP 必须是面板节点表中的 IPv4/IPv6。`panel.base_url` 必须与 `webAPIUrl` 的协议和主机一致。

推荐用 `uuid` 作为 HY2 凭据。API 返回哪些凭据字段由节点 `sort` 决定；若当前逻辑节点不返回 UUID，可将 `credential_fields` 改成 `passwd`。凭据必须随机且全局唯一，重复凭据会被适配器拒绝。

> 此项目负责节点认证和流量记账，不修改 SSPanel-UIM 的订阅生成器。要自动下发 `hysteria2://` 链接，还需要在面板侧增加相应订阅输出，并把同一个 UUID/节点密码作为 HY2 `auth` 下发。

### 2. Adapter

```bash
cp config.example.yaml config.yaml
```

配置文件会展开 `${ENV_NAME}`。最小环境变量示例：

```bash
export ADAPTER_AUTH_TOKEN='随机十六进制字符串'
export SSPANEL_BASE_URL='https://panel.example.com'
export SSPANEL_MU_KEY='面板 muKey'
export HY2_STATS_SECRET='另一个随机长密钥'
```

然后按实际节点修改 `panel.node_id`。数据库认证模式还需设置数据库变量并将 `user_source.mode` 改为 `database`：

```bash
export SSPANEL_DB_HOST='127.0.0.1'
export SSPANEL_DB_NAME='sspanel'
export SSPANEL_DB_USER='sspanel_adapter'
export SSPANEL_DB_PASSWORD='数据库密码'
```

数据库账户只需读取 `user`、`node` 表。流量仍由 WebAPI 写入，不应给适配器直接更新业务表的权限。

### 3. Hysteria 2

将 [deploy/hysteria-snippet.yaml](deploy/hysteria-snippet.yaml) 合并进 HY2 服务端配置。关键配置如下：

```yaml
auth:
  type: http
  http:
    url: http://127.0.0.1:8080/auth?token=ADAPTER_TOKEN

trafficStats:
  listen: 127.0.0.1:9999
  secret: HY2_STATS_SECRET
```

客户端的 `auth` 值必须等于配置的 SSPanel 用户字段，例如 UUID。

## 运行

本机编译运行：

```bash
go build -o bin/sspanel-hy2-adapter ./cmd/sspanel-hy2-adapter
./bin/sspanel-hy2-adapter -config config.yaml
```

Docker（生产 Linux，HY2 在宿主机运行）：

```bash
cp docker-compose.example.yaml docker-compose.yaml
docker compose up -d --build
```

systemd 示例见 [deploy/sspanel-hy2-adapter.service](deploy/sspanel-hy2-adapter.service)。使用该文件时，将 `hy2.state_file` 设置为 `/var/lib/sspanel-hy2-adapter/traffic-state.json`。

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

## 可靠性与边界

- `hy2.state_file` 必须持久化。面板上报失败时不会推进 checkpoint，下次会重试同一增量。
- HY2 重启导致计数变小后，适配器会把新计数视为重启后的增量。
- 单个 HY2 stats API 只能由一个适配器实例采集；多实例会重复记账。
- SSPanel WebAPI 没有幂等键。若进程在“面板已记账、checkpoint 尚未落盘”的极小窗口崩溃，重启后可能重复上报该批流量；不会因为普通网络失败而主动丢弃流量。
- 不要让其他程序调用 `/traffic?clear=1`，否则被清除但尚未采集的流量无法恢复。
- HY2 HTTP Auth 只能返回允许/拒绝，无法下发 SSPanel 的每用户限速。当前版本也不维护 SSPanel `aliveip`，因此不提供精确的 HY2 在线 IP/设备数限制。
- `server.auth_token` 是纵深防护。最佳部署仍是 Adapter Auth 与 HY2 stats 都只监听回环地址，并通过防火墙阻止外部访问。

## 开发验证

```bash
go test ./...
go vet ./...
```

协议参考：[Hysteria 2 HTTP authentication](https://v2.hysteria.network/docs/advanced/Full-Server-Config/#http-authentication)、[Hysteria 2 Traffic Stats API](https://v2.hysteria.network/docs/advanced/Traffic-Stats-API/)、[SSPanel-UIM](https://github.com/Anankke/SSPanel-UIM)。
