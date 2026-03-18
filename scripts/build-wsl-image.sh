#!/usr/bin/env bash
# =============================================================================
# build-wsl-image.sh
#
# Orchestrates the full WSL Rocky Linux image build:
#   1. Pulls Rocky Linux base image
#   2. Starts an ephemeral build container
#   3. Applies org customizations (packages, files, hook scripts)
#   4. Applies STIG/SCAP hardening via OpenSCAP
#   5. Collects SCAP compliance results
#   6. Exports the container as a WSL-importable rootfs tarball
#   7. Commits the container as a Docker image for GHCR publishing
#
# Environment variables (set by CI or caller):
#   ROCKY_VERSION    — e.g. "9"  (default: 9)
#   STIG_PROFILE     — SCAP profile ID (default: stig)
#   ARTIFACT_BASE    — output filename stem (default: wsl-rocky-<version>-local)
# =============================================================================
set -euo pipefail

ROCKY_VERSION="${ROCKY_VERSION:-9}"
STIG_PROFILE="${STIG_PROFILE:-xccdf_org.ssgproject.content_profile_stig}"
ARTIFACT_BASE="${ARTIFACT_BASE:-wsl-rocky-${ROCKY_VERSION}-local}"

CONTAINER_NAME="wsl-build-$$"
ARTIFACTS_DIR="$(pwd)/artifacts"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo "[build] $*"; }
warn() { echo "[build] WARNING: $*" >&2; }

cleanup() {
  log "Cleaning up build container..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Directories ─────────────────────────────────────────────────────────────
mkdir -p "${ARTIFACTS_DIR}/scap-results"

# ─── 1. Pull base image ───────────────────────────────────────────────────────
log "Pulling rockylinux:${ROCKY_VERSION}..."
docker pull "rockylinux:${ROCKY_VERSION}"

# ─── 2. Start build container ─────────────────────────────────────────────────
log "Starting build container: ${CONTAINER_NAME}"
docker run -d \
  --name "${CONTAINER_NAME}" \
  --cap-add=SYS_PTRACE \
  --security-opt apparmor=unconfined \
  --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-local/wsl-rocky}" \
  --label "org.opencontainers.image.description=Hardened Rocky Linux ${ROCKY_VERSION} for WSL2" \
  --label "org.opencontainers.image.licenses=MIT" \
  "rockylinux:${ROCKY_VERSION}" \
  sleep infinity

log "Container ${CONTAINER_NAME} is running"

# ─── 3. Bootstrap dnf inside the container ────────────────────────────────────
log "Bootstrapping package manager..."
docker exec "${CONTAINER_NAME}" bash -c "
  set -euo pipefail
  # --allowerasing allows dnf to replace curl-minimal (shipped in the base
  # image) with the full curl package, which would otherwise conflict.
  # glibc-common is included for completeness; glibc-langpack-en ships the
  # pre-compiled locale data used below.
  dnf install -y --allowerasing \
    ca-certificates \
    curl \
    wget \
    gnupg2 \
    glibc-common \
    glibc-langpack-en \
    sudo \
    which
  # glibc-langpack-en already ships pre-compiled locale data; writing
  # /etc/locale.conf is sufficient — no need to run localedef, which
  # requires charmap files that are stripped from the minimal container image.
  echo 'LANG=en_US.UTF-8' > /etc/locale.conf
"

# ─── 4. Copy scripts and customizations into container ────────────────────────
log "Copying build scripts and customizations..."
docker exec "${CONTAINER_NAME}" mkdir -p /opt/build /opt/customizations
docker cp "${SCRIPT_DIR}/." "${CONTAINER_NAME}:/opt/build/"
docker cp "${REPO_ROOT}/customizations/." "${CONTAINER_NAME}:/opt/customizations/"

# ─── 5. Apply org customizations ──────────────────────────────────────────────
log "Applying customizations..."
docker exec \
  -e ROCKY_VERSION="${ROCKY_VERSION}" \
  "${CONTAINER_NAME}" \
  bash /opt/build/apply-customizations.sh

# ─── 6. STIG/SCAP hardening ───────────────────────────────────────────────────
log "Applying STIG/SCAP hardening (profile: ${STIG_PROFILE})..."
docker exec \
  -e ROCKY_VERSION="${ROCKY_VERSION}" \
  -e STIG_PROFILE="${STIG_PROFILE}" \
  "${CONTAINER_NAME}" \
  bash /opt/build/harden.sh

# ─── 7. Collect SCAP results from container ───────────────────────────────────
log "Collecting SCAP results..."
docker cp "${CONTAINER_NAME}:/opt/scap-results/." "${ARTIFACTS_DIR}/scap-results/" 2>/dev/null \
  || warn "No SCAP results found at /opt/scap-results"

# ─── 8. Clean up build artifacts inside container ─────────────────────────────
log "Cleaning up build artifacts inside container..."
docker exec "${CONTAINER_NAME}" bash -c "
  set -euo pipefail
  # Remove build scripts and caches
  rm -rf /opt/build /opt/customizations
  # Clear dnf caches
  dnf clean all
  rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*
  # Clear bash history
  history -c 2>/dev/null || true
  rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true
"

# ─── 9. Export WSL rootfs tarball ─────────────────────────────────────────────
OUTPUT_TAR="${ARTIFACTS_DIR}/${ARTIFACT_BASE}.tar.gz"
log "Exporting WSL rootfs to ${OUTPUT_TAR}..."
docker export "${CONTAINER_NAME}" | gzip --best > "${OUTPUT_TAR}"

TARBALL_SIZE=$(du -sh "${OUTPUT_TAR}" | cut -f1)
log "WSL tarball created: ${OUTPUT_TAR} (${TARBALL_SIZE})"

# ─── 10. Commit Docker image for GHCR publishing ──────────────────────────────
log "Committing Docker image wsl-rocky:local..."
docker commit \
  --change 'CMD ["/bin/bash"]' \
  --change "LABEL org.opencontainers.image.title=\"WSL Rocky Linux ${ROCKY_VERSION}\"" \
  --change "LABEL org.opencontainers.image.description=\"Hardened Rocky Linux ${ROCKY_VERSION} WSL2 image with STIG hardening\"" \
  "${CONTAINER_NAME}" \
  wsl-rocky:local

log "Build complete."
log "  WSL tarball : ${OUTPUT_TAR}"
log "  Docker image: wsl-rocky:local"
log "  SCAP results: ${ARTIFACTS_DIR}/scap-results/"
