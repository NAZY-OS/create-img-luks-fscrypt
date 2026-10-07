#!/bin/bash
# LUKS + fscrypt Secure Image Creator
# Creates a LUKS image, formats ext4, enables fscrypt, and mounts it.

set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Check Root
if [[ $EUID -ne 0 ]]; then
    log_err "Please run as root (sudo)."
    exit 1
fi

# 2. Check Dependencies
for cmd in cryptsetup fscrypt mkfs.ext4 truncate; do
    command -v $cmd &> /dev/null || { log_err "Missing: $cmd"; exit 1; }
done

# 3. Ask for Image Path
read -p "Path for image file (e.g., ~/imgs/secure.img): " IMG_PATH
IMG_PATH="${IMG_PATH/#\~/$HOME}"

# Create dir if needed
mkdir -p "$(dirname "$IMG_PATH")"

# 4. Create or Verify Image
if [[ -f "$IMG_PATH" ]]; then
    log_warn "File exists! Data will be erased."
    read -p "Continue? [y/N]: " CONF
    [[ "$CONF" =~ ^[Yy]$ ]] || exit 1
else
    log_info "Creating 10GB image..."
    truncate -s 10G "$IMG_PATH"
fi

# 5. Ask for Mount Point
read -p "Mount point (e.g., /mnt/secure): " MOUNT_POINT
mkdir -p "$MOUNT_POINT"

# 6. Format LUKS
log_info "Formatting LUKS..."
cryptsetup luksFormat --type luks2 --cipher aes-256-xts-plain64 --key-size 512 "$IMG_PATH"

# 7. Open LUKS
MAPPER_NAME="luks_$(basename "$IMG_PATH" .img)"
log_info "Opening LUKS as $MAPPER_NAME..."
cryptsetup luksOpen "$IMG_PATH" "$MAPPER_NAME"

# 8. Format ext4
log_info "Formatting ext4..."
mkfs.ext4 -L "secure_vol" "/dev/mapper/$MAPPER_NAME"

# 9. Setup fscrypt
log_info "Setting up fscrypt..."
# fscrypt setup asks for a password interactively
fscrypt setup "/dev/mapper/$MAPPER_NAME"

# 10. Mount
log_info "Mounting to $MOUNT_POINT..."
mount "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"

# 11. Success
log_info "Done! Mounted at: $MOUNT_POINT"
log_info "To unmount: umount $MOUNT_POINT && cryptsetup luksClose $MAPPER_NAME"
