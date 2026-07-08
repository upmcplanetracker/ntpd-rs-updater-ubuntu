#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
DEB_URL=""
FORCE=0
SHA256_EXPECTED=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --sha256)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --sha256 requires a hash argument."
                exit 1
            fi
            SHA256_EXPECTED="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: ${SCRIPT_NAME} <url-to-ntpd-rs-deb-package> [options]

Options:
    --dry-run          Show what would be done without making changes.
    --force            Skip confirmation before purging conflicting daemons.
    --sha256 <hash>    Verify the downloaded .deb against this SHA256 checksum.

Example:
    sudo ${SCRIPT_NAME} https://github.com/pendulum-project/ntpd-rs/releases/download/v1.9.0/ntpd-rs_1.9.0-1_amd64.deb --sha256 abc123...
EOF
            exit 0
            ;;
        *)
            if [[ -z "$DEB_URL" ]]; then
                DEB_URL="$1"
            else
                echo "Error: Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate URL
if [[ -z "$DEB_URL" ]]; then
    echo "Error: Missing package URL."
    echo "Usage: ${SCRIPT_NAME} <url> [--dry-run] [--force] [--sha256 <hash>]"
    exit 1
fi

# Check for root
if [[ "$EUID" -ne 0 ]]; then
    echo "Error: Please run this script with sudo."
    exit 1
fi

# Dry-run banner
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY RUN MODE — no changes will be made."
fi

# Helper to run commands with dry-run support
run() {
    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$@"
    else
        # Quote arguments for display
        printf "   (dry-run: would run:"
        for arg in "$@"; do
            printf " '%s'" "$arg"
        done
        printf ")\n"
    fi
}

# Check for required tools
for tool in wget curl dpkg-deb; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: $tool is not installed. Please install it and try again."
        exit 1
    fi
done

# Use wget or curl
download_file() {
    local url="$1" output="$2"
    if command -v wget &>/dev/null; then
        wget -q -O "$output" "$url"
    else
        curl -s -o "$output" "$url"
    fi
}

# Check for apt lock
# Check for apt lock with a retry mechanism
check_apt_lock() {
    local max_retries=5
    local count=0
    local lock_files=("/var/lib/dpkg/lock" "/var/lib/apt/lists/lock" "/var/cache/apt/archives/lock")

    while [ $count -lt $max_retries ]; do
        local locked=0
        for lock in "${lock_files[@]}"; do
            if [[ -f "$lock" ]]; then
                if lsof "$lock" &>/dev/null || pgrep -x "apt|dpkg" &>/dev/null; then
                    locked=1
                    break
                fi
            fi
        done

        if [ $locked -eq 0 ]; then
            return 0
        fi

        echo "Apt/dpkg lock detected. Retrying in 5 seconds... ($((count+1))/$max_retries)"
        sleep 5
        count=$((count + 1))
    done

    echo "Error: Timed out waiting for apt/dpkg lock. Please close other package managers and try again."
    exit 1
}

# Confirmation for purging
confirm_purge() {
    if [[ "$FORCE" -eq 1 ]] || [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    echo "WARNING: This script will purge conflicting time daemons (chrony, ntp, ntpsec) and mask systemd-timesyncd."
    echo "Their configuration files will be removed. If you need them, back up first."
    read -p "Proceed? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted by user."
        exit 0
    fi
}

# Main
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
DEB_FILE="${TEMP_DIR}/ntpd-rs_latest.deb"

echo "=================================================="
echo " ${SCRIPT_NAME} — ntpd-rs Update/Installation Utility"
echo "=================================================="

# Get current version
CURRENT_STATUS="$(dpkg-query -W -f='${Status}' ntpd-rs 2>/dev/null || true)"
if grep -q "install ok installed" <<<"$CURRENT_STATUS"; then
    OLD_VER="$(dpkg-query -W -f='${Version}' ntpd-rs 2>/dev/null)"
else
    OLD_VER="not installed"
fi
echo "Currently installed ntpd-rs version: ${OLD_VER}"

# Check and purge conflicting daemons
CONFLICTING_DAEMONS=("chrony" "ntpsec" "ntp")
echo "Checking for dpkg-tracked conflicting time daemons..."
for daemon in "${CONFLICTING_DAEMONS[@]}"; do
    STATE="$(dpkg-query -W -f='${Status}' "$daemon" 2>/dev/null || echo "")"
    case "$STATE" in
        "install ok installed")
            echo "   -> $daemon is installed and active. Neutralizing (config files will be purged)..."
            if [[ "$DRY_RUN" -eq 0 ]]; then
                systemctl stop "$daemon" 2>/dev/null || true
                systemctl mask "$daemon" 2>/dev/null || true
                apt-get purge -y "$daemon"
            else
                echo "      (dry-run: would stop, mask, and purge $daemon)"
            fi
            ;;
        *"config-files"*|*"deinstall"*)
            echo "   -> $daemon has residual config. Purging..."
            if [[ "$DRY_RUN" -eq 0 ]]; then
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
if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true
    systemctl mask systemd-timesyncd 2>/dev/null || true
else
    echo "   (dry-run: would stop, disable, and mask systemd-timesyncd)"
fi

echo "Downloading package from: ${DEB_URL}"
if [[ "$DRY_RUN" -eq 0 ]]; then
    check_apt_lock

    if ! download_file "$DEB_URL" "$DEB_FILE"; then
        echo "Error: Failed to download the package from the provided URL."
        exit 1
    fi

    # Validate .deb
    if ! dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1; then
        echo "Error: Downloaded file is not a valid .deb package."
        echo "   Check that the URL points directly at a .deb release asset."
        exit 1
    fi

    # Architecture check
    DEB_ARCH="$(dpkg-deb -f "$DEB_FILE" Architecture)"
    SYS_ARCH="$(dpkg --print-architecture)"
    if [[ "$DEB_ARCH" != "$SYS_ARCH" && "$DEB_ARCH" != "all" ]]; then
        echo "Error: Architecture mismatch — package is '${DEB_ARCH}', system is '${SYS_ARCH}'."
        exit 1
    fi

    # SHA256 verification if requested
    if [[ -n "$SHA256_EXPECTED" ]]; then
        echo "Verifying SHA256 checksum..."
        ACTUAL_SHA="$(sha256sum "$DEB_FILE" | awk '{print $1}')"
        if [[ "$ACTUAL_SHA" != "$SHA256_EXPECTED" ]]; then
            echo "Error: SHA256 mismatch. Expected: $SHA256_EXPECTED, got: $ACTUAL_SHA"
            exit 1
        fi
        echo "   Checksum OK."
    fi

    NEW_VER="$(dpkg-deb -f "$DEB_FILE" Version)"
    echo "   -> Validated package. Architecture: ${DEB_ARCH}. Candidate version: ${NEW_VER}"
else
    echo "   (dry-run: would download, validate, and architecture-check $DEB_URL)"
    if [[ -n "$SHA256_EXPECTED" ]]; then
        echo "   (dry-run: would also verify SHA256 checksum)"
    fi
fi

echo "Installing/upgrading ntpd-rs..."
if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! apt-get install -y "$DEB_FILE"; then
        echo "Initial install failed, attempting dependency fix-up..."
        apt-get install -f -y
        apt-get install -y "$DEB_FILE"
    fi
else
    echo "   (dry-run: would run apt-get install -y <downloaded .deb>)"
fi

echo "Enabling and starting ntpd-rs..."
if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl daemon-reload
    systemctl unmask ntpd-rs 2>/dev/null || true
    systemctl enable --now ntpd-rs
else
    echo "   (dry-run: would daemon-reload, unmask, enable, and start ntpd-rs)"
fi

echo "=================================================="
echo " Verification"
echo "=================================================="

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run complete. No changes were made."
    exit 0
fi

# Final version
FINAL_VER="not installed"
FINAL_STATUS="$(dpkg-query -W -f='${Status}' ntpd-rs 2>/dev/null || true)"
if grep -q "install ok installed" <<<"$FINAL_STATUS"; then
    FINAL_VER="$(dpkg-query -W -f='${Version}' ntpd-rs 2>/dev/null)"
fi
echo "Version: ${OLD_VER} -> ${FINAL_VER}"

# Locate binary
BIN_PATH=""
for candidate in ntpd-rsd ntpd-rs; do
    MATCH="$(dpkg -L ntpd-rs 2>/dev/null | grep -E "/s?bin/${candidate}\$" | head -n1 || echo "")"
    if [[ -n "$MATCH" ]]; then
        BIN_PATH="$MATCH"
        break
    fi
done
if [[ -z "$BIN_PATH" ]]; then
    BIN_PATH="$(dpkg -L ntpd-rs 2>/dev/null | grep -E '/(usr/)?s?bin/' | head -n1 || echo "")"
fi

if [[ -n "$BIN_PATH" && -x "$BIN_PATH" ]]; then
    echo -e "\nBinary (${BIN_PATH}) version:"
    "$BIN_PATH" --version 2>/dev/null || "$BIN_PATH" -v 2>/dev/null || echo "Binary exists but --version failed."
else
    echo "Could not resolve an ntpd-rs binary from the installed package's file list."
fi

echo -e "\nService status:"
if systemctl is-active --quiet ntpd-rs; then
    echo "ntpd-rs is active and running."
else
    echo "ntpd-rs failed to start. Check: sudo journalctl -u ntpd-rs -n 50"
fi

echo ""
echo "────────────────────────────────────────────────────"
echo " Configuration"
echo "────────────────────────────────────────────────────"
echo "Edit the configuration file to set your preferred servers:"
echo "    sudo ${EDITOR:-nano} /etc/ntpd-rs/ntp.toml"
echo ""
echo "After editing, restart the daemon:"
echo "    sudo systemctl restart ntpd-rs"
echo ""
echo "To see current synchronization status:"
echo "    ntp-ctl status"
echo "To validate changes to the configuration file:"
echo "    ntp-ctl validate"
echo "────────────────────────────────────────────────────"

echo ""
echo " Note: displaced daemons may have left orphaned dependency packages."
echo " Review before removing — some libs may still be used elsewhere:"
echo "   sudo apt-get autoremove --purge"
