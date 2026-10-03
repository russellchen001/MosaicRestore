#!/bin/bash
set -u

LADA="$HOME/MosaicRestore/benchmark/lada-upstream"
FAIL=0

if [ ! -d "$LADA/.venv" ]; then
  echo "✗ Lada virtual environment"
  echo "FAIL Lada runtime — virtual environment missing"
  exit 1
fi

cd "$LADA" || exit 1

PYVER="$(uv run --no-project python -c 'import sys; print(".".join(map(str, sys.version_info[:2])))' 2>/dev/null)"
if [ "$PYVER" = "3.13" ]; then
  echo "✓ Python 3.13"
else
  echo "✗ Python runtime: $PYVER"
  FAIL=$((FAIL + 1))
fi

MPS="$(uv run --no-project python -c 'import torch; print(torch.backends.mps.is_available())' 2>/dev/null)"
if [ "$MPS" = "True" ]; then
  echo "✓ PyTorch MPS available"
else
  echo "✗ PyTorch MPS unavailable"
  FAIL=$((FAIL + 1))
fi

if uv run lada-cli --help >/dev/null 2>&1; then
  echo "✓ lada-cli starts"
else
  echo "✗ lada-cli failed"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS Lada runtime"
  exit 0
fi

echo "FAIL Lada runtime — $FAIL check(s) failed"
exit 1
