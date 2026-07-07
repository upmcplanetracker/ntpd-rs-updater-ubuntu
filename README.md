Install or upgrade `ntpd-rs` on Ubuntu (targeting 26.04 and later) using a `.deb` package from the official GitHub releases. It safely displaces any other active time daemon (`chrony`, `systemd-timesyncd`, `ntp`, `ntpsec`) and ensures `ntpd-rs` is the sole NTP service.

Background
----------
*   Canonical plans to replace `chrony` with `ntpd-rs` as the default time synchronisation daemon in **Ubuntu 27.04**, aligning with a move toward Rust-based system utilities.
*   The `ntpd-rs` package in the Ubuntu repositories may be outdated; this script always pulls the latest (or a specific) upstream Ubuntu `.deb` release directly from [pendulum-project/ntpd-rs](https://github.com/pendulum-project/ntpd-rs).

Features
--------
*   Downloads and performs basic safety checks on the .deb package:
    *   Verifies the file is a valid Debian package.
    *   Ensures its declared architecture matches the current system.
    *   No cryptographic verification is performed. The script does not check PGP signatures, checksums, or the origin of the downloaded file. However this `README.md` shows you how to pull the `.deb`             from the canonical github source.
*   Disables and purges conflicting time daemons:
    *   `chrony`, `ntp`, `ntpsec` – removed via `apt-get purge`.
    *   `systemd-timesyncd` – stopped, disabled, and masked (it is part of systemd and cannot be purged).
*   Idempotent: running the script with the same version already installed will re-verify the system state and keep competing services disabled without breaking anything.
*   Does **not** compare version numbers – it will install whatever version is supplied via the URL (no minimum-version checks).
*   Includes a dry-run mode (`--dry-run`) to preview all actions.
*   Provides a post-install summary with service status, version info, and a reminder to edit the configuration file.

Requirements
------------
*   Ubuntu 26.04 (or later) with `systemd` and `apt`. Probably works on 25.10 and earlier versions but not tested.
*   `sudo` privileges.
*   Internet access to download the `.deb` package.

Usage
-----
1.  Visit the [ntpd-rs releases page](https://github.com/pendulum-project/ntpd-rs/releases).
2.  Locate the desired release version.
3.  Copy the URL of the `.deb` file that matches your system architecture:
    *   `amd64` for x86-64 systems.
    *   `arm64` for ARM64 systems (e.g., Raspberry Pi 4, AWS Graviton).
4.  Run the script as root:
    
        sudo ./ntp-updater.sh https://github.com/pendulum-project/ntpd-rs/releases/download/v1.9.0/ntpd-rs_1.9.0-1_amd64.deb
    
Optional dry-run:

    sudo ./ntp-updater.sh <url> --dry-run

Security Note
-------------
The script accepts any URL you supply – it does not verify the cryptographic integrity or authenticity of the downloaded package. Always copy the URL directly from the official `ntpd-rs` releases page and, if you need a higher security guarantee, verify the file’s SHA256 checksum against the published release checksums before running the script.

What the Script Does
--------------------
1.  Checks for an existing `ntpd-rs` installation and displays the current version.
2.  Stops, masks, and purges any installed conflicting daemon (`chrony`, `ntp`, `ntpsec`).
3.  Disables and masks `systemd-timesyncd`.
4.  Downloads the provided `.deb`, verifies it, and checks its architecture against the system.
5.  Installs/upgrades `ntpd-rs` using `apt-get`, with an automatic dependency fix‑up if needed.
6.  Unmasks, enables, and restarts the `ntpd-rs` service.
7.  Prints the new version, the binary location, and the service status.
8.  Reminds you to edit `/etc/ntpd-rs/ntp.toml` and to eventually clean up orphaned packages.

After Installation
------------------
Edit the configuration file to add your preferred NTP servers:

    sudo nano /etc/ntpd-rs/ntp.toml

Restart the daemon to apply changes:

    sudo systemctl restart ntpd-rs

Check `ntpd-rs` version:
    `ntp-ctl -v`

Check synchronisation status:

    ntp-ctl status

Notes
-----
*   Running the script with the same version already installed is safe – it will not reinstall the package but will still ensure all competing services remain disabled. This helps defend against an Ubuntu system update accidentally re‑enabling another time daemon.
*   The script removes configuration files of the displaced daemons (e.g., `/etc/chrony/chrony.conf`). If you need those, back them up first.
*   Orphaned dependencies from removed daemons are **not** automatically removed. The script prints a reminder to manually run `apt-get autoremove --purge` after reviewing the list of packages to be removed.

License
-------
This script is provided as-is, without warranty. MIT license. Use at your own risk.
