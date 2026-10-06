#!/bin/sh
# Functions are sourced from a generated file and consume the fixture variables.
# shellcheck disable=SC1091,SC2034
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' 0
trap 'exit 130' 1 2 3 15
# Load functions only; never enter the root-only menu or touch installed services.
awk '
    /^if \[ "\$#" -gt 1 \]/ { exit }
    /^\[ "\$\(id -u\)"/ { next }
    /^exec 3<&0/ { next }
    /^trap / { next }
    { print }
' "$project_dir/scripts/native-manager.sh" > "$test_root/functions.sh"
. "$test_root/functions.sh"
MANAGED_DIR=$test_root/managed
CERT_LOCK_DIR=$test_root/acme.lock
mkdir -p "$MANAGED_DIR/bin"
if [ "${REAL_NATIVE_BINARIES:-0}" = 1 ]; then
    ln -s "$project_dir/bin/xray-linux" "$MANAGED_DIR/bin/xray-linux"
    ln -s "$project_dir/bin/sspanel-hy2-adapter-linux" "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux"
else
    # Portable config checks; REAL_NATIVE_BINARIES=1 runs shipped Linux validators.
    cat > "$MANAGED_DIR/bin/xray-linux" <<'EOF'
#!/bin/sh
jq -e . "$4" >/dev/null
EOF
    cat > "$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" <<'EOF'
#!/bin/sh
if [ "$1" = -h ]; then printf '%s\n' '-check-config'; exit 0; fi
[ "$1" = -check-config ] && [ "$2" = -config ]
if grep -q '^anytls:' "$3"; then exit 0; fi
grep -q 'flow: ""' "$3"
EOF
    chmod +x "$MANAGED_DIR/bin/"*
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=ws.example.net \
    -addext subjectAltName=DNS:ws.example.net \
    -keyout "$test_root/key.pem" -out "$test_root/cert.pem" >/dev/null 2>&1

MODE=vless
mode_names "$MODE"
PANEL_URL=https://panel.example.net
MU_KEY=secret
NODE_ID=12
ADAPTER_TOKEN=token
PUBLIC_PORT=30002
LOCAL_PORT=8443
DOMAIN=ws.example.net
WS_PATH=/proxy/vless
TLS_CERT_FILE=$test_root/cert.pem
TLS_KEY_FILE=$test_root/key.pem
VLESS_TRANSPORT=ws-tls
TLS_CERT_MODE=manual
write_config
jq -e --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" '
    .inbounds[0] | .port == 8443 and .tag == "vless-ws" and .settings.clients == [] and
    .streamSettings.network == "ws" and .streamSettings.security == "tls" and
    .streamSettings.wsSettings.path == "/proxy/vless" and .streamSettings.wsSettings.host == "ws.example.net" and
    .streamSettings.tlsSettings.certificates[0].certificateFile == $cert and
    .streamSettings.tlsSettings.certificates[0].keyFile == $key and
    .streamSettings.tlsSettings.certificates[0].oneTimeLoading == false and
    .streamSettings.tlsSettings.alpn == ["http/1.1"] and (.streamSettings | has("realitySettings") | not)
' "$STAGE/server.json" >/dev/null
grep -q 'inbound_tag: vless-ws' "$STAGE/adapter.yaml"
grep -q 'flow: ""' "$STAGE/adapter.yaml"
write_settings
[ "$(setting vless VLESS_TRANSPORT)" = ws-tls ]
[ "$(setting vless PUBLIC_PORT)" = 30002 ]
[ "$(setting vless TLS_CERT_FILE)" = "$TLS_CERT_FILE" ]
exec 3<<'EOF'

EOF
choose_vless_transport
[ "$VLESS_TRANSPORT" = ws-tls ]
rm -rf -- "$STAGE"
STAGE=

# Switching keeps service/API ports and restores REALITY's default Vision flow.
VLESS_TRANSPORT=reality
TARGET=www.microsoft.com
SNI=$TARGET
REALITY_PRIVATE=4KUgMex3lQ3FllmJJA3RI5c7nOnJucAqlPmLFTNjwk0
SHORT_ID=0123456789abcdef
write_config
jq -e '.inbounds[0].streamSettings | .network == "raw" and .security == "reality" and (has("wsSettings") | not)' "$STAGE/server.json" >/dev/null
grep -q 'inbound_tag: vless-reality' "$STAGE/adapter.yaml"
if grep -q 'flow:' "$STAGE/adapter.yaml"; then die 'REALITY should use the legacy default flow'; fi
write_settings
exec 3<<'EOF'

EOF
choose_vless_transport
[ "$VLESS_TRANSPORT" = reality ]
rm -rf -- "$STAGE"
STAGE=

# An old settings file without the new key defaults to REALITY.
sed '/^VLESS_TRANSPORT=/d' "$MANAGED_DIR/settings/vless.conf" > "$test_root/legacy.conf"
mv "$test_root/legacy.conf" "$MANAGED_DIR/settings/vless.conf"
exec 3<<'EOF'

EOF
choose_vless_transport
[ "$VLESS_TRANSPORT" = reality ]

# Reject invalid paths and missing certificates before any deployment.
for invalid_case in bad-path missing-cert; do
    if (
        if [ "$invalid_case" = bad-path ]; then
            exec 3<<EOF
$DOMAIN
/bad?query
EOF
        else
            exec 3<<EOF
$DOMAIN
/vless
2
$test_root/missing.pem
$TLS_KEY_FILE
EOF
        fi
        prompt_vless_ws
    ) >/dev/null 2>&1; then die "accepted $invalid_case"; fi
done

# Automatic certificates: exercise issue/skip/install/renew with a local ACME
# fixture. No real Cloudflare credentials or production CA requests in tests.
DOMAIN=ws.example.net
EMAIL=admin@example.net
CF_TOKEN=fixture-secret-token
CF_ZONE_ID=0123456789abcdef0123456789abcdef
TLS_CERT_MODE=acme
VLESS_TRANSPORT=ws-tls
export ACME_TEST_CERT="$test_root/cert.pem" ACME_TEST_KEY="$test_root/key.pem" ACME_TEST_LOG="$test_root/acme.log"
ensure_acme_client() {
    install -d -m 700 "$ACME_CLIENT" "$ACME_STATE/tls"
    cat > "$ACME_CLIENT/acme.sh" <<'EOF'
#!/bin/sh
set -eu
action= state= cert= key=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config-home) state=$2; shift 2 ;;
        --issue|--renew|--install-cert) action=$1; shift ;;
        --fullchain-file) cert=$2; shift 2 ;;
        --key-file) key=$2; shift 2 ;;
        --reloadcmd) [ "$2" = ':' ]; shift 2 ;;
        --home|--server|--dns|-d|--keylength|--accountemail) shift 2 ;;
        --ecc) shift ;;
        *) exit 1 ;;
    esac
done
[ "$CF_Token" = fixture-secret-token ] && [ "$CF_Zone_ID" = 0123456789abcdef0123456789abcdef ]
printf '%s\n' "$action" >> "$ACME_TEST_LOG"
case "$action" in
    --issue) touch "$state/issued"; exit "${ACME_TEST_STATUS:-0}" ;;
    --renew) [ -f "$state/issued" ]; exit "${ACME_TEST_STATUS:-0}" ;;
    --install-cert)
        [ -f "$state/issued" ]
        cp "$ACME_TEST_CERT" "$cert"
        cp "$ACME_TEST_KEY" "$key"
        ;;
esac
EOF
}
prepare_vless_acme
[ -s "$TLS_CERT_FILE" ] && [ -s "$TLS_KEY_FILE" ]
write_settings
[ "$(setting vless TLS_CERT_MODE)" = acme ]
[ "$(setting vless CF_ZONE_ID)" = "$CF_ZONE_ID" ]
mkdir -p "$ACME_STATE/${DOMAIN}_ecc"
printf "CF_Token='obsolete-token'\nCF_Zone_ID='obsolete-zone'\nLe_Domain='%s'\n" "$DOMAIN" > "$ACME_STATE/${DOMAIN}_ecc/$DOMAIN.conf"
release_acme_lock
renew_vless_cert
[ -z "$ACME_LOCK" ]
if grep -q '^CF_Token=' "$ACME_STATE/${DOMAIN}_ecc/$DOMAIN.conf"; then die 'ACME retained obsolete DNS credentials'; fi
grep -q '^Le_Domain=' "$ACME_STATE/${DOMAIN}_ecc/$DOMAIN.conf"
grep -q -- '--renew' "$ACME_TEST_LOG"
export ACME_TEST_STATUS=2
prepare_vless_acme
release_acme_lock
renew_vless_cert
unset ACME_TEST_STATUS
exec 3<<'EOF'

EOF
choose_vless_cert_mode
[ "$TLS_CERT_MODE" = acme ]
if (
    export ACME_TEST_STATUS=1
    renew_vless_cert
) >/dev/null 2>&1; then die 'renewal failure was ignored'; fi
# A failed background renewal releases its lock through the manager exit trap.
# This test sources functions without that trap, so remove the fixture lock.
rmdir "$CERT_LOCK_DIR"
[ -s "$TLS_CERT_FILE" ]

# Render systemd jobs in a temporary directory and record service operations.
CERT_SYSTEMD_DIR=$test_root/systemd
CERT_PERIODIC_DIR=$test_root/periodic
mkdir -p "$CERT_SYSTEMD_DIR" "$CERT_PERIODIC_DIR"
init_system() { printf 'systemd\n'; }
systemctl() { printf '%s\n' "$*" >> "$test_root/systemctl.log"; }
configure_vless_cert_renewal
grep -q '^OnCalendar=daily$' "$CERT_SYSTEMD_DIR/sspanel-native-vless-cert.timer"
grep -q '^Persistent=true$' "$CERT_SYSTEMD_DIR/sspanel-native-vless-cert.timer"
grep -q -- '--renew-vless-cert' "$CERT_SYSTEMD_DIR/sspanel-native-vless-cert.service"
TLS_CERT_MODE=manual
configure_vless_cert_renewal
[ ! -f "$CERT_SYSTEMD_DIR/sspanel-native-vless-cert.timer" ]
grep -q 'disable --now sspanel-native-vless-cert.timer' "$test_root/systemctl.log"
# Manual certificates and REALITY must never make renewal API calls.
calls_before=$(wc -l < "$ACME_TEST_LOG")
write_settings
renew_vless_cert
VLESS_TRANSPORT=reality
write_settings
renew_vless_cert
[ "$calls_before" = "$(wc -l < "$ACME_TEST_LOG")" ]

# OpenRC uses the existing daily periodic scheduler and leaves shared crond up
# when this application's renewal job is removed.
VLESS_TRANSPORT=ws-tls
TLS_CERT_MODE=acme
CERT_RENEW_LOG=$test_root/log/renew.log
MANAGER_BIN=$test_root/manager
cat > "$MANAGER_BIN" <<'EOF'
#!/bin/sh
[ "$1" = --renew-vless-cert ]
[ -n "$NATIVE_MANAGED_DIR" ]
printf 'periodic job ran\n'
EOF
chmod +x "$MANAGER_BIN"
init_system() { printf 'openrc\n'; }
ensure_openrc_cert_cron() { :; }
mkdir -p "$test_root/mock-bin"
export OPENRC_TEST_LOG="$test_root/openrc.log"
cat > "$test_root/mock-bin/rc-update" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$OPENRC_TEST_LOG"
EOF
chmod +x "$test_root/mock-bin/rc-update"
PATH="$test_root/mock-bin:$PATH"
service_active() { return 0; }
configure_vless_cert_renewal
sh -n "$CERT_PERIODIC_DIR/sspanel-native-vless-cert"
sh "$CERT_PERIODIC_DIR/sspanel-native-vless-cert"
grep -q 'periodic job ran' "$CERT_RENEW_LOG"
grep -q 'add crond default' "$test_root/openrc.log"
TLS_CERT_MODE=manual
configure_vless_cert_renewal
[ ! -f "$CERT_PERIODIC_DIR/sspanel-native-vless-cert" ]
MODE=anytls
unset VLESS_TRANSPORT
mode_names "$MODE"
[ "$ADMIN_PORT" = 18082 ] && [ "$PROXY_SERVICE" = "$ADAPTER_SERVICE" ]
exec 3<<'EOF'
3
EOF
[ "$(choose_mode)" = anytls ]
TLS_CERT_MODE=manual
TLS_CERT_FILE=$test_root/cert.pem
TLS_KEY_FILE=$test_root/key.pem
BBR_ENABLED=true
write_config
grep -q '^anytls:' "$STAGE/adapter.yaml"
grep -q 'listen: "0.0.0.0:8443"' "$STAGE/adapter.yaml"
grep -q 'listen: 127.0.0.1:18082' "$STAGE/adapter.yaml"
[ ! -f "$STAGE/server.json" ]
write_settings
[ "$(setting anytls TLS_CERT_MODE)" = manual ]
[ "$(setting anytls DOMAIN)" = ws.example.net ]
[ "$(setting anytls BBR_ENABLED)" = true ]
rm -rf -- "$STAGE"
STAGE=
TLS_CERT_MODE=acme
prepare_vless_acme
case "$ACME_STATE" in */acme-anytls/ws.example.net) ;; *) die 'AnyTLS reused VLESS certificate state' ;; esac
write_settings
release_acme_lock
renew_anytls_cert
init_system() { printf 'systemd\n'; }
configure_tls_cert_renewal anytls
grep -q -- '--renew-anytls-cert' "$CERT_SYSTEMD_DIR/sspanel-native-anytls-cert.service"
# Disabling AnyTLS renewal must not remove VLESS jobs.
touch "$CERT_SYSTEMD_DIR/sspanel-native-vless-cert.timer"
TLS_CERT_MODE=manual
configure_tls_cert_renewal anytls
[ ! -f "$CERT_SYSTEMD_DIR/sspanel-native-anytls-cert.timer" ]
[ -f "$CERT_SYSTEMD_DIR/sspanel-native-vless-cert.timer" ]
say 'native-manager tests passed (VLESS + AnyTLS)'
