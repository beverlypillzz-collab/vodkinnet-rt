#!/bin/sh

echo ""
echo "  ██╗   ██╗ ██████╗ ██████╗ ██╗  ██╗██╗███╗   ██╗"
echo "  ██║   ██║██╔═══██╗██╔══██╗██║ ██╔╝██║████╗  ██║"
echo "  ██║   ██║██║   ██║██║  ██║█████╔╝ ██║██╔██╗ ██║"
echo "  ╚██╗ ██╔╝██║   ██║██║  ██║██╔═██╗ ██║██║╚██╗██║"
echo "   ╚████╔╝ ╚██████╔╝██████╔╝██║  ██╗██║██║ ╚████║"
echo "    ╚═══╝   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝"
echo "  extroot setup v3.0"
echo "  beverlypillzz-collab/Vodkinnet-RT"
echo ""

# =============================================================================
# quick-extroot-openwrt.sh
# ExtRoot setup script for OpenWrt (supports both opkg and apk)
# Based on: https://openwrt.org/docs/guide-user/additional-software/extroot_configuration
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $1"; }

# =============================================================================
# Detect package manager
# =============================================================================
detect_pkg_manager() {
    if command -v apk > /dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add"
        log "Package manager: apk (OpenWrt 24.x+)"
    elif command -v opkg > /dev/null 2>&1; then
        PKG_MANAGER="opkg"
        PKG_UPDATE="opkg update"
        PKG_INSTALL="opkg install"
        log "Package manager: opkg (OpenWrt 23.x)"
    else
        error "No supported package manager found (apk or opkg)"
    fi
}

# =============================================================================
# Install required packages
# =============================================================================
install_packages() {
    log "Updating package lists..."
    $PKG_UPDATE || warn "Package update failed, trying to continue..."

    log "Installing required packages..."
    $PKG_INSTALL block-mount kmod-fs-ext4 e2fsprogs parted kmod-usb-storage || \
        error "Failed to install required packages"

    # Optional: UAS support for SSDs
    $PKG_INSTALL kmod-usb-storage-uas 2>/dev/null && \
        log "UAS support installed (SSD)" || \
        info "UAS support not available, skipping"
}

# =============================================================================
# Wait for USB disk to appear
# =============================================================================
wait_for_disk() {
    log "Waiting for USB storage device..."
    local retries=10
    while [ $retries -gt 0 ]; do
        if ls /dev/sd* > /dev/null 2>&1; then
            log "USB device detected"
            return 0
        fi
        warn "No USB device found, waiting 3s... ($retries attempts left)"
        sleep 3
        retries=$((retries - 1))
    done
    error "No USB device appeared after waiting. Plug in USB and restart script."
}

# =============================================================================
# Detect USB disk
# =============================================================================
detect_disk() {
    wait_for_disk

    echo ""
    info "Devices in /sys/block:"
    ls -l /sys/block | grep -v "loop\|ram\|mtd\|ubi" || true

    echo ""
    info "Available /dev/sd* devices:"
    ls /dev/sd* 2>/dev/null || true

    echo ""
    warn "Enter the disk to use for extroot (e.g. /dev/sda):"
    read -r DISK < /dev/tty

    [ -b "$DISK" ] || error "Device $DISK not found or not a block device"
    log "Using disk: $DISK"
}

# =============================================================================
# Partition and format
# =============================================================================
partition_disk() {
    warn "ALL DATA ON $DISK WILL BE ERASED! Continue? (yes/no)"
    read -r CONFIRM < /dev/tty
    [ "$CONFIRM" = "yes" ] || error "Aborted by user"

    log "Partitioning $DISK..."
    parted -s "$DISK" -- mklabel gpt mkpart extroot 2048s -2048s || \
        error "Partitioning failed"

    DEVICE="${DISK}1"

    log "Waiting for partition to appear..."
    sleep 3

    [ -b "$DEVICE" ] || error "Partition $DEVICE did not appear after partitioning"

    log "Formatting ${DEVICE} as ext4..."
    mkfs.ext4 -L extroot "$DEVICE" || error "Formatting failed"

    log "Verifying filesystem..."
    e2fsck -n "$DEVICE" && log "Filesystem OK" || error "Filesystem check failed"

    log "Partition ready: $DEVICE"
}

# =============================================================================
# Generate fstab via block detect (ключевой шаг!)
# =============================================================================
generate_fstab() {
    log "Generating fstab via block detect..."

    # Генерируем базовый fstab через block detect
    block detect > /etc/config/fstab || error "block detect failed"

    log "fstab generated:"
    cat /etc/config/fstab
    echo ""
}

# =============================================================================
# Configure extroot fstab
# =============================================================================
configure_extroot() {
    log "Configuring extroot mount..."

    # UUID через block info
    UUID="$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)"

    if [ -z "$UUID" ]; then
        warn "block info did not return UUID, trying blkid..."
        UUID="$(blkid -s UUID -o value "$DEVICE" 2>/dev/null)"
    fi

    [ -n "$UUID" ] || error "Could not determine UUID of $DEVICE"
    info "UUID: $UUID"

    # Находим overlay
    MOUNT="$(block info | grep -o 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)"
    [ -n "$MOUNT" ] || MOUNT="/overlay"
    info "Overlay mount point: $MOUNT"

    # Записываем extroot
    uci -q delete fstab.extroot
    uci set fstab.extroot="mount"
    uci set fstab.extroot.uuid="$UUID"
    uci set fstab.extroot.target="$MOUNT"
    uci set fstab.extroot.enabled="1"
    uci commit fstab

    # Проверяем UUID
    SAVED_UUID="$(uci get fstab.extroot.uuid 2>/dev/null)"
    [ "$SAVED_UUID" = "$UUID" ] || error "UUID mismatch! Saved: $SAVED_UUID | Real: $UUID"

    # Глобальные настройки fstab
    uci set fstab.@global[0].auto_mount="1" 2>/dev/null || true
    uci set fstab.@global[0].auto_swap="1" 2>/dev/null || true
    uci commit fstab 2>/dev/null || true

    log "extroot configured (UUID: $UUID)"
}

# =============================================================================
# Configure rwm (original overlay backup)
# =============================================================================
configure_rwm() {
    log "Configuring rwm mount (original overlay backup)..."

    ORIG="$(block info | sed -n -e '/MOUNT="[^"]*\/overlay"/s/:[[:space:]].*$//p')"

    if [ -z "$ORIG" ]; then
        warn "Could not auto-detect original overlay, trying common paths..."
        for dev in /dev/ubi0_1 /dev/mtdblock3 /dev/mtdblock4; do
            [ -e "$dev" ] && ORIG="$dev" && break
        done
    fi

    [ -n "$ORIG" ] || error "Could not find original overlay device"
    info "Original overlay device: $ORIG"

    uci -q delete fstab.rwm
    uci set fstab.rwm="mount"
    uci set fstab.rwm.device="$ORIG"
    uci set fstab.rwm.target="/rwm"
    uci set fstab.rwm.enabled="1"
    uci commit fstab

    log "rwm fstab entry configured"
}

# =============================================================================
# Enable fstab service
# =============================================================================
enable_fstab() {
    log "Enabling fstab service..."

    /etc/init.d/fstab enable && log "fstab service enabled" || \
        warn "Could not enable fstab via init.d"

    /etc/init.d/fstab boot && log "fstab boot triggered" || \
        warn "Could not trigger fstab boot"

    # Fallback
    block mount 2>/dev/null && log "block mount OK" || true
}

# =============================================================================
# Transfer overlay data
# =============================================================================
transfer_data() {
    log "Mounting $DEVICE to /mnt..."
    mount "$DEVICE" /mnt || error "Failed to mount $DEVICE to /mnt"

    log "Transferring overlay data to external disk..."
    tar -C "${MOUNT}" -cvf - . | tar -C /mnt -xf - || \
        error "Data transfer failed"

    sync
    umount /mnt
    log "Data transfer complete"
}

# =============================================================================
# Verify config before reboot
# =============================================================================
verify_config() {
    log "Verifying configuration..."

    echo ""
    info "--- fstab config ---"
    uci show fstab
    echo ""

    info "--- block info ---"
    block info
    echo ""

    info "--- Current mounts ---"
    mount | grep -E "overlay|mnt|sda" || true
    echo ""

    info "--- Disk space ---"
    df -h
    echo ""

    SAVED_UUID="$(uci get fstab.extroot.uuid 2>/dev/null)"
    REAL_UUID="$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)"

    if [ "$SAVED_UUID" = "$REAL_UUID" ]; then
        log "UUID match confirmed: $SAVED_UUID"
    else
        error "UUID MISMATCH! Saved: $SAVED_UUID | Real: $REAL_UUID"
    fi

    log "Configuration verified successfully"
}

# =============================================================================
# Main
# =============================================================================
main() {
    detect_pkg_manager
    install_packages
    detect_disk
    partition_disk
    generate_fstab
    configure_extroot
    configure_rwm
    enable_fstab
    transfer_data
    verify_config

    echo ""
    log "ExtRoot setup complete!"
    warn "After reboot check: df -h — overlay should show external disk size"
    warn "If still small: block info && mount | grep overlay"
    log "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    reboot
}

main "$@"
