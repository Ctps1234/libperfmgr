#!/usr/bin/env sh
# Smoke test for the dynamic powerhint generator.  It uses a synthetic,
# writable cpufreq/devfreq tree and does not require an Android device.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/libperfmgr-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

CPU="$TMP/cpu"
GPU="$TMP/gpu"
mkdir -p "$CPU/cpufreq/policy0" "$CPU/cpufreq/policy4" "$GPU"

for policy in "$CPU/cpufreq/policy0" "$CPU/cpufreq/policy4"; do
    printf '%s\n' '300000 600000 900000 1200000 1500000 1800000' >"$policy/scaling_available_frequencies"
    printf '%s\n' '1800000' >"$policy/cpuinfo_max_freq"
    printf '%s\n' '300000' >"$policy/cpuinfo_min_freq"
    : >"$policy/scaling_min_freq"
    : >"$policy/scaling_max_freq"
done

printf '%s\n' '150000 250000 350000 450000 550000 650000 750000' >"$GPU/available_frequencies"
printf '%s\n' '150000' >"$GPU/min_freq"
printf '%s\n' '750000' >"$GPU/max_freq"

CPU_BASE="$CPU" GPU_BASE="$GPU" sh "$ROOT/module/common/gen-powerhint.sh" "$TMP/powerhint.json" /not-present

python3 - "$TMP/powerhint.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    hint = json.load(source)

actions = {(a["PowerHint"], a.get("Node")): a for a in hint["Actions"]}
assert actions[("LAUNCH", "GPUMinFreq")]["Duration"] == 450
assert actions[("INTERACTION", "GPUMinFreq")]["Duration"] == 120
assert actions[("DISPLAY_UPDATE_IMMINENT", "GPUMinFreq")]["Duration"] == 48
assert actions[("INTERACTION", "GPUMinFreq")]["Value"] == "550000"
print("ok: balanced GPU/Blur powerhint actions generated")
PY

# With only idle and max OPPs, a safe intermediate GPU boost does not exist.
# The generator must omit it instead of forcing the max OPP for Blur.
printf '%s\n' '200000 400000' >"$GPU/available_frequencies"
printf '%s\n' '200000' >"$GPU/min_freq"
printf '%s\n' '400000' >"$GPU/max_freq"
CPU_BASE="$CPU" GPU_BASE="$GPU" sh "$ROOT/module/common/gen-powerhint.sh" "$TMP/sparse-powerhint.json" /not-present

python3 - "$TMP/sparse-powerhint.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    hint = json.load(source)

assert not [a for a in hint["Actions"] if a.get("Node") == "GPUMinFreq"]
print("ok: sparse GPU table does not force max frequency")
PY
