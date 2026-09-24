# Reverting ubuntu-post-install changes

Every run writes backups to `/var/backups/ubuntu-post-install/<timestamp>/`
and a log to `/var/log/ubuntu-post-install.log`. The package snapshot for a
run lives at `<backup-dir>/installed-packages.txt`.

## Removed packages (step 30)

Purged packages can be reinstalled from the plan the run printed (also in the
log). With `pin_removed=true`:

```bash
sudo rm /etc/apt/preferences.d/00-ubuntu-post-install-debloat.pref
sudo apt-mark unhold <packages>
sudo apt update && sudo apt install <packages>
```

## snapd (step 40)

```bash
sudo rm -f /etc/apt/preferences.d/no-snapd.pref
sudo apt-mark unhold snapd
sudo systemctl unmask snapd.service snapd.socket 2>/dev/null
sudo apt update && sudo apt install snapd
```

Reverting does not restore previously installed snaps; reinstall by hand.

## lxd group membership (step 40)

```bash
sudo gpasswd -a <user> lxd
```

Only re-add members who actually manage containers; lxd group membership is a
known local privilege-escalation path.

## Telemetry (step 40)

Config backups (e.g. `/etc/default/apport`) are in the run's backup
directory. Restore with:

```bash
sudo cp <backup-dir>/etc/default/apport /etc/default/apport
```

## Firewall (step 50)

The previous rules were backed up (`/etc/ufw/user.rules.bak*` plus the run's
backup directory). Options:

```bash
sudo cp <backup-dir>/etc/ufw/user.rules /etc/ufw/user.rules && sudo ufw reload
# or start over:
sudo ufw reset && sudo ufw disable
```

## SSH hardening (step 50)

```bash
sudo rm /etc/ssh/sshd_config.d/50-upi-hardening.conf
sudo sshd -t && sudo systemctl restart ssh
```

## Kernel sysctl hardening (step 50)

```bash
sudo rm /etc/sysctl.d/60-upi-hardening.conf
sudo sysctl --system
```

## unattended-upgrades (step 50)

```bash
sudo rm /etc/apt/apt.conf.d/20auto-upgrades
sudo apt remove unattended-upgrades   # only if you want the package gone
```

## fail2ban (step 50, optional)

```bash
sudo systemctl disable --now fail2ban
sudo apt remove fail2ban
```

## MOTD cleanup (step 45)

```bash
sudo cp <backup-dir>/etc/default/motd-news /etc/default/motd-news
sudo chmod +x /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news
```

## Performance tuning (step 52)

```bash
sudo rm /etc/sysctl.d/60-upi-performance.conf
sudo rm /etc/security/limits.d/20-upi-nofile.conf
sudo sysctl --system
```

New login sessions pick up the old limits again.

## DNS-over-TLS (step 55)

```bash
sudo rm /etc/systemd/resolved.conf.d/10-upi-dot.conf
sudo systemctl restart systemd-resolved
```

If the step failed during the run it already removed the drop-in itself.

## Journal cap (step 60)

```bash
sudo rm /etc/systemd/journald.conf.d/50-upi-cap.conf
sudo systemctl restart systemd-journald
```
