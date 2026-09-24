#!/usr/bin/env bash
# 45-motd - remove Ubuntu MOTD advertising and news.
# Disables motd-news at the source and de-executes the help-text and
# motd-news login scripts. Nothing is deleted; restore is chmod +x.

step_45-motd() {
    if [ "${UPI_CLEAN_MOTD:-true}" != true ]; then
        return 0
    fi

    if [ -f /etc/default/motd-news ]; then
        backup_file /etc/default/motd-news
        if $DRY_RUN; then
            printf '%s[drun]%s set ENABLED=0 in /etc/default/motd-news\n' "$C_INFO" "$C_RST"
        else
            sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
            ok "motd-news disabled in /etc/default/motd-news"
        fi
    else
        info "/etc/default/motd-news not present; nothing to disable there."
    fi

    if [ -d /etc/update-motd.d ]; then
        local f
        for f in /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news; do
            if [ -e "$f" ]; then
                run chmod -x "$f"
            fi
        done
    else
        warn "/etc/update-motd.d not found; skipping MOTD script cleanup."
    fi
    ok "MOTD cleanup finished"
    return 0
}
