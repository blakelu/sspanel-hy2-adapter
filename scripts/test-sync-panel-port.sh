#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/sync-panel-port.sh"
TEST_DIR="$(mktemp -d)"
MOCK_BIN="${TEST_DIR}/mock-bin"
ENV_FILE="${TEST_DIR}/.env"
COMPOSE_FILE="${TEST_DIR}/docker-compose.hy2.yaml"
DOCKER_LOG="${TEST_DIR}/docker.log"

cleanup() {
    rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

mkdir -p "${MOCK_BIN}"

cat >"${ENV_FILE}" <<'EOF'
SSPANEL_BASE_URL=https://panel.example.com
SSPANEL_MU_KEY=secret
SSPANEL_NODE_ID=11
HY2_PUBLIC_PORT=8443
HY2_ALLOWED_PORT_MIN=8000
HY2_ALLOWED_PORT_MAX=9000
ADAPTER_AUTH_TOKEN=adapter-secret
ADAPTER_DEBUG_PORT=18080
EOF
chmod 600 "${ENV_FILE}"

cat >"${COMPOSE_FILE}" <<'EOF'
services:
  hysteria:
    image: example.invalid/hysteria
EOF

cat >"${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/admin/collect"* ]]; then
    printf '%s\n' collect >>"${MOCK_CURL_LOG}"
    if [[ "${MOCK_COLLECT_FAIL:-0}" == "1" ]]; then
        exit 22
    fi
    printf '%s' '{"ok":true}'
    exit 0
fi
printf '%s' "${MOCK_PANEL_RESPONSE}"
EOF

cat >"${MOCK_BIN}/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    exit 0
fi
printf '%s\n' "$*" >>"${MOCK_DOCKER_LOG}"
if [[ "${MOCK_DOCKER_FAIL_ONCE:-0}" == "1" && ! -e "${MOCK_DOCKER_FAIL_MARKER}" ]]; then
    : >"${MOCK_DOCKER_FAIL_MARKER}"
    exit 1
fi
exit 0
EOF

chmod +x "${MOCK_BIN}/curl" "${MOCK_BIN}/docker" "${MOCK_BIN}/flock"

run_sync() {
    PATH="${MOCK_BIN}:${PATH}" \
    PROJECT_DIR="${TEST_DIR}" \
    ENV_FILE="${ENV_FILE}" \
    COMPOSE_FILE="${COMPOSE_FILE}" \
    LOCK_FILE="${TEST_DIR}/sync.lock" \
    MOCK_DOCKER_LOG="${DOCKER_LOG}" \
    MOCK_CURL_LOG="${TEST_DIR}/curl.log" \
    MOCK_PANEL_RESPONSE="${MOCK_PANEL_RESPONSE}" \
    MOCK_COLLECT_FAIL="${MOCK_COLLECT_FAIL:-0}" \
    MOCK_DOCKER_FAIL_ONCE="${MOCK_DOCKER_FAIL_ONCE:-0}" \
    MOCK_DOCKER_FAIL_MARKER="${TEST_DIR}/docker-failed" \
    "${SYNC_SCRIPT}"
}

MOCK_PANEL_RESPONSE='{"ret":1,"data":{"custom_config":{"offset_port_node":"8555"}}}'
run_sync
grep -qx 'HY2_PUBLIC_PORT=8555' "${ENV_FILE}"
grep -q -- '--force-recreate hysteria' "${DOCKER_LOG}"
grep -qx 'collect' "${TEST_DIR}/curl.log"

: >"${DOCKER_LOG}"
run_sync
[[ ! -s "${DOCKER_LOG}" ]]

MOCK_PANEL_RESPONSE='{"ret":1,"data":{"custom_config":{"offset_port_node":9999}}}'
if run_sync; then
    printf 'expected out-of-range port to fail\n' >&2
    exit 1
fi
grep -qx 'HY2_PUBLIC_PORT=8555' "${ENV_FILE}"

MOCK_PANEL_RESPONSE='{"ret":1,"data":{"custom_config":{"offset_port_node":8666}}}'
MOCK_COLLECT_FAIL=1
: >"${DOCKER_LOG}"
if run_sync; then
    printf 'expected failed traffic collection to return an error\n' >&2
    exit 1
fi
grep -qx 'HY2_PUBLIC_PORT=8555' "${ENV_FILE}"
[[ ! -s "${DOCKER_LOG}" ]]
MOCK_COLLECT_FAIL=0

MOCK_PANEL_RESPONSE='{"ret":1,"data":{"custom_config":{"offset_port_node":8666}}}'
MOCK_DOCKER_FAIL_ONCE=1
rm -f "${TEST_DIR}/docker-failed"
if run_sync; then
    printf 'expected failed recreate to return an error\n' >&2
    exit 1
fi
grep -qx 'HY2_PUBLIC_PORT=8555' "${ENV_FILE}"
[[ "$(grep -c -- '--force-recreate hysteria' "${DOCKER_LOG}")" -eq 2 ]]

printf 'sync-panel-port tests passed\n'
