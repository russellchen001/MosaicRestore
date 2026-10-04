#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:---offline}" in
  --offline)
    if python3 verify/test_p5_oneclick.py; then
      echo '✓ Offline evidence, reconnect and cancellation behavior'
      echo 'PASS P5 one-click offline preparation (fixture only; real GUI NOT RUN)'
    else
      echo 'FAIL P5 one-click offline preparation'
      exit 1
    fi
    ;;
  --real)
    shift
    exec python3 verify/run_p5_real.py "$@"
    ;;
  *) echo 'FAIL P5 one-click: expected --offline or --real'; exit 1 ;;
esac
