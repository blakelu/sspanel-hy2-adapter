#!/usr/bin/env bash

set -uo pipefail

interval="${PORT_SYNC_INTERVAL:-30}"
if [[ ! "${interval}" =~ ^[1-9][0-9]*$ ]]; then
    printf '[sspanel-hy2-port-sync] ERROR: PORT_SYNC_INTERVAL must be a positive integer\n' >&2
    exit 1
fi

stopping=0
sleep_pid=""
stop() {
    stopping=1
    if [[ -n "${sleep_pid}" ]]; then
        kill "${sleep_pid}" 2>/dev/null || true
    fi
}
trap stop INT TERM

printf '[sspanel-hy2-port-sync] container loop started; interval=%ss\n' "${interval}"
while (( ! stopping )); do
    /usr/local/bin/sync-panel-port.sh || \
        printf '[sspanel-hy2-port-sync] sync failed; retrying in %ss\n' "${interval}" >&2
    (( stopping )) && break
    sleep "${interval}" &
    sleep_pid=$!
    wait "${sleep_pid}" 2>/dev/null || true
    sleep_pid=""
done
printf '[sspanel-hy2-port-sync] container loop stopped\n'
