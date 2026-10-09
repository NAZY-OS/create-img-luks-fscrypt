#!/usr/bin/env bash
#
# fscrypt-opener backend (Multi-LUKS, Daemon, API & CLI)
# Licensed under GNU GPL v3

set -uo pipefail

VERSION="2.5.0"
CONFIG_DIR="/etc/fscrypt-opener"
RUN_DIR="/run/fscrypt-opener"
CONFIG_FILE="$CONFIG_DIR/config"
PID_FILE="$RUN_DIR/daemon.pid"

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_err()  { printf '[ERROR] %s\n' "$*" >&2; }

# --- Initialisierung ---
init_environment() {
    mkdir -p "$CONFIG_DIR" "$RUN_DIR" 2>/dev/null || true
    chmod 755 "$RUN_DIR" 2>/dev/null || true
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat << 'EOF' > "$CONFIG_FILE"
# Format: MAPPER_NAME|IMG_PATH|MOUNT_POINT|FSCRYPT_METHOD
# Methods: custom, login, raw_key
secure_img1|/var/lib/secure1.img|/mnt/secure1|custom
EOF
    fi
}

check_system_requirements() {
    if (( EUID != 0 )); then
        log_err "This script must be executed with root privileges."
        return 1
    fi
    local required_commands=(cryptsetup mount umount fscrypt realpath mountpoint findmnt)
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_err "Missing required command: $cmd"
            return 1
        fi
    done
    return 0
}

# --- LUKS & Mount Management ---
open_luks_container() {
    local mapper_name="$1"
    local img_path="$2"

    if cryptsetup status "$mapper_name" >/dev/null 2>&1; then
        return 0
    fi
    [[ ! -f "$img_path" ]] && return 1

    if [[ -t 0 ]]; then
        cryptsetup luksOpen "$img_path" "$mapper_name" || return 1
    else
        cryptsetup luksOpen --key-file - "$img_path" "$mapper_name" || return 1
    fi
}

mount_filesystem() {
    local mapper_name="$1"
    local mount_point="$2"

    if ! mountpoint -q -- "$mount_point"; then
        mkdir -p -- "$mount_point"
        mount "/dev/mapper/$mapper_name" "$mount_point" || return 1
    fi
    return 0
}

# --- FSCRYPT Management (Unterstützt alle 3 Methoden) ---
unlock_fscrypt_folder() {
    local target_dir="$1"
    local method="$2"
    local key_file="${3:-}"

    if [[ -d "$target_dir/.fscrypt" ]] && fscrypt status "$target_dir" 2>&1 | grep -qi "unlocked: yes"; then
        return 0
    fi

    log_info "Unlocking fscrypt directory ($method): $target_dir"
    local cmd=("fscrypt" "unlock" "--quiet")

    case "$method" in
        raw_key)
            if [[ -n "$key_file" && -f "$key_file" ]]; then
                cmd+=("--key=$key_file")
            else
                log_err "Raw key method requires a valid key file."
                return 1
            fi
            ;;
        login|custom|*)
            # Läuft nicht-interaktiv über API/D-Bus
            ;;
    esac

    cmd+=("$target_dir")
    "${cmd[@]}" || {
        log_err "Failed to unlock fscrypt directory: $target_dir"
        return 1
    }
    return 0
}

lock_fscrypt_folder() {
    local target_dir="$1"
    local safe_name="${target_dir//[^a-zA-Z0-9_]/_}"
    fscrypt lock "$target_dir"
    rm -f "$RUN_DIR/timer_${safe_name}"
}

# --- JSON API Status-Ausgabe ---
api_output_json_status() {
    printf '{\n  "containers": [\n'
    local first_container=true

    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='|' read -r mapper_name img_path mount_point method; do
            [[ "$mapper_name" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$mapper_name" ]] && continue
            
            mapper_name=$(echo "$mapper_name" | xargs)
            img_path=$(echo "$img_path" | xargs)
            mount_point=$(echo "$mount_point" | xargs)
            method=$(echo "$method" | xargs)

            local luks_locked=true
            local actual_mount="N/A"

            if cryptsetup status "$mapper_name" >/dev/null 2>&1; then
                luks_locked=false
                actual_mount=$(findmnt -n -o TARGET "/dev/mapper/$mapper_name" 2>/dev/null || echo "$mount_point")
            fi

            [[ "$first_container" == "true" ]] || printf ',\n'
            printf '    {\n'
            printf '      "mapper": "%s",\n' "$mapper_name"
            printf '      "image": "%s",\n' "$img_path"
            printf '      "mount_point": "%s",\n' "$actual_mount"
            printf '      "luks_locked": %s,\n' "$luks_locked"
            printf '      "fscrypt_folders": [\n'

            if [[ "$luks_locked" == "false" && -d "$actual_mount" ]]; then
                local first_folder=true
                while IFS= read -r -d '' dir; do
                    local rel_path="${dir#$actual_mount/}"
                    [[ "$rel_path" == "lost+found" || "$rel_path" =~ ^\. ]] && continue

                    local locked=true
                    fscrypt status "$dir" 2>&1 | grep -qi "unlocked: yes" && locked=false

                    [[ "$first_folder" == "true" ]] || printf ',\n'
                    printf '        {\n'
                    printf '          "name": "%s",\n' "$rel_path"
                    printf '          "path": "%s",\n' "$dir"
                    printf '          "locked": %s,\n' "$locked"
                    printf '          "method": "%s"\n' "$method"
                    printf '        }'
                    first_folder=false
                done < <(find "$actual_mount" -mindepth 1 -maxdepth 1 -type d -print0)
            fi

            printf '\n      ]\n'
            printf '    }'
            first_container=false
        done < "$CONFIG_FILE"
    fi

    printf '\n  ]\n}\n'
}

# --- Daemon Management ---
start_daemon() {
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        log_info "Daemon is already running."
        return 0
    fi
    check_system_requirements || exit 1
    log_info "Starting fscrypt-opener background daemon..."
    (
        while true; do sleep 30; done
    ) &
    echo $! > "$PID_FILE"
    log_info "Daemon started with PID $(cat "$PID_FILE")."
}

stop_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        log_info "Daemon stopped."
    else
        log_info "Daemon is not running."
    fi
}

restart_daemon() {
    stop_daemon
    start_daemon
}

show_help() {
    cat << EOF
Usage: $0 [COMMAND] [ARGS...]

Commands:
  start                     Start background daemon
  stop                      Stop background daemon
  restart                   Restart background daemon
  status                    Output JSON status of containers
  open                      Open all configured LUKS containers
  close                     Close all LUKS containers
  unlock <dir> <method> [key] Unlock fscrypt directory
  lock <dir>                Lock fscrypt directory
  -h, --help                Display help
  --version                 Display version
EOF
}

# --- Dispatcher ---
main() {
    init_environment
    case "${1:-}" in
        start) start_daemon ;;
        stop) stop_daemon ;;
        restart) restart_daemon ;;
        status|api_status) api_output_json_status ;;
        open|api_open)
            check_system_requirements || exit 1
            while IFS='|' read -r mapper img mount _; do
                [[ "$mapper" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$mapper" ]] && continue
                open_luks_container "$(echo "$mapper" | xargs)" "$(echo "$img" | xargs | realpath -m --)" || continue
                mount_filesystem "$(echo "$mapper" | xargs)" "$(echo "$mount" | xargs | realpath -m --)" || continue
            done < "$CONFIG_FILE"
            ;;
        close|api_close)
            if [[ -f "$CONFIG_FILE" ]]; then
                while IFS='|' read -r mapper _ mount _; do
                    [[ "$mapper" =~ ^[[:space:]]*# ]] && continue
                    [[ -z "$mapper" ]] && continue
                    umount "$(echo "$mount" | xargs)" 2>/dev/null || true
                    cryptsetup luksClose "$(echo "$mapper" | xargs)" 2>/dev/null || true
                done < "$CONFIG_FILE"
            fi
            ;;
        unlock|api_unlock_folder)
            check_system_requirements || exit 1
            unlock_fscrypt_folder "${2:-}" "${3:-custom}" "${4:-}"
            ;;
        lock|api_lock_folder)
            check_system_requirements || exit 1
            lock_fscrypt_folder "${2:-}"
            ;;
        -h|--help) show_help ;;
        --version) echo "fscrypt-opener v$VERSION" ;;
        *) show_help; exit 1 ;;
    esac
}

main "$@"
