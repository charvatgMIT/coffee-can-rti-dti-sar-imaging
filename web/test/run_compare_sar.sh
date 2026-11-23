#!/bin/bash
# Compares the web app's SAR imaging with the Mac app's.  test/run_compare_sar.sh <file.wav> name='<params JSON>' ...
set -euo pipefail
cd "$(dirname "$0")/.."
WAV="$1"; shift
OUT="${TMPDIR:-/tmp}/ccr-compare-sar"; mkdir -p "$OUT"
MAC="../build/Release/Coffee Can RTI DTI SAR Imaging.app/Contents/MacOS/Coffee Can RTI DTI SAR Imaging"
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
for spec in "$@"; do
  name="${spec%%=*}"; json="${spec#*=}"
  echo "== $name"
  SAR_PARAMS="$json" "$MAC" --sar-dump "$WAV" "$OUT/$name" | sed 's/^/   mac: /'
  "$JSC" test/compare_sar.js -- "$WAV" "$OUT/$name" "$json" | sed 's/^/   /'
done
