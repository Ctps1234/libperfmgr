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
require 'if pm_override_allowed; then' module/service.sh
require 'if pm_override_allowed; then' module/customize.sh
require 'BLOQUEADO: HAL de fabrica detetado' module/action.sh
require 'ALLOW_STOCK_OVERRIDE 1' module/perfmgr.conf

printf '%s\n' 'ok: stock Power HAL override is opt-in and boot-only'
