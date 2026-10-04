#!/bin/bash
set -u

cd "$(dirname "$0")/.." || exit 1

APP="desktop/build/MosaicRestore.app"
APP_EXECUTABLE="$APP/Contents/MacOS/MosaicRestore"
CORE_EXECUTABLE="$APP/Contents/Resources/mosaic-core"
LOG_DIR=$(mktemp -d /tmp/mosaic-glass-ui.XXXXXX)
APP_PID=""
FAIL=0

cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT

pass() {
  echo "✓ $1"
}

fail() {
  echo "✗ $1"
  FAIL=1
}

if desktop/build_app.sh >"$LOG_DIR/build.log" 2>&1; then
  pass "Swift and Rust Release products build into the app bundle"
else
  fail "Release build failed"
fi

if [ -x "$APP_EXECUTABLE" ] && [ -x "$CORE_EXECUTABLE" ]; then
  pass "App bundle contains executable Desktop and Core products"
else
  fail "App bundle is incomplete"
fi

if codesign --verify --deep --strict "$APP" 2>"$LOG_DIR/codesign.log"; then
  pass "App bundle has a valid strict signature"
else
  fail "App bundle signature verification failed"
fi

BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$BUNDLE_ID" = "com.russellchen.mosaicrestore" ]; then
  pass "App bundle metadata is readable"
else
  fail "App bundle metadata is invalid"
fi

if [ -x "$APP_EXECUTABLE" ]; then
  "$APP_EXECUTABLE" >"$LOG_DIR/launch.log" 2>&1 &
  APP_PID=$!
  sleep 3
  if kill -0 "$APP_PID" 2>/dev/null; then
    pass "Release Desktop process launches and remains running"
  else
    fail "Release Desktop process exited during launch smoke test"
  fi
else
  fail "Release Desktop executable is unavailable for launch"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS MosaicRestore Glass UI"
  exit 0
fi

echo "FAIL MosaicRestore Glass UI — one or more executable checks failed"
exit 1
