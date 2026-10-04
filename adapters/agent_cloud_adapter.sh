#!/bin/bash
set -u

ACTION=${1:-}
shift || true
PROFILE=""
FORWARD=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) PROFILE=$2; shift 2 ;;
    *) FORWARD+=("$1"); shift ;;
  esac
done

case "$PROFILE" in
  ""|*[!A-Za-z0-9._-]*) echo "error_kind=invalid-request" >&2; echo "message=invalid profile" >&2; exit 2 ;;
esac

PROFILE_FILE="${MOSAIC_AGENT_CLOUD_PROFILE_DIR:-$HOME/.config/mosaicrestore/agent-profiles}/$PROFILE.conf"
[ -f "$PROFILE_FILE" ] || {
  echo "error_kind=invalid-request" >&2
  echo "message=agent cloud profile not found" >&2
  exit 2
}

CONTROLLER=""
CONTROLLER_PROFILE=""
while IFS='=' read -r key value; do
  case "$key" in
    controller) CONTROLLER=${value/#\~/$HOME} ;;
    controller_profile) CONTROLLER_PROFILE=${value/#\~/$HOME} ;;
  esac
done < "$PROFILE_FILE"

if [ ! -x "$CONTROLLER" ] || [ -z "$CONTROLLER_PROFILE" ]; then
  echo "error_kind=provider-unavailable" >&2
  echo "message=agent controller or controller profile is unavailable" >&2
  exit 3
fi

exec "$CONTROLLER" "$ACTION" --profile "$CONTROLLER_PROFILE" ${FORWARD[@]+"${FORWARD[@]}"}
