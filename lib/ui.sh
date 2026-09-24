#!/usr/bin/env bash
# ui.sh - user interface layer for ubuntu-post-install.
# whiptail dialogs when a terminal is available; console fallback otherwise.
# Non-interactive runs (--yes, piped stdin, CI) never block on a dialog.

UI_W=78
UI_FALLBACK_REASON=""

ui_available() {
    # whiptail (newt) draws on /dev/tty, so only stderr must be a terminal.
    if [ "${UPI_NO_UI:-false}" = true ]; then
        UI_FALLBACK_REASON="UPI_NO_UI=true"
        return 1
    fi
    if ! have whiptail; then
        UI_FALLBACK_REASON="whiptail is not installed"
        return 1
    fi
    if ! [ -t 2 ]; then
        UI_FALLBACK_REASON="stderr is not a terminal"
        return 1
    fi
    return 0
}

ensure_whiptail() {
    # Whiptail-first guarantee: install whiptail when it is missing so the
    # dialogs can actually render. Skipped in dry-run and headless contexts.
    have whiptail && return 0
    [ -t 2 ] || { info "no terminal for dialogs; console mode."; return 0; }
    have apt-get || { info "no apt; staying in console mode."; return 0; }
    if $DRY_RUN; then
        info "[dry-run] would install whiptail for the interactive interface."
        return 0
    fi
    if confirm "Install whiptail (small TUI package) for the dialog interface? [recommended]"; then
        if env DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >/dev/null 2>&1; then
            ok "whiptail installed; dialog interface enabled."
        else
            warn "whiptail install failed; continuing in console mode."
        fi
    else
        info "staying in console mode."
    fi
}

ui_fallback_notice() {
    # Explain once why console mode is active, so silent fallbacks cannot
    # surprise the user mid-run.
    if ! ui_available; then
        info "console mode (${UI_FALLBACK_REASON})."
        return 0
    fi
    return 0
}

_wt() {
    # _wt <whiptail args...> ; canonical fd dance so the selection lands on
    # stdout while the dialog draws on the terminal, plus /dev/tty keyboard
    # so piped stdin cannot starve the dialog of input.
    whiptail "$@" </dev/tty 3>&1 1>&2 2>&3
}

ui_confirm() {
    # ui_confirm <title> <text> ; returns 0 = yes.
    # Honors --yes and --dry-run exactly like the console confirm().
    if $ASSUME_YES; then
        return 0
    fi
    if $DRY_RUN; then
        printf '%s[drun]%s (auto-yes in dry-run) %s\n' "$C_INFO" "$C_RST" "$2"
        return 0
    fi
    if ui_available; then
        _wt --title "$1" --yesno "$2" 0 "$UI_W"
        local rc=$?
        # 0=yes, 1=no/cancel are normal; anything else means whiptail itself
        # failed - never leave the user with an invisible question.
        if [ "$rc" -le 1 ]; then
            return "$rc"
        fi
        warn "whiptail failed (rc=${rc}); falling back to console prompt."
    fi
    confirm "$2"
}

ui_msgbox() {
    # ui_msgbox <title> <text>
    if ui_available && _wt --title "$1" --scrolltext --msgbox "$2" 0 "$UI_W"; then
        return 0
    fi
    printf '\n== %s ==\n%s\n\n' "$1" "$2"
}

ui_menu() {
    # ui_menu <title> <text> <tag> <item> [...] ; prints the chosen tag.
    # Console fallback prints a numbered list and reads a choice.
    local title="$1" text="$2"
    shift 2
    local -a tags=() descs=()
    while [ $# -gt 0 ]; do
        tags+=("$1"); descs+=("$2")
        shift 2
    done
    if ui_available; then
        local -a args=() out rc
        local i
        for i in "${!tags[@]}"; do
            args+=("${tags[$i]}" "${descs[$i]}")
        done
        out="$(_wt --title "$title" --menu "$text" 0 "$UI_W" "${#tags[@]}" "${args[@]}")"
        rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
            printf '%s\n' "$out"
            return 0
        fi
        warn "whiptail menu failed (rc=${rc}); using console menu."
    fi
    # Console fallback.
    printf '\n== %s ==\n%s\n' "$title" "$text"
    local idx
    for idx in "${!tags[@]}"; do
        printf '  %d) %-12s %s\n' "$((idx + 1))" "${tags[$idx]}" "${descs[$idx]}"
    done
    local answer
    printf 'Choice [1-%d]: ' "${#tags[@]}"
    if ! read -r answer </dev/tty 2>/dev/null; then
        read -r answer || { printf '%s\n' "${tags[0]}"; return 0; }
    fi
    case "$answer" in
        ''|*[!0-9]*) printf '%s\n' "${tags[0]}" ;;
        *) if [ "$answer" -ge 1 ] && [ "$answer" -le "${#tags[@]}" ]; then
               printf '%s\n' "${tags[$((answer - 1))]}"
           else
               printf '%s\n' "${tags[0]}"
           fi ;;
    esac
}

ui_radiolist() {
    # ui_radiolist <title> <text> <tag> <desc> <on|off> [...] ; prints choice.
    local title="$1" text="$2"
    shift 2
    if ui_available; then
        local out rc
        out="$(_wt --title "$title" --radiolist "$text" 0 "$UI_W" "$#" "$@")"
        rc=$?
        if [ "$rc" -eq 0 ] && [ -n "${out//\"/}" ]; then
            printf '%s\n' "${out//\"/}"
            return 0
        fi
        [ "$rc" -ne 0 ] && warn "whiptail radiolist failed (rc=${rc}); using console default."
    fi
    # Console fallback: first 'on' entry wins; no prompt (keep non-interactive
    # runs moving; the menu offers the same choice interactively).
    local tag desc state
    while [ $# -gt 0 ]; do
        tag="$1"; desc="$2"; state="$3"; shift 3
        [ "$state" = "on" ] && { printf '%s\n' "$tag"; return 0; }
    done
}

ui_checklist() {
    # ui_checklist <title> <text> <tag> <desc> <on|off> [...]
    # Prints selected tags, one per line.
    local title="$1" text="$2"
    shift 2
    if ui_available; then
        local out rc
        out="$(_wt --title "$title" --checklist "$text" 0 "$UI_W" "$#" "$@")"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "${out//\"/}" | tr ' ' '\n' | grep -v '^$'
            return 0
        fi
        warn "whiptail checklist failed (rc=${rc}); keeping current choices."
    fi
    # Console fallback: return the tags that are already 'on'.
    local tag desc state
    while [ $# -gt 0 ]; do
        tag="$1"; desc="$2"; state="$3"; shift 3
        [ "$state" = "on" ] && printf '%s\n' "$tag"
    done
}

# ---------------------------------------------------------------------------
# Option metadata: one source for the UI, the help text, and config parsing.
# Keys are action-first: remove_*, disable_*, harden_*, encrypt_*, enable_*,
# install_*, tune_*, cap_*. Format per line: key|short description|default
# ---------------------------------------------------------------------------
option_group_spec() {
    # option_group_spec <debloat|harden|system>
    case "$1" in
        debloat)
            cat <<'EOF'
remove_snapd|Remove every snap, then purge snapd and pin it so it stays gone|true
remove_lxd|Remove the lxd snap and lxd group membership (privilege-escalation path)|true
remove_cloudinit|Remove cloud-init. NEVER enable on cloud/VPS images: they need it to boot and re-provision|true
remove_avahi|Remove avahi/mDNS discovery (.local names, network printer discovery)|true
remove_pro_client|Remove the Ubuntu Pro client (needed for ESM/USG/FIPS subscriptions)|false
disable_telemetry|Disable apport/whoopsie crash reporting and popularity tracking|true
clean_motd|Disable MOTD advertising and help-text login banners|true
pin_removed|Hold + pin every removed package so nothing reinstalls it|false
EOF
            ;;
        harden)
            cat <<'EOF'
harden_firewall|UFW: deny incoming, allow outgoing, allow the SSH port|true
harden_ssh|SSH drop-in: no root passwords, tighter auth limits (key-safe)|true
harden_kernel|Kernel network sysctls: anti-spoofing, no redirects, syncookies|true
encrypt_dns|Encrypt DNS (DNS-over-TLS via systemd-resolved, Cloudflare+Quad9)|false
enable_unattended_upgrades|Automatic security updates|true
install_fail2ban|Install fail2ban with the default SSH jail|false
EOF
            ;;
        system)
            cat <<'EOF'
tune_performance|swappiness=10, BBR congestion control, higher file limits|true
cap_journald|Cap the persistent journal at 500 MB|true
EOF
            ;;
    esac
}

option_groups() {
    printf '%s\n' debloat harden system
}

step_descriptions() {
    cat <<'EOF'
10 Preflight: detect flavor, snapshot installed packages
20 Update: apt update and full-upgrade
30 Debloat: remove catalog packages that are installed
40 Snap and cloud: lxd/snapd removal, telemetry off
45 MOTD cleanup: disable motd-news and help-text
50 Harden: firewall, SSH, kernel, unattended-upgrades
52 Performance: swappiness, BBR, file limits
55 DNS over TLS: encrypted DNS (opt-in)
60 Customize: journal cap, extra packages
EOF
}

profile_descriptions() {
    cat <<'EOF'
server|Production server defaults: snapd removed, cloud-init and avahi kept
desktop|Desktop defaults: snapd kept, desktop app catalog used
minimal|Most aggressive: optional packages removed, removals pinned, DoT on
EOF
}

# ---------------------------------------------------------------------------
# Main menu.
# ---------------------------------------------------------------------------
main_menu() {
    # Interactive configuration. Returns 0 to proceed with the run.
    if ! ui_available && [ ! -t 0 ]; then
        info "non-interactive session: profile=${PROFILE}, all steps, per-step confirmations."
        ui_fallback_notice
        return 0
    fi
    ui_fallback_notice

    while :; do
        local action
        action="$(ui_menu "ubuntu-post-install v${UPI_VERSION}" \
            "Configure the run, then choose an action." \
            profile "Profile (now: ${PROFILE})" \
            options "Toggle options" \
            steps "Select steps (now: all)" \
            preview "Preview the full plan (dry run) and exit" \
            run "RUN NOW (confirmations still apply)" \
            quit "Quit without changes")"
        case "$action" in
            profile)
                menu_choose_profile
                ;;
            options)
                menu_toggle_options
                ;;
            steps)
                menu_choose_steps
                ;;
            preview)
                DRY_RUN=true
                info "dry-run preview mode; confirmations auto-accept."
                return 0
                ;;
            run)
                return 0
                ;;
            quit|*)
                return 1
                ;;
        esac
    done
}

menu_choose_profile() {
    local -a items=() selected
    local line tag desc
    while read -r line; do
        tag="${line%%|*}"; desc="${line#*|}"
        [ "$tag" = "$PROFILE" ] && items+=("$tag" "$desc" "on") \
                               || items+=("$tag" "$desc" "off")
    done < <(profile_descriptions)
    selected="$(ui_radiolist "Profile" "Which profile should this run use?" "${items[@]}")"
    if [ -n "$selected" ]; then
        PROFILE="$selected"
        load_options_file "${SCRIPT_DIR}/profiles/${PROFILE}.conf"
        ok "profile set to ${PROFILE}"
    fi
}

menu_toggle_options() {
    # Sub-menu: pick a group, then toggle that group's options.
    local group
    group="$(ui_menu "Options" \
"What do you want to configure?" \
        debloat "What gets removed" \
        harden "Security hardening" \
        system "Performance and storage")"
    case "$group" in
        debloat|harden|system) ;;
        *) return 0 ;;
    esac
    local -a items=() selected
    local line key desc def val
    while read -r line; do
        key="${line%%|*}"; desc="${line#*|}"
        def="${desc##*|}"; desc="${desc%|*}"
        eval "val=\"\${UPI_$(option_key_to_var "$key"):-$def}\""
        [ "$val" = "true" ] && items+=("$key" "$desc" "on") \
                            || items+=("$key" "$desc" "off")
    done < <(option_group_spec "$group")
    selected="$(ui_checklist "${group} options" \
"Checked = enabled. extra_packages is config-file only
(see config.ini.example)." "${items[@]}")"
    local -A chosen=()
    while read -r line; do
        [ -n "$line" ] && chosen["$line"]=1
    done <<<"$selected"
    while read -r line; do
        key="${line%%|*}"
        if [ -n "${chosen[$key]:-}" ]; then
            upi_set_option "$key" true
        else
            upi_set_option "$key" false
        fi
    done < <(option_group_spec "$group")
    ok "${group} options updated"
}

menu_choose_steps() {
    local -a items=()
    local num label
    while read -r num label; do
        items+=("$num" "$label" "ON")
    done < <(step_descriptions)
    local selected
    selected="$(ui_checklist "Steps" "Which steps should run?" "${items[@]}")"
    SELECTED_STEPS="$(printf '%s\n' "$selected" | paste -sd, -)"
    [ -z "$SELECTED_STEPS" ] && info "nothing selected; every step will run."
    ok "steps: ${SELECTED_STEPS:-all}"
}
