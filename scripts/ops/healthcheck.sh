#!/usr/bin/env bash
# healthcheck.sh - run by a systemd timer every minute.
set -Eeuo pipefail

URL="${HEALTH_URL:-http://127.0.0.1/healthz}"
STATE_FILE="${STATE_FILE:-/var/lib/africair/healthcheck.failures}"
THRESHOLD=3
TAG="africair-health"

failures="$(cat "${STATE_FILE}" 2>/dev/null || echo 0)"

if curl -fsS --max-time 5 "${URL}" 2>/dev/null | grep -qx "ok"; then
  if (( failures > 0 )); then
    logger -t "${TAG}" "recovered after ${failures} failed check(s)"
  else
    logger -t "${TAG}" "OK"
  fi
  echo 0 > "${STATE_FILE}"
  exit 0
fi

failures=$((failures + 1))
echo "${failures}" > "${STATE_FILE}"
logger -t "${TAG}" -p user.err "FAILED (${failures} consecutive)"

if (( failures >= THRESHOLD )); then
  logger -t "${TAG}" -p user.warning "WARNING: ${failures} consecutive failures, reloading nginx"
  systemctl reload-or-restart nginx || logger -t "${TAG}" -p user.err "nginx reload failed"
  echo 0 > "${STATE_FILE}"
fi
exit 1
