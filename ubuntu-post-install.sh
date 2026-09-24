#!/usr/bin/env bash
# ubuntu-post-install - debloat, harden, and prepare a production Ubuntu system.
# Primary target: Ubuntu Server 26.04 amd64. See README.md for full usage.
#
# Exit codes:
#   0 success
#   1 usage error
#   2 step failure
#   3 unsupported OS
#   4 insufficient privileges

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/ui.sh
. "${SCRIPT_DIR}/lib/ui.sh"

usage() {
    cat <<EOF
ubuntu-post-install v${UPI_VERSION}

Debloat, harden, and prepare a production Ubuntu installation.
Primary target: Ubuntu Server 26.04. Profiles: server (default), desktop, minimal.

Usage:
  $(basename "$0") [options]

Options:
  -h, --help              Show this help and exit.
  --dry-run               Print every action without executing it.
  --yes                   Answer yes to all confirmations (unattended/auto mode).
  --profile <name>        server | desktop | minimal (default: server).
  --steps <spec>          Run only the given steps, e.g. 20,40 or 20-50.
                          Default: all steps in order.
  --config <file>         Read options from a key=value config file
                          (see config.ini.example). CLI flags override it.
  --selftest              Dry-run every step against a fixture package list
                          (tests/); runs on any OS with bash. Exits 0 on pass.

Precedence: built-in defaults < profile < config file < CLI flags.
Behaviour without arguments: interactive confirmation before each destructive
step (whiptail menu when available, console prompts otherwise).
EOF
    exit "${1:-0}"
}

die_usage() {
    err "$1"
    usage 1
}

parse_step_spec() {
    # Expand "20,40-50" into a sorted unique list of numbers. Prints errors to
    # stderr and returns 1 on invalid input.
    local input="$1" part start end i out=""
    local -A seen=()
    IFS=',' read -ra parts <<<"$input"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
            (( start > end )) && { printf 'invalid range: %s\n' "$part" >&2; return 1; }
            for (( i = start; i <= end; i++ )); do
                seen["$i"]=1
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            seen["$part"]=1
        else
            printf "invalid step spec: '%s'\n" "$part" >&2
            return 1
        fi
    done
    for i in $(printf '%s\n' "${!seen[@]}" | sort -n); do
        out+="$i "
    done
    printf '%s' "${out% }"
}

# --- help short-circuit -----------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage 0 ;;
    esac
done

# --- early scan: --profile / --config must be known before loading files ----
PROFILE="server"
CONFIG_FILE=""
prev=""
for arg in "$@"; do
    case "$prev" in
        --profile) PROFILE="$arg" ;;
        --config)  CONFIG_FILE="$arg" ;;
    esac
    prev="$arg"
done

case "$PROFILE" in
    server|desktop|minimal) ;;
    *) die_usage "invalid profile '$PROFILE' (use: server, desktop, minimal)" ;;
esac

# --- option loading: profile, then user config (config overrides profile) ---
PROFILE_FILE="${SCRIPT_DIR}/profiles/${PROFILE}.conf"
[ -f "$PROFILE_FILE" ] || die_usage "profile file missing: $PROFILE_FILE"
load_options_file "$PROFILE_FILE"
if [ -n "$CONFIG_FILE" ]; then
    load_options_file "$CONFIG_FILE"
fi

# --- catalog validation (before the OS gate so broken data is caught early) --
lint_catalogs "${SCRIPT_DIR}/catalogs" || { err "fix catalog files listed above first"; exit 1; }

# --- argument parsing: CLI flags override profile and config ----------------
SELFTEST=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY_RUN=true ;;
        --yes|-y)      ASSUME_YES=true ;;
        --profile)     shift ;;
        --config)      shift ;;
        --selftest)    SELFTEST=true ;;
        --steps)       [ $# -ge 2 ] || die_usage "--steps needs a value (e.g. 20,40-50)"
                       SELECTED_STEPS="$2"; shift ;;
        -h|--help)     usage 0 ;;
        *)             die_usage "unknown argument: $1" ;;
    esac
    shift
done

if [ -n "$SELECTED_STEPS" ]; then
    SELECTED_STEPS="$(parse_step_spec "$SELECTED_STEPS")" || die_usage "bad --steps value"
fi

# --- gates: OS first so non-Ubuntu hosts never reach destructive code -------
# Selftest mode replaces the real system with fixtures: dry-run forced, the
# package database comes from tests/installed-fixture.txt, no root needed.
if $SELFTEST; then
    DRY_RUN=true
    ASSUME_YES=true
    UPI_FAKE_DPKG="${SCRIPT_DIR}/tests/installed-fixture.txt"
    UBI_VERSION_ID="26.04"
    info "selftest: dry-run, fixture package list, profile=${PROFILE}"
else
    require_ubuntu

    if ! $DRY_RUN; then
        require_root
    fi
fi

log_init
show_banner

# --- main menu: interactive configuration (skipped by --steps, --yes, selftest)
if ! $SELFTEST && [ -z "$SELECTED_STEPS" ] && ! $ASSUME_YES; then
    ensure_whiptail
    if main_menu; then
        if [ -n "$SELECTED_STEPS" ]; then
            SELECTED_STEPS="$(parse_step_spec "$SELECTED_STEPS")" \
                || die_usage "menu returned a bad step selection"
        fi
    else
        info "cancelled; nothing to do."
        exit 0
    fi
fi

# --- step execution ---------------------------------------------------------
STEP_FAILURES=0

run_all_steps() {
    local name num want
    local available
    available="$(list_steps "$SCRIPT_DIR")"
    if [ -z "$available" ]; then
        warn "No step modules found in ${SCRIPT_DIR}/steps/."
        return 0
    fi
    for name in $available; do
        num="${name%%-*}"
        if [ -n "$SELECTED_STEPS" ]; then
            want=" $SELECTED_STEPS "
            case "$want" in
                *" $num "*) ;;
                *) info "step ${name}: skipped (--steps selection)"
                   continue ;;
            esac
        fi
        # shellcheck disable=SC1090
        . "${SCRIPT_DIR}/steps/${name}.sh"
        log_section "step ${name}"
        if ! "step_${name}"; then
            err "step ${name} failed"
            STEP_FAILURES=$((STEP_FAILURES + 1))
        fi
    done
}

run_all_steps

if [ "$STEP_FAILURES" -gt 0 ]; then
    err "${STEP_FAILURES} step(s) failed. See ${LOG_FILE}."
    exit 2
fi

$DRY_RUN && ok "Dry run complete. No changes were made."
exit 0
