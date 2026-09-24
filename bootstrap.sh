#!/usr/bin/env bash
# bootstrap.sh - one-command install-and-run for ubuntu-post-install.
#
#   curl -fsSL https://raw.githubusercontent.com/kronflux/ubuntu-post-install/main/bootstrap.sh \
#     | sudo bash -s -- --dry-run
#
# Clones (or updates) the repository into /opt/ubuntu-post-install and execs
# the main script with any arguments given after '-s --'. Needs root and git.

set -euo pipefail

REPO_URL="https://github.com/kronflux/ubuntu-post-install.git"
DEST="/opt/ubuntu-post-install"

if [ "$(id -u)" -ne 0 ]; then
    echo "[fail] bootstrap needs root. Re-run with sudo." >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "[info] git not found; installing..."
    apt-get update -qq
    env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
fi

if [ -d "${DEST}/.git" ]; then
    echo "[info] updating existing clone at ${DEST}"
    git -C "$DEST" pull --ff-only --quiet || echo "[warn] update failed; using existing files."
else
    rm -rf "$DEST"
    git clone --quiet "$REPO_URL" "$DEST"
fi

echo "[info] starting ubuntu-post-install with args: $*"
# Restore interactivity: when run as 'curl | sudo bash', stdin is the curl
# pipe. whiptail and console prompts need the real terminal.
if [ -t 2 ] && [ -e /dev/tty ]; then
    exec bash "${DEST}/ubuntu-post-install.sh" "$@" </dev/tty
else
    exec bash "${DEST}/ubuntu-post-install.sh" "$@"
fi
