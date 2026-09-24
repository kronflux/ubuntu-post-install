# ubuntu-post-install

A modular, detection-based script framework that debloats, hardens, and
prepares a production Ubuntu installation — with a primary focus on
**Ubuntu Server 26.04 LTS**, and best-effort support for Ubuntu Desktop,
other flavors, and 24.04+.

Every removal is proposed only for packages that are actually installed,
every configuration change is backed up first, and every change is
reversible. A dry run shows the exact commands before anything executes.

---

## Features

### Debloat — removes what you do not use

- **Detection-based removal.** Catalogs are intersected with the live
  `dpkg` database; nothing is ever purged by wildcard, and packages that
  are not installed are never proposed.
- **Snap cleanup.** Removes the `lxd` snap and strips `lxd` group
  membership (a known local privilege-escalation path). Optionally removes
  every snap, purges `snapd`, then holds and pins it (`Pin-Priority -10`)
  so upgrades cannot pull it back.
- **Telemetry off.** Removes or neutralizes `apport`, `whoopsie`,
  `popularity-contest`, and `ubuntu-report`.
- **Residual cleanup.** `autoremove --purge` plus purging leftover
  `rc`-state package configurations.
- **Optional hold + pin.** With `pin_removed=true`, every package the
  debloat step removed is `apt-mark hold` + pinned at −10, so nothing
  reinstalls it as a dependency.

### Harden — production security baseline

- **Firewall (UFW).** Deny all incoming, allow all outgoing, allow the port
  `sshd` actually listens on (read from `sshd_config`, not assumed 22).
- **SSH.** A drop-in at `/etc/ssh/sshd_config.d/50-upi-hardening.conf`:
  `PermitRootLogin prohibit-password`, `X11Forwarding no`, `MaxAuthTries 4`,
  `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `LoginGraceTime 30`.
  Password authentication is disabled **only** when an authorized key exists
  for root or the invoking user (lockout guard), and `sshd -t` validates the
  result before the service restarts — invalid config removes itself.
- **Kernel network hardening.** sysctl drop-in: reverse-path filtering,
  no ICMP redirects (IPv4 + IPv6), no source routing, syncookies, broadcast
  ICMP ignored, `dmesg` restricted.
- **Automatic security updates.** Enables `unattended-upgrades`.
- **Optional fail2ban.** One config key away, with the default SSH jail.

### Prepare — updates and quality-of-life

- **Full system update** (`apt update`, `full-upgrade`, `autoclean`).
- **MOTD cleanup** — disables `motd-news` and the help-text login banners.
- **Performance tuning** — conservative sysctls (`vm.swappiness=10`,
  `vfs_cache_pressure=50`, TCP BBR + `fq`, `fs.file-max`) and a 65535
  `nofile` limits file.
- **DNS-over-TLS (opt-in)** — switches systemd-resolved upstreams to
  Cloudflare/Quad9 with `DNSOverTLS=yes`, verifies resolution after the
  switch, and self-reverts if lookups fail.
- **Journal size cap** (500 MB persistent journal by default).
- **Extra packages** — define your own install list via config.
- **Package snapshot** of everything installed before the first change,
  plus run logs, kept under `/var/backups/ubuntu-post-install/`.

### Framework — built to be safe and repeatable

- `--dry-run` — print every action, execute nothing (confirmations
  auto-accept so the plan is always complete).
- **Confirm-before-act** by default; `--yes` or `auto=true` for unattended runs.
- **Full whiptail interface** when run without arguments: main menu to choose
  the profile, toggle every option (with a one-line explanation each), select
  steps, preview the dry-run plan, then run. Every confirmation is a dialog
  that states what happens, what is backed up, and how to revert.
  Whiptail is not preinstalled on modern Ubuntu Server; the tool installs it
  on first interactive run (asking first) and states the reason whenever it
  falls back to console mode.
- **Protected-package guard** — bootloader (grub, shim), kernel, init,
  systemd, apt, sudo, SSH, and firewall packages can never be removed by
  this tool: catalog entries are rejected at startup, purge plans are
  filtered, and `autoremove` runs only after a simulation proves no
  protected package would be touched.
- CLI flags and config files for headless operation; console fallback for
  every dialog when whiptail is unavailable.
- **Step selection** — run any subset: `--steps 20,30,50`.
- **Profiles** — `server` (default), `desktop`, `minimal`.
- **Configurable via config file** — every option is a documented key.
- **Idempotent steps** — running twice skips what is already done.
- **Extensible catalogs** — package lists are plain data files.
- **Self-test suite** — `bash tests/selftest.sh` runs fixture-based
  assertions on any OS with bash; no root, no network, no Ubuntu needed.

---

## What gets removed

### Server profile catalog (`catalogs/server.common`)

| Category | Packages |
|---|---|
| Telemetry & crash reporting | `apport`, `apport-symptoms`, `whoopsie`, `popularity-contest`, `ubuntu-report` |
| Management agent | `landscape-common` |
| Modem / mobile broadband | `modemmanager`, `mobile-broadband-provider-info` |
| Printing | `cups`, `cups-browsed` |
| Optional¹ `avahi` | `avahi-daemon`, `avahi-utils` |
| Optional¹ cloud provisioning | `cloud-init`, `cloud-guest-utils` |
| Optional¹ Ubuntu Pro client | `ubuntu-pro-client` |

¹ Gated by their own options: `remove_avahi`, `remove_cloudinit`,
`remove_pro_client`. All except the Pro client default to **on** (removal);
the Pro client stays unless subscribed-away, since ESM/USG/FIPS need it.
`remove_cloudinit` must never be enabled on cloud/VPS images.

### Desktop profile catalog (`catalogs/desktop.common` + `desktop.26.04`)

Mail and office (`thunderbird`, LibreOffice suite), media players (`totem`,
`rhythmbox`, `showtime`), games (`aisleriot`, `gnome-mahjongg`, `gnome-mines`,
`gnome-sudoku`), GNOME extras (`gnome-contacts`, `gnome-weather`, `gnome-maps`,
`simple-scan`, `cheese`, `yelp`, `deja-dup`, `shotwell`, `usb-creator-gtk`,
`snapshot`), P2P/remote clients (`transmission-gtk`, `remmina`).

### Snap layer (step 40)

All installed snaps (content snaps first, base snaps last), then `snapd`
itself — units stopped and masked, package purged, held and pinned at −10.
On desktop profiles, snapd removal defaults off.

Only packages actually present are ever touched, and the `ubuntu-server` /
`ubuntu-desktop` metapackages are never removed directly.

## What gets added or changed

| Change | Where | Revert |
|---|---|---|
| UFW default deny in / allow out / allow SSH port | live ruleset + `user.rules` backup | `docs/REVERT.md` |
| SSH hardening drop-in | `/etc/ssh/sshd_config.d/50-upi-hardening.conf` | delete file |
| Kernel sysctl drop-in | `/etc/sysctl.d/60-upi-hardening.conf` | delete file |
| Unattended upgrades enable | `unattended-upgrades` pkg + `20auto-upgrades` | delete file |
| fail2ban (optional) | package + service enable | remove package |
| Journal cap 500M | `/etc/systemd/journald.conf.d/50-upi-cap.conf` | delete file |
| MOTD news/help off | `/etc/default/motd-news`, `chmod -x` two scripts | revert file + `chmod +x` |
| Performance sysctls | `/etc/sysctl.d/60-upi-performance.conf` | delete file |
| nofile limits | `/etc/security/limits.d/20-upi-nofile.conf` | delete file |
| DNS-over-TLS (opt-in) | `/etc/systemd/resolved.conf.d/10-upi-dot.conf` | delete file + restart |
| snapd hold + pin | `apt-mark` + `/etc/apt/preferences.d/no-snapd.pref` | unhold + delete pin |
| Removed-package holds (optional) | `apt-mark` + `00-ubuntu-post-install-debloat.pref` | unhold + delete pin |

## What you can customize

- **Profiles** — `server` (safe server defaults), `desktop`, `minimal`
  (aggressive: optional packages go too, removals get pinned).
- **Config file keys** (see `config.ini.example`; every boolean is also a
  menu toggle). Naming is action-first — options say what the tool does,
  not what it spares:
  - *Debloat*: `remove_snapd`, `remove_lxd`, `remove_cloudinit` (default on —
    never on cloud/VPS images), `remove_avahi`, `remove_pro_client`,
    `disable_telemetry`, `clean_motd`, `pin_removed`
  - *Harden*: `harden_firewall`, `harden_ssh`, `harden_kernel`,
    `encrypt_dns`, `enable_unattended_upgrades`, `install_fail2ban`
  - *System*: `tune_performance`, `cap_journald`, `extra_packages`
  - *Run control*: `auto`, `dry_run`, `steps`, `profile`
- **Catalogs** — add or remove package names in `catalogs/*.common` and
  `*.26.04`; they are validated (format + uniqueness) at every start.
- **Your own steps** — drop a `NN-name.sh` defining `step_NN-name()` into
  `steps/`; the runner picks it up automatically.

---

## Quick start

One command (clones to `/opt/ubuntu-post-install`, installs git if missing,
then runs the script; arguments pass through):

```bash
curl -fsSL https://raw.githubusercontent.com/kronflux/ubuntu-post-install/main/bootstrap.sh | sudo bash -s -- --dry-run
```

Or clone manually:

```bash
git clone https://github.com/kronflux/ubuntu-post-install.git
cd ubuntu-post-install

# 1. See the full plan without changing anything.
sudo bash ubuntu-post-install.sh --dry-run

# 2. Interactive run: wizard menu, confirmation before each destructive step.
sudo bash ubuntu-post-install.sh

# 3. Unattended server run.
sudo bash ubuntu-post-install.sh --profile server --yes

# 4. Only some steps (see table below).
sudo bash ubuntu-post-install.sh --steps 20,30,50
```

The script needs `lib/`, `steps/`, `catalogs/`, and `profiles/` next to it —
clone the repository; do not pipe a single file from curl.

## Usage

```
ubuntu-post-install.sh [--dry-run] [--yes] [--profile server|desktop|minimal]
                       [--steps SPEC] [--config FILE] [--selftest] [--help]
```

Precedence: built-in defaults < profile < config file < CLI flags.
Exit codes: `0` success · `1` usage error · `2` step failure ·
`3` unsupported OS · `4` insufficient privileges.

### Steps

| # | Step | Action |
|---|------|--------|
| 10 | preflight | detect server/desktop flavor, snapshot installed packages, check disk space |
| 20 | update | `apt update`, `full-upgrade`, `autoclean` |
| 30 | debloat | catalog ∩ installed → confirm → purge → autoremove → residual-config cleanup |
| 40 | snap/cloud | lxd snap + group membership, optional full snapd purge (hold + pin), telemetry off |
| 45 | motd | disable motd-news and help-text login banners |
| 50 | harden | UFW, sshd drop-in, sysctl drop-in, unattended-upgrades, optional fail2ban |
| 52 | performance | swappiness, vfs cache pressure, BBR, `nofile` limits |
| 55 | dns (opt-in) | DNS-over-TLS via systemd-resolved, with self-revert on failure |
| 60 | customize | journal cap, optional extra packages |

## Safety model

1. **Dry-run first.** `--dry-run` prints every command; nothing executes.
   Confirmations auto-accept in dry-run so the printed plan is always
   complete.
2. **Detection before removal.** Catalogs are intersected with the live
   package database; absent packages are never acted on.
3. **Protected packages.** Bootloader, kernel, init, and core system
   packages are refused at the catalog, plan, and autoremove layers —
   the tool cannot remove the ability to boot.
4. **Backups before edits.** UFW rules, `sshd_config`, `/etc/default/apport`
   are copied to `/var/backups/ubuntu-post-install/<timestamp>/` first.
5. **Lockout guards.** SSH password auth survives unless a key exists;
   `sshd -t` must accept the new config or the drop-in removes itself;
   UFW opens the real SSH port before enabling deny-incoming.
6. **Reversible.** `docs/REVERT.md` documents the undo for every action.
7. **Idempotent.** Re-runs skip what is already done.

## Testing

```bash
bash tests/selftest.sh    # 15 fixture assertions; any OS with bash, no root
```

For real hardware: disposable VM, `--dry-run`, full run, then a re-run to
confirm idempotence — before touching production.

## Compatibility

- **Primary target:** Ubuntu Server 26.04 LTS (amd64).
- **Supported:** 24.04 LTS and later, Server and Desktop.
- **Untested:** older LTS releases, Ubuntu flavors, ARM, WSL, containers
  without systemd (steps degrade with warnings; dry-run works).

## Limitations

- Catalogs are compiled from reference projects; review the dry-run plan
  against your `dpkg -l` before an unattended run.
- Firewall hardening uses UFW only (`harden_firewall=false` to skip).
- DNS-over-TLS is opt-in (`encrypt_dns=true`): it changes name resolution
  and may not suit networks with internal DNS requirements.
- `minimal` removes `cloud-init` — never use it on cloud-provisioned machines.

## License

[MIT](LICENSE) — Copyright (c) 2026 kronflux.
