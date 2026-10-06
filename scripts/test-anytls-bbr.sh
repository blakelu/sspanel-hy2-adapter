#!/bin/sh
# Mock all kernel operations; these tests never change the host TCP settings.
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
BBR_SYSCTL_FILE=$test_root/sysctl.d/zz-sspanel-native-anytls-bbr.conf
BBR_MODULE_FILE=$test_root/modules-load.d/sspanel-native-anytls-bbr.conf
mkdir -p "$MANAGED_DIR/settings"
reset_kernel() {
    printf 'cubic\n' > "$test_root/current"
    printf 'reno cubic\n' > "$test_root/available"
    : > "$test_root/kernel.log"
}
sysctl() {
    case "$*" in
        '-n net.ipv4.tcp_congestion_control') cat "$test_root/current" ;;
        '-n net.ipv4.tcp_available_congestion_control') cat "$test_root/available" ;;
        '-w net.ipv4.tcp_congestion_control='*)
            printf '%s\n' "$*" >> "$test_root/kernel.log"
            printf '%s\n' "${2#*=}" > "$test_root/current"
            ;;
        *) die "unexpected sysctl: $*" ;;
    esac
}
modprobe() {
    [ "$1" = tcp_bbr ]
    printf 'modprobe %s\n' "$1" >> "$test_root/kernel.log"
    [ "${BBR_TEST_UNSUPPORTED:-0}" != 1 ] || return 1
    printf 'reno cubic bbr\n' > "$test_root/available"
}
reset_kernel
# Existing and first-install defaults, saved choices, and invalid input retry.
exec 3<<'EOF'

EOF
choose_anytls_bbr
[ "$BBR_ENABLED" = false ]
printf 'bbr\n' > "$test_root/current"
exec 3<<'EOF'

EOF
choose_anytls_bbr
[ "$BBR_ENABLED" = true ]
printf 'BBR_ENABLED=false\n' > "$MANAGED_DIR/settings/anytls.conf"
exec 3<<'EOF'
invalid
1
EOF
choose_anytls_bbr
[ "$BBR_ENABLED" = true ]
reset_kernel
# Unsupported kernels fail before writing sysctl or persistence files.
if (BBR_TEST_UNSUPPORTED=1; configure_anytls_bbr) >/dev/null 2>&1; then die 'unsupported BBR was accepted'; fi
[ "$(cat "$test_root/current")" = cubic ]
[ ! -e "$BBR_SYSCTL_FILE" ] && [ ! -e "$BBR_MODULE_FILE" ]
[ ! -e "$MANAGED_DIR/settings/anytls-bbr/original-congestion" ]
configure_anytls_bbr
[ "$(cat "$test_root/current")" = bbr ]
[ "$(bbr_original)" = cubic ]
grep -qx 'tcp_bbr' "$BBR_MODULE_FILE"
grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$BBR_SYSCTL_FILE"
# Repeated enable must retain the original algorithm and avoid extra writes.
cp "$test_root/kernel.log" "$test_root/kernel.before"
configure_anytls_bbr
cmp "$test_root/kernel.before" "$test_root/kernel.log"
[ "$(bbr_original)" = cubic ]
BBR_ENABLED=false
configure_anytls_bbr
[ "$(cat "$test_root/current")" = cubic ]
grep -qx 'net.ipv4.tcp_congestion_control = cubic' "$BBR_SYSCTL_FILE"
[ ! -e "$BBR_MODULE_FILE" ]
BBR_ENABLED=true
configure_anytls_bbr
remove_anytls_bbr
[ "$(cat "$test_root/current")" = cubic ]
[ ! -e "$BBR_SYSCTL_FILE" ] && [ ! -e "$BBR_MODULE_FILE" ]
# An administrator's later change survives uninstall.
configure_anytls_bbr
printf 'reno\n' > "$test_root/current"
remove_anytls_bbr
[ "$(cat "$test_root/current")" = reno ]
# Never overwrite files owned by another program.
mkdir -p "$(dirname "$BBR_SYSCTL_FILE")"
printf '# foreign file\n' > "$BBR_SYSCTL_FILE"
if (configure_anytls_bbr) >/dev/null 2>&1; then die 'foreign BBR file was overwritten'; fi
grep -qx '# foreign file' "$BBR_SYSCTL_FILE"
remove_anytls_bbr
[ -f "$BBR_SYSCTL_FILE" ]
rm "$BBR_SYSCTL_FILE"
rm -rf "$MANAGED_DIR/settings/anytls-bbr"
# Turning off a pre-existing BBR uses cubic, without deleting other tools' files.
printf 'bbr\n' > "$test_root/current"
BBR_ENABLED=false
configure_anytls_bbr
[ "$(bbr_original)" = bbr ]
[ "$(cat "$test_root/current")" = cubic ]
grep -qx 'net.ipv4.tcp_congestion_control = cubic' "$BBR_SYSCTL_FILE"
remove_anytls_bbr
[ "$(cat "$test_root/current")" = bbr ]
rm -rf "$MANAGED_DIR/settings/anytls-bbr"
# No kernel or boot changes when BBR is already off and unmanaged.
reset_kernel
configure_anytls_bbr
[ ! -e "$BBR_SYSCTL_FILE" ] && [ ! -s "$test_root/kernel.log" ]
say 'AnyTLS BBR tests passed'
