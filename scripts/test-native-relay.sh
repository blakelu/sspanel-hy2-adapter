#!/bin/sh
# shellcheck disable=SC1091,SC2034
# Portable validation/lifecycle tests; REAL_NATIVE_BINARIES=1 also checks Xray.
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
MANAGER_BIN=$test_root/manager
RELAY_BIN=$test_root/relay
RELAY_CONFIG_DIR=$test_root/config
RELAY_SYSTEMD_DIR=$test_root/systemd
RELAY_OPENRC_DIR=$test_root/init.d
RELAY_LOG_DIR=$test_root/log
export TMPDIR="$test_root"

for host in 127.0.0.1 192.0.2.1 example.com node-1.example.com localhost ::1 :: 2001:db8::1 ::ffff:192.0.2.1 2001:db8:1:2:3:4:5:6; do
    relay_host_valid "$host" || die "valid host rejected: $host"
done
for host in '' 'https://example.com' 'example.com:443' '-bad.com' 'bad-.com' 'bad..com' 'a b' '[::1]' '1.2.3.999' '01.2.3.4' ':::' '1::2::3' '1:2:3' '1:2:3:4:5:6:7:8::' '::ffff:999.0.0.1'; do
    if relay_host_valid "$host"; then die "invalid host accepted: $host"; fi
done
cat > "$test_root/rules.json" <<'EOF'
[
  {"port":23101,"protocol":"tcp","target":"127.0.0.1","target_port":24101},
  {"port":23101,"protocol":"udp","target":"localhost","target_port":24102},
  {"port":23102,"protocol":"both","target":"127.0.0.1","target_port":24103},
  {"port":23103,"protocol":"tcp","target":"::1","target_port":24104}
]
EOF
relay_validate_rules "$test_root/rules.json"
relay_write_config "$test_root/rules.json" "$test_root/server.json"
jq -e '
    (.inbounds | length) == 4 and
    .inbounds[0].settings.network == "tcp" and .inbounds[1].settings.network == "udp" and
    .inbounds[2].settings.network == "tcp,udp" and .inbounds[3].settings.address == "::1" and
    .inbounds[1].settings.address == "localhost" and
    all(.inbounds[]; .protocol == "dokodemo-door" and .listen == "0.0.0.0" and .settings.followRedirect == false) and
    .outbounds[0].protocol == "freedom" and (has("api") | not)
' "$test_root/server.json" >/dev/null
for mutation in '.[0].port = 0' '.[0].port = 65536' '.[0].port = 1.5' '.[0].port = "443"' \
    '.[0].target_port = -1' '.[0].protocol = "icmp"' '.[0].target = "bad.com:443"' \
    '.[0].target = "bad\nname"' '.[0].target = "1.2.3.999"' '. + [.[0]]' '.[0].protocol = "both"'; do
    jq "$mutation" "$test_root/rules.json" > "$test_root/bad.json"
    if (relay_validate_rules "$test_root/bad.json") >/dev/null 2>&1; then die "invalid rule accepted: $mutation"; fi
done

# All services/files are fixtures, even when the real binary validates configs.
test_init=systemd
init_system() { printf '%s\n' "$test_init"; }
systemctl() { printf '%s\n' "$*" >> "$test_root/service.log"; }
mkdir -p "$test_root/mock-bin"
export NATIVE_RELAY_TEST_ROOT="$test_root"
cat > "$test_root/mock-bin/rc-update" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NATIVE_RELAY_TEST_ROOT/service.log"
EOF
chmod +x "$test_root/mock-bin/rc-update"
PATH=$test_root/mock-bin:$PATH
service_active() { [ -f "$test_root/active" ]; }
service_start() {
    [ ! -f "$test_root/fail-start" ] || { rm "$test_root/fail-start"; return 1; }
    touch "$test_root/active"
}
service_stop() { rm -f "$test_root/active"; }
relay_port_listening() { [ -f "$test_root/occupied" ]; }
relay_wait_listeners() { [ -f "$test_root/active" ]; }
if [ "${REAL_NATIVE_BINARIES:-0}" = 1 ]; then
    case "$(uname -m)" in aarch64|arm64) suffix=linux-arm64 ;; *) suffix=linux ;; esac
    cp "$project_dir/bin/xray-$suffix" "$RELAY_BIN"
else
    cat > "$RELAY_BIN" <<'EOF'
#!/bin/sh
[ "$1" = run ] && [ "$2" = -test ] && [ "$3" = -config ]
jq -e . "$4" >/dev/null
EOF
fi
chmod +x "$RELAY_BIN"
apply_fixture() {
    STAGE=$(mktemp -d)
    cp "$1" "$STAGE/rules.json"
    relay_apply_rules
}
apply_fixture "$test_root/rules.json"
cmp "$test_root/rules.json" "$MANAGED_DIR/settings/relay.json"
grep -q "ExecStart=$RELAY_BIN run -config $RELAY_CONFIG_DIR/server.json" "$RELAY_SYSTEMD_DIR/$RELAY_SERVICE.service"
grep -qx 'Environment=GOMEMLIMIT=48MiB' "$RELAY_SYSTEMD_DIR/$RELAY_SERVICE.service"
grep -q "enable $RELAY_SERVICE.service" "$test_root/service.log"
cp "$RELAY_CONFIG_DIR/server.json" "$test_root/old-server.json"

# Failed starts and occupied ports restore the previous config and service;
# candidate settings must never be committed.
jq '.[0].target_port = 24200' "$test_root/rules.json" > "$test_root/update.json"
for failure in fail-start occupied; do
    touch "$test_root/$failure"
    if (apply_fixture "$test_root/update.json") > "$test_root/error.log" 2>&1; then die "$failure was accepted"; fi
    cmp "$test_root/old-server.json" "$RELAY_CONFIG_DIR/server.json"
    cmp "$test_root/rules.json" "$MANAGED_DIR/settings/relay.json"
    service_active "$RELAY_SERVICE" || die 'old service not restored'
    rm -f "$test_root/$failure"
done

# Reuse the interactive path for edits/deletes, including empty input defaults.
exec 3<<'EOF'
1


example.net
443
EOF
relay_edit edit
jq -e '.[0] == {port:23101,protocol:"tcp",target:"example.net",target_port:443}' "$MANAGED_DIR/settings/relay.json" >/dev/null
exec 3<<'EOF'
1
EOF
relay_edit delete
[ "$(jq 'length' "$MANAGED_DIR/settings/relay.json")" -eq 3 ]

# OpenRC definition and disabling after deletion of the last rule.
test_init=openrc
apply_fixture "$test_root/rules.json"
sh -n "$RELAY_OPENRC_DIR/$RELAY_SERVICE"
grep -q 'supervisor=supervise-daemon' "$RELAY_OPENRC_DIR/$RELAY_SERVICE"
grep -q "command=\"$RELAY_BIN\"" "$RELAY_OPENRC_DIR/$RELAY_SERVICE"
printf '[]\n' > "$test_root/empty.json"
apply_fixture "$test_root/empty.json"
if service_active "$RELAY_SERVICE"; then die 'empty relay still active'; fi
[ ! -e "$RELAY_CONFIG_DIR/server.json" ]
grep -q "del $RELAY_SERVICE default" "$test_root/service.log"
relay_remove
[ ! -e "$RELAY_BIN" ] && [ ! -e "$MANAGED_DIR/settings/relay.json" ]
[ ! -e "$RELAY_OPENRC_DIR/$RELAY_SERVICE" ] && [ ! -e "$RELAY_SYSTEMD_DIR/$RELAY_SERVICE.service" ]
say 'native relay validation and lifecycle tests passed'
