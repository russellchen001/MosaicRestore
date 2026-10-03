#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1

if cargo test --manifest-path core/Cargo.toml --quiet; then
  echo "✓ Mosaic Core contract tests"
else
  echo "✗ Mosaic Core contract tests"
  echo "FAIL P1 core contract — cargo test failed"
  exit 1
fi

echo "PASS P1 core contract"
