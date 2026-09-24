#!/usr/bin/env bash
# 52-performance - conservative performance tuning.
# sysctl drop-in (swappiness, vfs cache pressure, BBR, file-max) plus a
# nofile limits file. All values are widely-used defaults, none are
# workload-specific; revert by deleting the two files.

step_52-performance() {
    if [ "${UPI_TUNE_PERFORMANCE:-true}" != true ]; then
        return 0
    fi

    local sysctl_dropin="/etc/sysctl.d/60-upi-performance.conf"
    if $DRY_RUN; then
        printf '%s[drun]%s write %s (swappiness=10, vfs_cache_pressure=50, BBR, file-max)\n' \
            "$C_INFO" "$C_RST" "$sysctl_dropin"
    else
        if mkdir -p /etc/sysctl.d; then
            cat >"$sysctl_dropin" <<'EOF'
# Written by ubuntu-post-install. Delete this file and run
#   sysctl --system
# to revert.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 2097152
EOF
            chmod 0644 "$sysctl_dropin"
            if have sysctl; then
                # BBR may be unavailable (module not loaded on some kernels);
                # a failed reload leaves the file for the next boot.
                if sysctl --system >/dev/null 2>&1; then
                    ok "performance sysctls applied"
                else
                    warn "sysctl reload reported errors (BBR may be unavailable); applied at next boot."
                fi
            fi
        fi
    fi

    local limits="/etc/security/limits.d/20-upi-nofile.conf"
    if $DRY_RUN; then
        printf '%s[drun]%s write %s (nofile soft/hard 65535)\n' "$C_INFO" "$C_RST" "$limits"
    else
        if mkdir -p /etc/security/limits.d; then
            cat >"$limits" <<'EOF'
# Written by ubuntu-post-install. Delete this file to revert.
* soft nofile 65535
* hard nofile 65535
EOF
            chmod 0644 "$limits"
            ok "nofile limits written: ${limits}"
        fi
    fi
    ok "performance tuning finished"
    return 0
}
