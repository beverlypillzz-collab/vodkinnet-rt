#!/bin/sh

echo ""
echo "============================================="
echo "  !Vodkin greets you!"
echo "  OpenWrt ExtRoot Setup Script v2.0"
echo "============================================="
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

    # Enable fstab service — критично для монтирования при загрузке
    log "Enabling fstab service..."
    service fstab enable 2>/dev/null || block enable 2>/dev/null || \
        warn "Could not enable fstab service automatically"
}

# =============================================================================
# Detect USB disk
# =============================================================================
detect_disk() {
    log "Detecting USB storage devices..."
    echo ""
    info "Devices in /sys/block:"
    ls -l /sys/block | grep -v "loop\|ram\|mtd\|ubi" || true

    echo ""
    info "Available /dev/sd* devices:"
    ls /dev/sd* 2>/dev/null || info "No /dev/sd* devices found yet — plug in USB and retry"

    echo ""
    warn "Enter the disk to use for extroot (e.g. /dev/sda):"
    read -r DISK

    [ -b "$DISK" ] || error "Device $DISK not found or not a block device"
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

    log "Waiting for partition to appear..."
    sleep 3

    # Verify partition exists
    [ -b "$DEVICE" ] || error "Partition $DEVICE did not appear after partitioning"

    log "Formatting ${DEVICE} as ext4..."
    mkfs.ext4 -L extroot "$DEVICE" || error "Formatting failed"

    log "Verifying filesystem..."
    e2fsck -n "$DEVICE" && log "Filesystem OK" || error "Filesystem check failed"

    log "Partition ready: $DEVICE"
}

# =============================================================================
# Configure extroot fstab
# =============================================================================
configure_extroot() {
    log "Configuring extroot mount..."

    # Получаем UUID напрямую через blkid если block не отдаёт
    UUID="$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)"

    if [ -z "$UUID" ]; then
        warn "block info did not return UUID, trying blkid..."
        UUID="$(blkid -s UUID -o value "$DEVICE" 2>/dev/null)"
    fi

    [ -n "$UUID" ] || error "Could not determine UUID of $DEVICE"
    info "UUID: $UUID"

    # Находим точку монтирования overlay
    MOUNT="$(block info | grep -o 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)"
    [ -n "$MOUNT" ] || MOUNT="/overlay"
    info "Overlay mount point: $MOUNT"

    # Записываем в fstab
    uci -q delete fstab.extroot
    uci set fstab.extroot="mount"
    uci set fstab.extroot.uuid="$UUID"
    uci set fstab.extroot.target="$MOUNT"
    uci set fstab.extroot.enabled="1"
    uci commit fstab

    # Проверяем что записалось
    SAVED_UUID="$(uci get fstab.extroot.uuid 2>/dev/null)"
    [ "$SAVED_UUID" = "$UUID" ] || error "UUID mismatch after saving! Got: $SAVED_UUID"

    log "extroot fstab entry configured and verified (UUID: $UUID)"
}

# =============================================================================
# Configure rwm (original overlay backup)
# =============================================================================
configure_rwm() {
    log "Configuring rwm mount (original overlay backup)..."

    ORIG="$(block info | sed -n -e '/MOUNT="[^"]*\/overlay"/s/:[[:space:]].*$//p')"

    if [ -z "$ORIG" ]; then
        warn "Could not auto-detect original overlay device, trying common paths..."
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
# Verify fstab config before reboot
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

    # Финальная проверка UUID
    SAVED_UUID="$(uci get fstab.extroot.uuid 2>/dev/null)"
    REAL_UUID="$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)"

    if [ "$SAVED_UUID" = "$REAL_UUID" ]; then
        log "UUID match confirmed: $SAVED_UUID"
    else
        error "UUID MISMATCH! Saved: $SAVED_UUID | Real: $REAL_UUID — fix before reboot!"
    fi

    # Проверяем что fstab включён
    FSTAB_ENABLED="$(uci get fstab.@global[0].auto_mount 2>/dev/null)"
    info "fstab auto_mount: ${FSTAB_ENABLED:-not set}"

    # Включаем глобально
    uci set fstab.@global[0].auto_mount="1" 2>/dev/null || true
    uci set fstab.@global[0].auto_swap="1" 2>/dev/null || true
    uci commit fstab 2>/dev/null || true

    log "Configuration verified successfully"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "============================================="
    echo "  !Vodkin greets you!"
    echo "  OpenWrt ExtRoot Setup Script"
    echo "  Supports: opkg (23.x) and apk (24.x+)"
    echo "  v2.0 — with verification & fixes"
    echo "============================================="
    echo ""

    detect_pkg_manager
    install_packages
    detect_disk
    partition_disk
    configure_extroot
    configure_rwm
    transfer_data
    verify_config

    echo ""
    log "ExtRoot setup complete!"
    warn "After reboot, run: df -h — overlay should show external disk size"
    warn "If overlay is still small after reboot, check: block info && mount | grep overlay"
    log "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    reboot
}

main "$@"

main "$@"
