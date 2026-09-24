#!/usr/bin/env bash
# 60-customize - journal size cap and optional extra packages.

step_60-customize() {
    if [ "${UPI_CAP_JOURNALD:-true}" = true ]; then
        local dropin="/etc/systemd/journald.conf.d/50-upi-cap.conf"
        if $DRY_RUN; then
            printf '%s[drun]%s write %s (SystemMaxUse=500M)\n' "$C_INFO" "$C_RST" "$dropin"
        else
            if mkdir -p /etc/systemd/journald.conf.d; then
                printf '[Journal]\nSystemMaxUse=500M\n' >"$dropin"
                chmod 0644 "$dropin"
                if have systemctl; then
                    run systemctl try-restart systemd-journald
                else
                    warn "systemctl not found; journal cap applies after reboot."
                fi
                ok "journal capped at 500M: ${dropin}"
            fi
        fi
    fi

    if [ -n "${UPI_EXTRA_PACKAGES:-}" ]; then
        # Comma- or space-separated list from config.
        local pkgs
        pkgs="$(printf '%s\n' "$UPI_EXTRA_PACKAGES" | tr ',' ' ')"
        # shellcheck disable=SC2086  # validated package-name list from config
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
    fi
    ok "customize step finished"
    return 0
}
