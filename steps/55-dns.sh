#!/usr/bin/env bash
# 55-dns - DNS-over-TLS via systemd-resolved (opt-in: harden_dns=true).
# Switches upstream resolvers to Cloudflare and Quad9 with DNSOverTLS=yes.
# Verifies resolution after the switch and self-reverts on failure.

step_55-dns() {
    if [ "${UPI_ENCRYPT_DNS:-false}" != true ]; then
        return 0
    fi

    if ! have resolvectl || ! have systemctl; then
        if $DRY_RUN; then
            warn "systemd-resolved not found on this host; showing the plan anyway."
        else
            warn "systemd-resolved (resolvectl) not found; skipping DNS hardening."
            return 0
        fi
    fi
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null && ! $DRY_RUN; then
        warn "systemd-resolved is not active; skipping DNS hardening."
        return 0
    fi

    ui_confirm "DNS-over-TLS" \
"Encrypt DNS by switching systemd-resolved to Cloudflare and Quad9?

- Your resolvers change to 1.1.1.1 and 9.9.9.9 over TLS.
- Hostnames resolve through those providers afterwards.
- The step verifies lookups and reverts itself if resolution breaks.
- Networks with internal DNS zones should keep this off." \
        || { info "DNS hardening declined; skipping."; return 0; }

    local dropin="/etc/systemd/resolved.conf.d/10-upi-dot.conf"
    if $DRY_RUN; then
        printf '%s[drun]%s write %s (DNSOverTLS=yes, Cloudflare + Quad9)\n' "$C_INFO" "$C_RST" "$dropin"
        printf '%s[drun]%s systemctl restart systemd-resolved\n' "$C_INFO" "$C_RST"
        return 0
    fi

    if ! mkdir -p /etc/systemd/resolved.conf.d; then
        err "cannot create /etc/systemd/resolved.conf.d"
        return 1
    fi
    cat >"$dropin" <<'EOF'
# Written by ubuntu-post-install. Delete this file, then run
#   systemctl restart systemd-resolved
# to revert.
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net 2620:fe::9#dns.quad9.net
FallbackDNS=1.0.0.1#cloudflare-dns.com 149.112.112.112#dns.quad9.net
DNSOverTLS=yes
EOF
    chmod 0644 "$dropin"

    # Verify: restart, then resolve a name. Failure removes the drop-in again
    # so the machine is never left without working DNS.
    systemctl restart systemd-resolved
    sleep 2
    if resolvectl query github.com >/dev/null 2>&1; then
        ok "DNS-over-TLS active: ${dropin}"
    else
        err "resolution failed after switch; reverting ${dropin}"
        rm -f "$dropin"
        systemctl restart systemd-resolved
        return 1
    fi
    return 0
}
