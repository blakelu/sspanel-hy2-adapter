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
write_config
jq -e --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" '
    .inbounds[0] | .port == 8443 and .tag == "vless-ws" and .settings.clients == [] and
    .streamSettings.network == "ws" and .streamSettings.security == "tls" and
    .streamSettings.wsSettings.path == "/proxy/vless" and .streamSettings.wsSettings.host == "ws.example.net" and
    .streamSettings.tlsSettings.certificates[0].certificateFile == $cert and
    .streamSettings.tlsSettings.certificates[0].keyFile == $key and
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
$test_root/missing.pem
$TLS_KEY_FILE
EOF
        fi
        prompt_vless_ws
    ) >/dev/null 2>&1; then die "accepted $invalid_case"; fi
done
say 'native-manager tests passed'
