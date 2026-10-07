#!/usr/bin/env bash
# Create or open a LUKS2 image, mount its ext4 filesystem,
# and optionally create fscrypt-encrypted directories.
#
# Existing image files are never modified without an explicit choice.

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

log_info() { printf '%s[INFO]%s %s\n' "$GREEN" "$NC" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_err()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }

MAPPER_NAME=""
MOUNT_POINT=""
MOUNTED=0
MAPPER_OPEN=0
FORMAT_IMAGE=1

cleanup() {
    if (( MOUNTED )); then
        if umount -- "$MOUNT_POINT"; then
            MOUNTED=0
        else
            log_err "Could not unmount $MOUNT_POINT"
        fi
    fi

    if (( MAPPER_OPEN )); then
        if cryptsetup luksClose "$MAPPER_NAME"; then
            MAPPER_OPEN=0
        else
            log_err "Could not close mapper $MAPPER_NAME"
        fi
    fi
}
trap cleanup EXIT

if (( EUID != 0 )); then
    log_err "Run this script as root, for example with sudo."
    exit 1
fi

for cmd in cryptsetup fscrypt mkfs.ext4 truncate mount umount find mountpoint realpath; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_err "Required command is missing: $cmd"
        exit 1
    fi
done

read -r -p "Image file path (e.g. /home/user/secure.img): " IMG_PATH
if [[ -z "$IMG_PATH" ]]; then
    log_err "No image path provided."
    exit 1
fi

# Expand ~/ using the invoking user's home directory when run with sudo.
if [[ "$IMG_PATH" == "~/"* ]]; then
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        USER_HOME="${HOME:-}"
    fi

    if [[ -z "$USER_HOME" ]]; then
        log_err "Could not determine the user's home directory."
        exit 1
    fi

    IMG_PATH="${USER_HOME}/${IMG_PATH#~/}"
fi

IMG_PATH=$(realpath -m -- "$IMG_PATH")

if [[ -e "$IMG_PATH" ]]; then
    if [[ ! -f "$IMG_PATH" ]]; then
        log_err "The path exists but is not a regular file: $IMG_PATH"
        exit 1
    fi

    printf '\nImage file already exists: %s\n' "$IMG_PATH"
    printf '  o) Open existing LUKS image without formatting it\n'
    printf '  f) Format it as a new LUKS image (ERASES existing data)\n'
    printf '  c) Cancel\n'

    read -r -p "Choose [o/f/c]: " ACTION

    case "$ACTION" in
        o|O)
            FORMAT_IMAGE=0
            ;;
        f|F)
            read -r -p "This will erase existing data. Type ERASE to confirm: " CONFIRM
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
        log_err "Could not create the image directory."
        exit 1
    fi

    # Create exclusively: do not overwrite a file that appeared in the meantime.
    if ! ( set -o noclobber; : > "$IMG_PATH" ); then
        log_err "Could not safely create the image file; it may already exist."
        exit 1
    fi

    if ! truncate -s 10G -- "$IMG_PATH"; then
        log_err "Could not size the image file."
        exit 1
    fi

    FORMAT_IMAGE=1
    log_info "Created a new 10-GiB image file."
fi

read -r -p "Mount point (e.g. /mnt/secure): " MOUNT_POINT
if [[ -z "$MOUNT_POINT" || "$MOUNT_POINT" != /* ]]; then
    log_err "Please provide an absolute mount point."
    exit 1
fi

MOUNT_POINT=$(realpath -m -- "$MOUNT_POINT")

if ! mkdir -p -- "$MOUNT_POINT"; then
    log_err "Could not create the mount point."
    exit 1
fi

if mountpoint -q -- "$MOUNT_POINT"; then
    log_err "Something is already mounted at $MOUNT_POINT"
    exit 1
fi

if [[ -n "$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    log_err "Mount point is not empty: $MOUNT_POINT"
    exit 1
fi

# Use a predictable, valid mapper name.
MAPPER_NAME="secure_img_$$"

if (( FORMAT_IMAGE )); then
    while true; do
        log_warn "LUKS formatting will initialize the image. Enter and confirm the LUKS passphrase when prompted."

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
                log_err "Stopping. The image may have been partially initialized."
                exit 1
            fi
        fi
    done
else
    log_info "Opening existing image; skipping LUKS formatting."
fi

log_info "Opening LUKS image as $MAPPER_NAME..."
if ! cryptsetup luksOpen "$IMG_PATH" "$MAPPER_NAME"; then
    log_err "Could not open the LUKS image. Check that it is a valid LUKS volume and that the passphrase is correct."
    exit 1
fi
MAPPER_OPEN=1

if (( FORMAT_IMAGE )); then
    log_info "Creating ext4 filesystem..."
    if ! mkfs.ext4 -L secure_vol "/dev/mapper/$MAPPER_NAME"; then
        log_err "Could not create the ext4 filesystem."
        exit 1
    fi
else
    log_info "Keeping the existing filesystem; skipping mkfs.ext4."
fi

log_info "Mounting at $MOUNT_POINT..."
if ! mount "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"; then
    log_err "Could not mount the filesystem."
    exit 1
fi
MOUNTED=1

if (( FORMAT_IMAGE )); then
    log_info "Setting up fscrypt on the new filesystem..."
    if ! fscrypt setup "$MOUNT_POINT"; then
        log_err "fscrypt setup failed."
        exit 1
    fi
else
    log_info "Using the existing filesystem. fscrypt setup is not repeated."
    log_warn "The existing filesystem must already be set up for fscrypt to encrypt directories."
fi

while true; do
    printf '\n'
    read -r -p "Name of an fscrypt-encrypted directory (blank to finish): " DIR_NAME

    if [[ -z "$DIR_NAME" ]]; then
        break
    fi

    # Only allow one directory name, not a path.
    if [[ "$DIR_NAME" == "." || "$DIR_NAME" == ".." || "$DIR_NAME" == */* ]]; then
        log_err "Enter a single directory name, without slashes."
        continue
    fi

    DIR_PATH="$MOUNT_POINT/$DIR_NAME"

    if [[ -e "$DIR_PATH" ]]; then
        log_err "That path already exists: $DIR_PATH"
        continue
    fi

    if ! mkdir -- "$DIR_PATH"; then
        log_err "Could not create directory: $DIR_PATH"
        continue
    fi

    log_info "Starting fscrypt encryption for $DIR_PATH"
    log_info "Follow the fscrypt prompts to select a protector and enter its passphrase."

    if fscrypt encrypt "$DIR_PATH"; then
        log_info "Encrypted directory created: $DIR_PATH"
    else
        STATUS=$?
        log_err "fscrypt encrypt failed (exit status $STATUS)."
        log_warn "The directory was left in place; inspect it before retrying."
    fi
done

log_info "Finished. The volume is mounted at: $MOUNT_POINT"
log_info "To close it: umount '$MOUNT_POINT' && cryptsetup luksClose '$MAPPER_NAME'"
