#!/bin/sh
set -eu

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'run as root (sudo/doas)'
[ "$#" -eq 1 ] || die 'usage: install-native.sh hy2|vless'
mode="$1"
case "$mode" in
    hy2) proxy_name=hysteria; proxy_file=server.yaml; proxy_args='server -c'; admin_port=18080 ;;
    vless) proxy_name=xray; proxy_file=server.json; proxy_args='run -config'; admin_port=18081 ;;
    *) die 'mode must be hy2 or vless' ;;
esac

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${NATIVE_CONFIG_DIR:-${project_dir}/native/${mode}}"
adapter_bin="${ADAPTER_BIN:-${project_dir}/bin/sspanel-hy2-adapter-linux}"
proxy_bin="${PROXY_BIN:-${project_dir}/bin/${proxy_name}-linux}"
config_dir="/etc/sspanel-native/${mode}"
state_dir="/var/lib/sspanel-native/${mode}"
service_prefix="sspanel-native-${mode}"
proxy_service="${service_prefix}-${proxy_name}"
adapter_service="${service_prefix}-adapter"

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    init_system=systemd
elif command -v rc-service >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then
    init_system=openrc
else
    die 'systemd or OpenRC is required'
fi

service_active() {
    if [ "$init_system" = systemd ]; then
        systemctl is-active --quiet "$1.service"
    else
        rc-service "$1" status >/dev/null 2>&1
    fi
}

for path in "${source_dir}/adapter.yaml" "${source_dir}/server.env" "${source_dir}/${proxy_file}"; do
    [ -f "$path" ] || die "missing $path; copy the matching .example file and edit it"
    if grep -Eq 'REPLACE_|replace-with-|panel\.example\.com' "$path"; then
        die "example value remains in $path"
    fi
done
[ -x "$adapter_bin" ] || die "adapter binary is missing or not executable: $adapter_bin"
[ -x "$proxy_bin" ] || die "proxy binary is missing or not executable: $proxy_bin"
if ! "$adapter_bin" -version >/dev/null 2>&1; then
    die "adapter binary cannot run on $(uname -m): $adapter_bin"
fi
if [ "$mode" = hy2 ]; then
    if ! "$proxy_bin" version >/dev/null 2>&1; then
        die "Hysteria binary cannot run on $(uname -m): $proxy_bin"
    fi
    grep -Eq '^[[:space:]]*(tls|acme):' "${source_dir}/server.yaml" ||
        die 'HY2 server.yaml must configure tls or acme'
    grep -Eq '^[[:space:]]*auth:' "${source_dir}/server.yaml" ||
        die 'HY2 server.yaml must configure HTTP auth'
else
    command -v jq >/dev/null 2>&1 || die 'jq is required to validate Xray JSON (apk add jq)'
    jq -e . "${source_dir}/server.json" >/dev/null || die 'invalid Xray JSON'
fi

# Preserve traffic accumulated since the last Adapter checkpoint.
if service_active "$proxy_service" && ! service_active "$adapter_service"; then
    die 'proxy is running but adapter is down; restore adapter before reinstalling'
fi
if service_active "$adapter_service"; then
    command -v curl >/dev/null 2>&1 || die 'curl is required to collect traffic before restart (apk add curl)'
    old_env="${config_dir}/server.env"
    [ -f "$old_env" ] || die "missing installed $old_env"
    old_token="$(awk -F= '$1 == "ADAPTER_AUTH_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "$old_env")"
    [ -n "$old_token" ] || die 'installed ADAPTER_AUTH_TOKEN is empty'
    curl --fail --silent --show-error --max-time 20 --request POST \
        --header "X-Adapter-Token: ${old_token}" \
        "http://127.0.0.1:${admin_port}/admin/collect" >/dev/null ||
        die 'traffic collection failed; services were not restarted'
fi

install -d -m 700 "$config_dir" "$state_dir"
install -m 755 "$adapter_bin" /usr/local/bin/sspanel-hy2-adapter.new
mv -f /usr/local/bin/sspanel-hy2-adapter.new /usr/local/bin/sspanel-hy2-adapter
install -m 755 "$proxy_bin" "/usr/local/bin/${proxy_name}.new"
mv -f "/usr/local/bin/${proxy_name}.new" "/usr/local/bin/${proxy_name}"
install -m 600 "${source_dir}/server.env" "${config_dir}/server.env"
install -m 600 "${source_dir}/adapter.yaml" "${config_dir}/adapter.yaml"
install -m 600 "${source_dir}/${proxy_file}" "${config_dir}/${proxy_file}"

if [ "$init_system" = systemd ]; then
    cat >"/etc/systemd/system/${proxy_service}.service" <<EOF
[Unit]
Description=SSPanel native ${mode} ${proxy_name}
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${state_dir}
ExecStart=/usr/local/bin/${proxy_name} ${proxy_args} ${config_dir}/${proxy_file}
Restart=on-failure
RestartSec=3
Environment=GOGC=50
Environment=GOMEMLIMIT=48MiB
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${state_dir}
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    cat >"/etc/systemd/system/${adapter_service}.service" <<EOF
[Unit]
Description=SSPanel native ${mode} adapter
Wants=network-online.target ${proxy_service}.service
After=network-online.target ${proxy_service}.service

[Service]
Type=simple
WorkingDirectory=${state_dir}
EnvironmentFile=${config_dir}/server.env
Environment=GOGC=50
Environment=GOMEMLIMIT=32MiB
ExecStart=/usr/local/bin/sspanel-hy2-adapter -config ${config_dir}/adapter.yaml
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=${state_dir}
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "/etc/systemd/system/${proxy_service}.service" "/etc/systemd/system/${adapter_service}.service"
    systemctl daemon-reload
    systemctl enable "${proxy_service}.service" "${adapter_service}.service"
    systemctl restart "${proxy_service}.service"
    systemctl restart "${adapter_service}.service"
    systemctl --no-pager --full status "${proxy_service}.service" "${adapter_service}.service"
else
    log_dir=/var/log/sspanel-native
    install -d -m 700 "$log_dir"
    cat >"/etc/init.d/${proxy_service}" <<EOF
#!/sbin/openrc-run
name="${proxy_service}"
description="SSPanel native ${mode} ${proxy_name}"
supervisor=supervise-daemon
command="/usr/local/bin/${proxy_name}"
command_args="${proxy_args} ${config_dir}/${proxy_file}"
directory="${state_dir}"
pidfile="/run/\$RC_SVCNAME.pid"
respawn_delay=3
respawn_max=0
output_log="${log_dir}/${proxy_service}.log"
error_log="${log_dir}/${proxy_service}.err.log"
export GOGC=50 GOMEMLIMIT=48MiB

depend() { need net; after firewall; }
EOF

    cat >"/etc/init.d/${adapter_service}" <<EOF
#!/sbin/openrc-run
name="${adapter_service}"
description="SSPanel native ${mode} adapter"
supervisor=supervise-daemon
command="/usr/local/bin/sspanel-hy2-adapter"
command_args="-config ${config_dir}/adapter.yaml"
directory="${state_dir}"
pidfile="/run/\$RC_SVCNAME.pid"
respawn_delay=3
respawn_max=0
output_log="${log_dir}/${adapter_service}.log"
error_log="${log_dir}/${adapter_service}.err.log"
export GOGC=50 GOMEMLIMIT=32MiB

while IFS= read -r line || [ -n "\$line" ]; do
    case "\$line" in
        ''|\\#*) continue ;;
        *=*) export "\$line" ;;
        *) eerror "invalid EnvironmentFile line"; exit 1 ;;
    esac
done < "${config_dir}/server.env"

depend() { need net ${proxy_service}; }
EOF

    chmod 755 "/etc/init.d/${proxy_service}" "/etc/init.d/${adapter_service}"
    rc-update add "$proxy_service" default
    rc-update add "$adapter_service" default
    if service_active "$adapter_service"; then rc-service "$adapter_service" stop; fi
    if service_active "$proxy_service"; then rc-service "$proxy_service" restart; else rc-service "$proxy_service" start; fi
    rc-service "$adapter_service" start
    rc-service "$proxy_service" status
    rc-service "$adapter_service" status
fi

attempt=0
while [ "$attempt" -lt 15 ]; do
    if command -v curl >/dev/null 2>&1; then
        if curl --fail --silent --max-time 2 "http://127.0.0.1:${admin_port}/healthz" >/dev/null; then
            printf 'Adapter is healthy on 127.0.0.1:%s\n' "$admin_port"
            exit 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -T 2 -O /dev/null "http://127.0.0.1:${admin_port}/healthz"; then
            printf 'Adapter is healthy on 127.0.0.1:%s\n' "$admin_port"
            exit 0
        fi
    else
        die 'curl or wget is required for the Adapter health check'
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [ "$init_system" = openrc ]; then
    die "Adapter did not become healthy; inspect /var/log/sspanel-native/${adapter_service}.err.log and .log"
fi
die "Adapter did not become healthy; inspect journalctl -u ${adapter_service}"
