#!/usr/bin/env bash
# common.sh - shared primitives for ubuntu-post-install.
# Sourced by the entry script and every step module. Not executable on its own.
# Option and state variables below are consumed by sourced step modules.
# shellcheck disable=SC2034

UPI_VERSION="0.4.0"

LOG_FILE="/var/log/ubuntu-post-install.log"
BACKUP_ROOT="/var/backups/ubuntu-post-install"

# Runtime state, set by the entry script before steps run.
# Consumed by the sourcing entry script and step modules.
DRY_RUN=false
ASSUME_YES=false
# shellcheck disable=SC2034
PROFILE="server"
# shellcheck disable=SC2034
CONFIG_FILE=""
# shellcheck disable=SC2034
SELECTED_STEPS=""
UPI_LOG_OK=false
UPI_RUN_TS=""
UBI_VERSION_ID=""

# ---------------------------------------------------------------------------
# Output. Plain ASCII markers so output stays readable over serial consoles.
# ---------------------------------------------------------------------------
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    C_INFO="" ; C_OK=$(tput bold)   ; C_WARN=$(tput bold) ; C_ERR=$(tput bold)
    C_RST=$(tput sgr0)
else
    C_INFO="" ; C_OK="" ; C_WARN="" ; C_ERR="" ; C_RST=""
fi

_upi_log() {
    # Append a line to LOG_FILE when it is writable.
    if $UPI_LOG_OK; then
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null
    fi
}

info() { printf '%s[info]%s %s\n'  "$C_INFO" "$C_RST" "$*"; _upi_log "[info] $*"; }
ok()   { printf '%s[ ok ]%s %s\n'  "$C_OK"   "$C_RST" "$*"; _upi_log "[ ok ] $*"; }
warn() { printf '%s[warn]%s %s\n'  "$C_WARN" "$C_RST" "$*" >&2; _upi_log "[warn] $*"; }
err()  { printf '%s[fail]%s %s\n'  "$C_ERR"  "$C_RST" "$*" >&2; _upi_log "[fail] $*"; }

log_section() {
    printf '%s\n== %s ==%s\n' "$C_OK" "$*" "$C_RST"
    _upi_log "== $* =="
}

# ---------------------------------------------------------------------------
# Logging setup. Root-owned path; fall back to console-only when unwritable
# (for example a non-root --dry-run).
# ---------------------------------------------------------------------------
log_init() {
    UPI_RUN_TS="$(date '+%Y%m%d-%H%M%S')"
    if touch "$LOG_FILE" >/dev/null 2>&1; then
        UPI_LOG_OK=true
        _upi_log "--- ubuntu-post-install v${UPI_VERSION} run started ---"
    else
        UPI_LOG_OK=false
        warn "Cannot write ${LOG_FILE}; logging to console only."
    fi
}

# ---------------------------------------------------------------------------
# Command execution. Every system-mutating command in a step goes through
# run() so --dry-run covers the whole plan.
# ---------------------------------------------------------------------------
run() {
    if $DRY_RUN; then
        printf '%s[drun]%s %s\n' "$C_INFO" "$C_RST" "$*"
        _upi_log "[drun] $*"
        return 0
    fi
    _upi_log "\$ $*"
    "$@"
}

# ---------------------------------------------------------------------------
# Confirmation. --yes or auto=true suppresses the prompt; a non-TTY stdin
# without --yes declines rather than blocking provisioning pipelines.
# ---------------------------------------------------------------------------
confirm() {
    local prompt="$1" reply
    if $ASSUME_YES; then
        return 0
    fi
    # In dry-run nothing executes, so confirmations auto-accept: the printed
    # plan must be complete, not truncated by declined sections.
    if $DRY_RUN; then
        printf '%s[drun]%s (auto-yes in dry-run) %s\n' "$C_INFO" "$C_RST" "$prompt"
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "stdin is not a TTY and --yes was not given; declining: ${prompt}"
        return 1
    fi
    read -r -p "? ${prompt} [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Backups. Files are copied under BACKUP_ROOT/<run-timestamp>/<original-path>.
# docs/REVERT.md documents how to restore from there.
# ---------------------------------------------------------------------------
backup_file() {
    local f="$1" dest
    if [ ! -f "$f" ]; then
        warn "backup: ${f} does not exist; nothing to back up."
        return 0
    fi
    dest="${BACKUP_ROOT}/${UPI_RUN_TS}${f}"
    if $DRY_RUN; then
        printf '%s[drun]%s backup %s -> %s\n' "$C_INFO" "$C_RST" "$f" "$dest"
        return 0
    fi
    if mkdir -p "$(dirname "$dest")" && cp -a "$f" "$dest"; then
        ok "backed up ${f} -> ${dest}"
        return 0
    fi
    err "backup failed for ${f}"
    return 1
}

# ---------------------------------------------------------------------------
# Environment gates and package queries.
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This action needs root. Re-run with sudo, or use --dry-run."
        exit 4
    fi
}

require_ubuntu() {
    # Exit codes: 3 = unsupported OS.
    if [ ! -r /etc/os-release ]; then
        err "/etc/os-release not found. This is not Ubuntu (or not a Linux environment)."
        exit 3
    fi
    # shellcheck disable=SC1091
    . /etc/os-release   # sets ID, VERSION_ID, PRETTY_NAME
    if [ "${ID:-}" != "ubuntu" ]; then
        err "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Only Ubuntu is supported."
        exit 3
    fi
    UBI_VERSION_ID="${VERSION_ID:-unknown}"
    case "$UBI_VERSION_ID" in
        26.04|24.04) info "Ubuntu ${UBI_VERSION_ID} detected: supported." ;;
        *) warn "Ubuntu ${UBI_VERSION_ID} is untested; continuing with best effort." ;;
    esac
}

pkg_installed() {
    # True when dpkg reports the package as installed.
    # In --selftest mode the answer comes from the fixture instead.
    if [ -n "${UPI_FAKE_DPKG:-}" ] && [ -f "$UPI_FAKE_DPKG" ]; then
        grep -qxF "$1" "$UPI_FAKE_DPKG"
        return
    fi
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

installed_packages() {
    # One installed package name per line.
    if [ -n "${UPI_FAKE_DPKG:-}" ] && [ -f "$UPI_FAKE_DPKG" ]; then
        cat "$UPI_FAKE_DPKG"
        return
    fi
    dpkg-query -W -f='${Package}\n' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Options. Built-in defaults; profiles/ and the user config file override
# them (lib/config.sh), and CLI flags override everything.
# ---------------------------------------------------------------------------
UPI_REMOVE_LXD=true
UPI_REMOVE_SNAPD=true
UPI_DISABLE_TELEMETRY=true
UPI_REMOVE_CLOUDINIT=true
UPI_REMOVE_AVAHI=true
UPI_REMOVE_PRO_CLIENT=false
UPI_HARDEN_FIREWALL=true
UPI_HARDEN_SSH=true
UPI_HARDEN_KERNEL=true
UPI_ENCRYPT_DNS=false
UPI_ENABLE_UNATTENDED_UPGRADES=true
UPI_INSTALL_FAIL2BAN=false
UPI_CLEAN_MOTD=true
UPI_TUNE_PERFORMANCE=true
UPI_CAP_JOURNALD=true
UPI_EXTRA_PACKAGES=""
UPI_PIN_REMOVED=false

# ---------------------------------------------------------------------------
# Catalogs. Data files under catalogs/: one package per line, '#' comments.
#   <pkg>      remove when installed
#   opt:<pkg>  remove only when remove_optional=true, subject to keep_* guards
# ---------------------------------------------------------------------------
catalog_entries() {
    # catalog_entries <catalog-file>: print the package names this run targets.
    local file="$1" line pkg
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        pkg="$line"
        case "$pkg" in
            opt:*)
                pkg="${pkg#opt:}"
                # An opt: entry is gated by its own remove_* option; default
                # options remove everything the profile targets.
                case "$pkg" in
                    cloud-init|cloud-guest-utils)
                        [ "${UPI_REMOVE_CLOUDINIT:-true}" = true ] || continue ;;
                    avahi-daemon|avahi-utils)
                        [ "${UPI_REMOVE_AVAHI:-true}" = true ] || continue ;;
                    ubuntu-pro-client|ubuntu-advantage-tools)
                        [ "${UPI_REMOVE_PRO_CLIENT:-false}" = true ] || continue ;;
                esac
                ;;
        esac
        printf '%s\n' "$pkg"
    done <"$file"
}

catalog_set() {
    # catalog_set <catalog-dir> <flavor> <version>: prints existing catalog
    # files for the flavor: <flavor>.common plus <flavor>.<version>.
    local dir="$1" flavor="$2" version="$3"
    [ -f "${dir}/${flavor}.common" ] && printf '%s/%s.common\n' "$dir" "$flavor"
    [ -f "${dir}/${flavor}.${version}" ] && printf '%s/%s.%s\n' "$dir" "$flavor" "$version"
    return 0
}

catalogs_for_profile() {
    # catalogs_for_profile <catalog-dir> <profile> <version>: prints the catalog
    # files a profile loads. server -> server, desktop -> desktop,
    # minimal -> both (aggressive; dedupe belongs to the consuming step).
    local dir="$1" profile="$2" version="$3"
    case "$profile" in
        desktop) catalog_set "$dir" desktop "$version" ;;
        minimal) catalog_set "$dir" server "$version"
                 catalog_set "$dir" desktop "$version" ;;
        *)       catalog_set "$dir" server "$version" ;;
    esac
}

lint_catalogs() {
    # lint_catalogs <catalog-dir>: validate names and cross-file uniqueness.
    # Prints one [fail] line per problem; returns the problem count.
    local dir="$1" f line pkg base
    local -A seen=()
    local problems=0
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ''|'#'*) continue ;;
            esac
            pkg="$line"
            case "$pkg" in
                opt:*) pkg="${pkg#opt:}" ;;
            esac
            if ! [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*[a-z0-9+]$ ]]; then
                err "catalog ${base}: bad package name: ${line}"
                problems=$((problems + 1))
                continue
            fi
            if is_protected "$pkg"; then
                err "catalog ${base}: '${pkg}' is protected (boot/kernel/init); refusing"
                problems=$((problems + 1))
                continue
            fi
            if [ -n "${seen[$pkg]:-}" ]; then
                err "catalog: duplicate '${pkg}' in ${seen[$pkg]} and ${base}"
                problems=$((problems + 1))
            else
                seen["$pkg"]="$base"
            fi
        done <"$f"
    done
    return "$problems"
}

# ---------------------------------------------------------------------------
# Protected packages. Never removed, purged, or autoremoved by this tool.
# Enforced in three layers: catalog lint, purge-plan filter, autoremove guard.
# ---------------------------------------------------------------------------
UPI_PROTECTED_RE='^(grub.*|shim.*|shim-signed|syslinux.*|linux-image.*|linux-generic.*|linux-headers.*|linux-modules.*|systemd|systemd-.*|udev|eudev|bash|dash|coreutils|dpkg|dpkg-.*|apt|apt-.*|sudo|sudo-.*|openssh-server|openssh-sftp-server|openssh-client|ufw|e2fsprogs|e2fsprogs-.*|util-linux|util-linux-.*|mount|libc6|libc-bin|busybox.*|busybox-initramfs|initramfs-tools.*|init-system-helpers|sysvinit-utils|kmod|dbus|dbus-.*|netplan.*|networkd.*|systemd-resolved|resolvconf|firmware.*|fwupd.*|linux-firmware.*|ubuntu-server.*|ubuntu-desktop.*|ubuntu-minimal|ubuntu-standard|ubuntu-cloud.*)$'

is_protected() {
    # True when the package name matches the protected set.
    printf '%s' "$1" | grep -qE "$UPI_PROTECTED_RE"
}

filter_protected() {
    # filter_protected <package-list-on-stdin>: prints names that are NOT
    # protected; protected ones produce a warning.
    local p
    while read -r p; do
        [ -z "$p" ] && continue
        if is_protected "$p"; then
            warn "refusing to remove protected package: ${p}"
        else
            printf '%s\n' "$p"
        fi
    done
}

_sim_removed() {
    # _sim_removed <apt-get args...> : prints packages an apt-get simulation
    # would remove (direct + reverse-dependency cascade), or nothing.
    apt-get -s "$@" 2>/dev/null | awk '/^Remv / {print $2}'
}

_refuse_if_protected() {
    # _refuse_if_protected <sim-list> <label> ; returns 1 (and reports) when
    # the simulated removal touches a protected package.
    local p bad="" list="$1" label="$2"
    for p in $list; do
        is_protected "$p" && bad="${bad} ${p}"
    done
    if [ -n "$bad" ]; then
        err "${label} would remove protected packages (cascade):${bad}"
        err "refused - the boot chain stays intact. Inspect: apt-get -s ${label}"
        return 1
    fi
    return 0
}

safe_purge() {
    # safe_purge <pkg...> : apt-get purge that first SIMULATES and refuses
    # when the reverse-dependency cascade would touch protected packages
    # (kernel, bootloader, init, or the ubuntu-* metapackages that anchor
    # them).
    if $DRY_RUN; then
        run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"
        return 0
    fi
    have apt-get || return 1
    local sim
    sim="$(env DEBIAN_FRONTEND=noninteractive apt-get purge -s "$@" 2>/dev/null | awk '/^Remv / {print $2}')"
    _refuse_if_protected "$sim" "purge $*" || return 1
    env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"
}

safe_upgrade() {
    # safe_upgrade : full-upgrade that refuses when its removal phase would
    # touch protected packages.
    if $DRY_RUN; then
        run env DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
        return 0
    fi
    have apt-get || return 0
    local sim
    sim="$(apt-get -s full-upgrade 2>/dev/null | awk '/^Remv / {print $2}')"
    if ! _refuse_if_protected "$sim" "full-upgrade"; then
        warn "skipping full-upgrade; running upgrade (no removals) instead."
        env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
        return 0
    fi
    env DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
}

protect_boot_chain() {
    # Mark every installed protected package as manually installed, so no
    # autoremove - not ours, not a later manual one - can ever remove the
    # kernel or bootloader, even if a metapackage anchor was already broken.
    local list p marked=0
    list="$(installed_packages | grep -E "$UPI_PROTECTED_RE" || true)"
    [ -n "$list" ] || return 0
    if $DRY_RUN; then
        # shellcheck disable=SC2086  # validated package-name list
        printf '%s[drun]%s apt-mark manual %s\n' "$C_INFO" "$C_RST" "$list"
        return 0
    fi
    have apt-mark || { warn "apt-mark not found; cannot anchor the boot chain."; return 0; }
    for p in $list; do
        apt-mark manual "$p" >/dev/null 2>&1 && marked=$((marked + 1))
    done
    ok "boot chain anchored: ${marked} kernel/boot/meta packages marked manual"
}

safe_autoremove() {
    # apt-get autoremove --purge, but only after a simulation proves that no
    # protected package (bootloader, kernel, init) would be removed.
    if $DRY_RUN; then
        run apt-get autoremove --purge -y
        return 0
    fi
    have apt-get || return 0
    local sim
    sim="$(_sim_removed autoremove --purge)"
    _refuse_if_protected "$sim" "autoremove" || return 0
    apt-get autoremove --purge -y
}

show_banner() {
    log_section "ubuntu-post-install v${UPI_VERSION}"
    info "profile: ${PROFILE}   ubuntu: ${UBI_VERSION_ID:-unknown}   dry-run: ${DRY_RUN}"
}

# ---------------------------------------------------------------------------
# Step-module loading. Step files are named NN-name.sh and define
# step_NN_name() plus STEP_DESC_NN_NAME for the wizard.
# ---------------------------------------------------------------------------
list_steps() {
    local script_dir="$1" f name
    for f in "${script_dir}"/steps/[0-9][0-9]-*.sh; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .sh)"
        printf '%s\n' "$name"
    done
}
