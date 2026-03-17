# Customizations Guide

This directory contains everything needed to customize the WSL Rocky Linux image
beyond the baseline STIG/SCAP hardening. The structure is intentionally
self-documenting — each file's purpose is clear from its location and name.

## Directory Structure

```
customizations/
├── config.env          ← Build-time configuration variables
├── packages.list       ← Extra packages to install (one per line)
├── files/              ← Files copied verbatim into the image filesystem
│   └── etc/
│       ├── motd                    ← Login message
│       └── profile.d/
│           └── 99-org-env.sh       ← Shell environment for all users
└── scripts/            ← Numbered hook scripts run in order
    ├── 00-configure-dnf.sh         ← DNF, timezone, locale, WSL config
    └── 01-configure-users.sh       ← Default user, sudo, MOTD
```

## How to Customize

### 1. Add packages — `packages.list`

Add one dnf package name per line. Lines starting with `#` are comments.

```
# My org's packages
myorg-ca-bundle
myorg-vpn-client
```

### 2. Drop in files — `files/`

Place any file under `files/` using the same path it should have in the image.
The entire `files/` tree is copied into `/` of the image, preserving structure.

**Examples:**

```
# Add a CA certificate
files/usr/local/share/ca-certificates/myorg-root-ca.crt

# Add a custom bashrc
files/etc/skel/.bashrc

# Add a DNF repository definition
files/etc/yum.repos.d/myorg.repo
```

### 3. Add hook scripts — `scripts/`

Create numbered shell scripts (`NN-description.sh`) in `scripts/`. They run
**in alphabetical/numeric order** after package installation and file copying.

Use the numbering convention:

| Range | Purpose |
|-------|---------|
| `00-09` | System/DNF configuration |
| `10-49` | Package-related setup |
| `50-79` | User and identity configuration |
| `80-99` | Final configuration and cleanup |

**Example `scripts/50-add-vpn.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Install org VPN
dnf install -y openvpn
cp /opt/customizations/files/etc/openvpn/client.conf /etc/openvpn/
```

### 4. Edit `config.env`

Set organization-specific variables that hook scripts use:

```bash
ORG_NAME="Acme Corp"
ORG_SLUG="acme"
ORG_CONTACT="helpdesk@acme.com"
TIMEZONE="America/Chicago"
CREATE_DEFAULT_USER="true"
DEFAULT_USERNAME="acmeuser"
```

## Build-time vs Runtime

| When | What | Where |
|------|------|-------|
| Build time | Package install, file copy, hook scripts | `packages.list`, `files/`, `scripts/` |
| Build time | STIG/SCAP hardening | `../scripts/harden.sh` |
| WSL import | `/etc/wsl.conf` applied by Windows | Written by `00-configure-dnf.sh` |
| First launch | `systemd` units, if enabled | `/etc/systemd/system/` |

## Secrets and Credentials

**Do not** place secrets (passwords, tokens, API keys) in this directory.
They will be baked into the image and visible to anyone who imports it.

For secrets:
- Use GitHub Actions secrets in `.github/workflows/build.yml`
- Configure secrets at runtime via WSL environment variables or a vault client
