#!/usr/bin/env bash
# 30-debloat - detection-based package removal.
# Intersects the profile's catalogs with actually-installed packages, shows
# the plan, asks once, then purges. Optionally holds and pins the removed
# packages so nothing reinstalls them as a dependency.

plan_debloat() {
    # Prints the removal plan (catalog entries that are installed), one per line.
    local files f p
    files="$(catalogs_for_profile "${SCRIPT_DIR}/catalogs" "$PROFILE" "${UBI_VERSION_ID:-unknown}")"
    [ -n "$files" ] || { warn "no catalogs found for profile ${PROFILE}."; return 0; }
    local -A planned=()
    # Package names never contain whitespace (lint_catalogs enforces the format).
    # shellcheck disable=SC2207
    for f in $files; do
        for p in $(catalog_entries "$f"); do
            pkg_installed "$p" && planned["$p"]=1
        done
    done
    [ ${#planned[@]} -gt 0 ] && printf '%s\n' "${!planned[@]}" | sort -u
    return 0
}

step_30-debloat() {
    local plan count
    plan="$(plan_debloat | filter_protected)"
    if [ -z "$plan" ]; then
        ok "debloat: nothing from the catalogs is installed."
        return 0
    fi
    count="$(printf '%s\n' "$plan" | wc -l)"
    info "Packages installed that the ${PROFILE} catalog marks removable (${count}):"
    # shellcheck disable=SC2086  # word-splitting the plan is the point here
    printf '  %s\n' $plan

    # shellcheck disable=SC2086  # word-splitting the plan is the point here
    ui_msgbox "Debloat plan (${count} packages)" \
"These packages are installed and on the ${PROFILE} removal catalog.
Each can be reinstalled later (docs/REVERT.md); a full snapshot of
installed packages is saved before anything is removed.

$(printf '  %s\n' $plan)"

    ui_confirm "Debloat" \
"Purge the ${count} packages listed above?

- Only packages that are actually installed are ever touched.
- Protected packages (bootloader, kernel, init) are never removable here.
- Dependencies that become orphaned are cleaned only when a simulation
  proves nothing protected would be removed." \
        || { info "debloat declined; skipping."; return 0; }

    # shellcheck disable=SC2086  # plan is a validated newline list of package names
    safe_purge $plan || {
        err "debloat purge refused (protected cascade); no packages were removed."
        return 1
    }
    safe_autoremove

    # Residual configurations left by purged packages.
    run bash -c "dpkg -l | awk '/^rc/ {print \$2}' | xargs -r dpkg --purge"

    if [ "${UPI_PIN_REMOVED:-false}" = true ]; then
        local pinfile="/etc/apt/preferences.d/00-ubuntu-post-install-debloat.pref"
        backup_file "$pinfile"
        if $DRY_RUN; then
            printf '%s[drun]%s write pin file %s (Pin-Priority -10 for each removed package)\n' \
                "$C_INFO" "$C_RST" "$pinfile"
            # shellcheck disable=SC2086
            printf '%s[drun]%s apt-mark hold %s\n' "$C_INFO" "$C_RST" "$plan"
        else
            if mkdir -p /etc/apt/preferences.d; then
                {
                    echo "# Written by ubuntu-post-install. Revert: delete this file,"
                    echo "# then 'apt-mark unhold' the packages you want back."
                    local p
                    for p in $plan; do
                        printf 'Package: %s\nPin: release *\nPin-Priority: -10\n\n' "$p"
                    done
                } >"$pinfile"
                chmod 0644 "$pinfile"
                # shellcheck disable=SC2086
                apt-mark hold $plan
                ok "removed packages held and pinned (-10): ${pinfile}"
            else
                warn "could not write ${pinfile}; packages may return as dependencies."
            fi
        fi
    fi
    ok "debloat step finished"
    return 0
}
