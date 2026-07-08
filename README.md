# ntpd-rs Updater for Ubuntu
============================

Install or upgrade `ntpd-rs` on Ubuntu (targeting 26.04 and later) using a `.deb` package from the official GitHub releases. It safely displaces any other active time daemon (`chrony`, `systemd-timesyncd`, `ntp`, `ntpsec`) and ensures `ntpd-rs` is the sole NTP/NTS service.

## Background

- Canonical plans to replace `chrony` with `ntpd-rs` as the default time synchronization daemon in **Ubuntu 27.04**, aligning with a move toward Rust-based system utilities. Like `chrony`, `ntpd-rs` does both NTS and NTP, but is more memory safe being written in Rust vs. `chrony` in C.
- The `ntpd-rs` package in the **Ubuntu 26.04** repositories (1.7.0) is outdated; this script always pulls the latest (or a specific) upstream Ubuntu `.deb` release directly from [pendulum-project/ntpd-rs](https://github.com/pendulum-project/ntpd-rs).

## Features

- Downloads and performs basic safety checks on the .deb package:
    - Verifies the file is a valid Debian package.
    - Ensures its declared architecture matches the current system.
    - Optionally verifies the SHA256 checksum if you provide it (`--sha256`).
- Disables and purges conflicting time daemons:
    - `chrony`, `ntp`, `ntpsec` are removed via `apt-get purge` (after confirmation unless `--force` is used).
    - `systemd-timesyncd` is stopped, disabled, and masked (it is part of systemd and cannot be purged).
- Idempotent: running the script with the same version already installed will re-verify the system state and keep competing services disabled without breaking anything.
- Does **not** compare version numbers – it will install whatever version is supplied via the URL (no minimum-version checks).
- Includes a dry-run mode (`--dry-run`) to preview all actions.
- Provides a post-install summary with service status, version info, and a reminder to edit the configuration file.

## Requirements

- Ubuntu 26.04 (or later) with `systemd` and `apt`. Probably works on 25.10 and earlier versions but not tested.
- `sudo` privileges.
- Internet access to download the `.deb` package.
- `wget` or `curl` and `dpkg-deb` (all are usually present on Ubuntu).

## Usage

1. Pull the script:  
   `wget https://raw.githubusercontent.com/upmcplanetracker/ntpd-rs-updater-ubuntu/main/ntp-updater.sh`
2. Make it executable:  
   `chmod +x ./ntp-updater.sh`
3. Visit the [ntpd-rs releases page](https://github.com/pendulum-project/ntpd-rs/releases).
4. Locate the desired release version.
5. Copy the URL of the `.deb` file that matches your system architecture:
    - `amd64` for x86-64 systems.
    - `arm64` for ARM64 systems (e.g., Raspberry Pi 4, AWS Graviton).
    - Example: `https://github.com/pendulum-project/ntpd-rs/releases/download/v1.9.0/ntpd-rs_1.9.0-1_amd64.deb`
6. Run the script as root (it will ask for confirmation before purging other services):  
   `sudo ./ntp-updater.sh https://github.com/pendulum-project/ntpd-rs/releases/download/v1.9.0/ntpd-rs_1.9.0-1_amd64.deb`

Optional: skip the confirmation prompt with `--force` (use with caution):  
`sudo ./ntp-updater.sh <url> --force`

Optional dry-run (shows actions without making changes):  
`sudo ./ntp-updater.sh <url> --dry-run`

Optional SHA256 verification (recommended for security):  
`sudo ./ntp-updater.sh <url> --sha256 <expected-hash>`

## Security Note

The script accepts any URL you supply – it does **not** verify the cryptographic integrity or authenticity of the downloaded package unless you provide the `--sha256` option. Always copy the URL directly from the official `ntpd-rs` releases page. To verify the file:

1. Download the `.deb` manually.
2. Compute its SHA256: `sha256sum ntpd-rs_*.deb`
3. Compare with the published checksum (if provided) and then run the script with `--sha256 <hash>`.

## What the Script Does

1. Checks for an existing `ntpd-rs` installation and displays the current version.
2. **Asks for confirmation** (unless `--force` is given) before purging conflicting daemons.
3. Stops, masks, and purges any installed conflicting daemon (`chrony`, `ntp`, `ntpsec`).
4. Disables and masks `systemd-timesyncd`.
5. Downloads the provided `.deb`, verifies it, and checks its architecture against the system.
6. Optionally verifies the SHA256 checksum.
7. Installs/upgrades `ntpd-rs` using `apt-get`, with an automatic dependency fix‑up if needed.
8. Unmasks, enables, and restarts the `ntpd-rs` service.
9. Prints the new version, the binary location, and the service status.
10. Reminds you to edit `/etc/ntpd-rs/ntp.toml` and to eventually clean up orphaned packages.

## After Installation

Edit the configuration file to add your preferred NTP servers:  
`sudo nano /etc/ntpd-rs/ntp.toml`

Restart the daemon to apply changes:  
`sudo systemctl restart ntpd-rs`

Check `ntpd-rs` version:  
`ntp-ctl -v`

Check synchronization status:  
`ntp-ctl status`

Validate changes to the configuration file:  
`ntp-ctl validate`

## Troubleshooting

- **Service fails to start**: Check logs with `sudo journalctl -u ntpd-rs -n 50`. Common issues include configuration errors or port conflicts (port 123 is already in use).
- **`apt` lock error**: Wait for other package managers to finish, or reboot if the lock persists.
- **Download fails**: Ensure the URL is correct and accessible. Try with `curl` or `wget` manually.
- **Architecture mismatch**: Make sure you download the `.deb` that matches your system (e.g., `amd64` for x86_64, `arm64` for ARM).
- **Checksum mismatch**: Re‑download the file or verify the expected hash from the official release notes.

## Notes

- Running the script with the same version already installed is safe – it will not reinstall the package but will still ensure all competing services remain disabled. This helps defend against an Ubuntu system update accidentally re‑enabling another time daemon.
- The script removes configuration files of the displaced daemons (e.g., `/etc/chrony/chrony.conf`). If you need those, back them up first.
- Orphaned dependencies from removed daemons are **not** automatically removed. The script prints a reminder to manually run `sudo apt-get autoremove --purge` after reviewing the list of packages to be removed.

## License

This script is provided as-is, without warranty. MIT license. Use at your own risk.
