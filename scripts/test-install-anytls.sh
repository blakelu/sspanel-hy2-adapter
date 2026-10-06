#!/bin/sh
# Run the real Linux installer/binary in a disposable container. systemctl is a
# local fixture which runs the generated ExecStart; no host services are touched.
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' 0
trap 'exit 130' 1 2 3 15
mkdir -p "$test_root/mock-bin"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=anytls.example.com \
    -addext subjectAltName=DNS:anytls.example.com \
    -keyout "$test_root/key.pem" -out "$test_root/cert.pem" >/dev/null 2>&1
sed 's|/absolute/path/fullchain.pem|/fixtures/cert.pem|; s|/absolute/path/key.pem|/fixtures/key.pem|; s|listen: 0.0.0.0:443|listen: 0.0.0.0:18443|' \
    "$project_dir/native/anytls/adapter.yaml.example" > "$test_root/adapter.yaml"
cat > "$test_root/server.env" <<'EOF'
ADAPTER_AUTH_TOKEN=fixture-admin-token
SSPANEL_BASE_URL=http://127.0.0.1:19080
SSPANEL_MU_KEY=fixture-mukey
SSPANEL_NODE_ID=16
EOF
cat > "$test_root/panel.php" <<'EOF'
<?php
header('Content-Type: application/json');
if (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/mod_mu/users') {
    echo '{"ret":1,"data":[{"id":7,"uuid":"fixture-uuid"}]}';
} else {
    echo '{"ret":1}';
}
EOF
cat > "$test_root/mock-bin/systemctl" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    is-active) [ -f /run/anytls-test.pid ] && kill -0 "$(cat /run/anytls-test.pid)" 2>/dev/null; exit $? ;;
    restart)
        [ "$2" = sspanel-native-anytls-adapter.service ]
        if [ -f /run/anytls-test.pid ]; then
            old_pid=$(cat /run/anytls-test.pid)
            kill "$old_pid"
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$old_pid" 2>/dev/null || break
                [ "$(awk '{print $3}' "/proc/$old_pid/stat")" = Z ] && break
                sleep 0.1
            done
        fi
        unit=/etc/systemd/system/$2
        if grep -Eq '^(Wants|After)=.*sspanel-native-anytls-adapter' "$unit"; then exit 1; fi
        env_file=$(awk -F= '$1=="EnvironmentFile" {print $2}' "$unit")
        work_dir=$(awk -F= '$1=="WorkingDirectory" {print $2}' "$unit")
        start=$(sed -n 's/^ExecStart=//p' "$unit")
        while IFS= read -r line; do export "$line"; done < "$env_file"
        cd "$work_dir"
        # The generated unit's command and paths contain no spaces or quoting.
        # shellcheck disable=SC2086
        $start >/tmp/anytls-test.log 2>&1 &
        echo "$!" > /run/anytls-test.pid
        ;;
    daemon-reload|enable|--no-pager) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$test_root/mock-bin/systemctl"
cat > "$test_root/mock-bin/sysctl" <<'EOF'
#!/bin/sh
# Never modify the Docker host kernel.
case "$*" in
    '-n net.ipv4.tcp_congestion_control')
        if [ -f /run/anytls-test-congestion ]; then cat /run/anytls-test-congestion; else printf 'cubic\n'; fi ;;
    '-n net.ipv4.tcp_available_congestion_control') printf 'reno cubic bbr\n' ;;
    '-w net.ipv4.tcp_congestion_control='*) printf '%s\n' "${2#*=}" > /run/anytls-test-congestion ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$test_root/mock-bin/sysctl"
docker run --rm --platform linux/amd64 \
    -v "$project_dir:/workspace:ro" -v "$test_root:/fixtures:ro" \
    -w /workspace --entrypoint sh "${NATIVE_TEST_IMAGE:-sspanel-php-sub-tests:local}" -ec '
    mkdir -p /run/systemd/system /etc/systemd/system
    export PATH=/fixtures/mock-bin:$PATH
    php -S 127.0.0.1:19080 /fixtures/panel.php >/tmp/panel-test.log 2>&1 &
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        curl -fsS http://127.0.0.1:19080/mod_mu/users >/dev/null 2>&1 && break
        sleep 0.1
    done
    export NATIVE_CONFIG_DIR=/fixtures
    sh scripts/install-native.sh anytls
    curl -fsS http://127.0.0.1:18082/healthz
    [ "$(stat -c %a /etc/sspanel-native/anytls/server.env)" = 600 ]
    [ "$(stat -c %a /var/lib/sspanel-native/anytls)" = 700 ]
    [ ! -f /etc/systemd/system/sspanel-native-anytls-sspanel-hy2-adapter.service ]
    sh scripts/install-native.sh anytls
    curl -fsS http://127.0.0.1:18082/healthz
    export NATIVE_LOCAL_ASSETS_DIR=/workspace
    # Existing installation: exercise the real manager update flow with
    # checked local assets, hidden credentials, TLS validation and settings.
    sh scripts/native-manager.sh 4 <<EOF
3
http://127.0.0.1:19080
fixture-mukey
16
fixture-admin-token
18443
18443
anytls.example.com
2
/fixtures/cert.pem
/fixtures/key.pem
1
EOF
    curl -fsS http://127.0.0.1:18082/healthz
    grep -q "DOMAIN=anytls.example.com" /opt/sspanel-native/settings/anytls.conf
    grep -qx "BBR_ENABLED=true" /opt/sspanel-native/settings/anytls.conf
    [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ]
    grep -qx "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.d/zz-sspanel-native-anytls-bbr.conf
    sh scripts/native-manager.sh 4 <<EOF
3
http://127.0.0.1:19080
fixture-mukey
16
fixture-admin-token
18443
18443
anytls.example.com
2
/fixtures/cert.pem
/fixtures/key.pem
2
EOF
    curl -fsS http://127.0.0.1:18082/healthz
    grep -qx "BBR_ENABLED=false" /opt/sspanel-native/settings/anytls.conf
    [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = cubic ]
    [ ! -f /etc/modules-load.d/sspanel-native-anytls-bbr.conf ]
    kill "$(cat /run/anytls-test.pid)"
    '
printf '\nAnyTLS Linux installation and reinstallation passed\n'
