#!/bin/sh
# Interactive native deployment manager for small Linux NAT servers.
set -eu
umask 077

RAW_BASE=${NATIVE_REPO_RAW_BASE:-https://raw.githubusercontent.com/blakelu/sspanel-hy2-adapter/main}
MANAGED_DIR=${NATIVE_MANAGED_DIR:-/opt/sspanel-native}
MANAGER_BIN=/usr/local/sbin/sspanel-native-manager
STAGE=
TTY_STATE=

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
cleanup() {
    if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" <&3 2>/dev/null || :; fi
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf -- "$STAGE"; fi
}
trap cleanup 0
trap 'exit 130' 1 2 3 15

[ "$(id -u)" -eq 0 ] || die '请以 root 身份运行'
exec 3<&0

ask() {
    ask_label=$1
    ask_default=$2
    ask_secret=$3
    while :; do
        if [ "$ask_secret" = yes ]; then
            if [ -n "$ask_default" ]; then
                printf '%s [回车保留当前值]：' "$ask_label" >&2
            else
                printf '%s：' "$ask_label" >&2
            fi
            if [ -t 3 ]; then TTY_STATE=$(stty -g <&3); stty -echo <&3; fi
        elif [ -n "$ask_default" ]; then
            printf '%s [%s]：' "$ask_label" "$ask_default" >&2
        else
            printf '%s：' "$ask_label" >&2
        fi
        IFS= read -r ask_answer <&3 || die '输入已结束'
        if [ "$ask_secret" = yes ] && [ -n "$TTY_STATE" ]; then
            stty "$TTY_STATE" <&3
            TTY_STATE=
            printf '\n' >&2
        fi
        [ -n "$ask_answer" ] || ask_answer=$ask_default
        printf '%s\n' "$ask_answer"
        return
    done
}

required() {
    required_label=$1
    required_default=$2
    required_secret=$3
    while :; do
        required_value=$(ask "$required_label" "$required_default" "$required_secret")
        [ -n "$required_value" ] && { printf '%s\n' "$required_value"; return; }
        say '此项不能为空。' >&2
    done
}

random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
random_value() {
    random_label=$1
    random_current=$2
    random_bytes=$3
    if [ -n "$random_current" ]; then
        random_input=$(ask "$random_label（回车保留，输入 new 重新生成）" "$random_current" yes)
    else
        random_input=$(ask "$random_label（直接回车自动生成）" '' yes)
    fi
    case "$random_input" in
        ''|new) random_hex "$random_bytes" ;;
        *) printf '%s\n' "$random_input" ;;
    esac
}

valid_port() {
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
port_prompt() {
    port_label=$1
    port_default=$2
    while :; do
        port_value=$(required "$port_label" "$port_default" no)
        valid_port "$port_value" && { printf '%s\n' "$port_value"; return; }
        say '端口必须是 1 到 65535。' >&2
    done
}
safe_scalar() {
    case "$1" in *'"'*|*'\'*|*'`'*|'') return 1 ;; esac
    case "$1" in *[[:space:]]*) return 1 ;; esac
    return 0
}
safe_token() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_-]+$'; }
dns_name() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'; }
numeric_id() {
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 0 ]
}

init_system() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        printf 'systemd\n'
    elif command -v rc-service >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then
        printf 'openrc\n'
    else
        die '需要 Alpine OpenRC 或 systemd'
    fi
}
service_active() {
    if [ "$(init_system)" = systemd ]; then
        systemctl is-active --quiet "$1.service"
    else
        rc-service "$1" status >/dev/null 2>&1
    fi
}
service_stop() {
    if [ "$(init_system)" = systemd ]; then
        systemctl stop "$1.service"
    else
        rc-service "$1" stop
    fi
}
service_start() {
    if [ "$(init_system)" = systemd ]; then
        systemctl start "$1.service"
    else
        rc-service "$1" start
    fi
}
mode_names() {
    case "$1" in
        hy2) PROXY=hysteria; ADMIN_PORT=18080; PROTOCOL=UDP ;;
        vless) PROXY=xray; ADMIN_PORT=18081; PROTOCOL=TCP ;;
        *) die '未知协议' ;;
    esac
    PROXY_SERVICE=sspanel-native-$1-$PROXY
    ADAPTER_SERVICE=sspanel-native-$1-adapter
}
choose_mode() {
    say '1) HY2' >&2
    say '2) VLESS + REALITY' >&2
    say '0) 返回' >&2
    choice=$(ask '选择协议' '' no)
    case "$choice" in 1) printf 'hy2\n' ;; 2) printf 'vless\n' ;; 0) printf '\n' ;; *) say '无效选择。' >&2; printf '\n' ;; esac
}
installed() { [ -f "/etc/sspanel-native/$1/server.env" ]; }

ensure_dependencies() {
    dep_mode=$1
    dep_missing=
    if [ ! -r /etc/ssl/cert.pem ] && [ ! -r /etc/ssl/certs/ca-certificates.crt ]; then
        dep_missing='ca-certificates'
    fi
    command -v curl >/dev/null 2>&1 || dep_missing="$dep_missing curl"
    if [ "$dep_mode" = vless ]; then
        command -v jq >/dev/null 2>&1 || dep_missing="$dep_missing jq"
    fi
    if [ -z "$dep_missing" ]; then
        command -v sha256sum >/dev/null 2>&1 || die '需要 sha256sum'
        return 0
    fi
    if command -v apk >/dev/null 2>&1; then
        # Only install missing packages; avoid a repository fetch on every run.
        apk add --no-cache $dep_missing
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y $dep_missing
    else
        die '缺少支持的包管理器（apk 或 apt-get）'
    fi
    command -v sha256sum >/dev/null 2>&1 || die '需要 sha256sum'
}
download() {
    download_path=$1
    download_dest=$2
    mkdir -p "$(dirname "$download_dest")"
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 3 --connect-timeout 10 --max-time 180 \
            "$RAW_BASE/$download_path" -o "$download_dest" || die "下载失败：$download_path"
    else
        wget -q -O "$download_dest" "$RAW_BASE/$download_path" || die "下载失败：$download_path"
    fi
}
verify_download() {
    verify_path=$1
    verify_file=$2
    verify_sum=$(awk -v path="$verify_path" '$2 == path { print $1; exit }' "$STAGE/bin/SHA256SUMS")
    printf '%s\n' "$verify_sum" | grep -Eq '^[0-9a-f]{64}$' || die "校验清单缺少：$verify_path"
    printf '%s  %s\n' "$verify_sum" "$verify_file" | sha256sum -c - >/dev/null || die "SHA-256 校验失败：$verify_path"
}
fetch_assets() {
    fetch_mode=$1
    [ "$(uname -m)" = x86_64 ] || die '当前仓库二进制仅支持 Linux x86_64'
    [ "$(uname -s)" = Linux ] || die '只支持 Linux'
    STAGE=$(mktemp -d)
    download bin/SHA256SUMS "$STAGE/bin/SHA256SUMS"
    case "$fetch_mode" in hy2) fetch_proxy=hysteria ;; vless) fetch_proxy=xray ;; esac
    for fetch_path in scripts/install-native.sh bin/sspanel-hy2-adapter-linux "bin/$fetch_proxy-linux"; do
        download "$fetch_path" "$STAGE/$fetch_path"
        verify_download "$fetch_path" "$STAGE/$fetch_path"
    done
    install -d -m 700 "$MANAGED_DIR" "$MANAGED_DIR/bin" "$MANAGED_DIR/scripts" "$MANAGED_DIR/settings" "$MANAGED_DIR/native/$fetch_mode"
    install -m 600 "$STAGE/bin/SHA256SUMS" "$MANAGED_DIR/bin/SHA256SUMS"
    install -m 755 "$STAGE/scripts/install-native.sh" "$MANAGED_DIR/scripts/install-native.sh"
    install -m 755 "$STAGE/bin/sspanel-hy2-adapter-linux" "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux"
    install -m 755 "$STAGE/bin/$fetch_proxy-linux" "$MANAGED_DIR/bin/$fetch_proxy-linux"
    if [ "$fetch_mode" = hy2 ]; then
        "$MANAGED_DIR/bin/hysteria-linux" version >/dev/null || die 'Hysteria 无法在本机执行'
    else
        "$MANAGED_DIR/bin/xray-linux" version >/dev/null || die 'Xray 无法在本机执行'
    fi
    "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -version >/dev/null || die 'Adapter 无法在本机执行'
    rm -rf -- "$STAGE"
    STAGE=
}
ensure_assets() {
    mode_names "$1"
    if ! command -v curl >/dev/null 2>&1 || \
       { [ "$1" = vless ] && ! command -v jq >/dev/null 2>&1; }; then
        ensure_dependencies "$1"
    fi
    if [ ! -x "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" ] || \
       [ ! -x "$MANAGED_DIR/bin/$PROXY-linux" ] || \
       [ ! -f "$MANAGED_DIR/scripts/install-native.sh" ]; then
        ensure_dependencies "$1"
        fetch_assets "$1"
    fi
}

setting() {
    setting_mode=$1
    setting_key=$2
    setting_file="$MANAGED_DIR/settings/$setting_mode.conf"
    if [ -f "$setting_file" ]; then
        awk -v key="$setting_key" '$0 ~ "^" key "=" { sub(/^[^=]*=/, ""); print; exit }' "$setting_file"
        return
    fi
    setting_env="/etc/sspanel-native/$setting_mode/server.env"
    setting_config="/etc/sspanel-native/$setting_mode/server.yaml"
    [ "$setting_mode" = vless ] && setting_config="/etc/sspanel-native/vless/server.json"
    case "$setting_key" in
        PANEL_URL|MU_KEY|NODE_ID|ADAPTER_TOKEN|STATS_SECRET)
            case "$setting_key" in
                PANEL_URL) setting_name=SSPANEL_BASE_URL ;;
                MU_KEY) setting_name=SSPANEL_MU_KEY ;;
                NODE_ID) setting_name=SSPANEL_NODE_ID ;;
                ADAPTER_TOKEN) setting_name=ADAPTER_AUTH_TOKEN ;;
                STATS_SECRET) setting_name=HY2_STATS_SECRET ;;
            esac
            [ -f "$setting_env" ] && awk -v key="$setting_name" '$0 ~ "^" key "=" { sub(/^[^=]*=/, ""); print; exit }' "$setting_env"
            ;;
        LOCAL_PORT)
            if [ -f "$setting_config" ]; then
                if [ "$setting_mode" = hy2 ]; then
                    awk '/^listen:/ { sub(/^.*:/, ""); print; exit }' "$setting_config"
                else
                    jq -r '.inbounds[0].port // empty' "$setting_config"
                fi
            fi ;;
        DOMAIN) [ -f "$setting_config" ] && awk '/^  domains:/ { found=1; next } found && /^    - / { print $2; exit }' "$setting_config" ;;
        EMAIL) [ -f "$setting_config" ] && awk '/^  email:/ { print $2; exit }' "$setting_config" ;;
        CF_TOKEN) [ -f "$setting_config" ] && awk '/^      cloudflare_api_token:/ { print $2; exit }' "$setting_config" ;;
        CREDENTIAL_FIELD)
            setting_adapter="/etc/sspanel-native/$setting_mode/adapter.yaml"
            [ -f "$setting_adapter" ] && awk '/^  credential_fields:/ { gsub(/[^a-z]/, "", $2); print $2; exit }' "$setting_adapter" ;;
        TARGET) [ -f "$setting_config" ] && jq -r '.inbounds[0].streamSettings.realitySettings.target // empty | sub(":443$"; "")' "$setting_config" ;;
        SNI) [ -f "$setting_config" ] && jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$setting_config" ;;
        REALITY_PRIVATE) [ -f "$setting_config" ] && jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$setting_config" ;;
        SHORT_ID) [ -f "$setting_config" ] && jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$setting_config" ;;
    esac
    return 0
}
default_of() {
    default_value=$(setting "$1" "$2")
    printf '%s\n' "${default_value:-$3}"
}
write_settings() {
    settings_file="$MANAGED_DIR/settings/$MODE.conf"
    install -d -m 700 "$(dirname "$settings_file")"
    {
        printf 'PANEL_URL=%s\nMU_KEY=%s\nNODE_ID=%s\nADAPTER_TOKEN=%s\n' "$PANEL_URL" "$MU_KEY" "$NODE_ID" "$ADAPTER_TOKEN"
        printf 'PUBLIC_PORT=%s\nLOCAL_PORT=%s\n' "$PUBLIC_PORT" "$LOCAL_PORT"
        if [ "$MODE" = hy2 ]; then
            printf 'DOMAIN=%s\nEMAIL=%s\nCF_TOKEN=%s\nSTATS_SECRET=%s\nCREDENTIAL_FIELD=%s\n' \
                "$DOMAIN" "$EMAIL" "$CF_TOKEN" "$STATS_SECRET" "$CREDENTIAL_FIELD"
        else
            printf 'TARGET=%s\nSNI=%s\nREALITY_PRIVATE=%s\nSHORT_ID=%s\n' "$TARGET" "$SNI" "$REALITY_PRIVATE" "$SHORT_ID"
        fi
    } > "$settings_file.new"
    chmod 600 "$settings_file.new"
    mv -f "$settings_file.new" "$settings_file"
}

prompt_common() {
    PANEL_URL=$(required 'SSPanel 地址（https://...）' "$(setting "$MODE" PANEL_URL)" no)
    case "$PANEL_URL" in https://*|http://*) ;; *) die '面板地址必须以 http:// 或 https:// 开头' ;; esac
    safe_scalar "$PANEL_URL" || die '面板地址含有不支持的字符'
    PANEL_URL=${PANEL_URL%/}
    MU_KEY=$(required 'SSPanel MuKey（输入时隐藏）' "$(setting "$MODE" MU_KEY)" yes)
    safe_scalar "$MU_KEY" || die 'MuKey 含有不支持的字符'
    NODE_ID=$(required '该协议对应的节点 ID' "$(setting "$MODE" NODE_ID)" no)
    numeric_id "$NODE_ID" || die '节点 ID 必须是正整数'
    ADAPTER_TOKEN=$(random_value 'Adapter 鉴权密钥' "$(setting "$MODE" ADAPTER_TOKEN)" 32)
    safe_token "$ADAPTER_TOKEN" || die '鉴权密钥只能包含字母、数字、下划线和连字符'
    default_local=$(default_of "$MODE" LOCAL_PORT '')
    default_public=$(default_of "$MODE" PUBLIC_PORT "$default_local")
    PUBLIC_PORT=$(port_prompt "NAT 公网 $PROTOCOL 端口" "$default_public")
    LOCAL_PORT=$(port_prompt "NAT 转发到本机的 $PROTOCOL 端口" "${default_local:-$PUBLIC_PORT}")
}
prompt_hy2() {
    CREDENTIAL_FIELD=$(required 'HY2 用户密码字段（uuid 或 passwd）' "$(default_of hy2 CREDENTIAL_FIELD uuid)" no)
    case "$CREDENTIAL_FIELD" in uuid|passwd) ;; *) die '密码字段只能是 uuid 或 passwd' ;; esac
    DOMAIN=$(required 'HY2 证书域名 / 客户端 SNI' "$(setting hy2 DOMAIN)" no)
    dns_name "$DOMAIN" || die '证书域名格式不正确'
    EMAIL=$(required 'ACME 联系邮箱' "$(setting hy2 EMAIL)" no)
    safe_scalar "$EMAIL" || die '邮箱含有不支持的字符'
    case "$EMAIL" in *@*.*) ;; *) die '邮箱格式不正确' ;; esac
    CF_TOKEN=$(required 'Cloudflare DNS API Token（输入时隐藏）' "$(setting hy2 CF_TOKEN)" yes)
    safe_token "$CF_TOKEN" || die 'Cloudflare Token 只能包含字母、数字、下划线和连字符'
    STATS_SECRET=$(random_value 'HY2 统计密钥' "$(setting hy2 STATS_SECRET)" 32)
    safe_token "$STATS_SECRET" || die '统计密钥只能包含字母、数字、下划线和连字符'
}
prompt_vless() {
    TARGET=$(required 'REALITY 目标域名（需支持 TLS 1.3）' "$(setting vless TARGET)" no)
    dns_name "$TARGET" || die '目标域名格式不正确'
    SNI=$(required 'REALITY 客户端 SNI' "$(default_of vless SNI "$TARGET")" no)
    dns_name "$SNI" || die 'SNI 格式不正确'
    old_private=$(setting vless REALITY_PRIVATE)
    if [ -n "$old_private" ]; then
        key_input=$(ask 'REALITY 私钥（回车保留，输入 new 重新生成）' "$old_private" yes)
    else
        key_input=$(ask 'REALITY 私钥（直接回车自动生成）' '' yes)
    fi
    case "$key_input" in
        ''|new) key_pair=$("$MANAGED_DIR/bin/xray-linux" x25519) ;;
        *) key_pair=$("$MANAGED_DIR/bin/xray-linux" x25519 -i "$key_input") ;;
    esac
    REALITY_PRIVATE=$(printf '%s\n' "$key_pair" | awk '/^PrivateKey:/ { print $2; exit }')
    REALITY_PUBLIC=$(printf '%s\n' "$key_pair" | awk '/^Password:/ { print $2; exit }')
    [ -n "$REALITY_PRIVATE" ] && [ -n "$REALITY_PUBLIC" ] || die 'REALITY 密钥生成失败'
    SHORT_ID=$(random_value 'REALITY Short ID' "$(setting vless SHORT_ID)" 8)
    printf '%s\n' "$SHORT_ID" | grep -Eq '^[0-9a-fA-F]{2,16}$' || die 'Short ID 必须是 2 到 16 位十六进制字符'
}

write_config() {
    STAGE=$(mktemp -d)
    cat > "$STAGE/server.env" <<EOF
ADAPTER_AUTH_TOKEN=$ADAPTER_TOKEN
SSPANEL_BASE_URL=$PANEL_URL
SSPANEL_MU_KEY=$MU_KEY
SSPANEL_NODE_ID=$NODE_ID
EOF
    if [ "$MODE" = hy2 ]; then
        printf 'HY2_STATS_SECRET=%s\n' "$STATS_SECRET" >> "$STAGE/server.env"
        cat > "$STAGE/adapter.yaml" <<'EOF'
server:
  listen: 127.0.0.1:18080
  auth_path: /auth
  auth_token: "${ADAPTER_AUTH_TOKEN}"
  read_timeout: 5s
  write_timeout: 15s
panel:
  base_url: "${SSPANEL_BASE_URL}"
  key: "${SSPANEL_MU_KEY}"
  node_id: ${SSPANEL_NODE_ID}
  timeout: 5s
  heartbeat_interval: 60s
  insecure_skip_verify: false
user_source:
  mode: api
  credential_fields: [uuid]
  api:
    refresh_interval: 60s
    max_stale: 5m
hy2:
  enabled: true
  stats_url: http://127.0.0.1:19999
  stats_secret: "${HY2_STATS_SECRET}"
  timeout: 5s
  poll_interval: 60s
  state_file: ./traffic-state.json
  run_on_startup: true
xray:
  enabled: false
log:
  level: warn
EOF
        sed -i "s/credential_fields: \[uuid\]/credential_fields: [$CREDENTIAL_FIELD]/" "$STAGE/adapter.yaml"
        cat > "$STAGE/server.yaml" <<EOF
listen: 0.0.0.0:$LOCAL_PORT
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
  ca: letsencrypt
  dir: /var/lib/sspanel-native/hy2/acme
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: $CF_TOKEN
auth:
  type: http
  http:
    url: http://127.0.0.1:18080/auth?token=$ADAPTER_TOKEN
    insecure: false
trafficStats:
  listen: 127.0.0.1:19999
  secret: $STATS_SECRET
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
    else
        cat > "$STAGE/adapter.yaml" <<'EOF'
server:
  listen: 127.0.0.1:18081
  auth_path: /auth
  auth_token: "${ADAPTER_AUTH_TOKEN}"
  read_timeout: 5s
  write_timeout: 15s
panel:
  base_url: "${SSPANEL_BASE_URL}"
  key: "${SSPANEL_MU_KEY}"
  node_id: ${SSPANEL_NODE_ID}
  timeout: 5s
  heartbeat_interval: 60s
  insecure_skip_verify: false
user_source:
  mode: api
  credential_fields: [uuid]
  api:
    refresh_interval: 60s
    max_stale: 5m
hy2:
  enabled: false
xray:
  enabled: true
  api_address: 127.0.0.1:10085
  inbound_tag: vless-reality
  timeout: 5s
  sync_interval: 60s
  poll_interval: 60s
  state_file: ./xray-traffic-state.json
  run_on_startup: true
log:
  level: warn
EOF
        cat > "$STAGE/server.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "api": { "tag": "api", "listen": "127.0.0.1:10085", "services": ["HandlerService", "StatsService"] },
  "stats": {},
  "policy": { "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } } },
  "inbounds": [{
    "tag": "vless-reality", "listen": "0.0.0.0", "port": $LOCAL_PORT,
    "protocol": "vless", "settings": { "clients": [], "decryption": "none" },
    "streamSettings": {
      "network": "raw", "security": "reality",
      "realitySettings": {
        "show": false, "target": "$TARGET:443", "xver": 0,
        "serverNames": ["$SNI"], "privateKey": "$REALITY_PRIVATE",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
        jq -e . "$STAGE/server.json" >/dev/null || die 'Xray JSON 无效'
        "$MANAGED_DIR/bin/xray-linux" run -test -config "$STAGE/server.json" >/dev/null || die 'Xray 配置校验失败'
    fi
    chmod 600 "$STAGE"/*
}

deploy_config() {
    NATIVE_CONFIG_DIR=$STAGE /bin/sh "$MANAGED_DIR/scripts/install-native.sh" "$MODE" || die '安装失败；上方错误及服务日志可用于定位'
    install -d -m 700 "$MANAGED_DIR/native/$MODE"
    install -m 600 "$STAGE/server.env" "$MANAGED_DIR/native/$MODE/server.env"
    install -m 600 "$STAGE/adapter.yaml" "$MANAGED_DIR/native/$MODE/adapter.yaml"
    if [ "$MODE" = hy2 ]; then config_name=server.yaml; else config_name=server.json; fi
    install -m 600 "$STAGE/$config_name" "$MANAGED_DIR/native/$MODE/$config_name"
    write_settings
    install -d -m 755 "$(dirname "$MANAGER_BIN")"
    if [ "$0" != "$MANAGER_BIN" ]; then install -m 755 "$0" "$MANAGER_BIN"; fi
    rm -rf -- "$STAGE"
    STAGE=
    wait_listener "$LOCAL_PORT"
    say "完成。客户端使用 NAT 公网 $PROTOCOL 端口 $PUBLIC_PORT；本机监听 $LOCAL_PORT。"
    say "请确认面板节点 offset_port_user 为 $PUBLIC_PORT，并确保 NAT 的 $PROTOCOL 转发目标为本机 $LOCAL_PORT。"
    if [ "$MODE" = hy2 ]; then
        say "SNI：$DOMAIN；密码使用 SSPanel 用户的 $CREDENTIAL_FIELD。"
    else
        say "REALITY SNI：$SNI；Public Key：$REALITY_PUBLIC；Short ID：$SHORT_ID。"
        say '客户端 UUID 为 SSPanel 用户 UUID，flow 为 xtls-rprx-vision。'
    fi
    say "以后运行 $MANAGER_BIN，可选择卸载、重启或修改配置。"
}

configure_mode() {
    MODE=$1
    mode_names "$MODE"
    prompt_common
    if [ "$MODE" = hy2 ]; then prompt_hy2; else prompt_vless; fi
    write_config
    deploy_config
}

collect_traffic() {
    collect_mode=$1
    mode_names "$collect_mode"
    if ! service_active "$ADAPTER_SERVICE"; then
        service_active "$PROXY_SERVICE" && return 1
        return 0
    fi
    collect_env="/etc/sspanel-native/$collect_mode/server.env"
    [ -f "$collect_env" ] || return 1
    collect_token=$(awk -F= '$1 == "ADAPTER_AUTH_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "$collect_env")
    [ -n "$collect_token" ] || return 1
    curl -fsS --max-time 20 -X POST -H "X-Adapter-Token: $collect_token" \
        "http://127.0.0.1:$ADMIN_PORT/admin/collect" >/dev/null
}
collect_or_confirm() {
    if ! collect_traffic "$1"; then
        say '最后一段流量上报失败，继续会丢失尚未结算的流量。' >&2
        force_answer=$(ask '如要继续，输入 FORCE' '' no)
        [ "$force_answer" = FORCE ] || die '操作已取消'
    fi
}
wait_health() {
    health_try=0
    while [ "$health_try" -lt 20 ]; do
        if curl -fsS --max-time 2 "http://127.0.0.1:$ADMIN_PORT/healthz" >/dev/null 2>&1; then
            say 'Adapter 健康检查通过。'
            return 0
        fi
        health_try=$((health_try + 1))
        sleep 1
    done
    die "Adapter 未通过健康检查；查看 /var/log/sspanel-native/$ADAPTER_SERVICE.err.log"
}
wait_listener() {
    listener_port=$1
    listener_hex=$(printf '%04X' "$listener_port")
    if [ "$MODE" = hy2 ]; then
        listener_state=07
        listener_files='/proc/net/udp /proc/net/udp6'
    else
        listener_state=0A
        listener_files='/proc/net/tcp /proc/net/tcp6'
    fi
    listener_try=0
    while [ "$listener_try" -lt 45 ]; do
        # /proc/net is available on both Alpine/OpenRC and Linux/systemd.
        for listener_file in $listener_files; do
            [ -r "$listener_file" ] || continue
            if awk -v port=":$listener_hex" -v state="$listener_state" \
                '$2 ~ port "$" && $4 == state { found=1 } END { exit !found }' "$listener_file"; then
                say "代理已监听本机 $PROTOCOL 端口 $listener_port。"
                return 0
            fi
        done
        listener_try=$((listener_try + 1))
        sleep 1
    done
    die "代理没有监听 $listener_port/$PROTOCOL；查看 /var/log/sspanel-native/$PROXY_SERVICE.err.log"
}
restart_mode() {
    MODE=$1
    mode_names "$MODE"
    installed "$MODE" || die "$MODE 尚未安装"
    LOCAL_PORT=$(setting "$MODE" LOCAL_PORT)
    valid_port "$LOCAL_PORT" || die '无法确定本机监听端口'
    collect_or_confirm "$MODE"
    if service_active "$ADAPTER_SERVICE"; then service_stop "$ADAPTER_SERVICE"; fi
    if service_active "$PROXY_SERVICE"; then service_stop "$PROXY_SERVICE"; fi
    service_start "$PROXY_SERVICE"
    service_start "$ADAPTER_SERVICE"
    wait_health
    wait_listener "$LOCAL_PORT"
}

remove_service() {
    remove_name=$1
    if [ "$(init_system)" = systemd ]; then
        systemctl disable --now "$remove_name.service" >/dev/null 2>&1 || :
    else
        rc-update del "$remove_name" default >/dev/null 2>&1 || :
    fi
    if service_active "$remove_name"; then service_stop "$remove_name" || :; fi
    rm -f -- "/etc/init.d/$remove_name" "/etc/systemd/system/$remove_name.service"
}
uninstall_all() {
    say '将删除 HY2/VLESS 服务、项目二进制、配置、证书、状态与日志；不会删除当前 Git 仓库和系统共享软件包。'
    uninstall_answer=$(ask '确认输入 DELETE' '' no)
    [ "$uninstall_answer" = DELETE ] || die '卸载已取消'
    for uninstall_mode in hy2 vless; do
        if installed "$uninstall_mode"; then collect_or_confirm "$uninstall_mode"; fi
    done
    for uninstall_mode in hy2 vless; do
        mode_names "$uninstall_mode"
        remove_service "$ADAPTER_SERVICE"
        remove_service "$PROXY_SERVICE"
    done
    if [ "$(init_system)" = systemd ]; then systemctl daemon-reload; fi
    rm -f -- /usr/local/bin/sspanel-hy2-adapter /usr/local/bin/hysteria /usr/local/bin/xray
    rm -rf -- /etc/sspanel-native /var/lib/sspanel-native /var/log/sspanel-native "$MANAGED_DIR"
    rm -f -- "$MANAGER_BIN"
    say '原生服务及其项目文件已卸载。'
}

menu_action() {
    case "$1" in
        1)
            selected=$(choose_mode)
            [ -n "$selected" ] || return 0
            installed "$selected" && die "$selected 已安装；请选择 4 修改配置"
            ensure_dependencies "$selected"
            fetch_assets "$selected"
            configure_mode "$selected"
            ;;
        2) uninstall_all ;;
        3|4)
            selected=$(choose_mode)
            [ -n "$selected" ] || return 0
            installed "$selected" || die "$selected 尚未安装"
            if [ "$1" = 3 ]; then
                restart_mode "$selected"
            else
                ensure_assets "$selected"
                configure_mode "$selected"
            fi
            ;;
        0) exit 0 ;;
        *) say '无效命令。' >&2 ;;
    esac
}

if [ "$#" -gt 1 ]; then die '用法：native-manager.sh [0|1|2|3|4]'; fi
if [ "$#" -eq 1 ]; then menu_action "$1"; exit 0; fi
while :; do
    say ''
    say '1) 安装'
    say '2) 卸载全部'
    say '3) 重启'
    say '4) 修改配置并重启'
    say '0) 退出'
    menu_choice=$(ask '请输入命令' '' no)
    menu_action "$menu_choice"
done
