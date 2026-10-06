# AnyTLS 原生部署与 SSPanel 对接

交互脚本为 `scripts/native-manager.sh`，下载后的文件可以命名为
`sspanel-native-manager.sh`。选择 `1 安装 → 3 AnyTLS`，填写面板地址、MuKey、
独立节点 ID、公网 TCP 端口和本机 TCP 端口。原生 AnyTLS 与 Adapter 在同一
进程中运行，不需要额外的 sing-box/Xray 进程。

仓库发布新版脚本、`bin/sspanel-hy2-adapter-linux`、安装脚本及
`bin/SHA256SUMS` 后，可以沿用 GitHub Raw 下载方式。在发布之前，复制本仓库的
`scripts/`、`bin/` 到 Linux x86_64 机器，使用本地配套文件：

```sh
sudo env NATIVE_LOCAL_ASSETS_DIR="$PWD" sh scripts/native-manager.sh
```

管理器会核验 SHA-256，并拒绝不支持 AnyTLS 的旧 Adapter，避免只更新菜单却无法启动。

## TLS 与端口

域名 A/AAAA 指向源站，Cloudflare DNS 使用灰云。普通橙云只转发 HTTP，不能直接
承载原生 AnyTLS。选择自动证书时使用 Let's Encrypt + Cloudflare DNS-01，
无需开放 80；Token 需要目标 Zone 的 DNS 编辑权限。证书与 CA 状态保存在
`/opt/sspanel-native/acme-anytls/<域名>/`，与 VLESS 状态分开。

手动证书必须是客户端信任、覆盖 SNI 的完整 PEM 证书链。Cloudflare Origin CA
只适用于 Cloudflare 回源，不能作为开启证书校验的直连客户端证书。
安装前会验证证书与私钥匹配。每日检查续期，新的 TLS 握手读取更新后的证书，
无需重启已有用户会话。手动检查：

```sh
sudo sspanel-native-manager --renew-anytls-cert
```

放行公网和源站监听的 **TCP** 端口；客户端 UDP 流量通过 TCP 内的 UOT 转发，
不需要为 AnyTLS 放行公网 UDP 端口。管理 HTTP 端口 `127.0.0.1:18082`
只供本机使用。不要与现有 VLESS 的 TCP 监听端口冲突。

## 面板

配套面板仓库 `sspanel-uim-me` 新增 AnyTLS 节点类型，`sort=16`。部署配套面板修改后，
后台新增独立节点，类型选择 AnyTLS，节点地址填写直连域名。自定义配置示例：

```json
{
  "protocol": "anytls",
  "offset_port_user": "443",
  "offset_port_node": "443",
  "sni": "hk-anytls.example.com",
  "allow_insecure": false,
  "udp": true
}
```

NAT 场景中 `offset_port_user` 是客户端连接的公网端口；`offset_port_node`
填写本机监听端口。本服务监听端口由 Adapter 配置确定，不会自动跟随面板字段改变。
更新原 Clash 订阅即可获得 `type: anytls` 节点；同时支持 sing-box、`/anytls`
独立 URI 订阅及 `/v2ray` 混合 URI。Xray/V2Ray JSON 不支持 AnyTLS，导出时跳过，
不会误生成 VMess。密码使用该用户 UUID，不能填节点共享密码。

```text
anytls://USER_UUID@hk-anytls.example.com:443?sni=hk-anytls.example.com&insecure=0#AnyTLS
```

客户端需支持 AnyTLS，例如 Shadowrocket 2.2.65+、新版 mihomo 或 sing-box。
原版 Clash 不支持。服务端使用 `SagerNet/sing-anytls` 的协议实现和默认填充策略，固定到提交 `580984e4d8cb`。
实现参考：[AnyTLS](https://github.com/anytls/anytls-go)、
[SagerNet/sing-anytls](https://github.com/SagerNet/sing-anytls/tree/580984e4d8cb10f1c5e88d7ec14cfe4d955d66e6)。

## 用户与流量

通过当前 SSPanel `/mod_mu/users?node_id=...` 读取 UUID，默认每 30 秒刷新/同步，
无需重启新增或删除用户。重复 UUID 不授权；修改 UUID、撤销用户或用户缓存过期时，
已有会话也会关闭。短暂面板故障使用最多 5 分钟的已有用户缓存，然后拒绝访问。
不实现单用户限速/设备数统计；这与原 VLESS Adapter 的限制一致。

按用户 ID 统计转发成功的 TCP/UDP 载荷，通过 `/mod_mu/users/traffic` 每 60 秒
上报增量，由面板应用流量倍率；失败后继续累计重试。检查点保存在
`/var/lib/sspanel-native/anytls/anytls-traffic-state.json`。正常停止尝试结算最后一段
流量；强制终止、掉电可能丢失最后一次成功上报后的内存计数。

systemd/OpenRC 服务名均为 `sspanel-native-anytls-adapter`，菜单 `3` 重启、`4`
修改配置，`2` 卸载全部包含 AnyTLS 和续期任务。AnyTLS 合并进程的 Go 软堆目标为
48 MiB，并非 RSS 硬上限；请按连接数和实际负载评估小内存机器。

## 构建与许可

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags '-s -w' -o bin/sspanel-hy2-adapter-linux ./cmd/sspanel-hy2-adapter
```

需要 Go 1.24+。集成的 `sing-anytls` 与 `sing` 使用 GPL-3.0-or-later，包含这些
依赖的二进制按该许可证分发；本项目原创源码的 MIT 声明保留。
依赖版本/校验值保存在 go.mod/go.sum，第三方许可和源码来源随 bin/ 文件提供。
