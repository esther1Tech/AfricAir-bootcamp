#!/usr/bin/env bash
# bootstrap.sh - idempotent server setup for AfricAir (Ubuntu 24.04).
# Run as root: sudo ./bootstrap.sh
set -Eeuo pipefail

# Print the failing line number if anything goes wrong.
trap 'rc=$?; echo "ERROR: bootstrap.sh failed at line ${LINENO} (exit ${rc})" >&2' ERR

APP_USER="africair"
APP_ROOT="/opt/africair"
NODE_MAJOR="22"
PACKAGES=(nginx git ufw jq curl ca-certificates openssh-server)

CHANGES=0
log()     { echo "[bootstrap] $*"; }
changed() { CHANGES=$((CHANGES + 1)); log "CHANGED: $*"; }

# 1. Refuse to run unless root.
if [[ ${EUID} -ne 0 ]]; then
  echo "This script must be run as root (try: sudo $0)" >&2
  exit 1
fi

# 2. Install missing apt packages only.
missing=()
for pkg in "${PACKAGES[@]}"; do
  dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
done
if (( ${#missing[@]} > 0 )); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}"
  changed "installed packages: ${missing[*]}"
else
  log "apt packages already installed"
fi

# 3. Node.js LTS (from NodeSource, because Ubuntu 24.04 ships Node 18).
current_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
if [[ "${current_major}" != "${NODE_MAJOR}" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  changed "installed Node.js ${NODE_MAJOR}"
else
  log "Node.js ${NODE_MAJOR} already installed"
fi

# 4. corepack (ships with Node 22); 'enable' is safe to repeat.
corepack enable
log "corepack enabled"

# 5. System user with no login shell.
if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${APP_ROOT}" --no-create-home \
          --shell /usr/sbin/nologin "${APP_USER}"
  changed "created system user ${APP_USER}"
else
  log "user ${APP_USER} already exists"
fi

# 6. Directory layout. 'install -d' does nothing if it is already correct.
for dir in "${APP_ROOT}" "${APP_ROOT}/releases" "${APP_ROOT}/shared"; do
  if [[ ! -d "${dir}" ]]; then
    install -d -o "${APP_USER}" -g "${APP_USER}" -m 0755 "${dir}"
    changed "created ${dir}"
  fi
done
# 'current' is a symlink created by deploy.sh, not here.

# 7. Firewall: allow only SSH, 80, 443. Rules are added BEFORE enabling,
#    so we never lock ourselves out of an SSH session.
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH          >/dev/null
ufw allow 80/tcp           >/dev/null
ufw allow 443/tcp          >/dev/null
if ! ufw status | grep -q "^Status: active"; then
  ufw --force enable >/dev/null
  changed "enabled ufw"
else
  log "ufw already active"
fi

log "done. changes made this run: ${CHANGES}"
