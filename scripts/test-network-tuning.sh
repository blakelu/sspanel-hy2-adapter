#!/bin/sh
# Mock kernel operations; never modify host networking or require root.
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
# shellcheck disable=SC1091
. "$test_root/functions.sh"
MANAGED_DIR=$test_root/managed
NETWORK_SYSCTL_FILE=$test_root/sysctl.d/network.conf
NETWORK_MODULE_FILE=$test_root/modules-load.d/network.conf
BBR_SYSCTL_FILE=$test_root/sysctl.d/legacy-bbr.conf
BBR_MODULE_FILE=$test_root/modules-load.d/legacy-bbr.conf
mkdir -p "$MANAGED_DIR/settings" "$test_root/sysctl.d"
printf 'cubic\n' > "$test_root/cc"
printf 'pfifo_fast\n' > "$test_root/qdisc"
printf 'reno cubic\n' > "$test_root/available"
sysctl() {
    case "$*" in
        '-n net.ipv4.tcp_congestion_control') cat "$test_root/cc" ;;
        '-n net.ipv4.tcp_available_congestion_control') cat "$test_root/available" ;;
        '-n net.core.default_qdisc') cat "$test_root/qdisc" ;;
        '-w net.ipv4.tcp_congestion_control='*)
            [ "${FAIL_CC:-0}" != 1 ] || return 1
            bbr_algorithm_available "${2#*=}" || return 1
            printf '%s\n' "${2#*=}" > "$test_root/cc" ;;
        '-w net.core.default_qdisc='*)
            [ "${FAIL_QDISC:-0}" != 1 ] || return 1
            printf '%s\n' "${2#*=}" > "$test_root/qdisc" ;;
        *) die "unexpected sysctl: $*" ;;
    esac
}
modprobe() {
    case "$1" in
        tcp_bbr)
            [ "${UNSUPPORTED_BBR:-0}" != 1 ] || return 1
            printf 'reno cubic bbr\n' > "$test_root/available" ;;
        sch_*) return 0 ;;
        *) return 1 ;;
    esac
}
tc() { printf 'qdisc mq 0: dev eth0 root\nqdisc fq_codel 0: dev eth0 parent :1\nqdisc noqueue 0: dev lo root\n'; }
uname() { printf 'Linux\n'; }

# Unsupported algorithms and denied sysctls must not persist changes.
if (UNSUPPORTED_BBR=1; apply_network_tuning bbr fq) > "$test_root/error" 2>&1; then die 'unsupported BBR accepted'; fi
grep -q '无法加载 TCP 算法：bbr' "$test_root/error"
[ ! -e "$NETWORK_SYSCTL_FILE" ]
if (FAIL_QDISC=1; apply_network_tuning bbr fq) > "$test_root/error" 2>&1; then die 'denied qdisc accepted'; fi
[ "$(cat "$test_root/cc")" = cubic ]
[ "$(cat "$test_root/qdisc")" = pfifo_fast ]
[ ! -e "$NETWORK_SYSCTL_FILE" ]
if (FAIL_CC=1; apply_network_tuning bbr fq) > "$test_root/error" 2>&1; then die 'denied CC accepted'; fi
[ "$(cat "$test_root/qdisc")" = pfifo_fast ]
[ ! -e "$NETWORK_MODULE_FILE" ]
[ ! -e "$MANAGED_DIR/settings/network-tuning/original.conf" ]

# Save once, switch combinations, and display actual queues separately.
apply_network_tuning bbr fq > "$test_root/status"
grep -q '当前本机组合（系统默认）：bbr + fq' "$test_root/status"
grep -q 'dev eth0 parent :1' "$test_root/status"
grep -q 'dev lo root' "$test_root/status"
grep -qx 'net.core.default_qdisc = fq' "$NETWORK_SYSCTL_FILE"
grep -qx 'tcp_bbr' "$NETWORK_MODULE_FILE"
grep -qx 'sch_fq' "$NETWORK_MODULE_FILE"
cp "$MANAGED_DIR/settings/network-tuning/original.conf" "$test_root/original"
# A failed switch keeps both runtime and existing persistence unchanged.
cp "$NETWORK_SYSCTL_FILE" "$test_root/persisted"
if (FAIL_CC=1; apply_network_tuning cubic fq_codel) > "$test_root/error" 2>&1; then die 'denied switch accepted'; fi
[ "$(cat "$test_root/cc")" = bbr ]
[ "$(cat "$test_root/qdisc")" = fq ]
cmp "$NETWORK_SYSCTL_FILE" "$test_root/persisted"
apply_network_tuning bbr fq_codel > /dev/null
apply_network_tuning cubic fq_codel > /dev/null
cmp "$MANAGED_DIR/settings/network-tuning/original.conf" "$test_root/original"
[ "$(cat "$test_root/cc")" = cubic ]
[ "$(cat "$test_root/qdisc")" = fq_codel ]
# AnyTLS configuration must leave the chosen global combination intact.
BBR_ENABLED=true
configure_anytls_bbr > /dev/null
[ "$(cat "$test_root/cc")" = cubic ]
choose_anytls_bbr
[ "$BBR_ENABLED" = false ]
remove_network_tuning
[ "$(cat "$test_root/cc")" = cubic ]
[ "$(cat "$test_root/qdisc")" = pfifo_fast ]
[ ! -e "$NETWORK_SYSCTL_FILE" ] && [ ! -e "$NETWORK_MODULE_FILE" ]

# Preserve administrator changes during restore, independently for each key.
apply_network_tuning bbr fq > /dev/null
printf 'reno\n' > "$test_root/cc"
remove_network_tuning
[ "$(cat "$test_root/cc")" = reno ]
[ "$(cat "$test_root/qdisc")" = pfifo_fast ]
apply_network_tuning bbr fq > /dev/null
printf 'fq_codel\n' > "$test_root/qdisc"
remove_network_tuning
[ "$(cat "$test_root/cc")" = reno ]
[ "$(cat "$test_root/qdisc")" = fq_codel ]

# Migrate legacy AnyTLS BBR without losing its original algorithm.
printf 'cubic\n' > "$test_root/cc"
BBR_ENABLED=true
configure_anytls_bbr > /dev/null
[ "$(cat "$test_root/cc")" = bbr ]
apply_network_tuning bbr fq > /dev/null
[ ! -e "$BBR_SYSCTL_FILE" ] && [ ! -e "$BBR_MODULE_FILE" ]
remove_network_tuning
[ "$(cat "$test_root/cc")" = cubic ]
remove_anytls_bbr
[ "$(cat "$test_root/cc")" = cubic ]

# Refuse foreign files and invalid names without applying kernel settings.
printf '# foreign\n' > "$NETWORK_SYSCTL_FILE"
if (apply_network_tuning bbr fq) > "$test_root/error" 2>&1; then die 'foreign file overwritten'; fi
grep -qx '# foreign' "$NETWORK_SYSCTL_FILE"
if (remove_network_tuning) > "$test_root/error" 2>&1; then die 'foreign file removed'; fi
rm "$NETWORK_SYSCTL_FILE"
if (apply_network_tuning '../bad' fq) > "$test_root/error" 2>&1; then die 'invalid name accepted'; fi

# Real menu input exercises presets, refresh, invalid choice, and return.
exec 3<<'EOF'
invalid
1
2
3
5
0
EOF
menu_action 5 > "$test_root/menu"
[ "$(cat "$test_root/cc")" = cubic ]
[ "$(cat "$test_root/qdisc")" = fq_codel ]
grep -q '当前本机组合（系统默认）：bbr + fq' "$test_root/menu"
remove_network_tuning
# Custom selection and restoration are also reachable through the menu.
exec 3<<'EOF'
4
reno
0
6
0
EOF
menu_action 5 > /dev/null
[ "$(cat "$test_root/cc")" = cubic ]
[ ! -e "$NETWORK_SYSCTL_FILE" ]
say 'network tuning tests passed'
