#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
ENV_FILE="${ENV_FILE:-${PROJECT_DIR}/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_DIR}/docker-compose.hy2.yaml}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-hysteria}"
LOCK_FILE="${LOCK_FILE:-${PROJECT_DIR}/.port-sync.lock}"

log() {
    printf '[sspanel-hy2-port-sync] %s\n' "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

read_env() {
    local key="$1"
    local value

    value="$(awk -v key="${key}" '
        index($0, key "=") == 1 {
            sub(/^[^=]*=/, "")
            result = $0
        }
        END { print result }
    ' "${ENV_FILE}")"
    value="${value%$'\r'}"

    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "${value}"
}

require_command curl
require_command docker
require_command flock
require_command jq

[[ -f "${ENV_FILE}" ]] || fail "env file not found: ${ENV_FILE}"
[[ -f "${COMPOSE_FILE}" ]] || fail "compose file not found: ${COMPOSE_FILE}"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "another sync is running; skip"
    exit 0
fi

docker compose version >/dev/null 2>&1 || fail "docker compose plugin is unavailable"

panel_base_url="${SSPANEL_BASE_URL:-$(read_env SSPANEL_BASE_URL)}"
panel_key="${SSPANEL_MU_KEY:-$(read_env SSPANEL_MU_KEY)}"
node_id="${SSPANEL_NODE_ID:-$(read_env SSPANEL_NODE_ID)}"
allowed_min="${HY2_ALLOWED_PORT_MIN:-$(read_env HY2_ALLOWED_PORT_MIN)}"
allowed_max="${HY2_ALLOWED_PORT_MAX:-$(read_env HY2_ALLOWED_PORT_MAX)}"
current_port="$(read_env HY2_PUBLIC_PORT)"
adapter_token="${ADAPTER_AUTH_TOKEN:-$(read_env ADAPTER_AUTH_TOKEN)}"
adapter_debug_port="${ADAPTER_DEBUG_PORT:-$(read_env ADAPTER_DEBUG_PORT)}"

[[ -n "${panel_base_url}" ]] || fail "SSPANEL_BASE_URL is empty"
[[ -n "${panel_key}" ]] || fail "SSPANEL_MU_KEY is empty"
[[ "${node_id}" =~ ^[1-9][0-9]*$ ]] || fail "SSPANEL_NODE_ID must be a positive integer"
[[ -n "${adapter_token}" ]] || fail "ADAPTER_AUTH_TOKEN is empty"
[[ -n "${adapter_debug_port}" ]] || adapter_debug_port=18080
[[ "${adapter_debug_port}" =~ ^[0-9]+$ ]] && (( adapter_debug_port >= 1 && adapter_debug_port <= 65535 )) || \
    fail "ADAPTER_DEBUG_PORT must be an integer from 1 to 65535"
[[ "${allowed_min}" =~ ^[0-9]+$ ]] || allowed_min=1024
[[ "${allowed_max}" =~ ^[0-9]+$ ]] || allowed_max=65535
(( allowed_min >= 1 && allowed_min <= allowed_max && allowed_max <= 65535 )) || \
    fail "invalid allowed port range: ${allowed_min}-${allowed_max}"

panel_base_url="${panel_base_url%/}"
response="$(curl --fail --silent --show-error --max-time 10 \
    --get "${panel_base_url}/mod_mu/nodes/${node_id}/info" \
    --data-urlencode "key=${panel_key}" \
    --data-urlencode "muKey=${panel_key}")" || fail "failed to fetch node ${node_id} from panel"

desired_port="$(jq -er '
    if .ret != 1 then
        error(.msg // "panel returned an error")
    else
        .data.custom_config.offset_port_node
    end
    | if type == "string" then tonumber else . end
    | select(type == "number" and floor == . and . >= 1 and . <= 65535)
' <<<"${response}")" || fail "panel custom_config.offset_port_node is missing or invalid"

(( desired_port >= allowed_min && desired_port <= allowed_max )) || \
    fail "panel port ${desired_port} is outside allowed range ${allowed_min}-${allowed_max}"

if [[ "${current_port}" == "${desired_port}" ]]; then
    log "port unchanged: ${desired_port}/udp"
    exit 0
fi

if command -v ss >/dev/null 2>&1 && ss -H -lun "sport = :${desired_port}" | grep -q .; then
    fail "UDP port ${desired_port} is already in use"
fi

log "collecting pending traffic before port change"
curl --fail --silent --show-error --max-time 20 \
    --request POST \
    --header "X-Adapter-Token: ${adapter_token}" \
    "http://127.0.0.1:${adapter_debug_port}/admin/collect" >/dev/null || \
    fail "failed to collect traffic; port was not changed"

env_backup="$(mktemp "${ENV_FILE}.backup.XXXXXX")"
env_next="$(mktemp "${ENV_FILE}.next.XXXXXX")"
cleanup() {
    rm -f -- "${env_backup}" "${env_next}"
}
trap cleanup EXIT

cp -p -- "${ENV_FILE}" "${env_backup}"
cp -p -- "${ENV_FILE}" "${env_next}"
awk -v port="${desired_port}" '
    BEGIN { updated = 0 }
    index($0, "HY2_PUBLIC_PORT=") == 1 {
        print "HY2_PUBLIC_PORT=" port
        updated = 1
        next
    }
    { print }
    END {
        if (! updated) {
            print "HY2_PUBLIC_PORT=" port
        }
    }
' "${ENV_FILE}" >"${env_next}"
mv -f -- "${env_next}" "${ENV_FILE}"

log "panel requests ${desired_port}/udp; recreating ${COMPOSE_SERVICE}"
if (
    cd -- "${PROJECT_DIR}"
    docker compose -f "${COMPOSE_FILE}" up -d --no-deps --force-recreate "${COMPOSE_SERVICE}"
); then
    rm -f -- "${env_backup}"
    log "port applied: ${desired_port}/udp"
    exit 0
fi

log "recreate failed; restoring previous env and service" >&2
mv -f -- "${env_backup}" "${ENV_FILE}"
(
    cd -- "${PROJECT_DIR}"
    docker compose -f "${COMPOSE_FILE}" up -d --no-deps --force-recreate "${COMPOSE_SERVICE}"
) || log "ERROR: failed to restore ${COMPOSE_SERVICE}; manual intervention required"
exit 1
