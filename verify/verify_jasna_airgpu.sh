#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:---offline}" in
  --offline)
    PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/mosaic-jasna-pyc" python3 -m py_compile adapters/windows_gui_agent.py adapters/http_jasna_cloud_adapter.py verify/run_jasna_airgpu.py
    python3 -m json.tool adapters/jasna-airgpu-v0.10.0.json >/dev/null
    python3 verify/test_jasna_airgpu.py
    python3 verify/test_p5_oneclick.py
    test -x core/target/release/mosaic-core
    echo 'PASS Jasna dual-path offline preparation (real NVIDIA E2E NOT RUN)'
    ;;
  --real)
    shift
    exec python3 verify/run_jasna_airgpu.py "$@"
    ;;
  *) echo 'FAIL Jasna acceptance: expected --offline or --real'; exit 1 ;;
esac
