#!/usr/bin/env bash

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
DEB_URL=""
FORCE=0
SHA256_EXPECTED=""
VERBOSE=0

# Map conflicting dpkg package names to their systemd service names.
# chrony -> chronyd (daemon), chronyc is CLI (no service)
declare -A DAEMON_SERVICES=(
    [chrony]="chronyd"
    [ntpsec]="ntpsec"
    [ntp]="ntp"
    [openntpd]="openntpd"
    [linuxptp]="ptp4l"
)

# Packages that provide timekeeping daemons but are NOT systemd services
NON_SERVICE_TIMEKEEPERS=(
    "ntpdate"
    "tlsdate"
)

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
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "Error: --sha256 requires a hash argument." >&2
                exit 1
            fi
            SHA256_EXPECTED="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: ${SCRIPT_NAME} <url-to-ntpd-rs-deb-package> [options]

Options:
    --dry-run          Show what would be done without making changes.
    --force            Skip confirmation before handling conflicting daemons.
    --sha256 <hash>    Verify the downloaded .deb against this SHA256 checksum.
    --verbose          Enable verbose/debug output.

Example:
    sudo ${SCRIPT_NAME} https://github.com/pendulum-project/ntpd-rs/releases/download/v1.9.0/ntpd-rs_1.9.0-1_amd64.deb --sha256 abc123...
EOF
            exit 0
            ;;
        --*)
            echo "Error: Unknown option: $1" >&2
            echo "Run '${SCRIPT_NAME} --help' for usage." >&2
            exit 1
            ;;
        *)
            if [[ -z "$DEB_URL" ]]; then
                DEB_URL="$1"
            else
                echo "Error: Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate URL
if [[ -z "$DEB_URL" ]]; then
    echo "Error: Missing package URL." >&2
    echo "Usage: ${SCRIPT_NAME} <url> [--dry-run] [--force] [--sha256 <hash>]" >&2
    exit 1
fi

# Validate SHA256 format if provided
if [[ -n "$SHA256_EXPECTED" && ! "$SHA256_EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo "Error: --sha256 requires a valid 64-character hex SHA256 hash." >&2
    exit 1
fi

# Check for root
if [[ "$EUID" -ne 0 ]]; then
    echo "Error: Please run this script with sudo." >&2
    exit 1
fi

# Enable verbose mode if requested
if [[ "$VERBOSE" -eq 1 ]]; then
    set -x
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
        printf "   (dry-run: would run:"
        for arg in "$@"; do
            printf " '%s'" "$arg"
        done
        printf ")
"
    fi
}

# Check for required tools
for tool in wget curl dpkg-deb fuser; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Error: $tool is not installed. Please install it and try again." >&2
        if [[ "$tool" == "fuser" ]]; then
            echo "Note: fuser is usually provided by the 'psmisc' package." >&2
        fi
        exit 1
    fi
done

# Use curl or wget (prefer curl for broader compatibility)
download_file() {
    local url="$1" output="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL -o "$output" "$url"
    else
        wget --progress=dot:giga -O "$output" "$url"
    fi
}

# Check for apt lock with a retry mechanism
check_apt_lock() {
    local max_retries=5
    local count=0
    local lock_files=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock" "/var/cache/apt/archives/lock")

    while [ $count -lt $max_retries ]; do
        local locked=0
        for lock in "${lock_files[@]}"; do
            if [[ -f "$lock" ]]; then
                if fuser "$lock" &>/dev/null || pgrep -x "apt|apt-get|dpkg" &>/dev/null; then
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

    echo "Error: Timed out waiting for apt/dpkg lock. Please close other package managers and try again." >&2
    exit 1
}

# Confirmation before making changes
confirm_action() {
    local msg="$1"
    if [[ "$FORCE" -eq 1 ]] || [[ "$DRY_RUN" -eq 1 ]] || [[ ! -t 0 ]]; then
        return 0
    fi
    echo "$msg"
    read -p "Proceed? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        if [[ -z "$REPLY" ]]; then
            echo "Aborted (no response)."
            exit 0
        fi
        echo "Aborted by user."
        exit 0
    fi
}

# Main
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Fix _apt sandbox warning: make temp dir readable by _apt user
chmod 755 "$TEMP_DIR"

DEB_FILE="${TEMP_DIR}/ntpd-rs_latest.deb"
PURGE_FOUND=0

# Helper: get installed version of a package
get_pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "not installed"
}

# Helper: check if a package is installed (any state)
pkg_is_installed() {
    local state
    state="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || echo "")"
    [[ "$state" == "install ok installed" ]]
}

echo "=================================================="
echo " ${SCRIPT_NAME} — ntpd-rs Update/Installation Utility"
echo "=================================================="

# Get current version
OLD_VER="$(get_pkg_version ntpd-rs)"
echo "Currently installed ntpd-rs version: ${OLD_VER}"

# --- Phase 1: Handle systemd-timesyncd (special case) ---
echo ""
echo "Checking systemd-timesyncd..."
if systemctl is-enabled systemd-timesyncd &>/dev/null || systemctl is-active systemd-timesyncd &>/dev/null; then
    echo "   -> systemd-timesyncd is active/enabled. Disabling..."
    run systemctl stop systemd-timesyncd
    run systemctl disable systemd-timesyncd
    run systemctl mask systemd-timesyncd
else
    echo "   -> systemd-timesyncd already disabled/inactive."
fi

# --- Phase 2: Handle dpkg-tracked timekeeping daemons ---
CONFLICTING_DAEMONS=("chrony" "ntpsec" "ntp" "openntpd" "linuxptp")
echo ""
echo "Checking for dpkg-tracked conflicting time daemons..."
for daemon in "${CONFLICTING_DAEMONS[@]}"; do
    STATE="$(dpkg-query -W -f='${Status}' "$daemon" 2>/dev/null || echo "")"
    case "$STATE" in
        "install ok installed")
            SERVICE_NAME="${DAEMON_SERVICES[$daemon]:-$daemon}"
            echo "   -> $daemon is installed. Stopping service ($SERVICE_NAME) and removing package..."
            PURGE_FOUND=1
            if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
                run systemctl stop "$SERVICE_NAME"
                run systemctl mask "$SERVICE_NAME"
            fi
            run apt-get remove -y "$daemon"
            ;;
        *"config-files"*|*"deinstall"*)
            echo "   -> $daemon has residual config. Purging residual..."
            PURGE_FOUND=1
            run apt-get purge -y "$daemon"
            ;;
        *)
            echo "   -> $daemon not present. Skipping."
            ;;
    esac
done

# --- Phase 3: Handle non-service timekeepers ---
for pkg in "${NON_SERVICE_TIMEKEEPERS[@]}"; do
    if pkg_is_installed "$pkg"; then
        echo "   -> $pkg is installed (non-service timekeeper). Removing..."
        PURGE_FOUND=1
        run apt-get remove -y "$pkg"
    fi
done

# --- Phase 4: Clean up orphaned time sync cron jobs ---
if [[ -f /etc/cron.daily/ntpdate ]]; then
    echo "   -> Found /etc/cron.daily/ntpdate. Removing..."
    run rm -f /etc/cron.daily/ntpdate
fi

# Only prompt if we actually found something to handle
if [[ "$PURGE_FOUND" -eq 0 ]]; then
    FORCE=1
fi

confirm_action "WARNING: This script will remove conflicting time daemons and mask systemd-timesyncd. Proceed?"

echo ""
echo "Downloading package from: ${DEB_URL}"
if [[ "$DRY_RUN" -eq 0 ]]; then
    check_apt_lock

    if ! download_file "$DEB_URL" "$DEB_FILE"; then
        echo "Error: Failed to download the package from the provided URL." >&2
        exit 1
    fi

    if ! dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1; then
        echo "Error: Downloaded file is not a valid .deb package." >&2
        echo "   Check that the URL points directly at a .deb release asset." >&2
        exit 1
    fi

    DEB_ARCH="$(dpkg-deb -f "$DEB_FILE" Architecture)"
    SYS_ARCH="$(dpkg --print-architecture)"
    if [[ "$DEB_ARCH" != "$SYS_ARCH" && "$DEB_ARCH" != "all" ]]; then
        echo "Error: Architecture mismatch — package is '${DEB_ARCH}', system is '${SYS_ARCH}'." >&2
        exit 1
    fi

    if [[ -n "$SHA256_EXPECTED" ]]; then
        echo "Verifying SHA256 checksum..."
        ACTUAL_SHA="$(sha256sum "$DEB_FILE" | awk '{print $1}')"
        if [[ "$ACTUAL_SHA" != "$SHA256_EXPECTED" ]]; then
            echo "Error: SHA256 mismatch. Expected: $SHA256_EXPECTED, got: $ACTUAL_SHA" >&2
            exit 1
        fi
        echo "   Checksum OK."
    fi

    NEW_VER="$(dpkg-deb -f "$DEB_FILE" Version)"
    PKG_NAME="$(dpkg-deb -f "$DEB_FILE" Package)"
    echo "   -> Validated package. Architecture: ${DEB_ARCH}. Candidate version: ${NEW_VER}"
else
    echo "   (dry-run: would download, validate, and architecture-check $DEB_URL)"
    if [[ -n "$SHA256_EXPECTED" ]]; then
        echo "   (dry-run: would also verify SHA256 checksum)"
    fi
fi

echo "Installing/upgrading ntpd-rs..."
if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! apt-get install --no-install-recommends -y "$DEB_FILE"; then
        echo "Initial install failed, attempting dependency fix-up..."
        apt-get install --no-install-recommends -f -y
        if ! apt-get install --no-install-recommends -y "$DEB_FILE"; then
            echo "Error: Failed to install $DEB_FILE even after dependency fix-up." >&2
            exit 1
        fi
    fi
else
    echo "   (dry-run: would run apt-get install -y <downloaded .deb>)"
fi

echo "Enabling and starting ntpd-rs..."
run systemctl daemon-reload
run systemctl unmask ntpd-rs
run systemctl enable --now ntpd-rs

# Also handle metrics service if it exists, has [Install], and isn't already enabled
if systemctl list-unit-files "ntpd-rs-metrics.service" &>/dev/null; then
    if systemctl cat "ntpd-rs-metrics.service" 2>/dev/null | grep -q "^\[Install\]"; then
        if ! systemctl is-enabled ntpd-rs-metrics &>/dev/null; then
            echo "Enabling ntpd-rs-metrics service..."
            run systemctl enable --now ntpd-rs-metrics
        else
            echo "   -> ntpd-rs-metrics.service already enabled."
        fi
    else
        echo "   -> ntpd-rs-metrics.service is static, skipping enable."
    fi
fi

echo "=================================================="
echo " Verification"
echo "=================================================="

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run complete. No changes were made."
    exit 0
fi

FINAL_VER="$(get_pkg_version ntpd-rs)"
echo "Package version: ${OLD_VER} -> ${FINAL_VER}"

# ntp-ctl outputs version to stderr, not stdout. Capture both.
if command -v ntp-ctl &>/dev/null; then
    echo -e "
Control utility version:"
    NTP_CTL_VER="$(ntp-ctl --version 2>&1 || ntp-ctl -v 2>&1 || true)"
    if [[ -n "$NTP_CTL_VER" ]]; then
        echo "  $NTP_CTL_VER"
    else
        echo "  (version check returned no output)"
    fi
fi

echo -e "
Service status:"
if systemctl is-active --quiet ntpd-rs; then
    echo "ntpd-rs is active and running."
else
    echo "ntpd-rs failed to start. Check: sudo journalctl -u ntpd-rs -n 50"
fi

echo ""
echo "────────────────────────────────────────────────────"
echo " Configuration"
echo "────────────────────────────────────────────────────"
if command -v ntp-ctl &>/dev/null; then
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
else
    echo "ntp-ctl not found in PATH. Check the package documentation for configuration."
fi
echo "────────────────────────────────────────────────────"

echo ""
echo " Note: displaced daemons may have left orphaned dependency packages."
echo " Review before removing — some libs may still be used elsewhere:"
echo "   sudo apt-get autoremove --purge"
