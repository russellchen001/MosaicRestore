#!/bin/bash
set -u
FAIL=0
for p in core desktop providers benchmark; do
  if [ -d "$p" ]; then echo "✓ $p"; else echo "✗ $p"; FAIL=$((FAIL+1)); fi
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && echo "✓ Git repository" || { echo "✗ Git repository"; FAIL=$((FAIL+1)); }
[ -f HANDOFF.md ] && echo "✓ HANDOFF.md" || { echo "✗ HANDOFF.md"; FAIL=$((FAIL+1)); }
[ "$FAIL" -eq 0 ] && { echo "PASS MosaicRestore bootstrap"; exit 0; }
echo "FAIL MosaicRestore bootstrap — $FAIL check(s) failed"
exit 1
