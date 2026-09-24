#!/usr/bin/env bash
# 20-update - apt update, full-upgrade, autoclean.

step_20-update() {
    if ! have apt-get; then
        warn "apt-get not found; skipping system update."
        return 0
    fi
    run apt-get update
    safe_upgrade
    run apt-get autoclean
    ok "system update step finished"
    return 0
}
