#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
ENV_FILE="${ENV_FILE:-${PROJECT_DIR}/.env}"
PORT_SYNC_MODE="${PORT_SYNC_MODE:-hy2}"
LOCK_FILE="${LOCK_FILE:-${PROJECT_DIR}/.port-sync.lock}"

case "${PORT_SYNC_MODE}" in
    hy2)
        COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_DIR}/docker-compose.hy2.yaml}"
        COMPOSE_SERVICE="${COMPOSE_SERVICE:-hysteria}"
        CONTAINER_PORT="${CONTAINER_PORT:-${HY2_CONTAINER_PORT:-8443}}"
        PORT_PROTOCOL="udp"
        PUBLIC_PORT_ENV="HY2_PUBLIC_PORT"
        ALLOWED_MIN_ENV="HY2_ALLOWED_PORT_MIN"
        ALLOWED_MAX_ENV="HY2_ALLOWED_PORT_MAX"
        SYNC_REQUIRED_FILE=""
        ;;
    vless)
        COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_DIR}/docker-compose.vless-reality.yaml}"
        COMPOSE_SERVICE="${COMPOSE_SERVICE:-xray}"
        CONTAINER_PORT="${CONTAINER_PORT:-${VLESS_CONTAINER_PORT:-443}}"
        PORT_PROTOCOL="tcp"
        PUBLIC_PORT_ENV="VLESS_PUBLIC_PORT"
        ALLOWED_MIN_ENV="VLESS_ALLOWED_PORT_MIN"
        ALLOWED_MAX_ENV="VLESS_ALLOWED_PORT_MAX"
        SYNC_REQUIRED_FILE="${SYNC_REQUIRED_FILE:-${PROJECT_DIR}/.vless-sync-required}"
        ;;
    *)
        printf '[sspanel-port-sync] ERROR: PORT_SYNC_MODE must be hy2 or vless\n' >&2
        exit 1
        ;;
esac

log() {
    printf '[sspanel-%s-port-sync] %s\n' "${PORT_SYNC_MODE}" "$*"
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

sync_users() {
    curl --fail --silent --show-error --max-time 20 \
        --request POST \
        --header "X-Adapter-Token: ${adapter_token}" \
        "${adapter_sync_url}" >/dev/null
}

retry_sync_users() {
    local attempt
    for ((attempt = 1; attempt <= sync_retry_attempts; attempt++)); do
        if sync_users; then
            rm -f -- "${SYNC_REQUIRED_FILE}"
            log "Xray users synchronized after port change"
            return 0
        fi
        (( attempt == sync_retry_attempts )) || sleep 1
    done
    return 1
}

require_command curl
require_command docker
require_command flock
require_command jq

[[ "${PROJECT_DIR}" == /* ]] || fail "PROJECT_DIR must be an absolute path"
[[ -f "${ENV_FILE}" ]] || fail "env file not found: ${ENV_FILE}"
[[ -f "${COMPOSE_FILE}" ]] || fail "compose file not found: ${COMPOSE_FILE}"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "another sync is running; skip"
    exit 0
fi

docker compose version >/dev/null 2>&1 || fail "docker compose plugin is unavailable"
[[ "${CONTAINER_PORT}" =~ ^[0-9]+$ ]] && (( CONTAINER_PORT >= 1 && CONTAINER_PORT <= 65535 )) || \
    fail "container port must be an integer from 1 to 65535"

panel_base_url="${SSPANEL_BASE_URL:-$(read_env SSPANEL_BASE_URL)}"
panel_key="${SSPANEL_MU_KEY:-$(read_env SSPANEL_MU_KEY)}"
node_id="${SSPANEL_NODE_ID:-$(read_env SSPANEL_NODE_ID)}"
allowed_min="${!ALLOWED_MIN_ENV:-$(read_env "${ALLOWED_MIN_ENV}")}"
allowed_max="${!ALLOWED_MAX_ENV:-$(read_env "${ALLOWED_MAX_ENV}")}"
current_port="$(read_env "${PUBLIC_PORT_ENV}")"
adapter_token="${ADAPTER_AUTH_TOKEN:-$(read_env ADAPTER_AUTH_TOKEN)}"
adapter_debug_port="${ADAPTER_DEBUG_PORT:-$(read_env ADAPTER_DEBUG_PORT)}"
adapter_admin_url="${ADAPTER_ADMIN_URL:-$(read_env ADAPTER_ADMIN_URL)}"
adapter_sync_url="${ADAPTER_SYNC_URL:-$(read_env ADAPTER_SYNC_URL)}"
sync_retry_attempts="${SYNC_RETRY_ATTEMPTS:-10}"

[[ -n "${panel_base_url}" ]] || fail "SSPANEL_BASE_URL is empty"
[[ -n "${panel_key}" ]] || fail "SSPANEL_MU_KEY is empty"
[[ "${node_id}" =~ ^[1-9][0-9]*$ ]] || fail "SSPANEL_NODE_ID must be a positive integer"
[[ -n "${adapter_token}" ]] || fail "ADAPTER_AUTH_TOKEN is empty"
[[ -n "${adapter_debug_port}" ]] || adapter_debug_port=18080
[[ "${adapter_debug_port}" =~ ^[0-9]+$ ]] && (( adapter_debug_port >= 1 && adapter_debug_port <= 65535 )) || \
    fail "ADAPTER_DEBUG_PORT must be an integer from 1 to 65535"
[[ -n "${adapter_admin_url}" ]] || adapter_admin_url="http://127.0.0.1:${adapter_debug_port}/admin/collect"
[[ -n "${adapter_sync_url}" ]] || adapter_sync_url="http://127.0.0.1:${adapter_debug_port}/admin/sync-users"
[[ "${sync_retry_attempts}" =~ ^[1-9][0-9]*$ ]] || fail "SYNC_RETRY_ATTEMPTS must be a positive integer"
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

published_address=""
if published_address="$(
    cd -- "${PROJECT_DIR}"
    docker compose -f "${COMPOSE_FILE}" port --protocol "${PORT_PROTOCOL}" "${COMPOSE_SERVICE}" "${CONTAINER_PORT}" 2>/dev/null
)"; then
    published_address="$(printf '%s\n' "${published_address}" | head -n 1)"
fi
actual_port="${published_address##*:}"
[[ "${actual_port}" =~ ^[0-9]+$ ]] || actual_port=""

if [[ "${current_port}" == "${desired_port}" && "${actual_port}" == "${desired_port}" ]]; then
    if [[ -n "${SYNC_REQUIRED_FILE}" && -f "${SYNC_REQUIRED_FILE}" ]]; then
        log "port is applied but Xray user synchronization is pending"
        retry_sync_users || fail "failed to synchronize Xray users; will retry"
    fi
    log "port unchanged: ${desired_port}/${PORT_PROTOCOL}"
    exit 0
fi

if [[ "${current_port}" == "${desired_port}" ]]; then
    log "env requests ${desired_port}/${PORT_PROTOCOL} but Docker publishes ${actual_port:-none}; repairing"
fi

if [[ "${actual_port}" != "${desired_port}" ]] && command -v ss >/dev/null 2>&1; then
    if [[ "${PORT_PROTOCOL}" == "udp" ]] && ss -H -lun "sport = :${desired_port}" | grep -q .; then
        fail "UDP port ${desired_port} is already in use"
    fi
    if [[ "${PORT_PROTOCOL}" == "tcp" ]] && ss -H -ltn "sport = :${desired_port}" | grep -q .; then
        fail "TCP port ${desired_port} is already in use"
    fi
fi

log "collecting pending traffic before port change"
curl --fail --silent --show-error --max-time 20 \
    --request POST \
    --header "X-Adapter-Token: ${adapter_token}" \
    "${adapter_admin_url}" >/dev/null || \
    fail "failed to collect traffic; port was not changed"

env_backup="$(mktemp "${ENV_FILE}.backup.XXXXXX")"
env_next="$(mktemp "${ENV_FILE}.next.XXXXXX")"
cleanup() {
    rm -f -- "${env_backup}" "${env_next}"
}
trap cleanup EXIT

cp -p -- "${ENV_FILE}" "${env_backup}"
cp -p -- "${ENV_FILE}" "${env_next}"
awk -v key="${PUBLIC_PORT_ENV}" -v port="${desired_port}" '
    BEGIN { updated = 0 }
    index($0, key "=") == 1 {
        print key "=" port
        updated = 1
        next
    }
    { print }
    END {
        if (! updated) {
            print key "=" port
        }
    }
' "${ENV_FILE}" >"${env_next}"
mv -f -- "${env_next}" "${ENV_FILE}"

if [[ -n "${SYNC_REQUIRED_FILE}" ]]; then
    touch "${SYNC_REQUIRED_FILE}"
fi

log "panel requests ${desired_port}/${PORT_PROTOCOL}; recreating ${COMPOSE_SERVICE}"
if (
    cd -- "${PROJECT_DIR}"
    docker compose -f "${COMPOSE_FILE}" up -d --no-deps --force-recreate "${COMPOSE_SERVICE}"
); then
    rm -f -- "${env_backup}"
    log "port applied: ${desired_port}/${PORT_PROTOCOL}"
    if [[ -n "${SYNC_REQUIRED_FILE}" ]] && ! retry_sync_users; then
        log "ERROR: port is applied but Xray user synchronization failed; will retry" >&2
        exit 1
    fi
    exit 0
fi

log "recreate failed; restoring previous env and service" >&2
mv -f -- "${env_backup}" "${ENV_FILE}"
if (
    cd -- "${PROJECT_DIR}"
    docker compose -f "${COMPOSE_FILE}" up -d --no-deps --force-recreate "${COMPOSE_SERVICE}"
); then
    if [[ -n "${SYNC_REQUIRED_FILE}" ]] && ! retry_sync_users; then
        log "ERROR: previous Xray port was restored but user synchronization is pending" >&2
    fi
else
    log "ERROR: failed to restore ${COMPOSE_SERVICE}; manual intervention required" >&2
fi
exit 1
