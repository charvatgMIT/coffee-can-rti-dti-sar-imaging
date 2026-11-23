#!/bin/bash
# Compares the web app's Doppler-vs-time processing with the Mac app's on a recording.
#   test/run_compare_dti.sh <file.wav> [name=MACFLAGS|webJSON ...]   e.g.  mp="DT_MP=1|{\"dtMethod\":\"Matrix pencil\"}"
set -euo pipefail
cd "$(dirname "$0")/.."
WAV="$1"; shift
OUT="${TMPDIR:-/tmp}/ccr-compare-dti"; mkdir -p "$OUT"
MAC="../build/Release/Coffee Can RTI DTI SAR Imaging.app/Contents/MacOS/Coffee Can RTI DTI SAR Imaging"
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
for spec in "$@"; do
  name="${spec%%=*}"; rest="${spec#*=}"; flags="${rest%%|*}"; json="${rest#*|}"
  echo "== $name"
  env DT_DEFAULTS=1 $flags "$MAC" --doppler-dump "$WAV" "$OUT/$name.f32" | head -1 | sed 's/^/   mac: /'
  "$JSC" test/compare_dti.js -- "$WAV" "$OUT/$name.f32" "$json" | sed 's/^/   /'
done
