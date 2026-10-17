#!/bin/sh
# Exercise architecture selection and checksum validation without installing services.
set -eu
project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' 0
trap 'exit 130' 1 2 3 15
TMPDIR=$test_root
export TMPDIR
awk '
    /^if \[ "\$#" -gt 1 \]/ { exit }
    /^\[ "\$\(id -u\)"/ { next }
    /^exec 3<&0/ { next }
    /^trap / { next }
    { print }
' "$project_dir/scripts/native-manager.sh" > "$test_root/functions.sh"
# shellcheck disable=SC1091
. "$test_root/functions.sh"

NATIVE_LOCAL_ASSETS_DIR=$test_root/assets
mkdir -p "$NATIVE_LOCAL_ASSETS_DIR/bin" "$NATIVE_LOCAL_ASSETS_DIR/scripts"
cp "$project_dir/scripts/install-native.sh" "$NATIVE_LOCAL_ASSETS_DIR/scripts/"
cp "$project_dir/bin/anytls-LICENSE" "$project_dir/bin/anytls-SOURCE.txt" "$NATIVE_LOCAL_ASSETS_DIR/bin/"
for suffix in linux linux-arm64; do
    for binary in sspanel-hy2-adapter hysteria xray; do
        fixture="$NATIVE_LOCAL_ASSETS_DIR/bin/$binary-$suffix"
        cat > "$fixture" <<EOF
#!/bin/sh
case "\$1" in
    -version|version) printf '%s\\n' '$binary-$suffix' ;;
    -capabilities) printf 'anytls\\n' ;;
    *) exit 1 ;;
esac
EOF
    done
done
(
    cd "$NATIVE_LOCAL_ASSETS_DIR"
    sha256sum scripts/install-native.sh bin/* > bin/SHA256SUMS
)

test_os=Linux
uname() {
    case "$1" in
        -s) printf '%s\n' "$test_os" ;;
        -m) printf '%s\n' "$test_arch" ;;
        *) return 1 ;;
    esac
}
for test_arch in x86_64 amd64 aarch64 arm64; do
    case "$test_arch" in x86_64|amd64) expected_suffix=linux ;; *) expected_suffix=linux-arm64 ;; esac
    for test_mode in hy2 vless anytls; do
        MANAGED_DIR=$test_root/managed-$test_arch-$test_mode
        fetch_assets "$test_mode"
        [ "$("$MANAGED_DIR/bin/sspanel-hy2-adapter-linux" -version)" = "sspanel-hy2-adapter-$expected_suffix" ]
        case "$test_mode" in
            hy2) [ "$("$MANAGED_DIR/bin/hysteria-linux" version)" = "hysteria-$expected_suffix" ] ;;
            vless) [ "$("$MANAGED_DIR/bin/xray-linux" version)" = "xray-$expected_suffix" ] ;;
            anytls) [ ! -e "$MANAGED_DIR/bin/hysteria-linux" ] && [ ! -e "$MANAGED_DIR/bin/xray-linux" ] ;;
        esac
        cmp "$project_dir/scripts/install-native.sh" "$MANAGED_DIR/scripts/install-native.sh"
        [ -z "$STAGE" ]
    done
done

# Unsupported hosts must fail before trying to download or creating managed files.
MANAGED_DIR=$test_root/unsupported
test_arch=armv7l
if (fetch_assets hy2) > "$test_root/error.log" 2>&1; then die 'ARMv7 was accepted'; fi
grep -q '不支持的 CPU 架构' "$test_root/error.log" || { cat "$test_root/error.log"; exit 1; }
[ ! -e "$MANAGED_DIR" ]
test_arch=aarch64
test_os=Darwin
if (fetch_assets hy2) > "$test_root/error.log" 2>&1; then die 'Darwin was accepted'; fi
grep -q '只支持 Linux' "$test_root/error.log"
[ ! -e "$MANAGED_DIR" ]
test_os=Linux

# A corrupt or unpublished ARM64 file must never fall back to the x86_64 binary.
MANAGED_DIR=$test_root/corrupt
printf '\ncorrupt\n' >> "$NATIVE_LOCAL_ASSETS_DIR/bin/hysteria-linux-arm64"
if (fetch_assets hy2) > "$test_root/error.log" 2>&1; then die 'corrupt ARM64 binary was accepted'; fi
grep -q 'SHA-256 校验失败：bin/hysteria-linux-arm64' "$test_root/error.log"
[ ! -e "$MANAGED_DIR" ]
MANAGED_DIR=$test_root/missing
mv "$NATIVE_LOCAL_ASSETS_DIR/bin/sspanel-hy2-adapter-linux-arm64" "$test_root/adapter"
if (fetch_assets anytls) > "$test_root/error.log" 2>&1; then die 'missing ARM64 binary was accepted'; fi
grep -q '本地文件不存在：bin/sspanel-hy2-adapter-linux-arm64' "$test_root/error.log"
[ ! -e "$MANAGED_DIR" ]
mv "$test_root/adapter" "$NATIVE_LOCAL_ASSETS_DIR/bin/sspanel-hy2-adapter-linux-arm64"
MANAGED_DIR=$test_root/missing-checksum
sed '/  bin\/sspanel-hy2-adapter-linux-arm64$/d' "$NATIVE_LOCAL_ASSETS_DIR/bin/SHA256SUMS" > "$test_root/sums"
mv "$test_root/sums" "$NATIVE_LOCAL_ASSETS_DIR/bin/SHA256SUMS"
if (fetch_assets anytls) > "$test_root/error.log" 2>&1; then die 'ARM64 binary without checksum was accepted'; fi
grep -q '校验清单缺少：bin/sspanel-hy2-adapter-linux-arm64' "$test_root/error.log"
[ ! -e "$MANAGED_DIR" ]

# Optionally execute the actual release binaries on the current Linux host.
if [ "${REAL_NATIVE_BINARIES:-0}" = 1 ]; then
    unset -f uname
    NATIVE_LOCAL_ASSETS_DIR=$project_dir
    for test_mode in hy2 vless anytls; do
        MANAGED_DIR=$test_root/real-$test_mode
        fetch_assets "$test_mode"
    done
fi
say 'native assets tests passed (x86_64 / ARM64, HY2 / VLESS / AnyTLS)'
