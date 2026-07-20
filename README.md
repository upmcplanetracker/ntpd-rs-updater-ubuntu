# ntpd-rs Updater for Ubuntu

Install or upgrade `ntpd-rs` on Ubuntu (targeting 26.04 and later) using a `.deb` package from the official GitHub releases. It safely displaces any other active time daemon (`chrony`, `systemd-timesyncd`, `ntp`, `ntpsec`, `openntpd`, `linuxptp`, `ntpdate`, `tlsdate`) and ensures `ntpd-rs` is the sole NTP/NTS service.

## Background

- Canonical plans to replace `chrony` with `ntpd-rs` as the default time synchronization daemon in **Ubuntu 27.04**, aligning with a move toward Rust-based system utilities. Like `chrony`, `ntpd-rs` does both NTS and NTP, but is more memory safe being written in Rust vs. `chrony` in C.
- The `ntpd-rs` package in the **Ubuntu 26.04** repositories (1.7.0) is outdated; this script pulls a specific upstream Ubuntu `.deb` release directly from [pendulum-project/ntpd-rs](https://github.com/pendulum-project/ntpd-rs). The assumption is that you want to upgrade to a newer version, but conceivably this script could let you change to any version.

## Features

- Downloads and performs basic safety checks on the .deb package:
    - Verifies the file is a valid Debian package.
    - Ensures its declared architecture matches the current system.
    - Optionally verifies the SHA256 checksum if you provide it (`--sha256`).
- Disables conflicting time daemons:
    - `chrony`, `ntp`, `ntpsec`, `openntpd`, `linuxptp` are stopped, masked, and removed via `apt-get remove` (after confirmation unless `--force` is used). `remove` is used instead of `purge` to avoid triggering Ubuntu's dependency resolver to auto-install a replacement timekeeper (i.e., avoids Ubuntu timekeeper whack-a-mole).
    - Residual configs of removed packages are purged.
    - `systemd-timesyncd` is stopped, disabled, and masked (it is part of systemd and cannot be purged).
    - `ntpdate`, `tlsdate` are removed if present.
    - Orphaned `/etc/cron.daily/ntpdate` cron job is removed if present.
- Idempotent: running the script with the same version already installed is safe — it will re-verify the system state and keep competing services disabled without breaking anything.
- Does **not** compare version numbers – it will install whatever version is supplied via the URL (no minimum-version checks).
- Includes a dry-run mode (`--dry-run`) to preview all actions.
- Provides a post-install summary with service status, version info, and a reminder to edit the configuration file.

## Requirements

- Ubuntu 26.04 (or later) with `systemd` and `apt`. Probably works on 25.10 and earlier versions but not tested.
- `sudo` privileges.
- Internet access to download the `.deb` package.
- `wget` or `curl`, `dpkg-deb`, and `fuser` (usually from `psmisc`) (all are usually present on Ubuntu).

## Usage

1. Pull the script:  
   `wget https://raw.githubusercontent.com/upmcplanetracker/ntpd-rs-updater-ubuntu/main/ntpd-rs`
2. Make it executable:  
   `chmod +x ./ntpd-rs`
3. Visit the [ntpd-rs releases page](https://github.com/pendulum-project/ntpd-rs/releases).
4. Locate the desired release version.
5. Copy the URL of the `.deb` file that matches your system architecture:
    - `amd64` for x86-64/AMD64 systems.
    - `arm64` for ARM64 systems (e.g., Raspberry Pi 4, AWS Graviton).
    - Example: `https://github.com/pendulum-project/ntpd-rs/releases/download/v1.9.0/ntpd-rs_1.9.0-1_amd64.deb`
6. Run the script as root (it will ask for confirmation before removing other services):  
   `sudo ./ntpd-rs https://github.com/pendulum-project/ntpd-rs/releases/download/v1.9.0/ntpd-rs_1.9.0-1_amd64.deb`

Optional: skip the confirmation prompt with `--force` (use with caution):  
`sudo ./ntpd-rs <url> --force`

Optional dry-run (shows actions without making changes):  
`sudo ./ntpd-rs <url> --dry-run`

Optional SHA256 verification (recommended for security):  
`sudo ./ntpd-rs <url> --sha256 <expected-hash>`

Optional verbose output (shows all commands being executed):  
`sudo ./ntpd-rs <url> --verbose`

## Security Note

The script accepts any URL you supply – it does **not** verify the cryptographic integrity or authenticity of the downloaded package unless you provide the `--sha256` option. Always copy the URL directly from the official `ntpd-rs` releases page. To verify the file:

1. Download the `.deb` manually.
2. Compute its SHA256: `sha256sum ntpd-rs_*.deb`
3. Compare with the published checksum (if provided) and then run the script with `--sha256 <hash>`.

## What the Script Does

1. Checks for an existing `ntpd-rs` installation and displays the current version.
2. **Asks for confirmation** (unless `--force` is given) before handling conflicting daemons.
3. Stops, masks, and removes any installed conflicting daemon (`chrony`, `ntp`, `ntpsec`, `openntpd`, `linuxptp`). Uses `apt-get remove` (not `purge`) for active packages to avoid triggering Ubuntu's auto-install of a replacement timekeeper. Purges only residual configs.
4. Removes non-service timekeepers (`ntpdate`, `tlsdate`) and cleans up orphaned cron jobs.
5. Disables and masks `systemd-timesyncd`.
6. Downloads the provided `.deb`, verifies it, and checks its architecture against the system.
7. Optionally verifies the SHA256 checksum.
8. Installs/upgrades `ntpd-rs` using `apt-get`, with an automatic dependency fix‑up if needed.
9. Unmasks, enables, and restarts the `ntpd-rs` service. Also enables `ntpd-rs-metrics.service` if present and not static.
10. Prints the new version (via `ntp-ctl --version`), service status, and configuration reminders.

## After Installation

Edit the configuration file to add your preferred NTP servers:  
`sudo nano /etc/ntpd-rs/ntp.toml`

Validate changes to the configuration file:  
`ntp-ctl validate`

Restart the daemon to apply changes:  
`sudo systemctl restart ntpd-rs`

Check `ntpd-rs` version:  
`ntp-ctl -v` or `ntp-ctl --version`

Check synchronization status:  
`ntp-ctl status`

## Troubleshooting

- **Service fails to start**: Check logs with `sudo journalctl -u ntpd-rs -n 50`. Common issues include configuration errors or port conflicts (port 123 is already in use).
- **`apt` lock error**: The script retries up to 5 times with 5-second delays. If it persists, wait for other package managers to finish, or reboot.
- **Download fails**: Ensure the URL is correct and accessible. Try with `curl` or `wget` manually.
- **Architecture mismatch**: Make sure you download the `.deb` that matches your system (e.g., `amd64` for x86_64, `arm64` for ARM).
- **Checksum mismatch**: Re‑download the file or verify the expected hash from the official release notes.
- **`_apt` sandbox warning**: Fixed by making the temp directory readable to the `_apt` user during install.

## Notes

- Running the script with the same version already installed is safe – it will not reinstall the package but will still ensure all competing services remain disabled. This helps defend against an Ubuntu system update accidentally re‑enabling another time daemon.
- The script removes configuration files of the displaced daemons only when purging residual configs. If you need those, back them up first.
- Orphaned dependencies from removed daemons are **not** automatically removed. The script prints a reminder to manually run `sudo apt-get autoremove --purge` after reviewing the list of packages to be removed.
- The actual daemon binary is `ntp-daemon` (not `ntpd-rs`). The control utility is `ntp-ctl`.

## License

This script is provided as-is, without warranty. MIT license. Use at your own risk.
