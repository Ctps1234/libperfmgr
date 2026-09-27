#!/usr/bin/env sh
# Guard against accidentally restoring an unsafe stock Power HAL takeover.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

require() {
    pattern=$1
    file=$2
    if ! grep -Fq "$pattern" "$ROOT/$file"; then
        echo "missing safety guard '$pattern' in $file" >&2
        exit 1
    fi
}

require 'ENABLE_HAL=0' module/perfmgr.conf
require 'ENABLE_HINTS=0' module/perfmgr.conf
require 'OVERRIDE_STOCK=0' module/perfmgr.conf
require 'ALLOW_STOCK_OVERRIDE=0' module/perfmgr.conf
require 'pm_override_allowed' module/common/libperfmgr-common.sh
require 'pm_override_manifest_on' module/common/libperfmgr-common.sh
require 'pm_override_manifest_off' module/common/libperfmgr-common.sh
require 'if pm_override_allowed; then' module/service.sh
require 'if pm_override_allowed; then' module/customize.sh
require 'BLOQUEADO: HAL de fabrica detetado' module/action.sh
require 'pm_override_manifest_on' module/action.sh
require 'pm_override_manifest_off' module/action.sh
require 'ALLOW_STOCK_OVERRIDE 1' module/perfmgr.conf

TMP=$(mktemp -d "${TMPDIR:-/tmp}/libperfmgr-hal-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/mod/.backup_vintf/manifest"
cat >"$TMP/mod/.backup_vintf/manifest/android.hardware.power-service.pixel.xml" <<'EOF'
<manifest><hal format="aidl"><name>android.hardware.power</name></hal></manifest>
EOF
MODDIR="$TMP/mod" sh -c '
    . "$1"
    pm_override_manifest_on
    dst="$MODDIR/system/vendor/etc/vintf/manifest/android.hardware.power-service.pixel.xml"
    test -f "$dst"
    grep -Fq "format=\"aidl\" override=\"true\"" "$dst"
    pm_override_manifest_off
    test ! -e "$MODDIR/system/vendor/etc/vintf"
' sh "$ROOT/module/common/libperfmgr-common.sh"

printf '%s\n' 'ok: stock Power HAL override is opt-in and boot-only'
