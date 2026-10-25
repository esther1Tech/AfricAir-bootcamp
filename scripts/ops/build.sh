#!/usr/bin/env bash
# build.sh - build a reproducible AfricAir artifact from a git ref.
set -Eeuo pipefail

trap 'rc=$?; echo "ERROR: build.sh failed at line ${LINENO} (exit ${rc})" >&2' ERR

REPO_URL="${REPO_URL:-https://github.com/esther1Tech/AfricAir-bootcamp.git}"
OUT_DIR="${OUT_DIR:-$PWD}"

usage() {
  cat <<'EOF'
Usage: build.sh <git-ref>

Builds AfricAir from a branch, tag or commit SHA and writes
africair-<shortsha>.tar.gz and africair-<shortsha>.tar.gz.sha256
to $OUT_DIR (default: current directory).

Environment:
  REPO_URL   git repository to clone (default: the AfricAir GitHub repo)
  OUT_DIR    where to write the artifact (default: current directory)

Exit codes:
  0   success
  1   bad usage or unexpected error
  10  checkout failed (clone, fetch or unknown ref)
  20  dependency install failed (pnpm install --frozen-lockfile)
  30  quality gate failed (pnpm check or pnpm test)
  40  build failed (pnpm build)
  50  packaging failed (version.json, tar or checksum)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ $# -ne 1 ]]; then usage >&2; exit 1; fi
REF="$1"

# run_step <exit-code> <description> <command...>
# Runs a command; on failure prints which step failed and exits with its code.
run_step() {
  local code="$1" desc="$2"; shift 2
  echo "==> ${desc}"
  if ! "$@"; then
    echo "FAILED: ${desc} (exit code ${code})" >&2
    exit "${code}"
  fi
}

WORK="$(mktemp -d -t africair-build.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
SRC="${WORK}/src"

# 1. Fetch the code and check out the ref (branch, tag or SHA).
checkout() {
  git clone --quiet --no-checkout "${REPO_URL}" "${SRC}" &&
  git -C "${SRC}" fetch --quiet --tags origin &&
  { git -C "${SRC}" checkout --quiet --detach "${REF}^{commit}" 2>/dev/null ||
    git -C "${SRC}" checkout --quiet --detach "origin/${REF}^{commit}"; }
}
run_step 10 "checkout ${REF}" checkout

COMMIT="$(git -C "${SRC}" rev-parse HEAD)"
SHORT="${COMMIT:0:7}"
cd "${SRC}"

# 2. Install, check, test, build. Stop on the first failure.
run_step 20 "pnpm install --frozen-lockfile" pnpm install --frozen-lockfile
run_step 30 "pnpm check" pnpm check
run_step 30 "pnpm test"  pnpm test
run_step 40 "pnpm build" pnpm build

# 3. version.json, written with jq (not string concatenation).
write_version() {
  jq -n \
    --arg commit "${COMMIT}" \
    --arg ref "${REF}" \
    --arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg builtBy "$(id -un)@$(hostname)" \
    --arg nodeVersion "$(node -v)" \
    '{commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion}' \
    > dist/version.json
}
run_step 50 "write dist/version.json" write_version

# 4. Package dist/ and write a checksum next to it.
package() {
  local tarball="${OUT_DIR}/africair-${SHORT}.tar.gz"
  mkdir -p "${OUT_DIR}"
  tar -C dist --sort=name --owner=0 --group=0 --numeric-owner -cf - . \
    | gzip -n > "${tarball}"
  (cd "${OUT_DIR}" && sha256sum "africair-${SHORT}.tar.gz" > "africair-${SHORT}.tar.gz.sha256")
}
run_step 50 "package artifact" package

echo "Built ${OUT_DIR}/africair-${SHORT}.tar.gz"
cat "${OUT_DIR}/africair-${SHORT}.tar.gz.sha256"
