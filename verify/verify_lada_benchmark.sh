#!/bin/bash
set -u

OUTPUT="$HOME/MosaicRestore/benchmark/results/lada_m4_output.mp4"
REPORT="$HOME/MosaicRestore/benchmark/results/lada_m4_baseline.txt"
FAIL=0

if [ -s "$OUTPUT" ]; then
  echo "✓ restored output exists"
else
  echo "✗ restored output missing"
  FAIL=$((FAIL + 1))
fi

if ffprobe -v error "$OUTPUT" >/dev/null 2>&1; then
  echo "✓ restored output readable"
else
  echo "✗ restored output unreadable"
  FAIL=$((FAIL + 1))
fi

DURATION="$(ffprobe -v error \
  -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 \
  "$OUTPUT" 2>/dev/null)"

if awk -v d="$DURATION" 'BEGIN { exit !(d >= 59 && d <= 61) }'; then
  echo "✓ output duration ≈ 60s"
else
  echo "✗ unexpected output duration: $DURATION"
  FAIL=$((FAIL + 1))
fi

if [ -s "$REPORT" ]; then
  echo "✓ benchmark report created"
else
  echo "✗ benchmark report missing"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS Lada M4 benchmark"
  echo
  cat "$REPORT"
  exit 0
fi

echo "FAIL Lada M4 benchmark — $FAIL check(s) failed"
exit 1
