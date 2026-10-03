#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1

echo "=== P1 Provider Contract ==="

if cargo test --manifest-path core/Cargo.toml --quiet; then
  echo "✓ provider behavior tests"
else
  echo "✗ provider behavior tests"
  echo "FAIL P1 provider contract"
  exit 1
fi

if cargo check --manifest-path core/Cargo.toml --quiet; then
  echo "✓ core compiles"
else
  echo "✗ core compile check"
  echo "FAIL P1 provider contract"
  exit 1
fi

echo "PASS P1 provider contract"
