#!/bin/sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
exec /bin/sh "${script_dir}/install-native.sh" vless "$@"
