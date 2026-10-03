#!/bin/bash
set -u

OUT="benchmark/p0_environment.txt"
FAIL=0

mkdir -p benchmark
: > "$OUT"

report() {
  echo "$1" | tee -a "$OUT"
}

check_cmd() {
  local cmd="$1"

  if command -v "$cmd" >/dev/null 2>&1; then
    report "✓ $cmd: $(command -v "$cmd")"
  else
    report "✗ $cmd: not installed"
    FAIL=$((FAIL + 1))
  fi
}

report "=== MosaicRestore P0 Environment ==="
report ""

report "=== Hardware ==="
report "Architecture: $(uname -m)"
report "macOS: $(sw_vers -productVersion)"
report "Chip: $(system_profiler SPHardwareDataType 2>/dev/null | grep 'Chip:' | sed 's/^[[:space:]]*//')"
report "Memory: $(system_profiler SPHardwareDataType 2>/dev/null | grep 'Memory:' | sed 's/^[[:space:]]*//')"

report ""
report "=== Required Tools ==="

check_cmd git
check_cmd python3
check_cmd uv
check_cmd ffmpeg
check_cmd brew

report ""
report "=== Versions ==="

command -v git >/dev/null 2>&1 && report "git: $(git --version)"
command -v python3 >/dev/null 2>&1 && report "python3: $(python3 --version)"
command -v uv >/dev/null 2>&1 && report "uv: $(uv --version)"
command -v ffmpeg >/dev/null 2>&1 && report "ffmpeg: $(ffmpeg -version | head -1)"
command -v brew >/dev/null 2>&1 && report "brew: $(brew --version | head -1)"

report ""
report "=== Apple GPU Check ==="

if [ "$(uname -m)" = "arm64" ]; then
  report "✓ Apple Silicon detected"
else
  report "✗ Apple Silicon not detected"
  FAIL=$((FAIL + 1))
fi

if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Metal Support"; then
  report "✓ Metal support detected"
else
  report "✗ Metal support not detected"
  FAIL=$((FAIL + 1))
fi

report ""
report "=== Disk ==="
df -h "$HOME" | tail -1 | tee -a "$OUT"

report ""
if [ "$FAIL" -eq 0 ]; then
  report "PASS P0 environment"
  exit 0
fi

report "FAIL P0 environment — $FAIL requirement(s) missing"
exit 1
