#!/bin/sh
# Interactive native deployment manager for small Linux NAT servers.
set -eu
umask 077

RAW_BASE=${NATIVE_REPO_RAW_BASE:-https://raw.githubusercontent.com/blakelu/sspanel-hy2-adapter/main}
MANAGED_DIR=${NATIVE_MANAGED_DIR:-/opt/sspanel-native}
MANAGER_BIN=/usr/local/sbin/sspanel-native-manager
STAGE=
TTY_STATE=
ACME_LOCK=
CERT_SYSTEMD_DIR=/etc/systemd/system
CERT_PERIODIC_DIR=/etc/periodic/daily
CERT_RENEW_LOG=/var/log/sspanel-native/vless-cert-renew.log
CERT_LOCK_DIR=/run/sspanel-native-vless-cert.lock

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
release_acme_lock() {
    if [ -n "$ACME_LOCK" ]; then rmdir "$ACME_LOCK" 2>/dev/null || :; ACME_LOCK=; fi
}
cleanup() {
    if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" <&3 2>/dev/null || :; fi
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf -- "$STAGE"; fi
    release_acme_lock
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
        anytls) PROXY=sspanel-hy2-adapter; ADMIN_PORT=18082; PROTOCOL=TCP ;;
        *) die '未知协议' ;;
    esac
    PROXY_SERVICE=sspanel-native-$1-$PROXY
    ADAPTER_SERVICE=sspanel-native-$1-adapter
    [ "$1" != anytls ] || PROXY_SERVICE=$ADAPTER_SERVICE
}
choose_mode() {
    say '1) HY2' >&2
    say '2) VLESS（REALITY / WebSocket + TLS）' >&2
    say '3) AnyTLS（TLS 直连 / SSPanel 多用户）' >&2
    say '0) 返回' >&2
    choice=$(ask '选择协议' '' no)
    case "$choice" in 1) printf 'hy2\n' ;; 2) printf 'vless\n' ;; 3) printf 'anytls\n' ;; 0) printf '\n' ;; *) say '无效选择。' >&2; printf '\n' ;; esac
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
    if [ -n "${NATIVE_LOCAL_ASSETS_DIR:-}" ]; then
        cp "$NATIVE_LOCAL_ASSETS_DIR/$download_path" "$download_dest" || die "本地文件不存在：$download_path"
        return
    fi
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
    case "$fetch_mode" in hy2) fetch_proxy=hysteria ;; vless) fetch_proxy=xray ;; anytls) fetch_proxy=sspanel-hy2-adapter ;; esac
    fetch_files='scripts/install-native.sh bin/sspanel-hy2-adapter-linux bin/anytls-LICENSE bin/anytls-SOURCE.txt'
    if [ "$fetch_mode" != anytls ]; then fetch_files="$fetch_files bin/$fetch_proxy-linux"; fi
    for fetch_path in $fetch_files; do
        download "$fetch_path" "$STAGE/$fetch_path"
        verify_download "$fetch_path" "$STAGE/$fetch_path"
    done
    install -d -m 700 "$MANAGED_DIR" "$MANAGED_DIR/bin" "$MANAGED_DIR/scripts" "$MANAGED_DIR/settings" "$MANAGED_DIR/native/$fetch_mode"
    install -m 600 "$STAGE/bin/SHA256SUMS" "$MANAGED_DIR/bin/SHA256SUMS"
    install -m 755 "$STAGE/scripts/install-native.sh" "$MANAGED_DIR/scripts/install-native.sh"
    install -m 755 "$STAGE/bin/sspanel-hy2-adapter-linux" "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux"
    install -m 644 "$STAGE/bin/anytls-LICENSE" "$STAGE/bin/anytls-SOURCE.txt" "$MANAGED_DIR/bin/"
    if [ "$fetch_mode" != anytls ]; then install -m 755 "$STAGE/bin/$fetch_proxy-linux" "$MANAGED_DIR/bin/$fetch_proxy-linux"; fi
    if [ "$fetch_mode" = hy2 ]; then
        "$MANAGED_DIR/bin/hysteria-linux" version >/dev/null || die 'Hysteria 无法在本机执行'
    elif [ "$fetch_mode" = vless ]; then
        "$MANAGED_DIR/bin/xray-linux" version >/dev/null || die 'Xray 无法在本机执行'
    fi
    "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -version >/dev/null || die 'Adapter 无法在本机执行'
    if [ "$fetch_mode" = anytls ]; then
        "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -capabilities 2>/dev/null | grep -qw anytls ||
            die '下载源的 Adapter 尚未支持 AnyTLS；请发布新版二进制，或设置 NATIVE_LOCAL_ASSETS_DIR 使用本地新版文件'
    fi
    rm -rf -- "$STAGE"
    STAGE=
}
ensure_assets() {
    mode_names "$1"
    if ! command -v curl >/dev/null 2>&1 || \
       { [ "$1" = vless ] && ! command -v jq >/dev/null 2>&1; }; then
        ensure_dependencies "$1"
    fi
    if [ "$1" = anytls ] && ! "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -capabilities 2>/dev/null | grep -qw anytls; then
        fetch_assets anytls
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
        if awk -v key="$setting_key" '$0 ~ "^" key "=" { sub(/^[^=]*=/, ""); print; found=1; exit } END { exit !found }' "$setting_file"; then
            return
        fi
    fi
    setting_env="/etc/sspanel-native/$setting_mode/server.env"
    setting_config="/etc/sspanel-native/$setting_mode/server.yaml"
    [ "$setting_mode" = vless ] && setting_config="/etc/sspanel-native/vless/server.json"
    [ "$setting_mode" != anytls ] || setting_config="/etc/sspanel-native/anytls/adapter.yaml"
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
                elif [ "$setting_mode" = anytls ]; then
                    awk '/^anytls:/ { found=1; next } found && /^  listen:/ { sub(/^.*:/, ""); gsub(/"/, ""); print; exit }' "$setting_config"
                else
                    jq -r '.inbounds[0].port // empty' "$setting_config"
                fi
            fi ;;
        DOMAIN)
            if [ -f "$setting_config" ]; then
                if [ "$setting_mode" = hy2 ]; then
                    awk '/^  domains:/ { found=1; next } found && /^    - / { print $2; exit }' "$setting_config"
                elif [ "$setting_mode" = anytls ]; then
                    [ -f "$setting_env" ] && awk -F= '$1 == "ANYTLS_DOMAIN" { print $2; exit }' "$setting_env"
                else
                    jq -r '.inbounds[0].streamSettings.tlsSettings.serverName // empty' "$setting_config"
                fi
            fi ;;
        VLESS_TRANSPORT)
            if [ -f "$setting_config" ]; then
                jq -r 'if .inbounds[0].streamSettings.network == "ws" then "ws-tls" else "reality" end' "$setting_config"
            fi ;;
        WS_PATH) [ -f "$setting_config" ] && jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$setting_config" ;;
        TLS_CERT_FILE|TLS_KEY_FILE)
            if [ -f "$setting_config" ]; then
                if [ "$setting_mode" = anytls ]; then
                    case "$setting_key" in TLS_CERT_FILE) setting_tls_name=certificate_file ;; TLS_KEY_FILE) setting_tls_name=key_file ;; esac
                    awk -v key="$setting_tls_name" '/^anytls:/ { found=1; next } found && $1 == key ":" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$setting_config"
                elif [ "$setting_key" = TLS_CERT_FILE ]; then
                    jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile // empty' "$setting_config"
                else
                    jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].keyFile // empty' "$setting_config"
                fi
            fi ;;
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
        elif [ "$MODE" = anytls ] || [ "$VLESS_TRANSPORT" = ws-tls ]; then
            if [ "$MODE" = vless ]; then printf 'VLESS_TRANSPORT=ws-tls\nWS_PATH=%s\n' "$WS_PATH"; fi
            printf 'DOMAIN=%s\nTLS_CERT_FILE=%s\nTLS_KEY_FILE=%s\n' "$DOMAIN" "$TLS_CERT_FILE" "$TLS_KEY_FILE"
            printf 'TLS_CERT_MODE=%s\n' "$TLS_CERT_MODE"
            if [ "$TLS_CERT_MODE" = acme ]; then
                printf 'EMAIL=%s\nCF_TOKEN=%s\nCF_ZONE_ID=%s\n' "$EMAIL" "$CF_TOKEN" "$CF_ZONE_ID"
            fi
        else
            printf 'VLESS_TRANSPORT=reality\n'
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
    if [ "$MODE" = vless ] && [ "$VLESS_TRANSPORT" = ws-tls ]; then
        say '客户端固定连接 Cloudflare 域名的 443；下方填写 Cloudflare 回源使用的 NAT 公网端口。' >&2
        PUBLIC_PORT=$(port_prompt 'Cloudflare 回源 NAT 公网 TCP 端口' "${default_public:-443}")
        if [ "$PUBLIC_PORT" != 443 ]; then
            say "必须在 Cloudflare 为该域名配置 Origin Rule，将目标端口改为 $PUBLIC_PORT；客户端仍使用 443。" >&2
        fi
    else
        PUBLIC_PORT=$(port_prompt "NAT 公网 $PROTOCOL 端口" "$default_public")
    fi
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
choose_vless_transport() {
    transport_current=$(default_of vless VLESS_TRANSPORT reality)
    case "$transport_current" in reality) transport_default=1 ;; ws-tls) transport_default=2 ;; *) die '未知 VLESS 传输方式' ;; esac
    say '1) VLESS + REALITY（直连）' >&2
    say '2) VLESS + WebSocket + TLS（Cloudflare 橙云，客户端 443）' >&2
    while :; do
        transport_choice=$(ask '选择 VLESS 传输方式' "$transport_default" no)
        case "$transport_choice" in
            1) VLESS_TRANSPORT=reality; return ;;
            2) VLESS_TRANSPORT=ws-tls; return ;;
            *) say '无效选择。' >&2 ;;
        esac
    done
}
prompt_vless_ws() {
    DOMAIN=$(required 'Cloudflare 橙云域名（客户端地址 / SNI / WS Host）' "$(setting vless DOMAIN)" no)
    dns_name "$DOMAIN" || die '域名格式不正确'
    DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    WS_PATH=$(required 'WebSocket 路径（以 / 开头）' "$(default_of vless WS_PATH /vless)" no)
    printf '%s\n' "$WS_PATH" | grep -Eq '^/[A-Za-z0-9/_-]*$' || die '路径必须以 / 开头，只能包含字母、数字、/、_、-'
    choose_vless_cert_mode
    say 'Cloudflare SSL/TLS 请设为 Full (strict)。' >&2
    if [ "$TLS_CERT_MODE" = acme ]; then
        EMAIL=$(required 'ACME 联系邮箱' "$(setting vless EMAIL)" no)
        safe_scalar "$EMAIL" || die '邮箱含有不支持的字符'
        case "$EMAIL" in *@*.*) ;; *) die '邮箱格式不正确' ;; esac
        CF_TOKEN=$(required 'Cloudflare DNS API Token（输入时隐藏）' "$(setting vless CF_TOKEN)" yes)
        safe_token "$CF_TOKEN" || die 'Cloudflare Token 只能包含字母、数字、下划线和连字符'
        CF_ZONE_ID=$(required 'Cloudflare Zone ID（域名概览页）' "$(setting vless CF_ZONE_ID)" no)
        printf '%s\n' "$CF_ZONE_ID" | grep -Eq '^[0-9a-fA-F]{32}$' || die 'Zone ID 必须是 32 位十六进制字符'
        prepare_vless_acme
    else
        say '请先准备覆盖该域名的 PEM 证书和私钥（支持 Cloudflare Origin CA）。' >&2
        TLS_CERT_FILE=$(required '源站 TLS 证书绝对路径' "$(setting vless TLS_CERT_FILE)" no)
        TLS_KEY_FILE=$(required '源站 TLS 私钥绝对路径' "$(setting vless TLS_KEY_FILE)" no)
    fi
    for tls_file in "$TLS_CERT_FILE" "$TLS_KEY_FILE"; do
        case "$tls_file" in /*) ;; *) die '证书和私钥必须使用绝对路径' ;; esac
        safe_scalar "$tls_file" || die '证书路径含有不支持的字符'
        if [ ! -f "$tls_file" ] || [ ! -r "$tls_file" ] || [ ! -s "$tls_file" ]; then
            die "证书文件不存在、不可读或为空：$tls_file"
        fi
    done
    # Old cached adapters reject xray.flow. Upgrade before stopping any service.
    if ! "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -h 2>&1 | grep -q -- '-check-config'; then
        say '更新 Adapter 以支持 WebSocket 空 flow。' >&2
        fetch_assets vless
    fi
}
prompt_anytls() {
    DOMAIN=$(required 'AnyTLS 证书域名 / 客户端 SNI（DNS 使用灰云直连）' "$(setting anytls DOMAIN)" no)
    dns_name "$DOMAIN" || die '域名格式不正确'
    DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    say 'AnyTLS 使用原生 TLS/TCP，域名应指向源站并关闭普通 Cloudflare 橙云；用户密码为 SSPanel UUID。' >&2
    choose_vless_cert_mode
    if [ "$TLS_CERT_MODE" = acme ]; then
        EMAIL=$(required 'ACME 联系邮箱' "$(setting anytls EMAIL)" no)
        safe_scalar "$EMAIL" || die '邮箱含有不支持的字符'
        case "$EMAIL" in *@*.*) ;; *) die '邮箱格式不正确' ;; esac
        CF_TOKEN=$(required 'Cloudflare DNS API Token（输入时隐藏）' "$(setting anytls CF_TOKEN)" yes)
        safe_token "$CF_TOKEN" || die 'Cloudflare Token 格式不正确'
        CF_ZONE_ID=$(required 'Cloudflare Zone ID（域名概览页）' "$(setting anytls CF_ZONE_ID)" no)
        printf '%s\n' "$CF_ZONE_ID" | grep -Eq '^[0-9a-fA-F]{32}$' || die 'Zone ID 必须是 32 位十六进制字符'
        prepare_vless_acme
    else
        say '请使用客户端信任、覆盖该域名的完整 PEM 证书链（例如 Let’s Encrypt）；Cloudflare Origin CA 不适用于直连客户端。' >&2
        TLS_CERT_FILE=$(required 'TLS 证书绝对路径' "$(setting anytls TLS_CERT_FILE)" no)
        TLS_KEY_FILE=$(required 'TLS 私钥绝对路径' "$(setting anytls TLS_KEY_FILE)" no)
    fi
    for tls_file in "$TLS_CERT_FILE" "$TLS_KEY_FILE"; do
        case "$tls_file" in /*) ;; *) die '证书和私钥必须使用绝对路径' ;; esac
        safe_scalar "$tls_file" || die '证书路径含有不支持的字符'
        [ -r "$tls_file" ] && [ -s "$tls_file" ] || die "证书文件不存在、不可读或为空：$tls_file"
    done
}
choose_vless_cert_mode() {
    cert_current=$(setting "${MODE:-vless}" TLS_CERT_MODE)
    if [ -z "$cert_current" ]; then
        if [ -n "$(setting "${MODE:-vless}" TLS_CERT_FILE)" ]; then cert_current=manual; else cert_current=acme; fi
    fi
    case "$cert_current" in acme) cert_default=1 ;; manual) cert_default=2 ;; *) die '未知证书管理方式' ;; esac
    say "1) 自动申请并续期（Let's Encrypt / Cloudflare DNS API）" >&2
    say '2) 手动指定 PEM 证书和私钥路径' >&2
    while :; do
        cert_choice=$(ask '选择源站 TLS 证书管理方式' "$cert_default" no)
        case "$cert_choice" in
            1) TLS_CERT_MODE=acme; return ;;
            2) TLS_CERT_MODE=manual; return ;;
            *) say '无效选择。' >&2 ;;
        esac
    done
}
acme_paths() {
    # Paths are also embedded in systemd/periodic jobs; keep them unambiguous.
    printf '%s\n' "$MANAGED_DIR" | grep -Eq '^/[A-Za-z0-9._/-]+$' || die '自动证书模式要求管理目录为不含空格或特殊字符的绝对路径'
    dns_name "$DOMAIN" || die '证书域名格式不正确'
    ACME_CLIENT="$MANAGED_DIR/acme-client"
    ACME_STATE="$MANAGED_DIR/acme-${MODE:-vless}/$DOMAIN"
    TLS_CERT_FILE="$ACME_STATE/tls/fullchain.pem"
    TLS_KEY_FILE="$ACME_STATE/tls/key.pem"
}
acquire_acme_lock() {
    install -d -m 700 "$MANAGED_DIR/acme-${MODE:-vless}"
    mkdir "$CERT_LOCK_DIR" 2>/dev/null || die "另一项证书操作正在运行；如进程已退出，请检查并移除 $CERT_LOCK_DIR 后重试"
    ACME_LOCK=$CERT_LOCK_DIR
}
ensure_acme_client() {
    if ! command -v openssl >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then apk add --no-cache openssl
        elif command -v apt-get >/dev/null 2>&1; then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
        else die '自动申请证书需要 openssl'; fi
    fi
    install -d -m 700 "$ACME_CLIENT" "$ACME_CLIENT/dnsapi" "$ACME_STATE/tls"
    # acme.sh 3.1.4, pinned to its release commit and file SHA-256 values.
    acme_base=https://raw.githubusercontent.com/acmesh-official/acme.sh/3661fd86b6304115e42f43910e6dd452ab9866d6
    for acme_file in acme.sh dnsapi/dns_cf.sh; do
        case "$acme_file" in
            acme.sh) acme_sum=fcabf274d4f96966ec933879ae0257266e8ef2f7d16161f14b84dd896c0cac32 ;;
            dnsapi/dns_cf.sh) acme_sum=9628ee8238cb3f9cfa1b1a985c0e9593436a3e4f8a9d65a6f775b981be9e76c8 ;;
        esac
        if printf '%s  %s\n' "$acme_sum" "$ACME_CLIENT/$acme_file" | sha256sum -c - >/dev/null 2>&1; then continue; fi
        curl -fLsS --retry 3 --connect-timeout 10 --max-time 180 "$acme_base/$acme_file" \
            -o "$ACME_CLIENT/$acme_file.new" || die "acme.sh 下载失败：$acme_file"
        printf '%s  %s\n' "$acme_sum" "$ACME_CLIENT/$acme_file.new" | sha256sum -c - >/dev/null || die "acme.sh 校验失败：$acme_file"
        chmod 700 "$ACME_CLIENT/$acme_file.new"
        mv -f "$ACME_CLIENT/$acme_file.new" "$ACME_CLIENT/$acme_file"
    done
}
acme_run() {
    # renew/install source the domain config, which otherwise overrides rotated
    # credentials passed in the environment. Use the manager's saved values.
    acme_conf="$ACME_STATE/${DOMAIN}_ecc/$DOMAIN.conf"
    if [ -f "$acme_conf" ]; then
        sed '/^CF_Token=/d; /^CF_Zone_ID=/d; /^CF_Account_ID=/d' "$acme_conf" > "$acme_conf.new" || die '无法更新 ACME DNS 凭据'
        chmod 600 "$acme_conf.new"
        mv -f "$acme_conf.new" "$acme_conf"
    fi
    # Credentials stay out of argv; manager settings supply them at each run.
    CF_Token=$CF_TOKEN CF_Zone_ID=$CF_ZONE_ID CF_Account_ID='' CF_Key='' CF_Email='' \
        /bin/sh "$ACME_CLIENT/acme.sh" --home "$ACME_CLIENT" --config-home "$ACME_STATE" "$@"
}
install_vless_acme_cert() {
    acme_run --install-cert -d "$DOMAIN" --ecc --key-file "$TLS_KEY_FILE" \
        --fullchain-file "$TLS_CERT_FILE" --reloadcmd ':' || die '安装 ACME 证书失败'
    chmod 600 "$TLS_KEY_FILE" "$TLS_CERT_FILE"
    openssl x509 -in "$TLS_CERT_FILE" -noout -checkend 0 -checkhost "$DOMAIN" >/dev/null || die 'ACME 证书已过期或不覆盖该域名'
}
prepare_vless_acme() {
    acme_paths
    acquire_acme_lock
    ensure_acme_client
    say "自动申请 $DOMAIN 的 Let's Encrypt 证书（DNS-01，无需开放公网 80）。"
    acme_result=0
    acme_run --issue --server letsencrypt --dns dns_cf -d "$DOMAIN" --keylength ec-256 \
        --accountemail "$EMAIL" || acme_result=$?
    case "$acme_result" in 0|2) ;; *) die 'ACME 申请失败；请检查 Token、Zone ID、DNS 和 CA 连通性' ;; esac
    # Exit 2 means an existing certificate is not due for renewal. Reinstall it.
    install_vless_acme_cert
}
renew_vless_cert() { renew_tls_cert vless; }
renew_anytls_cert() { renew_tls_cert anytls; }
renew_tls_cert() {
    MODE=$1
    if [ "$MODE" = vless ]; then [ "$(setting vless VLESS_TRANSPORT)" = ws-tls ] || return 0; fi
    [ "$(setting "$MODE" TLS_CERT_MODE)" = acme ] || return 0
    DOMAIN=$(setting "$MODE" DOMAIN)
    CF_TOKEN=$(setting "$MODE" CF_TOKEN)
    CF_ZONE_ID=$(setting "$MODE" CF_ZONE_ID)
    [ -n "$CF_TOKEN" ] && [ -n "$CF_ZONE_ID" ] || die '缺少已保存的 Cloudflare Token 或 Zone ID'
    acme_paths
    acquire_acme_lock
    [ -f "$ACME_CLIENT/acme.sh" ] || die '缺少 acme.sh，请使用修改配置重新安装自动证书'
    acme_result=0
    acme_run --renew -d "$DOMAIN" --ecc --server letsencrypt || acme_result=$?
    case "$acme_result" in 0|2) ;; *) die 'ACME 续期失败，将在下一次定时任务重试' ;; esac
    install_vless_acme_cert
    release_acme_lock
}
disable_vless_cert_renewal() { disable_tls_cert_renewal vless; }
disable_tls_cert_renewal() {
    cert_job=sspanel-native-$1-cert
    if [ "$(init_system)" = systemd ]; then
        if [ -f "$CERT_SYSTEMD_DIR/$cert_job.timer" ]; then
            systemctl disable --now "$cert_job.timer"
            systemctl stop "$cert_job.service"
            rm -f -- "$CERT_SYSTEMD_DIR/$cert_job.timer" "$CERT_SYSTEMD_DIR/$cert_job.service"
            systemctl daemon-reload
        fi
    fi
    rm -f -- "$CERT_PERIODIC_DIR/$cert_job"
}
configure_vless_cert_renewal() { configure_tls_cert_renewal vless; }
configure_tls_cert_renewal() {
    cert_job_mode=$1
    cert_job=sspanel-native-$cert_job_mode-cert
    if { [ "$cert_job_mode" = vless ] && [ "$VLESS_TRANSPORT" != ws-tls ]; } || [ "$TLS_CERT_MODE" != acme ]; then
        disable_tls_cert_renewal "$cert_job_mode"
        return
    fi
    if [ "$(init_system)" = systemd ]; then
        cat > "$CERT_SYSTEMD_DIR/$cert_job.service" <<EOF
[Unit]
Description=Renew SSPanel $cert_job_mode TLS certificate with Cloudflare DNS
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=NATIVE_MANAGED_DIR=$MANAGED_DIR
ExecStart=$MANAGER_BIN --renew-$cert_job_mode-cert
UMask=0077
EOF
        cat > "$CERT_SYSTEMD_DIR/$cert_job.timer" <<EOF
[Unit]
Description=Daily SSPanel $cert_job_mode TLS certificate renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
        chmod 644 "$CERT_SYSTEMD_DIR/$cert_job.service" "$CERT_SYSTEMD_DIR/$cert_job.timer"
        systemctl daemon-reload
        systemctl enable --now "$cert_job.timer"
    else
        ensure_openrc_cert_cron
        install -d -m 755 "$CERT_PERIODIC_DIR"
        install -d -m 700 "$(dirname "$CERT_RENEW_LOG")"
        cert_job_log=$CERT_RENEW_LOG
        if [ "$CERT_RENEW_LOG" = /var/log/sspanel-native/vless-cert-renew.log ]; then cert_job_log=/var/log/sspanel-native/$cert_job_mode-cert-renew.log; fi
        cat > "$CERT_PERIODIC_DIR/$cert_job" <<EOF
#!/bin/sh
umask 077
NATIVE_MANAGED_DIR="$MANAGED_DIR" "$MANAGER_BIN" --renew-$cert_job_mode-cert >> "$cert_job_log" 2>&1
EOF
        chmod 700 "$CERT_PERIODIC_DIR/$cert_job"
        rc-update add crond default
        service_active crond || service_start crond
    fi
}
ensure_openrc_cert_cron() {
    if [ ! -f /etc/init.d/crond ]; then
        command -v apk >/dev/null 2>&1 || die 'OpenRC 自动续期需要 crond 服务'
        apk add --no-cache busybox-openrc
    fi
}
prompt_vless_reality() {
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
        sed "s/credential_fields: \[uuid\]/credential_fields: [$CREDENTIAL_FIELD]/" "$STAGE/adapter.yaml" > "$STAGE/adapter.yaml.new"
        mv "$STAGE/adapter.yaml.new" "$STAGE/adapter.yaml"
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
    elif [ "$MODE" = anytls ]; then
        printf 'ANYTLS_DOMAIN=%s\n' "$DOMAIN" >> "$STAGE/server.env"
        cat > "$STAGE/adapter.yaml" <<EOF
server:
  listen: 127.0.0.1:18082
  auth_token: "\${ADAPTER_AUTH_TOKEN}"
  write_timeout: 15s
panel:
  base_url: "\${SSPANEL_BASE_URL}"
  key: "\${SSPANEL_MU_KEY}"
  node_id: \${SSPANEL_NODE_ID}
  timeout: 5s
user_source:
  mode: api
  credential_fields: [uuid]
  api:
    refresh_interval: 30s
    max_stale: 5m
hy2:
  enabled: false
xray:
  enabled: false
anytls:
  enabled: true
  listen: "0.0.0.0:$LOCAL_PORT"
  server_name: "$DOMAIN"
  certificate_file: "$TLS_CERT_FILE"
  key_file: "$TLS_KEY_FILE"
  sync_interval: 30s
  poll_interval: 60s
  handshake_timeout: 10s
  dial_timeout: 10s
  udp_timeout: 2m
  state_file: ./anytls-traffic-state.json
log:
  level: warn
EOF
        ADAPTER_AUTH_TOKEN=$ADAPTER_TOKEN SSPANEL_BASE_URL=$PANEL_URL SSPANEL_MU_KEY=$MU_KEY SSPANEL_NODE_ID=$NODE_ID \
            "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -check-config -config "$STAGE/adapter.yaml" >/dev/null ||
            die 'AnyTLS 配置校验失败；请确认新版 Adapter、证书和私钥匹配'
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
        if [ "$VLESS_TRANSPORT" = ws-tls ]; then
            sed 's/inbound_tag: vless-reality/inbound_tag: vless-ws/' "$STAGE/adapter.yaml" | \
                awk '{ print } /inbound_tag: vless-ws/ { print "  flow: \"\"" }' > "$STAGE/adapter.yaml.new"
            mv "$STAGE/adapter.yaml.new" "$STAGE/adapter.yaml"
            jq -n --argjson port "$LOCAL_PORT" --arg domain "$DOMAIN" --arg path "$WS_PATH" \
                --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" '{
                log: {loglevel: "warning"},
                api: {tag: "api", listen: "127.0.0.1:10085", services: ["HandlerService", "StatsService"]},
                stats: {},
                policy: {levels: {"0": {statsUserUplink: true, statsUserDownlink: true}}},
                inbounds: [{
                    tag: "vless-ws", listen: "0.0.0.0", port: $port, protocol: "vless",
                    settings: {clients: [], decryption: "none"},
                    streamSettings: {
                        network: "ws", security: "tls",
                        tlsSettings: {serverName: $domain, minVersion: "1.2", alpn: ["http/1.1"],
                            certificates: [{certificateFile: $cert, keyFile: $key, oneTimeLoading: false}]},
                        wsSettings: {path: $path, host: $domain}
                    },
                    sniffing: {enabled: true, destOverride: ["http", "tls"]}
                }],
                outbounds: [{tag: "direct", protocol: "freedom"}, {tag: "block", protocol: "blackhole"}]
            }' > "$STAGE/server.json"
            ADAPTER_AUTH_TOKEN=$ADAPTER_TOKEN SSPANEL_BASE_URL=$PANEL_URL SSPANEL_MU_KEY=$MU_KEY SSPANEL_NODE_ID=$NODE_ID \
                "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -check-config -config "$STAGE/adapter.yaml" >/dev/null ||
                die 'Adapter 不支持 WebSocket 配置；请确认下载源已发布新版 Adapter'
        else
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
        fi
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
    if [ "$MODE" != anytls ]; then
        if [ "$MODE" = hy2 ]; then config_name=server.yaml; else config_name=server.json; fi
        install -m 600 "$STAGE/$config_name" "$MANAGED_DIR/native/$MODE/$config_name"
    fi
    write_settings
    install -d -m 755 "$(dirname "$MANAGER_BIN")"
    if [ "$0" != "$MANAGER_BIN" ]; then install -m 755 "$0" "$MANAGER_BIN"; fi
    # Release the issuance lock before Persistent timers can start renewal.
    release_acme_lock
    if [ "$MODE" = vless ]; then configure_vless_cert_renewal; fi
    if [ "$MODE" = anytls ]; then configure_tls_cert_renewal anytls; fi
    rm -rf -- "$STAGE"
    STAGE=
    wait_listener "$LOCAL_PORT"
    if [ "$MODE" = vless ] && [ "$VLESS_TRANSPORT" = ws-tls ]; then
        say "完成。客户端连接 $DOMAIN:443；Cloudflare 回源 NAT TCP $PUBLIC_PORT → 本机 $LOCAL_PORT。"
        say 'Cloudflare：DNS 开启橙云，SSL/TLS 使用 Full (strict)，开启 WebSockets。'
        if [ "$TLS_CERT_MODE" = acme ]; then
            say "证书：Let's Encrypt / Cloudflare DNS-01；已开启每日续期检查，Xray 每小时自动热重载证书。"
            say "证书文件：$TLS_CERT_FILE；私钥文件：$TLS_KEY_FILE。"
        fi
        if [ "$PUBLIC_PORT" != 443 ]; then
            say "Cloudflare Origin Rule：匹配域名 $DOMAIN，将目标端口改为 $PUBLIC_PORT。"
        fi
        say "客户端：VLESS / ws / TLS；SNI 和 Host 为 $DOMAIN；路径 $WS_PATH；flow 留空；UUID 使用 SSPanel 用户 UUID。"
        say '面板订阅应使用橙云域名、offset_port_user=443 及相同 WS/TLS 参数。'
        ws_uri_path=$(printf '%s' "$WS_PATH" | sed 's|/|%2F|g')
        say "链接模板（替换 USER_UUID）：vless://USER_UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$ws_uri_path#VLESS-WS-TLS"
    else
        say "完成。客户端使用 NAT 公网 $PROTOCOL 端口 $PUBLIC_PORT；本机监听 $LOCAL_PORT。"
        say "请确认面板节点 offset_port_user 为 $PUBLIC_PORT，并确保 NAT 的 $PROTOCOL 转发目标为本机 $LOCAL_PORT。"
    fi
    if [ "$MODE" = hy2 ]; then
        say "SNI：$DOMAIN；密码使用 SSPanel 用户的 $CREDENTIAL_FIELD。"
    elif [ "$MODE" = anytls ]; then
        say "客户端：AnyTLS / TLS；SNI：$DOMAIN；密码使用 SSPanel 用户 UUID；证书校验开启。"
        say '面板节点类型选择 AnyTLS（sort=16），地址填写源站域名，自定义配置：'
        printf '{"protocol":"anytls","offset_port_user":"%s","offset_port_node":"%s","sni":"%s","allow_insecure":false,"udp":true}\n' "$PUBLIC_PORT" "$LOCAL_PORT" "$DOMAIN"
        say "链接模板（替换 USER_UUID）：anytls://USER_UUID@$DOMAIN:$PUBLIC_PORT?sni=$DOMAIN&insecure=0#AnyTLS"
    elif [ "$VLESS_TRANSPORT" = reality ]; then
        say "REALITY SNI：$SNI；Public Key：$REALITY_PUBLIC；Short ID：$SHORT_ID。"
        say '客户端 UUID 为 SSPanel 用户 UUID，flow 为 xtls-rprx-vision。'
    fi
    say "以后运行 $MANAGER_BIN，可选择卸载、重启或修改配置。"
}

configure_mode() {
    MODE=$1
    mode_names "$MODE"
    if [ "$MODE" = vless ]; then choose_vless_transport; fi
    prompt_common
    if [ "$MODE" = hy2 ]; then
        prompt_hy2
    elif [ "$MODE" = anytls ]; then
        prompt_anytls
    elif [ "$VLESS_TRANSPORT" = ws-tls ]; then
        prompt_vless_ws
    else
        prompt_vless_reality
    fi
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
    if [ "$MODE" != anytls ]; then service_start "$PROXY_SERVICE"; fi
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
    say '将删除 HY2/VLESS/AnyTLS 服务、项目二进制、配置、证书、状态与日志；不会删除当前 Git 仓库和系统共享软件包。'
    uninstall_answer=$(ask '确认输入 DELETE' '' no)
    [ "$uninstall_answer" = DELETE ] || die '卸载已取消'
    for uninstall_mode in hy2 vless anytls; do
        if installed "$uninstall_mode"; then collect_or_confirm "$uninstall_mode"; fi
    done
    disable_vless_cert_renewal
    disable_tls_cert_renewal anytls
    for uninstall_mode in hy2 vless anytls; do
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

if [ "$#" -gt 1 ]; then die '用法：native-manager.sh [0|1|2|3|4|--renew-vless-cert|--renew-anytls-cert]'; fi
if [ "$#" -eq 1 ] && [ "$1" = --renew-vless-cert ]; then renew_vless_cert; exit 0; fi
if [ "$#" -eq 1 ] && [ "$1" = --renew-anytls-cert ]; then renew_anytls_cert; exit 0; fi
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
