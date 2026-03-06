#!/bin/bash
# common.sh v0.3 - Common utilities and logging functions

set -euo pipefail

if [[ -n "${_WSCODE_COMMON_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
readonly _WSCODE_COMMON_SH_LOADED=1

# Version
readonly VERSION="0.3.0"

# Constants
readonly SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR="$(cd "${SRC_DIR}/.." && pwd)"
readonly LIB_DIR="${SRC_DIR}/lib"
readonly TEMPLATE_DIR="${SRC_DIR}/templates"
readonly CONFIG_DIR="${REPO_DIR}/config"
readonly STATE_DIR="${REPO_DIR}/state"
readonly BACKUP_DIR="${STATE_DIR}/backups"

readonly ETC_CONFIG_DIR="/etc/wscode"
readonly CONFIG_FILE_DEFAULT="${ETC_CONFIG_DIR}/config.env"
readonly USERS_ALLOW_FILE_DEFAULT="${ETC_CONFIG_DIR}/users.allow"
readonly USERS_DENY_FILE_DEFAULT="${ETC_CONFIG_DIR}/users.deny"

readonly CONFIG_FILE="${WSCODE_CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"
readonly USERS_ALLOW_FILE="${WSCODE_USERS_ALLOW:-$USERS_ALLOW_FILE_DEFAULT}"
readonly USERS_DENY_FILE="${WSCODE_USERS_DENY:-$USERS_DENY_FILE_DEFAULT}"

# Global variables
DEBUG_MODE=0
DRY_RUN=0
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Minimum version requirements
readonly MIN_CODESERVER_VERSION="4.0.0"

# Logging functions
log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_debug() { [[ $DEBUG_MODE -eq 1 ]] && echo "[DEBUG] $*" >&2 || true; }
log_success() { echo "[SUCCESS] $*" >&2; }

# Error handler
error_exit() { log_error "$1"; exit 1; }

# Check if running as root
check_root() { [[ $EUID -eq 0 ]] || error_exit "This script must be run as root"; }

# Check if command exists
command_exists() { command -v "$1" &> /dev/null; }

strip_comment_and_trim() {
    local value="$1"
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

assert_secure_file() {
    local path="$1"
    local max_mode="${2:-600}"

    [[ -f "$path" ]] || error_exit "File not found: $path"
    [[ -L "$path" ]] && error_exit "Refusing symlink for security-sensitive file: $path"

    local owner
    owner=$(stat -c '%U:%G' "$path")
    [[ "$owner" == "root:root" ]] || error_exit "Insecure owner for $path: $owner (expected root:root)"

    local mode
    mode=$(stat -c '%a' "$path")
    if (( 10#$mode > 10#$max_mode )); then
        error_exit "Insecure permissions for $path: $mode (expected <= $max_mode)"
    fi
}

# Version comparison function
version_compare() {
    local ver1="$1"
    local op="$2"
    local ver2="$3"

    local result
    result=$(printf '%s\n%s' "$ver1" "$ver2" | sort -V | head -n1)

    case "$op" in
        "lt"|"<")
            [[ "$result" == "$ver1" ]] && [[ "$ver1" != "$ver2" ]]
            ;;
        "le"|"<=")
            [[ "$result" == "$ver1" ]]
            ;;
        "gt"|">")
            [[ "$result" == "$ver2" ]] && [[ "$ver1" != "$ver2" ]]
            ;;
        "ge"|">=")
            [[ "$result" == "$ver2" ]]
            ;;
        "eq"|"==")
            [[ "$ver1" == "$ver2" ]]
            ;;
        *)
            error_exit "Invalid comparison operator: $op"
            ;;
    esac
}

# Detect code-server binary path
detect_codeserver_binary() {
    local binary_path

    if command_exists code-server; then
        binary_path=$(command -v code-server)
        log_debug "Found code-server at: $binary_path"
        echo "$binary_path"
        return 0
    fi

    local common_paths=(
        "/usr/bin/code-server"
        "/usr/local/bin/code-server"
        "/opt/code-server/bin/code-server"
        "$HOME/.local/bin/code-server"
    )

    for path in "${common_paths[@]}"; do
        if [[ -x "$path" ]]; then
            log_debug "Found code-server at: $path"
            echo "$path"
            return 0
        fi
    done

    log_error "code-server binary not found"
    return 1
}

resolve_users_allow_file() {
    if [[ -f "$USERS_ALLOW_FILE" ]]; then
        printf '%s\n' "$USERS_ALLOW_FILE"
    else
        printf '%s\n' "${CONFIG_DIR}/users.allow"
    fi
}

resolve_users_deny_file() {
    if [[ -f "$USERS_DENY_FILE" ]]; then
        printf '%s\n' "$USERS_DENY_FILE"
    else
        printf '%s\n' "${CONFIG_DIR}/users.deny"
    fi
}

user_exists() {
    local username="$1"
    getent passwd "$username" >/dev/null 2>&1
}

is_valid_username() {
    local username="$1"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

get_user_home() {
    local username="$1"
    local home
    home=$(getent passwd "$username" | cut -d: -f6)
    [[ -n "$home" ]] || error_exit "Could not determine home directory for $username"
    echo "$home"
}

# Load configuration
load_config() {
    [[ -f "$CONFIG_FILE" ]] || error_exit "Config file not found: $CONFIG_FILE"

    assert_secure_file "$CONFIG_FILE" 600
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    [[ -z "${CF_TUNNEL_NAME:-}" ]] && error_exit "CF_TUNNEL_NAME is required"
    [[ -z "${CF_DOMAIN_BASE:-}" ]] && error_exit "CF_DOMAIN_BASE is required"

    if [[ -z "${CF_TUNNEL_TOKEN:-}" ]] && [[ -z "${CF_CREDENTIALS_FILE:-}" ]]; then
        error_exit "Either CF_TUNNEL_TOKEN or CF_CREDENTIALS_FILE must be set"
    fi

    if [[ -n "${CF_CREDENTIALS_FILE:-}" ]]; then
        assert_secure_file "$CF_CREDENTIALS_FILE" 600
    fi
}

read_list_file() {
    local list_file="$1"
    local -n out_ref="$2"

    [[ -f "$list_file" ]] || return 0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line
        line=$(strip_comment_and_trim "$raw_line")
        [[ -z "$line" ]] && continue

        if ! is_valid_username "$line"; then
            log_warn "Ignoring invalid username in $list_file: $line"
            continue
        fi
        out_ref+=("$line")
    done < "$list_file"
}

# Get enabled users
get_enabled_users() {
    local allow_file deny_file
    allow_file=$(resolve_users_allow_file)
    deny_file=$(resolve_users_deny_file)

    local -a users=()
    if [[ -s "$allow_file" ]]; then
        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            local user
            user=$(strip_comment_and_trim "$raw_line")
            [[ -z "$user" ]] && continue

            if ! is_valid_username "$user"; then
                log_warn "Ignoring invalid username in allowlist: $user"
                continue
            fi

            if user_exists "$user"; then
                users+=("$user")
            else
                log_warn "User does not exist, skipping: $user"
            fi
        done < "$allow_file"
    else
        # Safer default: do not auto-enroll every login-capable user.
        if [[ "${WSCODE_ALLOW_PASSWD_DISCOVERY:-0}" != "1" ]]; then
            error_exit "Allowlist is empty or missing: $allow_file"
        fi

        local -a denylist=()
        read_list_file "$deny_file" denylist

        while IFS=: read -r username _ uid _ _ home shell; do
            [[ $uid -lt 1000 ]] && continue

            local denied=0
            for denied_user in "${denylist[@]:-}"; do
                if [[ "$username" == "$denied_user" ]]; then
                    denied=1
                    break
                fi
            done
            [[ $denied -eq 1 ]] && continue

            grep -qx "$shell" /etc/shells 2>/dev/null || continue
            [[ -d "$home" ]] || continue
            users+=("$username")
        done < /etc/passwd
    fi

    printf '%s\n' "${users[@]}"
}

# Get user port
get_user_port() {
    local username="$1"
    local uid
    uid=$(id -u "$username")
    echo $((20000 + uid))
}

# Validate port range
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || error_exit "Port must be numeric: $port"
    (( port >= 1 )) || error_exit "Port must be >= 1: $port"
    (( port <= 65535 )) || error_exit "Port exceeds maximum allowed value 65535: $port"
    return 0
}

# Backup file
backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local backup_dir="${BACKUP_DIR}/${TIMESTAMP}"
    mkdir -p "$backup_dir"
    local backup_path="${backup_dir}${file}"
    mkdir -p "$(dirname "$backup_path")"
    cp -a "$file" "$backup_path"
    log_debug "Backed up: $file"
}

# Execute with dry-run support
execute() {
    [[ $DRY_RUN -eq 1 ]] && {
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    }
    "$@"
}

# Ensure directory exists with proper permissions
ensure_dir() {
    local dir="$1"
    local perms="${2:-0755}"
    local owner="${3:-root:root}"

    [[ -d "$dir" ]] || mkdir -p "$dir"
    chmod "$perms" "$dir"
    chown "$owner" "$dir"
}
