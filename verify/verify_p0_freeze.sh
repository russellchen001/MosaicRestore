#!/bin/bash
set -u
FAIL=0
[ -s HANDOFF.md ] && echo "✓ HANDOFF exists" || { echo "✗ HANDOFF missing"; FAIL=1; }
git check-ignore -q .DS_Store && echo "✓ .DS_Store ignored" || { echo "✗ .DS_Store not ignored"; FAIL=1; }
git check-ignore -q benchmark/results && echo "✓ benchmark results ignored" || { echo "✗ benchmark results not ignored"; FAIL=1; }
git diff --check >/dev/null && echo "✓ git diff clean" || { echo "✗ git diff check failed"; FAIL=1; }
[ "$FAIL" -eq 0 ] && { echo "PASS P0 freeze"; exit 0; }
echo "FAIL P0 freeze"; exit 1
