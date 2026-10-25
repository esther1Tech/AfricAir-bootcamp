#!/usr/bin/env bash
# deploy.sh - zero-downtime release of an AfricAir build artifact.
set -Eeuo pipefail

trap 'rc=$?; echo "ERROR: deploy.sh failed at line ${LINENO} (exit ${rc})" >&2' ERR

APP_USER="africair"
APP_ROOT="/opt/africair"
RELEASES="${APP_ROOT}/releases"
CURRENT="${APP_ROOT}/current"
KEEP=5
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1}"

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: sudo deploy.sh <africair-<sha>.tar.gz>"
  echo "Needs <artifact>.sha256 next to the artifact. Exit 0 = deployed, non-zero = failed (rolled back if possible)."
  exit 1
fi
if [[ ${EUID} -ne 0 ]]; then echo "Run as root (sudo)." >&2; exit 1; fi

ARTIFACT="$(readlink -f "$1")"
[[ -f "${ARTIFACT}" ]] || { echo "Artifact not found: ${ARTIFACT}" >&2; exit 1; }

# 1. Verify the checksum; abort if it does not match.
if ! (cd "$(dirname "${ARTIFACT}")" && sha256sum -c "$(basename "${ARTIFACT}").sha256"); then
  echo "Checksum mismatch - aborting. Nothing was changed." >&2
  exit 1
fi

# 2. Extract to a new release directory owned by africair.
base="$(basename "${ARTIFACT}" .tar.gz)"
RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-${base#africair-}"
RELEASE_DIR="${RELEASES}/${RELEASE_ID}"
mkdir -p "${RELEASE_DIR}"
if ! tar -xzf "${ARTIFACT}" -C "${RELEASE_DIR}"; then
  rm -rf "${RELEASE_DIR}"
  echo "Extraction failed - aborting." >&2
  exit 1
fi
chown -R "${APP_USER}:${APP_USER}" "${RELEASE_DIR}"
EXPECTED_COMMIT="$(jq -r .commit "${RELEASE_DIR}/version.json")"
PREVIOUS=""
if [[ -L "${CURRENT}" ]]; then PREVIOUS="$(readlink -f "${CURRENT}")"; fi

# 3. Atomic switch: build a temporary link, then rename it over 'current'.
switch_to() {
  local tmp="${APP_ROOT}/.current.tmp.$$"
  ln -sfn "$1" "${tmp}"
  mv -T "${tmp}" "${CURRENT}"
}

# 4. Always test the config before reloading. Never restart.
reload_nginx() { nginx -t && systemctl reload nginx; }

# 5. Health check: /healthz is up AND /version.json is the commit we deployed.
healthy() {
  local i hz commit root
  for i in 1 2 3 4 5; do
    hz="$(curl -fsS --max-time 5 "${HEALTH_URL}/healthz" 2>/dev/null || true)"
    commit="$(curl -fsS --max-time 5 "${HEALTH_URL}/version.json" 2>/dev/null | jq -r .commit 2>/dev/null || true)"
    root="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${HEALTH_URL}/" || true)"
    if [[ "${hz}" == "ok" && "${commit}" == "${EXPECTED_COMMIT}" && "${root}" == "200" ]]; then return 0; fi
    sleep 2
  done
  return 1
}

echo "==> switching current -> ${RELEASE_ID}"
switch_to "${RELEASE_DIR}"

if reload_nginx && healthy; then
  echo "==> healthy: commit ${EXPECTED_COMMIT}"
else
  echo "FAILED: health check did not pass. Rolling back." >&2
  if [[ "${PREVIOUS}" == "${RELEASES}/"* && -d "${PREVIOUS}" ]]; then
    switch_to "${PREVIOUS}"
    reload_nginx || true
    echo "Rolled back to ${PREVIOUS}" >&2
  else
    echo "No previous release to roll back to." >&2
  fi
  exit 1
fi

# 6. Keep only the newest releases (never the live one).
mapfile -t old < <(ls -1 "${RELEASES}" | sort -r | tail -n +$((KEEP + 1)))
for r in "${old[@]}"; do
  if [[ "${RELEASES}/${r}" != "$(readlink -f "${CURRENT}")" ]]; then
    rm -rf -- "${RELEASES:?}/${r}"
  fi
done
echo "==> deployed ${RELEASE_ID}"
