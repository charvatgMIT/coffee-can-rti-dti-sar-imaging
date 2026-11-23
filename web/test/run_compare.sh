#!/bin/bash
# Compares the web app's RTI processing with the Mac app's on a recording, for several settings.
#   test/run_compare.sh <file.wav> '<base params JSON>' [scratch dir]
set -euo pipefail
cd "$(dirname "$0")/.."
WAV="$1"; BASE="${2:-{\}}"; OUT="${3:-${TMPDIR:-/tmp}/ccr-compare}"
mkdir -p "$OUT"
MAC="../build/Release/Coffee Can RTI DTI SAR Imaging.app/Contents/MacOS/Coffee Can RTI DTI SAR Imaging"
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
run() {
  local name="$1" extra="$2"
  local params; params=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); a.update(json.loads(sys.argv[2])); print(json.dumps(a))" "$BASE" "$extra")
  echo "== $name"
  RTI_PARAMS="$params" "$MAC" --rti-dump "$WAV" "$OUT/$name" | sed 's/^/   mac: /'
  "$JSC" test/compare.js -- "$WAV" "$OUT/$name" "$params" | sed 's/^/   /'
}
for spec in "${@:4}"; do run "${spec%%=*}" "${spec#*=}"; done
