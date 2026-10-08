# VLESS + XHTTP + REALITY

使用新版 `scripts/native-manager.sh`，已有 VLESS 选择：

```text
4) 修改配置并重启
2) VLESS
3) VLESS + XHTTP + REALITY（直连，flow 留空）
```

新安装选择 `1 → 2 → 3`。切换复用 VLESS 服务、管理端口 18081 和 Xray API 端口
10085；切换会重启 VLESS 服务。原用户 UUID、REALITY 私钥、Short ID、公网/本机
端口和目标域名可以回车保留。AnyTLS、HY2 服务不受影响。

REALITY 目标需要支持 TLS 1.3 和 HTTP/2。XHTTP 路径默认 `/xhttp`，模式默认
`auto`，客户端与服务端保持一致。可选 `stream-one`、`stream-up`、`packet-up`；
Host 可留空，有值时需在客户端填写同一值。修改配置时默认保留当前传输和参数，
Host 输入 `-` 清空。

本方式是**源站直连**：节点地址用 VPS IP 或灰云域名，放行公网和本机 TCP 端口。
REALITY 目标域名是 SNI，不是节点连接地址。普通 Cloudflare 橙云不能转发这一
REALITY 握手；这里的 XHTTP + REALITY 不用于替换橙云入口。无需申请本机 TLS 证书。

脚本生成 `network: xhttp`、`security: reality`、`xhttpSettings`，用户同步到
`vless-xhttp-reality` 入站，Adapter 的 `xray.flow` 显式为空。
**不要使用 `xtls-rprx-vision`**。所有客户端凭据仍使用 SSPanel 用户 UUID，流量
继续通过 Xray 用户统计接口上报。仓库自带 Xray 26.2.6 已校验支持这套配置。

## SSPanel 和客户端

先部署配套 `sspanel-uim-me` 中的 XHTTP 订阅修改，再修改该节点。
节点类型继续使用 V2Ray（`sort=11`），地址填源站 IP/灰云域名，自定义配置：

```json
{
  "protocol": "vless",
  "offset_port_user": "443",
  "offset_port_node": "443",
  "network": "xhttp",
  "security": "reality",
  "flow": "",
  "sni": "www.example.com",
  "fingerprint": "chrome",
  "public_key": "替换为原 REALITY 公钥",
  "short_id": "替换为原 REALITY Short ID",
  "path": "/xhttp",
  "mode": "auto",
  "udp": true
}
```

`offset_port_user` 是客户端连接的公网端口，`offset_port_node` 是本机监听端口；
没有 NAT 时通常相同。有 XHTTP Host 时增加 `"host": "对应域名"`。
保留 `protocol=vless`，避免面板按 VMess 输出。
脚本完成后会打印本次真实参数的完整 JSON 和带占位符的 `vless://` 链接。

Shadowrocket 使用新版客户端，更新原 Clash 订阅即可；Clash/Mihomo 客户端也需
支持 XHTTP。配套面板输出 `network: xhttp`、`xhttp-opts`、`reality-opts`，省略 flow。
Xray 客户端可使用 `/vless` 或 `/v2ray` URI 订阅。
官方 sing-box 暂无 XHTTP 传输，面板 `/singbox` 和旧 `/v2rayjson` 不导出此类节点，
避免错误地降级为 TCP REALITY。现有 TCP REALITY、WS/TLS 订阅继续可用。

XHTTP 更换传输方式并不保证速度更快或 IP 不会被封锁，需在用户网络上验证。

协议参考：[Xray XHTTP](https://github.com/XTLS/Xray-core/discussions/4113)、
[Mihomo XHTTP 参数](https://wiki.metacubex.one/config/proxies/transport/#xhttp-opts)、
[Shadowrocket 更新记录](https://apps.apple.com/us/app/shadowrocket/id932747118)。
