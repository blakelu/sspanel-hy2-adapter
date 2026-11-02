#!/bin/sh
# Exercise HY2 mode changes without root, network calls, or installed services.
# shellcheck disable=SC1091,SC2034
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' 0
trap 'exit 130' 1 2 3 15
awk '
    /^if \[ "\$#" -gt 1 \]/ { exit }
    /^\[ "\$\(id -u\)"/ { next }
    /^exec 3<&0/ { next }
    /^trap / { next }
    { print }
' "$project_dir/scripts/native-manager.sh" > "$test_root/functions.sh"
. "$test_root/functions.sh"
MANAGED_DIR=$test_root/managed
mkdir -p "$MANAGED_DIR/settings"
printf 'preserve existing VLESS configuration\n' > "$MANAGED_DIR/settings/vless.conf"
MODE=hy2
mode_names "$MODE"
PANEL_URL=https://panel.example.net
MU_KEY=fixture-key
NODE_ID=13
ADAPTER_TOKEN=fixture-adapter-token
STATS_SECRET=fixture-stats-secret
CREDENTIAL_FIELD=uuid
DOMAIN=hy2.example.net
EMAIL=admin@example.net
CF_TOKEN=fixture-cloudflare-token
PUBLIC_PORT=30001
LOCAL_PORT=443

save_config() {
    if [ -n "${NATIVE_HY2_TEST_OUTPUT:-}" ]; then
        mkdir -p "$NATIVE_HY2_TEST_OUTPUT/$HY2_OBFS"
        cp "$STAGE/server.yaml" "$STAGE/server.env" "$STAGE/adapter.yaml" "$NATIVE_HY2_TEST_OUTPUT/$HY2_OBFS/"
    fi
    rm -rf -- "$STAGE"
    STAGE=
}

# Old deployments without a mode stay standard HTTP/3, with existing auth.
exec 3<<'EOF'

EOF
prompt_hy2_obfs
[ "$HY2_OBFS" = none ] && [ -z "$HY2_OBFS_PASSWORD" ]
write_config
grep -qx 'listen: 0.0.0.0:443' "$STAGE/server.yaml"
grep -qx '  type: http' "$STAGE/server.yaml"
grep -qx '  listen: 127.0.0.1:18080' "$STAGE/adapter.yaml"
if grep -q '^obfs:' "$STAGE/server.yaml"; then die 'standard mode unexpectedly enabled obfs'; fi
[ "$(read_hy2_obfs_setting "$STAGE/server.yaml" HY2_OBFS)" = none ]
save_config

# Select Salamander and generate both server and matching panel/link parameters.
exec 3<<'EOF'
2
salamander-test_0123456789
EOF
prompt_hy2_obfs
write_config
grep -qx '  type: salamander' "$STAGE/server.yaml"
grep -qx '    password: "salamander-test_0123456789"' "$STAGE/server.yaml"
[ "$(read_hy2_obfs_setting "$STAGE/server.yaml" HY2_OBFS)" = salamander ]
[ "$(read_hy2_obfs_setting "$STAGE/server.yaml" HY2_OBFS_PASSWORD)" = "$HY2_OBFS_PASSWORD" ]
print_hy2_client > "$test_root/client.txt"
grep '^{' "$test_root/client.txt" | jq -e '.obfs == "salamander" and .obfs_password == "salamander-test_0123456789" and .offset_port_user == 30001 and .offset_port_node == 30001 and .allow_insecure == false' >/dev/null
grep -q 'insecure=0&obfs=salamander&obfs-password=salamander-test_0123456789' "$test_root/client.txt"
write_settings
[ "$(setting hy2 HY2_OBFS)" = salamander ]
[ "$(setting hy2 HY2_OBFS_PASSWORD)" = "$HY2_OBFS_PASSWORD" ]
if [ "$(uname -s)" = Darwin ]; then
    [ "$(stat -f '%Lp' "$MANAGED_DIR/settings/hy2.conf")" = 600 ]
else
    [ "$(stat -c '%a' "$MANAGED_DIR/settings/hy2.conf")" = 600 ]
fi
save_config

# Editing keeps the mode and secret; 'new' explicitly rotates the secret.
exec 3<<'EOF'


EOF
prompt_hy2_obfs
[ "$HY2_OBFS" = salamander ] && [ "$HY2_OBFS_PASSWORD" = salamander-test_0123456789 ]
exec 3<<'EOF'

new
EOF
prompt_hy2_obfs
[ "${#HY2_OBFS_PASSWORD}" -eq 64 ]
printf '%s\n' "$HY2_OBFS_PASSWORD" | grep -Eq '^[0-9a-f]{64}$'

# Returning to standard mode removes the stale secret and URI/panel obfs fields.
exec 3<<'EOF'
1
EOF
prompt_hy2_obfs
write_config
if grep -q '^obfs:' "$STAGE/server.yaml"; then die 'switching off obfs left the server block'; fi
print_hy2_client > "$test_root/client.txt"
grep '^{' "$test_root/client.txt" | jq -e '.obfs == "" and .obfs_password == ""' >/dev/null
if grep -q 'obfs-password=' "$test_root/client.txt"; then die 'standard URI leaked an old secret'; fi
write_settings
[ -z "$(setting hy2 HY2_OBFS_PASSWORD)" ]
save_config

# Import simple existing YAML, but refuse unsupported modes instead of clearing.
cat > "$test_root/import.yaml" <<'EOF'
obfs:
  type: 'salamander' # keep this mode
  salamander:
    password: 'existing-token_123'
auth:
  type: password
  password: another-secret
EOF
[ "$(read_hy2_obfs_setting "$test_root/import.yaml" HY2_OBFS)" = salamander ]
[ "$(read_hy2_obfs_setting "$test_root/import.yaml" HY2_OBFS_PASSWORD)" = existing-token_123 ]
printf 'obfs: {type: salamander}\n' > "$test_root/import.yaml"
[ "$(read_hy2_obfs_setting "$test_root/import.yaml" HY2_OBFS)" = unsupported ]
for invalid_mode in gecko unsupported; do
    if (HY2_OBFS=$invalid_mode; validate_hy2_obfs) >/dev/null 2>&1; then die 'unsupported obfs mode accepted'; fi
done
if (HY2_OBFS=salamander; HY2_OBFS_PASSWORD='bad$(touch never-execute)'; write_config) >/dev/null 2>&1; then
    die 'unsafe obfs password accepted'
fi
grep -qx 'preserve existing VLESS configuration' "$MANAGED_DIR/settings/vless.conf"
say 'HY2 standard/Salamander configuration tests passed.'
