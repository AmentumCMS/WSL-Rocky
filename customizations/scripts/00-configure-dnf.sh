#!/usr/bin/env bash
# =============================================================================
# customizations/scripts/00-configure-dnf.sh
#
# Hook script #00: Configure DNF settings and system basics for the WSL image.
# Runs inside the container before package installation.
#
# Numbering convention:
#   00-09  — System/DNF configuration (runs before package install)
#   10-49  — Package-related setup
#   50-79  — User and identity configuration
#   80-99  — Final configuration and cleanup
# =============================================================================
set -euo pipefail

log() { echo "[00-configure-dnf] $*"; }

# ── Configure HTTP proxy (if needed) ─────────────────────────────────────────
if [ -n "${DNF_HTTP_PROXY:-}" ]; then
  log "Configuring DNF proxy: ${DNF_HTTP_PROXY}"
  echo "proxy=${DNF_HTTP_PROXY}" >> /etc/dnf/dnf.conf
fi

# ── Configure timezone ────────────────────────────────────────────────────────
TIMEZONE="${TIMEZONE:-UTC}"
log "Setting timezone to ${TIMEZONE}..."
dnf install -y tzdata 2>/dev/null || true
ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
echo "${TIMEZONE}" > /etc/timezone

# ── Configure locale ─────────────────────────────────────────────────────────
LOCALE="${LOCALE:-en_US.UTF-8}"
LANG_CODE="${LOCALE%%.*}"     # e.g. en_US
CHARSET="${LOCALE##*.}"       # e.g. UTF-8
# Derive the glibc-langpack name: en_US → en, fr_FR → fr, zh_CN → zh
LANG_PREFIX="${LANG_CODE%%_*}"
log "Setting locale to ${LOCALE}..."
dnf install -y "glibc-langpack-${LANG_PREFIX}" 2>/dev/null || \
  dnf install -y "glibc-all-langpacks" 2>/dev/null || true
localedef -i "${LANG_CODE}" -f "${CHARSET}" "${LOCALE}" 2>/dev/null || true
cat > /etc/locale.conf << LOCALEEOF
LANG=${LOCALE}
LC_ALL=${LOCALE}
LOCALEEOF

# ── Configure WSL ─────────────────────────────────────────────────────────────
log "Writing /etc/wsl.conf..."
cat > /etc/wsl.conf << WSLEOF
[automount]
enabled = ${WSL_AUTOMOUNT:-true}
root = ${WSL_AUTOMOUNT_ROOT:-/mnt}
options = "${WSL_AUTOMOUNT_OPTIONS:-metadata,umask=22,fmask=11}"
mountFsTab = true

[network]
generateHosts = ${WSL_NETWORK_GENERATE_HOSTS:-true}
generateResolvConf = ${WSL_NETWORK_GENERATE_RESOLV_CONF:-true}

[interop]
enabled = ${WSL_INTEROP_ENABLED:-true}
appendWindowsPath = ${WSL_INTEROP_APPENDWINDOWSPATH:-false}

[boot]
systemd = false
WSLEOF

log "DNF and system configuration complete"
