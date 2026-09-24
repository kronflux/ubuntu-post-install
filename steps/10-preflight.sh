#!/usr/bin/env bash
# 10-preflight - detect flavor, snapshot installed packages, sanity checks.

step_10-preflight() {
    if ! have dpkg-query && [ -z "${UPI_FAKE_DPKG:-}" ]; then
        err "dpkg-query not found and no selftest fixture set; cannot inspect packages."
        return 1
    fi

    local flavor="unknown"
    if pkg_installed ubuntu-server || pkg_installed ubuntu-server-minimal; then
        flavor="server"
    elif pkg_installed ubuntu-desktop || pkg_installed ubuntu-desktop-minimal; then
        flavor="desktop"
    fi
    info "Detected flavor: ${flavor} (profile: ${PROFILE})"
    if [ "$flavor" = "server" ] && [ "$PROFILE" = "desktop" ]; then
        warn "Desktop profile on a server install; the desktop catalog may not match."
    fi
    if [ "$flavor" = "desktop" ] && [ "$PROFILE" = "server" ]; then
        warn "Server profile on a desktop install; consider --profile desktop."
    fi

    # Anchor the boot chain FIRST: mark every installed kernel/bootloader/
    # metapackage as manually installed so no later removal pass - ours or a
    # manual 'apt autoremove' - can ever take the system unbootable, even if
    # a metapackage anchor is already broken.
    protect_boot_chain

    local snapshot="${BACKUP_ROOT}/${UPI_RUN_TS}/installed-packages.txt"
    if $DRY_RUN; then
        printf '%s[drun]%s snapshot installed packages -> %s\n' "$C_INFO" "$C_RST" "$snapshot"
    else
        if mkdir -p "$(dirname "$snapshot")" && installed_packages >"$snapshot"; then
            ok "installed-package snapshot: ${snapshot}"
        else
            warn "could not write package snapshot: ${snapshot}"
        fi
    fi

    if have df; then
        local free_mb
        free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
        if [ -n "$free_mb" ] && [ "$free_mb" -lt 500 ]; then
            warn "only ${free_mb} MB free on /: upgrades and removals may fail."
        fi
    fi
    return 0
}
