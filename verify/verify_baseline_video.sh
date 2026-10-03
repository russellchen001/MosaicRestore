#!/bin/bash
set -u

VIDEO="$HOME/MosaicRestore/benchmark/samples/baseline.mp4"
FAIL=0

if [ -s "$VIDEO" ]; then
  echo "✓ baseline.mp4 exists"
else
  echo "✗ baseline.mp4 missing or empty"
  exit 1
fi

DURATION="$(ffprobe -v error \
  -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 \
  "$VIDEO" 2>/dev/null)"

WIDTH="$(ffprobe -v error \
  -select_streams v:0 \
  -show_entries stream=width \
  -of default=noprint_wrappers=1:nokey=1 \
  "$VIDEO" 2>/dev/null)"

HEIGHT="$(ffprobe -v error \
  -select_streams v:0 \
  -show_entries stream=height \
  -of default=noprint_wrappers=1:nokey=1 \
  "$VIDEO" 2>/dev/null)"

if awk -v d="$DURATION" 'BEGIN { exit !(d >= 59 && d <= 61) }'; then
  echo "✓ duration ≈ 60s"
else
  echo "✗ unexpected duration: $DURATION"
  FAIL=$((FAIL + 1))
fi

if [ "$WIDTH" -gt 0 ] 2>/dev/null && [ "$HEIGHT" -gt 0 ] 2>/dev/null; then
  echo "✓ video readable: ${WIDTH}x${HEIGHT}"
else
  echo "✗ video stream unreadable"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS baseline video"
  exit 0
fi

echo "FAIL baseline video — $FAIL check(s) failed"
exit 1
