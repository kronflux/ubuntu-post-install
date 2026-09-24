#!/usr/bin/env bash
# 50-harden - firewall, SSH, kernel sysctl, unattended-upgrades, fail2ban.
# Every config change goes into a drop-in file; originals are backed up and
# docs/REVERT.md documents the undo. SSH hardening never disables password
# auth while no authorized key exists for root or the invoking user.

_ssh_port() {
    # Print the port sshd actually listens on (first Port directive), 22 otherwise.
    local port
    if [ -f /etc/ssh/sshd_config ]; then
        port="$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' /etc/ssh/sshd_config)"
    fi
    printf '%s\n' "${port:-22}"
}

_ssh_key_present() {
    # Lockout guard: true when root or the invoking (sudo) user has a key.
    local home_dir real_user
    [ -s /root/.ssh/authorized_keys ] && return 0
    real_user="${SUDO_USER:-}"
    if [ -n "$real_user" ] && [ "$real_user" != "root" ]; then
        home_dir="$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6)"
        [ -n "$home_dir" ] && [ -s "${home_dir}/.ssh/authorized_keys" ] && return 0
    fi
    return 1
}

step_50-harden() {
    # --- Firewall ------------------------------------------------------------
    if [ "${UPI_HARDEN_FIREWALL:-true}" = true ]; then
        if have ufw; then
            if ui_confirm "Firewall (UFW)" \
"Reset the firewall to: deny all incoming, allow all outgoing,
allow SSH on port $(_ssh_port)?

- Current rules are backed up first and can be restored (docs/REVERT.md).
- Your current SSH port stays open, so this session is not cut off.
- Any other listening services become unreachable from outside until
  you open their ports with: ufw allow <port>"; then
                backup_file /etc/ufw/user.rules
                run ufw default deny incoming
                run ufw default allow outgoing
                run ufw allow "$(_ssh_port)/tcp" comment 'ssh'
                run ufw --force enable
                ok "firewall: deny incoming, allow outgoing, ssh on $(_ssh_port)/tcp"
            else
                info "firewall hardening declined; skipping."
            fi
        else
            warn "ufw not found; install it or choose another firewall. Skipping firewall."
        fi
    fi

    # --- SSH ------------------------------------------------------------------
    if [ "${UPI_HARDEN_SSH:-true}" = true ]; then
        if [ -d /etc/ssh ] || $DRY_RUN; then
            local sshd_dropin="/etc/ssh/sshd_config.d/50-upi-hardening.conf"
            backup_file /etc/ssh/sshd_config
            if $DRY_RUN; then
                printf '%s[drun]%s write %s\n' "$C_INFO" "$C_RST" "$sshd_dropin"
                if _ssh_key_present; then
                    printf '%s[drun]%s   PasswordAuthentication no (key found)\n' "$C_INFO" "$C_RST"
                else
                    printf '%s[drun]%s   PasswordAuthentication left alone (no SSH key found)\n' "$C_INFO" "$C_RST"
                fi
            else
                if mkdir -p /etc/ssh/sshd_config.d; then
                    {
                        echo "# Written by ubuntu-post-install. Delete this file to revert."
                        echo "PermitRootLogin prohibit-password"
                        echo "X11Forwarding no"
                        echo "MaxAuthTries 4"
                        echo "ClientAliveInterval 300"
                        echo "ClientAliveCountMax 2"
                        echo "LoginGraceTime 30"
                        if _ssh_key_present; then
                            echo "PasswordAuthentication no"
                        else
                            echo "# PasswordAuthentication kept: no authorized key found"
                        fi
                    } >"$sshd_dropin"
                    chmod 0644 "$sshd_dropin"
                    if have sshd && ! sshd -t >/dev/null 2>&1; then
                        err "sshd -t rejected the new config; removing drop-in to avoid lockout."
                        rm -f "$sshd_dropin"
                        return 1
                    fi
                    ok "ssh hardening drop-in written: ${sshd_dropin}"
                    have systemctl && run systemctl try-restart ssh
                else
                    warn "could not create /etc/ssh/sshd_config.d; skipping ssh hardening."
                fi
            fi
        else
            warn "/etc/ssh not found; no sshd to harden."
        fi
    fi

    # --- Kernel network hardening ---------------------------------------------
    if [ "${UPI_HARDEN_KERNEL:-true}" = true ]; then
        local sysctl_dropin="/etc/sysctl.d/60-upi-hardening.conf"
        if $DRY_RUN; then
            printf '%s[drun]%s write %s (anti-spoofing, no redirects, syncookies)\n' "$C_INFO" "$C_RST" "$sysctl_dropin"
        else
            if mkdir -p /etc/sysctl.d; then
                cat >"$sysctl_dropin" <<'EOF'
# Written by ubuntu-post-install. Delete this file and run
#   sysctl --system
# to revert.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
kernel.dmesg_restrict = 1
EOF
                chmod 0644 "$sysctl_dropin"
                if have sysctl; then
                    if sysctl --system >/dev/null 2>&1; then
                        ok "sysctl hardening applied"
                    else
                        warn "sysctl reload failed; settings apply after reboot."
                    fi
                else
                    warn "sysctl not found; drop-in applies at next boot."
                fi
            fi
        fi
    fi

    # --- Unattended security upgrades -----------------------------------------
    if [ "${UPI_ENABLE_UNATTENDED_UPGRADES:-true}" = true ]; then
        if have apt-get; then
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
            local autof="/etc/apt/apt.conf.d/20auto-upgrades"
            if $DRY_RUN; then
                printf '%s[drun]%s write %s\n' "$C_INFO" "$C_RST" "$autof"
            else
                printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$autof"
                ok "unattended-upgrades enabled"
            fi
        fi
    fi

    # --- fail2ban (optional) ---------------------------------------------------
    if [ "${UPI_INSTALL_FAIL2BAN:-false}" = true ]; then
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
        have systemctl && run systemctl enable fail2ban
    fi
    ok "hardening step finished"
    return 0
}
