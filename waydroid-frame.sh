#!/usr/bin/env bash

###############################################################################
#
# Steam Frame ARM64 Waydroid Installer
#
# Target:
#   Valve Steam Frame
#   SteamOS
#   ARM64 / aarch64
#
# Binder:
#   Uses the Frame's built-in Binder/BinderFS.
#
# IMPORTANT:
#   Do NOT install binder_linux-dkms on the Steam Frame.
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# Configuration
###############################################################################

WORK_DIR="${HOME}/SteamFrame-Waydroid"
AUR_DIR="${WORK_DIR}/aur"

LOG_FILE="${WORK_DIR}/install.log"
PACMAN_LOG="${WORK_DIR}/pacman.log"

STEAMOS_UNLOCKED=0

###############################################################################
# AUR repositories
###############################################################################

AUR_LIBGLIBUTIL="https://aur.archlinux.org/libglibutil.git"
AUR_LIBGBINDER="https://aur.archlinux.org/libgbinder.git"
AUR_PYTHON_GBINDER="https://aur.archlinux.org/python-gbinder.git"
AUR_WAYDROID="https://aur.archlinux.org/waydroid.git"

###############################################################################
# Logging
###############################################################################

mkdir -p "$WORK_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

###############################################################################
# Output helpers
###############################################################################

info() {
    echo
    echo "==> $*"
}

success() {
    echo
    echo "OK: $*"
}

warn() {
    echo
    echo "WARNING: $*" >&2
}

die() {
    echo
    echo "============================================================"
    echo "ERROR"
    echo "============================================================"
    echo
    echo "$*" >&2
    echo
    echo "Installer log:"
    echo "  $LOG_FILE"
    echo
    echo "Pacman log:"
    echo "  $PACMAN_LOG"
    echo
    exit 1
}

###############################################################################
# SteamOS read-only handling
###############################################################################

unlock_steamos() {

    if [[ "$STEAMOS_UNLOCKED" -eq 1 ]]; then
        return 0
    fi

    if ! command -v steamos-readonly >/dev/null 2>&1; then
        warn "steamos-readonly was not found."
        return 0
    fi

    info "Disabling SteamOS read-only mode"

    if ! sudo steamos-readonly disable; then
        die "Could not disable SteamOS read-only mode."
    fi

    STEAMOS_UNLOCKED=1

    success "SteamOS filesystem is writable."
}

lock_steamos() {

    if [[ "$STEAMOS_UNLOCKED" -eq 0 ]]; then
        return 0
    fi

    if ! command -v steamos-readonly >/dev/null 2>&1; then
        return 0
    fi

    info "Restoring SteamOS read-only mode"

    if sudo steamos-readonly enable; then
        STEAMOS_UNLOCKED=0
        success "SteamOS read-only mode restored."
    else
        warn "Unable to restore SteamOS read-only mode."
        warn "Run:"
        warn
        warn "  sudo steamos-readonly enable"
        warn
    fi
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    lock_steamos
}

trap cleanup EXIT

###############################################################################
# Pacman wrapper
###############################################################################

pacman_run() {

    echo
    echo "PACMAN:"
    printf '  sudo pacman '
    printf '%q ' "$@"
    echo
    echo

    sudo pacman "$@" 2>&1 |
        tee -a "$PACMAN_LOG"
}

###############################################################################
# AUR repository helper
###############################################################################

clone_or_update_aur() {

    local url="$1"
    local directory="$2"

    local name
    name="$(basename "$directory")"

    if [[ -d "$directory/.git" ]]; then

        info "Updating AUR package: $name"

        (
            cd "$directory"

            git fetch --all

            if git show-ref --verify --quiet refs/remotes/origin/master; then
                git reset --hard origin/master
            else
                git reset --hard origin/main
            fi
        )

    else

        info "Cloning AUR package: $name"

        rm -rf "$directory"

        git clone \
            --depth=1 \
            "$url" \
            "$directory"
    fi
}

###############################################################################
# Remove previous build artifacts
###############################################################################

clean_package_artifacts() {

    local directory="$1"

    info "Cleaning previous build artifacts"

    (
        cd "$directory"

        #
        # Remove package archives from previous runs.
        #
        # This is necessary because makepkg refuses to overwrite an
        # existing package unless -f is specified.
        #

        find . \
            -maxdepth 1 \
            -type f \
            \( \
                -name '*.pkg.tar.zst' \
                -o -name '*.pkg.tar.xz' \
                -o -name '*.pkg.tar.gz' \
            \) \
            -delete

        #
        # Remove the previous source package if present.
        #

        rm -f \
            ./*.src.tar.gz \
            ./*.src.tar.zst \
            2>/dev/null ||
            true

    )
}

###############################################################################
# Build AUR package
###############################################################################

build_aur_package() {

    local directory="$1"

    local name
    name="$(basename "$directory")"

    info "Building $name"

    #
    # Make the function safe to rerun.
    #

    clean_package_artifacts "$directory"

    (
        cd "$directory"

        #
        # SteamOS MUST remain writable here.
        #
        # makepkg may invoke pacman to install missing dependencies.
        #

        makepkg \
            --syncdeps \
            --noconfirm \
            --cleanbuild \
            --force
    ) || die "Failed to build AUR package: $name"

    success "$name built."
}

###############################################################################
# Locate and install package
###############################################################################
install_built_package() {
    local directory="$1"
    local name
    name="$(basename "$directory")"

    info "Installing $name"

    cd "$directory"

    # Ask makepkg which package it actually produced.
    local package_file
    package_file="$(makepkg --packagelist | head -n1)"

    if [[ -z "$package_file" || ! -f "$package_file" ]]; then
        die "Could not locate the package produced by makepkg for $name."
    fi

    echo "Installing:"
    echo "  $package_file"

    if ! sudo pacman -U --noconfirm "$package_file"; then
        die "pacman failed to install $name."
    fi

    # Critical: verify pacman actually registered the package.
    local pkgbase
    pkgbase="$(pacman -Qqp "$package_file" | sed 's/-[0-9].*$//' | head -n1)"

    if ! pacman -Q "$pkgbase" >/dev/null 2>&1; then
        die "$name was built but was NOT registered as installed."
    fi

    success "$name installed and verified."
}


###############################################################################
# Initial checks
###############################################################################

clear

echo
echo "============================================================"
echo " Steam Frame ARM64 Waydroid Installer"
echo "============================================================"
echo
echo "This installer:"
echo
echo "  * Uses the Frame's built-in Binder/BinderFS"
echo "  * Does NOT install binder_linux-dkms"
echo "  * Builds Waydroid and dependencies locally"
echo "  * Keeps SteamOS writable during the complete build"
echo "  * Can safely be rerun after a failed build"
echo "  * Restores read-only mode at the end"
echo

if [[ "$EUID" -eq 0 ]]; then
    die "Do not run this script as root."
fi

if ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required."
fi

sudo -v

###############################################################################
# Architecture
###############################################################################

info "Checking architecture"

ARCH="$(uname -m)"

echo "Architecture: $ARCH"

if [[ "$ARCH" != "aarch64" ]]; then
    die "This installer requires aarch64/ARM64."
fi

success "ARM64 detected."

###############################################################################
# Operating system
###############################################################################

info "Checking operating system"

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

source /etc/os-release

echo "OS:          ${PRETTY_NAME:-unknown}"
echo "ID:          ${ID:-unknown}"
echo "Version:     ${VERSION_ID:-unknown}"
echo "Variant:     ${VARIANT_ID:-unknown}"

###############################################################################
# Kernel
###############################################################################

info "Checking kernel"

KERNEL="$(uname -r)"

echo "Kernel:"
echo "  $KERNEL"

###############################################################################
# Binder configuration
###############################################################################

info "Checking Binder kernel support"

BINDER_CONFIG=""

if [[ -r /proc/config.gz ]]; then

    BINDER_CONFIG="$(
        zcat /proc/config.gz 2>/dev/null |
        grep '^CONFIG_ANDROID_BINDER' ||
        true
    )

elif [[ -f "/boot/config-$KERNEL" ]]; then

    BINDER_CONFIG="$(
        grep '^CONFIG_ANDROID_BINDER' \
            "/boot/config-$KERNEL" ||
        true
    )

fi

echo
echo "$BINDER_CONFIG"
echo

if ! grep -q '^CONFIG_ANDROID_BINDER_IPC=y$' <<<"$BINDER_CONFIG"; then
    die "The running kernel does not have built-in Binder IPC."
fi

if ! grep -q '^CONFIG_ANDROID_BINDERFS=y$' <<<"$BINDER_CONFIG"; then
    die "The running kernel does not have built-in BinderFS."
fi

success "Built-in Binder IPC and BinderFS detected."

###############################################################################
# Binder filesystem
###############################################################################

info "Checking Binder filesystem"

if ! grep -qw binder /proc/filesystems; then
    die "Binder filesystem is not registered."
fi

success "Binder filesystem is available."

###############################################################################
# Disable SteamOS read-only mode ONCE
###############################################################################

unlock_steamos

###############################################################################
# Check pacman
###############################################################################

info "Checking pacman"

if ! command -v pacman >/dev/null 2>&1; then
    die "pacman is not available."
fi

###############################################################################
# Pacman keyring
###############################################################################

info "Checking pacman keyring"

if command -v pacman-key >/dev/null 2>&1; then

    if [[ ! -d /etc/pacman.d/gnupg ]]; then

        info "Initializing pacman keyring"

        sudo pacman-key --init ||
            die "pacman-key --init failed."

    fi

    if sudo pacman-key --populate steamdeck 2>/dev/null; then

        success "SteamOS keyring populated."

    elif sudo pacman-key --populate holo 2>/dev/null; then

        success "Holo keyring populated."

    elif sudo pacman-key --populate archlinux 2>/dev/null; then

        success "Arch Linux keyring populated."

    else

        warn "No standard pacman-key keyring could be populated."
        warn "Continuing."
    fi
fi

###############################################################################
# Pacman database
###############################################################################

info "Synchronizing pacman databases"

if ! sudo pacman -Sy 2>&1 |
    tee -a "$PACMAN_LOG"; then

    die "pacman could not synchronize its package databases."
fi

success "Pacman database synchronized."

###############################################################################
# Base dependencies
###############################################################################

info "Installing build dependencies"

REPO_PACKAGES=(
    git
    base-devel
    python
    python-gobject
    python-dbus
    lxc
    dnsmasq
    nftables
    curl
    wget
    rsync
)

if ! pacman_run \
    -S \
    --needed \
    --noconfirm \
    "${REPO_PACKAGES[@]}"; then

    die "Failed to install required repository packages."
fi

success "Base build dependencies installed."

###############################################################################
# makepkg check
###############################################################################

if ! command -v makepkg >/dev/null 2>&1; then
    die "makepkg was not installed."
fi

###############################################################################
# Prepare AUR directories
###############################################################################

mkdir -p "$AUR_DIR"

###############################################################################
# Obtain AUR packages
###############################################################################

clone_or_update_aur \
    "$AUR_LIBGLIBUTIL" \
    "$AUR_DIR/libglibutil"

clone_or_update_aur \
    "$AUR_LIBGBINDER" \
    "$AUR_DIR/libgbinder"

clone_or_update_aur \
    "$AUR_PYTHON_GBINDER" \
    "$AUR_DIR/python-gbinder"

clone_or_update_aur \
    "$AUR_WAYDROID" \
    "$AUR_DIR/waydroid"

###############################################################################
# libglibutil
###############################################################################

build_aur_package \
    "$AUR_DIR/libglibutil"

install_built_package \
    "$AUR_DIR/libglibutil"

###############################################################################
# libgbinder
###############################################################################

build_aur_package \
    "$AUR_DIR/libgbinder"

install_built_package \
    "$AUR_DIR/libgbinder"

###############################################################################
# python-gbinder
###############################################################################

build_aur_package \
    "$AUR_DIR/python-gbinder"

install_built_package \
    "$AUR_DIR/python-gbinder"

###############################################################################
# Waydroid
###############################################################################

build_aur_package \
    "$AUR_DIR/waydroid"

install_built_package \
    "$AUR_DIR/waydroid"

###############################################################################
# Verify Waydroid
###############################################################################

info "Verifying Waydroid"

if ! command -v waydroid >/dev/null 2>&1; then
    die "Waydroid executable was not installed."
fi

waydroid --version

success "Waydroid executable is working."

###############################################################################
# Initialize Waydroid
###############################################################################

echo
echo "============================================================"
echo " Android image initialization"
echo "============================================================"
echo
echo "The standard VANILLA Android image will be initialized."
echo
echo "GApps and ARM translation layers are intentionally omitted."
echo

if [[ -f /var/lib/waydroid/waydroid.cfg ]]; then

    success "Waydroid is already initialized."

else

    read -r -p \
        "Press ENTER to initialize Waydroid, or Ctrl+C to cancel... "

    if ! sudo waydroid init; then
        die "waydroid init failed."
    fi

    success "Waydroid initialized."
fi

###############################################################################
# Verify configuration
###############################################################################

info "Checking Waydroid configuration"

WAYDROID_CFG="/var/lib/waydroid/waydroid.cfg"

if [[ ! -f "$WAYDROID_CFG" ]]; then
    die "Waydroid configuration was not created."
fi

echo
cat "$WAYDROID_CFG"
echo

###############################################################################
# Start helper
###############################################################################

info "Creating Waydroid start helper"

cat > "$WORK_DIR/waydroid-frame-start" <<'EOF'
#!/usr/bin/env bash

set -u

echo
echo "============================================================"
echo " Starting Waydroid"
echo "============================================================"
echo

if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "WARNING: WAYLAND_DISPLAY is not set."
    echo "Run this from SteamOS Desktop Mode."
    echo
fi

echo "Starting Waydroid container..."

if ! sudo systemctl start waydroid-container.service; then

    echo
    echo "ERROR: Waydroid container failed to start."
    echo
    echo "Run:"
    echo
    echo "  waydroid-frame-diagnostics"
    echo

    exit 1
fi

sleep 5

echo
echo "Binder mounts:"
mount | grep binder || true

echo
echo "Binder devices:"
ls -la /dev/binder* 2>/dev/null || true
ls -la /dev/binderfs 2>/dev/null || true

echo
echo "Starting Waydroid session..."

waydroid session start \
    >/tmp/waydroid-session.log 2>&1 &

SESSION_PID=$!

sleep 8

echo
echo "Waydroid status:"
waydroid status || true

echo
echo "Waydroid session log:"
cat /tmp/waydroid-session.log 2>/dev/null || true

echo
echo "Launching Android UI..."

if ! waydroid show-full-ui; then

    echo
    echo "ERROR: Waydroid UI failed to start."
    echo
    echo "Run:"
    echo
    echo "  waydroid-frame-diagnostics"
    echo

    exit 1
fi

wait "$SESSION_PID" 2>/dev/null || true
EOF

chmod +x "$WORK_DIR/waydroid-frame-start"

sudo install \
    -m 0755 \
    "$WORK_DIR/waydroid-frame-start" \
    /usr/local/bin/waydroid-frame-start

###############################################################################
# Stop helper
###############################################################################

info "Creating Waydroid stop helper"

cat > "$WORK_DIR/waydroid-frame-stop" <<'EOF'
#!/usr/bin/env bash

echo "Stopping Waydroid session..."

waydroid session stop 2>/dev/null || true

echo "Stopping Waydroid container..."

sudo systemctl stop \
    waydroid-container.service \
    2>/dev/null || true

echo "Waydroid stopped."
EOF

chmod +x "$WORK_DIR/waydroid-frame-stop"

sudo install \
    -m 0755 \
    "$WORK_DIR/waydroid-frame-stop" \
    /usr/local/bin/waydroid-frame-stop

###############################################################################
# Diagnostics
###############################################################################

info "Creating diagnostic helper"

cat > "$WORK_DIR/waydroid-frame-diagnostics" <<'EOF'
#!/usr/bin/env bash

echo
echo "============================================================"
echo " Steam Frame Waydroid Diagnostics"
echo "============================================================"

echo
echo "=== Architecture ==="
uname -m

echo
echo "=== Kernel ==="
uname -r

echo
echo "=== SteamOS ==="
cat /etc/os-release

echo
echo "=== Binder kernel configuration ==="

if [[ -r /proc/config.gz ]]; then
    zcat /proc/config.gz 2>/dev/null |
        grep '^CONFIG_ANDROID_BINDER' ||
        true
elif [[ -f "/boot/config-$(uname -r)" ]]; then
    grep '^CONFIG_ANDROID_BINDER' \
        "/boot/config-$(uname -r)" ||
        true
fi

echo
echo "=== Binder filesystem ==="
grep binder /proc/filesystems || true

echo
echo "=== Binder mounts ==="
mount | grep binder || true

echo
echo "=== Binder devices ==="
ls -la /dev/binder* 2>&1 || true
ls -la /dev/binderfs 2>&1 || true

echo
echo "=== Wayland ==="
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset}"
echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}"

echo
echo "=== Waydroid version ==="
waydroid --version 2>&1 || true

echo
echo "=== Waydroid status ==="
waydroid status 2>&1 || true

echo
echo "=== Waydroid configuration ==="
sudo cat \
    /var/lib/waydroid/waydroid.cfg \
    2>/dev/null ||
    true

echo
echo "=== Container service ==="
systemctl status \
    waydroid-container.service \
    --no-pager \
    2>&1 ||
    true

echo
echo "=== Container journal ==="
journalctl \
    -u waydroid-container.service \
    -n 250 \
    --no-pager \
    2>&1 ||
    true

echo
echo "=== Waydroid log ==="
sudo waydroid log \
    2>&1 |
    tail -300 ||
    true

echo
echo "=== Binder kernel messages ==="
sudo dmesg \
    2>/dev/null |
    grep -i binder |
    tail -100 ||
    true

echo
echo "=== Installed packages ==="

pacman -Q \
    waydroid \
    python-gbinder \
    libgbinder \
    libglibutil \
    2>&1 ||
    true

echo
echo "=== Waydroid package information ==="

pacman -Qi waydroid 2>/dev/null |
    grep -E \
        '^(Name|Version|Architecture|Install Date)' ||
    true

echo
echo "============================================================"
EOF

chmod +x "$WORK_DIR/waydroid-frame-diagnostics"

sudo install \
    -m 0755 \
    "$WORK_DIR/waydroid-frame-diagnostics" \
    /usr/local/bin/waydroid-frame-diagnostics

###############################################################################
# Restore SteamOS read-only mode
###############################################################################

info "Installation finished"

lock_steamos

###############################################################################
# Final output
###############################################################################

echo
echo "============================================================"
echo " Steam Frame Waydroid installation complete"
echo "============================================================"
echo
echo "Waydroid:"
waydroid --version || true
echo
echo "Architecture:"
uname -m
echo
echo "Kernel:"
uname -r
echo
echo "------------------------------------------------------------"
echo
echo "Start:"
echo
echo "  waydroid-frame-start"
echo
echo "Stop:"
echo
echo "  waydroid-frame-stop"
echo
echo "Diagnostics:"
echo
echo "  waydroid-frame-diagnostics"
echo
echo "Log:"
echo
echo "  $LOG_FILE"
echo
echo "Pacman log:"
echo
echo "  $PACMAN_LOG"
echo
echo "------------------------------------------------------------"
echo
echo "Binder:"
echo "  Built into Steam Frame kernel"
echo
echo "Binder DKMS:"
echo "  NOT installed"
echo
echo "SteamOS:"
echo "  Read-only mode restored"
echo
echo "============================================================"
