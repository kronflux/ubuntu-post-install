#!/usr/bin/env bash
# config.sh - option-file loading for ubuntu-post-install.
# Reads the same key=value format for profiles/ and the user's config file.
# Precedence (later wins): built-in defaults -> profile -> config file -> CLI flags.
# Option variables written here are consumed by sourced step modules.
# shellcheck disable=SC2034

_is_bool() {
    case "$1" in
        true|false) return 0 ;;
        *) return 1 ;;
    esac
}

option_key_to_var() {
    # remove_snapd -> UPI_REMOVE_SNAPD
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '.' '_' | sed 's/^/UPI_/'
}

upi_set_option() {
    # upi_set_option <key> <value> ; single mapping point for option keys.
    # Option naming is action-first: remove_*, disable_*, harden_*,
    # encrypt_*, enable_*, install_*, tune_*, cap_*.
    local key="$1" val="$2"
    # Back-compat: translate keys from before the removal-first rename.
    case "$key" in
        keep_cloudinit)   key=remove_cloudinit;  val="$([ "$val" = true ] && echo false || echo true)"
                          warn "deprecated key 'keep_cloudinit' translated to remove_cloudinit=${val}" ;;
        keep_avahi)       key=remove_avahi;      val="$([ "$val" = true ] && echo false || echo true)"
                          warn "deprecated key 'keep_avahi' translated to remove_avahi=${val}" ;;
        remove_optional)  warn "deprecated key 'remove_optional' ignored (use remove_pro_client)"; return 0 ;;
        harden_dns)       key=encrypt_dns;       warn "deprecated key 'harden_dns' translated to encrypt_dns" ;;
        clean_motd)       : ;;  # unchanged name, accepted as-is
    esac
    case "$key" in
        remove_lxd|remove_snapd|disable_telemetry|remove_cloudinit|remove_avahi| \
        remove_pro_client|harden_firewall|harden_ssh|harden_kernel|encrypt_dns| \
        enable_unattended_upgrades|install_fail2ban|cap_journald|pin_removed| \
        clean_motd|tune_performance)
            _is_bool "$val" || { err "option ${key} must be true or false (got: ${val})"; return 1; }
            ;;
    esac
    case "$key" in
        auto)     [ "$val" = "true" ] && ASSUME_YES=true ;;
        dry_run)  [ "$val" = "true" ] && DRY_RUN=true ;;
        *)        eval "$(option_key_to_var "$key")=\"\$val\"" ;;
    esac
    return 0
}

load_options_file() {
    # load_options_file <file>
    # Maps known keys onto UPI_* option variables; ignores comments and blanks.
    local file="$1" line key val
    [ -f "$file" ] || { err "options file not found: $file"; exit 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        if [ "$key" = "$line" ]; then
            warn "${file}: ignoring malformed line: ${line}"
            continue
        fi
        case "$key" in
            remove_lxd|remove_snapd|disable_telemetry|remove_cloudinit| \
            remove_avahi|remove_pro_client|harden_firewall|harden_ssh| \
            harden_kernel|encrypt_dns|enable_unattended_upgrades|install_fail2ban| \
            cap_journald|pin_removed|clean_motd|tune_performance|extra_packages| \
            auto|dry_run|profile|steps|keep_cloudinit|keep_avahi|remove_optional|harden_dns)
                ;;
            *)
                warn "${file}: unknown key: ${key}"
                continue
                ;;
        esac
        upi_set_option "$key" "$val" || exit 1
    done <"$file"
}
