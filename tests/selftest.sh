#!/usr/bin/env bash
# selftest.sh - fixture-based assertions for ubuntu-post-install.
# Runs on any OS with bash; needs no Ubuntu, no root, no network.
# Usage: bash tests/selftest.sh   (exit 0 = all checks pass)

set -u
cd "$(dirname "$0")/.." || exit 1

out="$(bash ubuntu-post-install.sh --selftest 2>&1)"
rc=$?
fails=0
pass=0

check() {
    # check <description> <condition-exit-code>
    if [ "$2" -eq 0 ]; then
        echo "PASS: $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1"
        fails=$((fails + 1))
    fi
}

[ "$rc" -eq 0 ]
check "selftest exits 0" "$rc"

# Dry-run confirmations must auto-accept so the printed plan is complete,
# even with piped stdin (curl | bash case).
echo "" | bash -c '. lib/common.sh; DRY_RUN=true; confirm "unit check"' >/dev/null 2>&1
check "confirm auto-accepts in dry-run (piped stdin)" $?

# Catalog entries that ARE in the fixture must be planned for removal.
for p in apport whoopsie popularity-contest landscape-common modemmanager cups; do
    grep -qE "^  ${p}$" <<<"$out"
    check "planned for removal: ${p}" $?
done

# Catalog entries NOT in the fixture must not appear (detection works).
for p in apport-symptoms ubuntu-report cups-browsed mobile-broadband-provider-info; do
    ! grep -qE "^  ${p}$" <<<"$out"
    check "not planned (not installed): ${p}" $?
done

# Snap/cloud and hardening steps must print their dry-run actions.
grep -q "snap remove --purge lxd" <<<"$out"
check "lxd removal planned" $?
grep -q "apt-get purge -y snapd" <<<"$out"
check "snapd purge planned" $?
grep -q "ufw default deny incoming" <<<"$out" || grep -q "ufw not found" <<<"$out"
check "firewall step handled (applied or skipped with warning)" $?

# New steps: MOTD, performance, DNS.
grep -q "motd-news" <<<"$out"
check "MOTD cleanup planned" $?
grep -q "60-upi-performance.conf" <<<"$out"
check "performance tuning planned" $?
grep -q "nofile" <<<"$out"
check "nofile limits planned" $?
! grep -q "DNSOverTLS" <<<"$out"
check "DNS over TLS skipped (encrypt_dns=false default)" $?

# Minimal profile enables harden_dns; its plan must include the drop-in.
out_min="$(bash ubuntu-post-install.sh --selftest --profile minimal 2>&1)"
min_rc=$?
[ "$min_rc" -eq 0 ]
check "minimal-profile selftest exits 0" "$min_rc"
grep -q "DNSOverTLS" <<<"$out_min"
check "DNS over TLS planned under minimal profile" $?
grep -q "00-ubuntu-post-install-debloat.pref" <<<"$out_min"
check "pin_removed planned under minimal profile" $?

# The debloat purge line must contain the full detected set.
grep -q "apt-get purge -y apport" <<<"$out"
check "debloat purge command includes detected packages" $?

# Protected-package guard: bootloader/kernel/init can never be removed.
bash -c '. lib/common.sh
    is_protected grub2 && is_protected grub-efi-amd64-signed \
    && is_protected linux-image-6.14.0-21-generic && is_protected systemd \
    && is_protected ubuntu-server && is_protected ubuntu-desktop-minimal \
    && is_protected linux-generic && is_protected shim-signed \
    && ! is_protected cups && ! is_protected apport'
check "protected set covers grub/kernel/init/metapackages, not catalogs" $?

# The purge guard refuses a cascade that touches protected packages, even
# though the requested package itself is not protected.
bash -c '. lib/common.sh; DRY_RUN=false; ASSUME_YES=false
    apt-get() {
        if [ "${1:-}" = "-s" ]; then
            printf "Remv snapd [1:2.68]\nRemv ubuntu-server [1.601]\nRemv grub2 [2.12]\n"
        fi
    }
    _refuse_if_protected "snapd ubuntu-server grub2" "purge snapd" 2>/dev/null'
rc=$?
if [ "$rc" -eq 0 ]; then rc=1; else rc=0; fi
check "purge guard refuses protected cascade" "$rc"

# Preflight anchors the boot chain (dry-run shows apt-mark manual on the
# kernel/grub/metapackage entries from the fixture).
grep -q "apt-mark manual" <<<"$out"
check "boot chain marked manual in preflight" $?

# Catalog lint rejects protected entries at startup.
tmpd="$(mktemp -d)"; cp -r catalogs "$tmpd/c"; echo "grub2" >>"$tmpd/c/server.common"
UPI_TMP="$tmpd" bash -c '. lib/common.sh; lint_catalogs "$UPI_TMP/c" >/dev/null 2>&1; [ $? -gt 0 ]'
check "catalog lint rejects protected package" $?
rm -rf "$tmpd"

# Option mapping roundtrip (used by config files and the UI alike).
bash -c '. lib/common.sh; . lib/config.sh
    upi_set_option encrypt_dns true && [ "$UPI_ENCRYPT_DNS" = true ] \
    && upi_set_option remove_snapd false && [ "$UPI_REMOVE_SNAPD" = false ]'
check "upi_set_option maps keys to option variables" $?

# Deprecated keep_* keys translate to inverted remove_* keys.
bash -c '. lib/common.sh; . lib/config.sh
    upi_set_option keep_cloudinit true && [ "$UPI_REMOVE_CLOUDINIT" = false ] \
    && upi_set_option keep_avahi false && [ "$UPI_REMOVE_AVAHI" = true ]' 2>/dev/null
check "deprecated keep_* keys translate to remove_* (inverted)" $?

# Removal-first defaults: cloud-init and avahi are planned when installed;
# the pro client is not (remove_pro_client defaults false).
grep -qE "^  cloud-init$" <<<"$out"
check "cloud-init planned for removal by default" $?
grep -qE "^  avahi-daemon$" <<<"$out"
check "avahi planned for removal by default" $?
! grep -qE "^  ubuntu-pro-client$" <<<"$out"
check "ubuntu-pro-client not planned (remove_pro_client=false default)" $?

echo "----"
echo "selftest: ${pass} passed, ${fails} failed"
exit "$fails"
