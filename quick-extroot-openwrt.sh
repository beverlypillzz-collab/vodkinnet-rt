#!/bin/sh
# =============================================================================
# quick-extroot-openwrt.sh
# ExtRoot setup script for OpenWrt (supports both opkg and apk)
# Based on: https://openwrt.org/docs/guide-user/additional-software/extroot_configuration
# =============================================================================

set -e

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
# Detect USB disk
# =============================================================================
detect_disk() {
    log "Detecting USB storage devices..."
    ls -l /sys/block | grep -v "loop\|ram\|mtd\|ubi" || true

    info "Available block devices:"
    ls /dev/sd* 2>/dev/null || info "No /dev/sd* devices found yet"

    echo ""
    warn "Enter the disk to use for extroot (e.g. /dev/sda):"
    read -r DISK

    [ -b "$DISK" ] || error "Device $DISK not found"
    log "Using disk: $DISK"
}

# =============================================================================
# Partition and format
# =============================================================================
partition_disk() {
    warn "ALL DATA ON $DISK WILL BE ERASED! Continue? (yes/no)"
    read -r CONFIRM
    [ "$CONFIRM" = "yes" ] || error "Aborted by user"

    log "Partitioning $DISK..."
    parted -s "$DISK" -- mklabel gpt mkpart extroot 2048s -2048s || \
        error "Partitioning failed"

    DEVICE="${DISK}1"

    # Wait for device to appear
    sleep 2

    log "Formatting ${DEVICE} as ext4..."
    mkfs.ext4 -L extroot "$DEVICE" || error "Formatting failed"

    log "Partition ready: $DEVICE"
}

# =============================================================================
# Configure extroot fstab
# =============================================================================
configure_extroot() {
    log "Configuring extroot mount..."

    eval "$(block info "$DEVICE" | grep -o -e 'UUID="[^"]*"')"
    eval "$(block info | grep -o -e 'MOUNT="[^"]*/overlay"')"

    [ -n "$UUID" ]  || error "Could not determine UUID of $DEVICE"
    [ -n "$MOUNT" ] || error "Could not find overlay mount point"

    info "UUID:  $UUID"
    info "MOUNT: $MOUNT"

    uci -q delete fstab.extroot
    uci set fstab.extroot="mount"
    uci set fstab.extroot.uuid="$UUID"
    uci set fstab.extroot.target="$MOUNT"
    uci commit fstab

    log "extroot fstab entry configured"
}

# =============================================================================
# Configure rwm (original overlay backup)
# =============================================================================
configure_rwm() {
    log "Configuring rwm mount (original overlay backup)..."

    ORIG="$(block info | sed -n -e '/MOUNT="[^"]*\/overlay"/s/:[[:space:]].*$//p')"

    [ -n "$ORIG" ] || error "Could not find original overlay device"
    info "Original overlay: $ORIG"

    uci -q delete fstab.rwm
    uci set fstab.rwm="mount"
    uci set fstab.rwm.device="$ORIG"
    uci set fstab.rwm.target="/rwm"
    uci commit fstab

    log "rwm fstab entry configured"
}

# =============================================================================
# Transfer overlay data
# =============================================================================
transfer_data() {
    log "Mounting $DEVICE to /mnt..."
    mount "$DEVICE" /mnt || error "Failed to mount $DEVICE"

    log "Transferring overlay data to external disk..."
    tar -C "$MOUNT" -cvf - . | tar -C /mnt -xf - || \
        error "Data transfer failed"

    umount /mnt
    log "Data transfer complete"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "============================================="
    echo "  !Vodkin greets you!"
    echo "============================================="
    echo "  OpenWrt ExtRoot Setup Script"
    echo "  Supports: opkg (23.x) and apk (24.x+)"
    echo "============================================="
    echo ""

    detect_pkg_manager
    install_packages
    detect_disk
    partition_disk
    configure_extroot
    configure_rwm
    transfer_data

    echo ""
    log "ExtRoot setup complete!"
    log "Rebooting in 5 seconds..."
    sleep 5
    reboot
}

main "$@"
