#!/usr/bin/env bash
# 40-snapcloud - snap/lxd/telemetry cleanup.
# Order matters: snaps are removed while snapd still runs (matissd model),
# then snapd units are stopped/masked, the package purged, and snapd held and
# pinned at -10 so upgrades cannot pull it back (NullAngst model).

_snap_remove_all() {
    # Remove every snap, content snaps first, base snaps last.
    local s base="core core18 core20 core22 core24 core26 bare snapd"
    if $DRY_RUN; then
        printf '%s[drun]%s snap remove --purge <each installed snap, base snaps last)\n' "$C_INFO" "$C_RST"
        return 0
    fi
    if ! have snap; then
        info "snap CLI not present; no snaps to remove."
        return 0
    fi
    # snapd must be running for 'snap remove' to work.
    have systemctl && systemctl start snapd.service >/dev/null 2>&1
    for s in $(snap list 2>/dev/null | awk 'NR>1 {print $1}'); do
        case " $base " in
            *" $s "*) continue ;;
        esac
        snap remove --purge "$s" >/dev/null 2>&1 || warn "could not remove snap: ${s}"
    done
    for s in $base; do
        snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF "$s" \
            && snap remove --purge "$s" >/dev/null 2>&1 || true
    done
}

step_40-snapcloud() {
    # --- LXD: remove the snap and every user's lxd group membership ---------
    if [ "${UPI_REMOVE_LXD:-true}" = true ]; then
        if have snap || $DRY_RUN; then
            if $DRY_RUN; then
                printf '%s[drun]%s snap remove --purge lxd\n' "$C_INFO" "$C_RST"
            else
                snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF lxd \
                    && run snap remove --purge lxd
            fi
        fi
        local members
        members="$(getent group lxd 2>/dev/null | cut -d: -f4)"
        if [ -n "$members" ]; then
            info "lxd group members (known privilege-escalation path): ${members}"
            local m
            for m in ${members//,/ }; do
                run gpasswd -d "$m" lxd
            done
        else
            info "no lxd group or no members; nothing to do."
        fi
    fi

    # --- Full snapd removal (optional) --------------------------------------
    if [ "${UPI_REMOVE_SNAPD:-true}" = true ]; then
        if pkg_installed snapd; then
            if ! ui_confirm "Remove snapd?" \
"Remove every snap, then purge and pin snapd?

- All snap applications go away (browser, store, any snap-installed tools).
- snapd is held and pinned at -10 so upgrades cannot reinstall it.
- Undo: docs/REVERT.md (unhold, remove pin, reinstall snapd)."; then
                info "snapd removal declined; keeping snapd."
            else
            _snap_remove_all
            if have systemctl; then
                local unit
                for unit in $(systemctl list-unit-files --no-legend --no-pager 'snapd*' 2>/dev/null | awk '{print $1}'); do
                    run systemctl stop "$unit"
                    run systemctl mask "$unit"
                done
            else
                warn "systemctl not found; skipping snapd unit stop/mask."
            fi
            # Purging snapd can cascade into the ubuntu-server/desktop
            # metapackage (it Depends on snapd on Server); safe_purge refuses
            # the whole operation if that cascade would touch protected
            # packages. Losing the metapackage alone is survivable, but we
            # refuse rather than break the anchor for future upgrades.
            if ! safe_purge snapd; then
                warn "snapd purge refused (protected cascade); keeping snapd installed."
            else
            run apt-mark hold snapd
            local pinfile="/etc/apt/preferences.d/no-snapd.pref"
            if $DRY_RUN; then
                printf '%s[drun]%s write %s (Pin-Priority -10)\n' "$C_INFO" "$C_RST" "$pinfile"
            else
                if mkdir -p /etc/apt/preferences.d; then
                    cat >"$pinfile" <<'EOF'
# Written by ubuntu-post-install. To allow snapd again:
#   rm /etc/apt/preferences.d/no-snapd.pref && apt-mark unhold snapd
Package: snapd
Pin: release *
Pin-Priority: -10
EOF
                    chmod 0644 "$pinfile"
                    ok "snapd held and pinned (-10): ${pinfile}"
                fi
            fi
            # Only wipe snap state when no loop mounts remain (NullAngst guard).
            if $DRY_RUN; then
                printf '%s[drun]%s rm -rf /var/lib/snapd /var/cache/snapd /var/snap /snap\n' "$C_INFO" "$C_RST"
            elif ! grep -q '/snap\|/var/lib/snapd' /proc/mounts 2>/dev/null; then
                rm -rf /var/lib/snapd /var/cache/snapd /var/snap /snap
            else
                warn "snap mounts still active; reboot, then remove /var/lib/snapd /var/snap /snap by hand."
            fi
            safe_autoremove
            fi
            fi
        else
            info "snapd is not installed; nothing to remove."
        fi
    fi

    # --- Telemetry -----------------------------------------------------------
    if [ "${UPI_DISABLE_TELEMETRY:-true}" = true ]; then
        # Packages themselves are purged by the debloat step when present.
        # Here: neutralize config and services for anything that survived.
        if [ -f /etc/default/apport ]; then
            backup_file /etc/default/apport
            if $DRY_RUN; then
                printf '%s[drun]%s set enabled=0 in /etc/default/apport\n' "$C_INFO" "$C_RST"
            else
                sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
                ok "apport disabled in /etc/default/apport"
            fi
        fi
        if have systemctl; then
            run systemctl disable apport.service 2>/dev/null
            run systemctl disable whoopsie.service 2>/dev/null
        fi
    fi
    ok "snap/cloud step finished"
    return 0
}
