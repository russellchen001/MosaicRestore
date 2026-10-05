#!/usr/bin/env bash
# The controlling machine's half of a Cloud Compute window.
#
# Everything the window needs to be told is two strings the Windows host prints:
# a relay endpoint and the token the operator chose before starting. This builds
# the connection file from them, with owner-only permissions and under a path
# that is not the repository, so a token never lands in git and never has to be
# pasted anywhere a transcript can keep it.
#
# It closes Cloud Compute only. Agent Cloud Computer stays NOT RUN, honestly, in
# the report; one window, one product.
set -euo pipefail

endpoint="${1:-}"
token="${2:-}"
input="${3:-benchmark/samples/p1_lada_smoke.mp4}"

if [ -z "$endpoint" ] || [ -z "$token" ]; then
    echo "usage: verify/start_cloud_compute.sh <https://endpoint> <token> [input.mp4]" >&2
    exit 2
fi
case "$endpoint" in
    https://*) ;;
    *) echo "refusing a non-https endpoint: $endpoint" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

for tool in ffprobe python3; do
    command -v "$tool" >/dev/null || { echo "missing $tool on this machine" >&2; exit 2; }
done
[ -x core/target/release/mosaic-core ] || { echo "core/target/release/mosaic-core is missing; build it before the window" >&2; exit 2; }
[ -f "$input" ] || { echo "input not found: $input" >&2; exit 2; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run="${TMPDIR:-/tmp}/mosaic-window-$stamp"
mkdir -m 700 -p "$run"
connection="$run/connection.json"
umask 077
printf '{"endpoint": "%s", "token": "%s"}\n' "$endpoint" "$token" > "$connection"
chmod 600 "$connection"

echo "run directory: $run"
echo "input:         $input"
echo

set +e
python3 verify/run_jasna_airgpu.py \
    --connection "$connection" \
    --output "$run/evidence" \
    --input "$input" \
    --skip-agent-cloud
verdict=$?
set -e

# The token outlives nothing. The evidence does.
rm -f "$connection"

echo
if [ $verdict -ne 0 ]; then
    echo "CLOUD COMPUTE FAILED. STOP THE MACHINE NOW."
    echo "evidence and logs: $run/evidence"
    exit 1
fi
echo "CLOUD COMPUTE PASSED. STOP THE MACHINE NOW; nothing further needs the window."
echo "evidence: $run/evidence   (report.json, ffprobe json, restored mp4, logs)"
