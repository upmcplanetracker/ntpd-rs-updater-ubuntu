#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
DEB_URL=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            echo "Usage: ${SCRIPT_NAME} <url-to-ntpd-rs-deb-package> [--dry-run]"
            exit 0
            ;;
        *)
            if [ -z "$DEB_URL" ]; then
                DEB_URL="$arg"
            fi
            ;;
    esac
done

if [ -z "$DEB_URL" ]; then
    echo "Error: Missing package URL."
    echo "Usage: ${SCRIPT_NAME} <url-to-ntpd-rs-deb-package> [--dry-run]"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script with sudo."
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN MODE — no changes will be made."
fi

run() {
    if [ "$DRY_RUN" -eq 0 ]; then
        "$@"
    else
        echo "   (dry-run: would run: $*)"
    fi
}

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
DEB_FILE="${TEMP_DIR}/ntpd-rs_latest.deb"

echo "=================================================="
echo " ${SCRIPT_NAME} — ntpd-rs Update/Installation Utility"
echo "=================================================="

if dpkg-query -W -f='${Status}' ntpd-rs 2>/dev/null | grep -q "install ok installed"; then
    OLD_VER=$(dpkg-query -W -f='${Version}' ntpd-rs 2>/dev/null)
else
    OLD_VER="not installed"
fi
echo "Currently installed ntpd-rs version: ${OLD_VER}"

CONFLICTING_DAEMONS=("chrony" "ntpsec" "ntp")
echo "Checking for dpkg-tracked conflicting time daemons..."
for daemon in "${CONFLICTING_DAEMONS[@]}"; do
    STATE=$(dpkg-query -W -f='${Status}' "$daemon" 2>/dev/null || echo "")
    case "$STATE" in
        "install ok installed")
            echo "   -> $daemon is installed and active. Neutralizing (config files will be purged)..."
            if [ "$DRY_RUN" -eq 0 ]; then
                systemctl stop "$daemon" 2>/dev/null || true
                systemctl mask "$daemon" 2>/dev/null || true
                apt-get purge -y "$daemon"
            else
                echo "      (dry-run: would stop, mask, and purge $daemon)"
            fi
            ;;
        *"config-files"*|*"deinstall"*)
            echo "   -> $daemon has residual config. Purging..."
            if [ "$DRY_RUN" -eq 0 ]; then
                apt-get purge -y "$daemon"
            else
                echo "      (dry-run: would purge residual config for $daemon)"
            fi
            ;;
        *)
            echo "   -> $daemon not present. Skipping."
            ;;
    esac
done

echo "Neutralizing systemd-timesyncd (bundled with systemd, not dpkg-purgeable)..."
if [ "$DRY_RUN" -eq 0 ]; then
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true
    systemctl mask systemd-timesyncd 2>/dev/null || true
else
    echo "   (dry-run: would stop, disable, and mask systemd-timesyncd)"
fi

echo "Downloading package from: ${DEB_URL}"
if [ "$DRY_RUN" -eq 0 ]; then
    if ! wget -q -O "$DEB_FILE" "$DEB_URL"; then
        echo "Error: Failed to download the package from the provided URL."
        exit 1
    fi

    if ! dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1; then
        echo "Error: Downloaded file is not a valid .deb package."
        echo "   Check that the URL points directly at a .deb release asset."
        exit 1
    fi

    DEB_ARCH=$(dpkg-deb -f "$DEB_FILE" Architecture)
    SYS_ARCH=$(dpkg --print-architecture)
    if [ "$DEB_ARCH" != "$SYS_ARCH" ] && [ "$DEB_ARCH" != "all" ]; then
        echo "Error: Architecture mismatch — package is '${DEB_ARCH}', system is '${SYS_ARCH}'."
        exit 1
    fi

    NEW_VER=$(dpkg-deb -f "$DEB_FILE" Version)
    echo "   -> Validated package. Architecture: ${DEB_ARCH}. Candidate version: ${NEW_VER}"

    chmod a+rX "$TEMP_DIR"
else
    echo "   (dry-run: would download, validate, and architecture-check $DEB_URL)"
fi

echo "Installing/upgrading ntpd-rs..."
if [ "$DRY_RUN" -eq 0 ]; then
    if ! apt-get install -y "$DEB_FILE"; then
        echo "Initial install failed, attempting dependency fix-up..."
        apt-get install -f -y
        apt-get install -y "$DEB_FILE"
    fi
else
    echo "   (dry-run: would run apt-get install -y <downloaded .deb>)"
fi

echo "Enabling and restarting ntpd-rs..."
run systemctl daemon-reload
run systemctl unmask ntpd-rs        2>/dev/null || true
run systemctl enable ntpd-rs         2>/dev/null || true
run systemctl restart ntpd-rs

echo "=================================================="
echo " Verification"
echo "=================================================="

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete. No changes were made."
    exit 0
fi

FINAL_VER="not installed"
if dpkg-query -W -f='${Status}' ntpd-rs 2>/dev/null | grep -q "install ok installed"; then
    FINAL_VER=$(dpkg-query -W -f='${Version}' ntpd-rs 2>/dev/null)
fi
echo "Version: ${OLD_VER} -> ${FINAL_VER}"

BIN_PATH=""
for candidate in ntpd-rsd ntpd-rs; do
    MATCH=$(dpkg -L ntpd-rs 2>/dev/null | grep -E "/s?bin/${candidate}\$" | head -n1 || echo "")
    if [ -n "$MATCH" ]; then
        BIN_PATH="$MATCH"
        break
    fi
done
if [ -z "$BIN_PATH" ]; then
    BIN_PATH=$(dpkg -L ntpd-rs 2>/dev/null | grep -E '/(usr/)?s?bin/' | head -n1 || echo "")
fi

if [ -n "$BIN_PATH" ] && [ -x "$BIN_PATH" ]; then
    echo -e "\nBinary (${BIN_PATH}) version:"
    "$BIN_PATH" --version 2>/dev/null || "$BIN_PATH" -v 2>/dev/null || echo "Binary exists but --version failed."
else
    echo "Could not resolve an ntpd-rs binary from the installed package's file list."
fi

echo -e "\nService status:"
if systemctl is-active --quiet ntpd-rs; then
    echo "ntpd-rs is active and running."
else
    echo "ntpd-rs failed to start. Check: journalctl -u ntpd-rs -n 50"
fi

echo ""
echo "────────────────────────────────────────────────────"
echo " Configuration"
echo "────────────────────────────────────────────────────"
echo "Edit the configuration file to set your preferred servers:"
echo "    ${EDITOR:-nano} /etc/ntpd-rs/ntp.toml"
echo ""
echo "After editing, restart the daemon:"
echo "    sudo systemctl restart ntpd-rs"
echo ""
echo "To see current synchronization status:"
echo "    ntp-ctl status"
echo "────────────────────────────────────────────────────"

echo ""
echo " Note: displaced daemons may have left orphaned dependency packages."
echo " Review before removing — some libs may still be used elsewhere:"
echo "   apt-get autoremove --purge"
