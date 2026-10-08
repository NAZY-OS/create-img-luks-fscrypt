#!/usr/bin/env bash

set -uo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_err()  { printf '[ERROR] %s\n' "$*" >&2; }

MAPPER_NAME=""
MOUNT_POINT=""
MOUNTED=0
MAPPER_OPEN=0
FORMAT_IMAGE=1

cleanup() {
    local exit_status=$?
    if (( exit_status != 0 )); then
        log_warn "An unexpected error occurred (exit code $exit_status). Cleaning up..."
        
        if (( MOUNTED )); then
            if umount -- "$MOUNT_POINT"; then
                log_info "Successfully unmounted $MOUNT_POINT."
                MOUNTED=0
            else
                log_err "Failed to unmount $MOUNT_POINT."
            fi
        fi

        if (( MAPPER_OPEN )); then
            if cryptsetup luksClose "$MAPPER_NAME"; then
                log_info "Successfully closed mapper $MAPPER_NAME."
                MAPPER_OPEN=0
            else
                log_err "Failed to close mapper $MAPPER_NAME."
            fi
        fi
    fi
}
trap cleanup EXIT

if (( EUID != 0 )); then
    log_err "This script must be executed with root privileges (e.g. sudo)."
    exit 1
fi

REQUIRED_COMMANDS=(cryptsetup fscrypt mkfs.ext4 truncate mount umount find mountpoint realpath modprobe)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_err "Required command is missing: $cmd"
        exit 1
    fi
done

REQUIRED_MODULES=(xts aes_generic ext4 dm_crypt)
for mod in "${REQUIRED_MODULES[@]}"; do
    if ! modprobe -n "$mod" >/dev/null 2>&1; then
        log_warn "Kernel module '$mod' may not be available."
    else
        if ! lsmod | grep -q "^$mod\b"; then
            log_info "Loading kernel module: $mod"
            if ! modprobe "$mod"; then
                log_err "Failed to load kernel module: $mod"
                exit 1
            fi
        fi
    fi
done

read -r -p "Image file path (e.g. /home/user/secure.img): " IMG_PATH
if [[ -z "$IMG_PATH" ]]; then
    log_err "No image path provided."
    exit 1
fi

if [[ "$IMG_PATH" == "~/"* ]]; then
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        USER_HOME="${HOME:-}"
    fi

    if [[ -z "$USER_HOME" ]]; then
        log_err "Could not determine home directory."
        exit 1
    fi

    IMG_PATH="${USER_HOME}/${IMG_PATH#~/}"
fi

IMG_PATH=$(realpath -m -- "$IMG_PATH")

if [[ -e "$IMG_PATH" ]]; then
    if [[ ! -f "$IMG_PATH" ]]; then
        log_err "Path exists but is not a regular file: $IMG_PATH"
        exit 1
    fi

    printf '\nImage file already exists: %s\n' "$IMG_PATH"
    printf '  o) Open existing LUKS image without formatting\n'
    printf '  f) Format as a new LUKS image (ERASES existing data)\n'
    printf '  c) Cancel\n'

    read -r -p "Choose [o/f/c]: " ACTION

    case "$ACTION" in
        o|O)
            FORMAT_IMAGE=0
            ;;
        f|F)
            read -r -p "Create a backup of the existing image before formatting? [y/N]: " BACKUP_CHOICE
            if [[ "$BACKUP_CHOICE" =~ ^[Yy]$ ]]; then
                BACKUP_PATH="${IMG_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
                log_info "Creating backup at $BACKUP_PATH..."
                if cp -- "$IMG_PATH" "$BACKUP_PATH"; then
                    log_info "Backup created successfully."
                else
                    log_err "Failed to create backup. Aborting."
                    exit 1
                fi
            fi

            read -r -p "This will permanently erase existing data. Type ERASE to confirm: " CONFIRM
            if [[ "$CONFIRM" != "ERASE" ]]; then
                log_info "Cancelled."
                exit 0
            fi
            FORMAT_IMAGE=1
            ;;
        *)
            log_info "Cancelled."
            exit 0
            ;;
    esac
else
    if ! mkdir -p -- "$(dirname -- "$IMG_PATH")"; then
        log_err "Could not create image directory."
        exit 1
    fi

    printf '\n[NOTE] You can create image files manually using tools like:\n'
    printf '  - fallocate -l 10G %s\n' "$IMG_PATH"
    printf '  - dd if=/dev/zero of=%s bs=1M count=10240 status=progress\n\n' "$IMG_PATH"

    read -r -p "Enter desired size for the new image file (e.g. 5G, 10G, 500M) [Default: 10G]: " USER_SIZE
    USER_SIZE="${USER_SIZE:-10G}"

    if [[ ! "$USER_SIZE" =~ ^[0-9]+[KMGTPE]?$ ]]; then
        log_err "Invalid size format: $USER_SIZE"
        exit 1
    fi

    if ! ( set -o noclobber; : > "$IMG_PATH" ); then
        log_err "Could not safely create image file; it may already exist."
        exit 1
    fi

    log_info "Allocating $USER_SIZE image file..."
    if ! truncate -s "$USER_SIZE" -- "$IMG_PATH"; then
        log_err "Could not allocate specified size."
        exit 1
    fi

    FORMAT_IMAGE=1
    log_info "Created new $USER_SIZE image file at $IMG_PATH."
fi

read -r -p "Mount point (e.g. /mnt/secure): " MOUNT_POINT
if [[ -z "$MOUNT_POINT" || "$MOUNT_POINT" != /* ]]; then
    log_err "Please provide a valid absolute mount point."
    exit 1
fi

MOUNT_POINT=$(realpath -m -- "$MOUNT_POINT")

if [[ ! -d "$MOUNT_POINT" ]]; then
    log_info "Creating mount point directory: $MOUNT_POINT"
    if ! mkdir -p -- "$MOUNT_POINT"; then
        log_err "Could not create mount point directory."
        exit 1
    fi
else
    log_info "Mount point directory exists: $MOUNT_POINT"
fi

if mountpoint -q -- "$MOUNT_POINT"; then
    log_err "Active mount detected at $MOUNT_POINT."
    exit 1
fi

if [[ -n "$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    log_err "Mount point directory is not empty: $MOUNT_POINT"
    exit 1
fi

MAPPER_NAME="secure_img_$$"

if (( FORMAT_IMAGE )); then
    while true; do
        log_warn "LUKS formatting will initialize the volume. Enter passphrase when prompted."

        if cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            "$IMG_PATH"
        then
            break
        else
            STATUS=$?
            log_warn "cryptsetup luksFormat failed (exit status $STATUS)."
            read -r -p "Try LUKS formatting again? [y/N]: " RETRY

            if [[ ! "$RETRY" =~ ^[Yy]$ ]]; then
                log_err "Aborting."
                exit 1
            fi
        fi
    done
else
    log_info "Opening existing image; skipping formatting."
fi

log_info "Opening LUKS volume as $MAPPER_NAME..."
if ! cryptsetup luksOpen "$IMG_PATH" "$MAPPER_NAME"; then
    log_err "Could not open LUKS volume."
    exit 1
fi
MAPPER_OPEN=1

if (( FORMAT_IMAGE )); then
    log_info "Creating ext4 filesystem..."
    if ! mkfs.ext4 -L secure_vol "/dev/mapper/$MAPPER_NAME"; then
        log_err "Could not create ext4 filesystem."
        exit 1
    fi
else
    log_info "Skipping mkfs.ext4 (preserving existing filesystem)."
fi

log_info "Mounting filesystem at $MOUNT_POINT..."
if ! mount "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"; then
    log_err "Could not mount filesystem."
    exit 1
fi
MOUNTED=1

if (( FORMAT_IMAGE )); then
    log_info "Initializing fscrypt metadata..."
    if ! fscrypt setup "$MOUNT_POINT"; then
        log_err "fscrypt setup failed."
        exit 1
    fi
else
    log_info "Skipping fscrypt setup initialization."
fi

log_info "--- fscrypt Directory Configuration ---"
log_info "fscrypt handles multiple passwords through protectors."

while true; do
    printf '\n'
    read -r -p "Name of an fscrypt-encrypted directory to create (blank to finish): " DIR_NAME

    if [[ -z "$DIR_NAME" ]]; then
        break
    fi

    if [[ "$DIR_NAME" == "." || "$DIR_NAME" == ".." || "$DIR_NAME" == */* ]]; then
        log_err "Enter a single directory name without path slashes."
        continue
    fi

    DIR_PATH="$MOUNT_POINT/$DIR_NAME"

    if [[ -e "$DIR_PATH" ]]; then
        log_err "Path already exists: $DIR_PATH"
        continue
    fi

    if ! mkdir -- "$DIR_PATH"; then
        log_err "Could not create directory: $DIR_PATH"
        continue
    fi

    log_info "Configuring fscrypt encryption for: $DIR_PATH"

    if fscrypt encrypt "$DIR_PATH"; then
        log_info "Successfully created encrypted directory: $DIR_PATH"
    else
        STATUS=$?
        log_err "fscrypt encrypt failed (exit status $STATUS)."
        log_warn "Directory was left intact."
    fi
done

trap - EXIT

log_info "========================================================================"
log_info "Completed successfully! Volume mounted at: $MOUNT_POINT"
log_info "To close: umount '$MOUNT_POINT' && cryptsetup luksClose '$MAPPER_NAME'"
log_info "========================================================================"
