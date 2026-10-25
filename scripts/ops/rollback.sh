#!/usr/bin/env bash
# rollback.sh - switch 'current' back to the previous release.
set -Eeuo pipefail

trap 'rc=$?; echo "ERROR: rollback.sh failed at line ${LINENO} (exit ${rc})" >&2' ERR

APP_ROOT="/opt/africair"
RELEASES="${APP_ROOT}/releases"
CURRENT="${APP_ROOT}/current"

if [[ ${EUID} -ne 0 ]]; then echo "Run as root (sudo)." >&2; exit 1; fi

mapfile -t all < <(ls -1 "${RELEASES}" | sort)
now="$(basename "$(readlink -f "${CURRENT}")")"

prev=""
for i in "${!all[@]}"; do
  if [[ "${all[$i]}" == "${now}" && ${i} -gt 0 ]]; then prev="${all[$((i - 1))]}"; fi
done
[[ -n "${prev}" ]] || { echo "No earlier release to roll back to." >&2; exit 1; }

tmp="${APP_ROOT}/.current.tmp.$$"
ln -sfn "${RELEASES}/${prev}" "${tmp}"
mv -T "${tmp}" "${CURRENT}"

nginx -t && systemctl reload nginx
echo "==> rolled back: ${now} -> ${prev}"
