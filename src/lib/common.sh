#!/bin/bash
# common.sh v0.4 - Common utilities, logging, config loading,
# OS/arch detection, and package management helpers.
#
# This is the foundation module sourced by all other modules.
# It provides:
#   - Logging functions with color output
#   - Configuration file parsing (KEY=VALUE format)
#   - User management utilities
#   - File operations with backup support
#   - OS detection (Debian family / Arch family)
#   - Architecture detection (amd64 / arm64)
#   - Package management abstraction (apt-get / pacman)
#   - Template rendering ({{VAR}} substitution)
#
# All paths use the webcode namespace (renamed from wscode).

set -euo pipefail

# Guard against double-sourcing this module.
# Each shell session should only load common.sh once.
if [[ -n "${_WEBCODE_COMMON_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly _WEBCODE_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

readonly VERSION="0.4.0"

# ---------------------------------------------------------------------------
# Directory constants
#
# These are derived from the script location so they work regardless
# of the current working directory when webcode.sh is invoked.
# ---------------------------------------------------------------------------

readonly SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR="$(cd "${SRC_DIR}/.." && pwd)"
readonly LIB_DIR="${SRC_DIR}/lib"
readonly TEMPLATE_DIR="${SRC_DIR}/templates"
readonly CONFIG_DIR="${REPO_DIR}/config"
readonly STATE_DIR="${REPO_DIR}/state"
readonly BACKUP_DIR="${STATE_DIR}/backups"

# ---------------------------------------------------------------------------
# System paths
#
# All runtime config lives under /etc/webcode/.
# These are fixed paths — no env var overrides (see fix 1.5).
# ---------------------------------------------------------------------------

readonly ETC_CONFIG_DIR="/etc/webcode"
readonly CONFIG_FILE="${ETC_CONFIG_DIR}/config.env"
readonly USERS_ALLOW_FILE="${ETC_CONFIG_DIR}/users.allow"
readonly USERS_DENY_FILE="${ETC_CONFIG_DIR}/users.deny"
readonly ACTIVE_STATE_FILE="${ETC_CONFIG_DIR}/active-users.state"

# ---------------------------------------------------------------------------
# Global variables (mutable state)
# ---------------------------------------------------------------------------

# Debug mode: enables verbose log_debug output.
# Activated via --debug flag.
DEBUG_MODE=0

# Dry-run mode: logs commands instead of executing them.
# Activated via --dry-run flag.
DRY_RUN=0

# Timestamp for backup directory naming.
# Format: YYYYMMDD_HHMMSS
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Minimum code-server version required for compatibility.
readonly MIN_CODESERVER_VERSION="4.0.0"

# ---------------------------------------------------------------------------
# Logging functions
#
# All output goes to stderr (>&2) so it doesn't interfere with
# functions that return data via stdout (e.g., get_enabled_users).
# ---------------------------------------------------------------------------

# General information message.
log_info() { echo "[INFO] $*" >&2; }

# Warning message — non-fatal issues that need attention.
log_warn() { echo "[WARN] $*" >&2; }

# Error message — typically followed by exit.
log_error() { echo "[ERROR] $*" >&2; }

# Debug message — only shown when --debug flag is set.
log_debug() { [[ $DEBUG_MODE -eq 1 ]] && echo "[DEBUG] $*" >&2 || true; }

# Success message — used for completed steps.
log_success() { echo "[SUCCESS] $*" >&2; }

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

# Print error message and exit with code 1.
# Use this for unrecoverable errors (missing config, failed prerequisites).
# Params:
#   $1 - Error message to display
error_exit() { log_error "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Root and command checks
# ---------------------------------------------------------------------------

# Verify the script is running as root (UID 0).
# Most operations (systemctl, package install, file permissions) require root.
check_root() { [[ $EUID -eq 0 ]] || error_exit "This script must be run as root"; }

# Check if a command is available in PATH.
# Params:
#   $1 - Command name to check (e.g., "curl", "nft")
# Returns:
#   0 if found, 1 if not found
command_exists() { command -v "$1" &> /dev/null; }

# ---------------------------------------------------------------------------
# OS and architecture detection
#
# These functions detect the Linux distribution family and CPU
# architecture. They are used by package management and binary
# download functions to select the correct commands and URLs.
# ---------------------------------------------------------------------------

# Detect the Linux distribution family.
# Reads /etc/os-release (available on all modern Linux distros).
# Returns:
#   "debian" for Debian, Ubuntu, Raspbian
#   "arch" for Arch, Manjaro, EndeavourOS
# Exits with error for unsupported distros.
detect_distro_family() {
  [[ -f /etc/os-release ]] || error_exit "Cannot determine OS: /etc/os-release not found"

  # Extract the ID field from os-release (e.g., ID=ubuntu, ID=manjaro)
  # Strip quotes in case the value is quoted (ID="debian")
  local id=""
  id=$(grep -E "^ID=" /etc/os-release | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'")

  case "$id" in
    debian|ubuntu|raspbian)
      echo "debian"
      ;;
    arch|archarm|manjaro*|endeavouros)
      echo "arch"
      ;;
    *)
      error_exit "Unsupported OS: $id (supported: debian, ubuntu, raspbian, arch, manjaro, endeavouros)"
      ;;
  esac
}

# Detect the CPU architecture for binary downloads.
# Translates uname -m output to the format used by GitHub releases.
# Returns:
#   "amd64" for x86_64
#   "arm64" for aarch64
# Exits with error for unsupported architectures.
detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)       error_exit "Unsupported architecture: $arch (supported: x86_64/amd64, aarch64/arm64)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Package management abstraction
#
# These functions provide a uniform interface to the system package
# manager. They use detect_distro_family() internally to select
# the correct commands (apt-get for Debian, pacman for Arch).
# ---------------------------------------------------------------------------

# Update the local package index.
# Must be called before pkg_install to ensure latest package lists.
pkg_update_index() {
  local family
  family=$(detect_distro_family)
  case "$family" in
    debian) apt-get update -qq ;;
    arch)   pacman -Sy --noconfirm ;;
  esac
}

# Check if a package is already installed on the system.
# Params:
#   $1 - Package name (e.g., "curl", "nftables")
# Returns:
#   0 if installed, 1 if not installed
pkg_is_installed() {
  local pkg="$1"
  local family
  family=$(detect_distro_family)
  case "$family" in
    debian) dpkg -l 2>/dev/null | grep -q "^ii  $pkg " ;;
    arch)   pacman -Qi "$pkg" &>/dev/null ;;
  esac
}

# Install a single package.
# Respects DRY_RUN mode — logs the command instead of executing.
# Params:
#   $1 - Package name to install
pkg_install() {
  local pkg="$1"
  local family
  family=$(detect_distro_family)
  case "$family" in
    debian) execute apt-get install -y -qq "$pkg" ;;
    arch)   execute pacman -S --noconfirm --needed "$pkg" ;;
  esac
}

# Get the list of required system packages for the current distro.
# Most packages are the same across distros, but some differ:
#   - lsb-release: only needed on Debian (for cloudflared apt repo)
# Returns:
#   Package names, one per line (for use with mapfile)
get_required_packages() {
  local family
  family=$(detect_distro_family)
  # Base packages required by webcode on all distros
  local packages=(curl ca-certificates bash jq gawk iproute2 gnupg wget nftables)
  # lsb-release is only needed on Debian for the cloudflared apt repo
  # (no longer used since we switched to binary download, but kept for
  # potential future use and compatibility)
  [[ "$family" == "debian" ]] && packages+=(lsb-release)
  printf '%s\n' "${packages[@]}"
}

# ---------------------------------------------------------------------------
# String utilities
# ---------------------------------------------------------------------------

# Strip inline comments and trim whitespace from a value.
# Used for parsing config files and user list files.
# Params:
#   $1 - Raw line value (e.g., 'VALUE  # comment')
# Output:
#   Trimmed value without comment (e.g., 'VALUE')
strip_comment_and_trim() {
  local value="$1"
  # Remove everything after first #
  value="${value%%#*}"
  # Trim leading whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  # Trim trailing whitespace
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# File security validation
# ---------------------------------------------------------------------------

# Verify that a security-sensitive file has safe ownership and permissions.
# Refuses symlinks to prevent symlink attacks.
# Params:
#   $1 - File path to validate
#   $2 - Maximum allowed permission mode (default: 600)
# Exits with error if validation fails.
assert_secure_file() {
  local path="$1"
  local max_mode="${2:-600}"

  # File must exist
  [[ -f "$path" ]] || error_exit "File not found: $path"

  # Refuse symlinks — an attacker could redirect to a malicious file
  [[ -L "$path" ]] && error_exit "Refusing symlink for security-sensitive file: $path"

  # Owner must be root:root — prevents unprivileged users from modifying config
  local owner
  owner=$(stat -c '%U:%G' "$path")
  [[ "$owner" == "root:root" ]] || error_exit "Insecure owner for $path: $owner (expected root:root)"

  # Permission mode must not exceed max_mode
  local mode
  mode=$(stat -c '%a' "$path")
  if (( 10#$mode > 10#$max_mode )); then
    error_exit "Insecure permissions for $path: $mode (expected <= $max_mode)"
  fi
}

# ---------------------------------------------------------------------------
# Version comparison
#
# Compares two version strings using sort -V (version sort).
# Used to check if installed code-server meets minimum requirements.
# ---------------------------------------------------------------------------

# Compare two version strings.
# Params:
#   $1 - First version (e.g., "4.96.0")
#   $2 - Comparison operator: lt, le, gt, ge, eq (or <, <=, >, >=, ==)
#   $3 - Second version (e.g., "4.0.0")
# Returns:
#   0 if comparison is true, 1 if false
version_compare() {
  local ver1="$1"
  local op="$2"
  local ver2="$3"

  # Use sort -V to determine which version is "smaller"
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

# ---------------------------------------------------------------------------
# Binary detection
#
# Simplified version — just checks PATH (fix 1.4).
# Since webcode installs code-server itself, the binary is always in PATH.
# ---------------------------------------------------------------------------

# Detect the code-server binary path.
# Searches PATH only — no hardcoded fallback paths needed.
# Output:
#   Full path to code-server binary (e.g., "/usr/local/bin/code-server")
# Returns:
#   0 if found, 1 if not found
detect_codeserver_binary() {
  if command_exists code-server; then
    command -v code-server
    return 0
  fi
  log_error "code-server binary not found in PATH"
  return 1
}

# ---------------------------------------------------------------------------
# User list file resolution
#
# These functions resolve user allow/deny list file paths.
# They first check the system path (/etc/webcode/), then fall back
# to the repo config/ directory (for development/testing).
# ---------------------------------------------------------------------------

# Resolve the path to the users.allow file.
# Checks /etc/webcode/users.allow first, then falls back to repo config/.
# Output:
#   Path to the allow file
resolve_users_allow_file() {
  if [[ -f "$USERS_ALLOW_FILE" ]]; then
    printf '%s\n' "$USERS_ALLOW_FILE"
  else
    printf '%s\n' "${CONFIG_DIR}/users.allow"
  fi
}

# Resolve the path to the users.deny file.
# Checks /etc/webcode/users.deny first, then falls back to repo config/.
# Output:
#   Path to the deny file
resolve_users_deny_file() {
  if [[ -f "$USERS_DENY_FILE" ]]; then
    printf '%s\n' "$USERS_DENY_FILE"
  else
    printf '%s\n' "${CONFIG_DIR}/users.deny"
  fi
}

# ---------------------------------------------------------------------------
# User management utilities
# ---------------------------------------------------------------------------

# Check if a system user account exists.
# Uses getent passwd which works across all supported distros.
# Params:
#   $1 - Username to check
# Returns:
#   0 if user exists, 1 if not
user_exists() {
  local username="$1"
  getent passwd "$username" >/dev/null 2>&1
}

# Validate a username against POSIX conventions.
# Allows: lowercase letters, digits, underscores, hyphens.
# Must start with a letter or underscore. May end with $ (Samba).
# Params:
#   $1 - Username to validate
# Returns:
#   0 if valid, 1 if invalid
is_valid_username() {
  local username="$1"
  [[ "$username" =~ ^[a-z_][a-z0-9_]*[$]?$ ]]
}

# Get the home directory for a user.
# Uses getent passwd for reliable resolution (no hardcoded /home/%i).
# Params:
#   $1 - Username
# Output:
#   Home directory path (e.g., "/home/alice")
get_user_home() {
  local username="$1"
  local home
  home=$(getent passwd "$username" | cut -d: -f6)
  [[ -n "$home" ]] || error_exit "Could not determine home directory for $username"
  echo "$home"
}

# ---------------------------------------------------------------------------
# Configuration loading
#
# Parses KEY=VALUE format config files without executing them
# (safer than bash `source`). Validates required fields and
# file security.
#
# Required config keys:
#   CF_TUNNEL_NAME     - Cloudflare tunnel name
#   CF_DOMAIN_BASE     - Base domain for user URLs
#   CF_CREDENTIALS_FILE - Path to Cloudflare tunnel credentials JSON
# ---------------------------------------------------------------------------

# Load and validate the configuration file.
# Validates file permissions, required keys, and credential file access.
# Sets CF_TUNNEL_NAME, CF_DOMAIN_BASE, CF_CREDENTIALS_FILE as globals.
load_config() {
  [[ -f "$CONFIG_FILE" ]] || error_exit "Config file not found: $CONFIG_FILE"

  # Verify config file has secure permissions (root:root, mode <= 600)
  assert_secure_file "$CONFIG_FILE" 600

  # Parse KEY=VALUE lines from the config file.
  # This is safer than `source` because it doesn't execute arbitrary code.
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    # Skip empty lines and comments
    [[ -z "$key" ]] && continue
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    # Strip comments and quotes from value
    value=$(strip_comment_and_trim "$value")
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    # Export as environment variable for use by other modules
    export "$key=$value"
  done < "$CONFIG_FILE"

  # Validate required configuration keys
  [[ -z "${CF_TUNNEL_NAME:-}" ]] && error_exit "CF_TUNNEL_NAME is required in $CONFIG_FILE"
  [[ -z "${CF_DOMAIN_BASE:-}" ]] && error_exit "CF_DOMAIN_BASE is required in $CONFIG_FILE"
  [[ -z "${CF_CREDENTIALS_FILE:-}" ]] && error_exit "CF_CREDENTIALS_FILE is required in $CONFIG_FILE"
  [[ -z "${CF_API_TOKEN:-}" ]] && error_exit "CF_API_TOKEN is required in $CONFIG_FILE"
  [[ -z "${CF_ZONE_ID:-}" ]] && error_exit "CF_ZONE_ID is required in $CONFIG_FILE"

  # Verify the credentials file exists and has secure permissions
  assert_secure_file "$CF_CREDENTIALS_FILE" 600
}

# ---------------------------------------------------------------------------
# User list file parsing
# ---------------------------------------------------------------------------

# Read a user list file (allow or deny) and populate an array.
# Strips comments, validates usernames, and warns on invalid entries.
# Params:
#   $1 - Path to the list file
#   $2 - Name of the array variable to populate (nameref)
read_list_file() {
  local list_file="$1"
  local -n out_ref="$2"

  # File might not exist (e.g., users.deny is optional)
  [[ -f "$list_file" ]] || return 0

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line
    line=$(strip_comment_and_trim "$raw_line")
    [[ -z "$line" ]] && continue

    # Validate username format before adding
    if ! is_valid_username "$line"; then
      log_warn "Ignoring invalid username in $list_file: $line"
      continue
    fi
    out_ref+=("$line")
  done < "$list_file"
}

# ---------------------------------------------------------------------------
# User discovery
# ---------------------------------------------------------------------------

# Get the list of enabled users who should have code-server instances.
#
# Two discovery modes:
#   1. Allowlist mode (default): Read usernames from users.allow file.
#      Only users in the file who also exist on the system are included.
#   2. Auto-discover mode: If allowlist is empty and
#      WEBCODE_ALLOW_PASSWD_DISCOVERY=1, scan /etc/passwd for
#      login-capable users with UID >= 1000 (minus denylist).
#
# Output:
#   One username per line (for use with mapfile)
get_enabled_users() {
  local allow_file deny_file
  allow_file=$(resolve_users_allow_file)
  deny_file=$(resolve_users_deny_file)

  local -a users=()

  if [[ -s "$allow_file" ]]; then
    # Mode 1: Allowlist — read file and filter for existing users
    local -a raw_users=()
    read_list_file "$allow_file" raw_users

    for user in "${raw_users[@]}"; do
      if user_exists "$user"; then
        users+=("$user")
      else
        log_warn "User does not exist, skipping: $user"
      fi
    done
  elif [[ "${WEBCODE_ALLOW_PASSWD_DISCOVERY:-0}" == "1" ]]; then
    # Mode 2: Auto-discover from /etc/passwd
    # Read deny list first
    local -a denylist=()
    read_list_file "$deny_file" denylist

    # Scan /etc/passwd for eligible users
    while IFS=: read -r username _ uid _ _ home shell; do
      # Skip system accounts (UID < 1000)
      [[ $uid -lt 1000 ]] && continue

      # Skip denied users
      local denied=0
      for denied_user in "${denylist[@]:-}"; do
        if [[ "$username" == "$denied_user" ]]; then
          denied=1
          break
        fi
      done
      [[ $denied -eq 1 ]] && continue

      # Only include users with a valid login shell
      grep -qx "$shell" /etc/shells 2>/dev/null || continue
      # User must have an existing home directory
      [[ -d "$home" ]] || continue

      users+=("$username")
    done < /etc/passwd
  else
    error_exit "Allowlist is empty or missing: $allow_file"
  fi

  printf '%s\n' "${users[@]}"
}

# ---------------------------------------------------------------------------
# Port management
# ---------------------------------------------------------------------------

# Calculate the port number for a user.
# Formula: 20000 + UID (e.g., UID 1000 → port 21000)
# Params:
#   $1 - Username
# Output:
#   Port number
get_user_port() {
  local username="$1"
  local uid
  uid=$(id -u "$username")
  # Validate UID won't cause port overflow (max port = 65535)
  if (( uid > 45535 )); then
    error_exit "UID $uid for user $username would exceed max port 65535 (20000 + $uid = $((20000 + uid)))"
  fi
  echo $((20000 + uid))
}

# Validate that a port number is in the valid range (1-65535).
# Params:
#   $1 - Port number
# Exits with error if invalid.
validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || error_exit "Port must be numeric: $port"
  (( port >= 1 )) || error_exit "Port must be >= 1: $port"
  (( port <= 65535 )) || error_exit "Port exceeds maximum allowed value 65535: $port"
  return 0
}

# ---------------------------------------------------------------------------
# File operations
# ---------------------------------------------------------------------------

# Create a backup of a file before modifying it.
# Backups are stored in state/backups/{TIMESTAMP}/ preserving the
# original directory structure for easy restoration.
# Params:
#   $1 - Path to the file to back up
# Skips silently if file doesn't exist.
backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  # Resolve to absolute path to prevent path traversal
  local abs_file
  abs_file=$(realpath "$file")
  local backup_path="${BACKUP_DIR}/${TIMESTAMP}${abs_file}"
  mkdir -p "$(dirname "$backup_path")"
  cp -a "$file" "$backup_path"
  log_debug "Backed up: $file"
}

# Execute a command with dry-run support.
# In dry-run mode, logs the command instead of executing it.
# Params:
#   $@ - Command and arguments to execute
execute() {
  [[ $DRY_RUN -eq 1 ]] && {
    log_info "[DRY-RUN] Would execute: $*"
    return 0
  }
  "$@"
}

# Ensure a directory exists with proper permissions.
# Creates the directory if it doesn't exist, then sets ownership and mode.
# Params:
#   $1 - Directory path
#   $2 - Permission mode (default: 0755)
#   $3 - Owner:group (default: root:root)
ensure_dir() {
  local dir="$1"
  local perms="${2:-0755}"
  local owner="${3:-root:root}"

  [[ -d "$dir" ]] || mkdir -p "$dir"
  chmod "$perms" "$dir"
  chown "$owner" "$dir"
}

# ---------------------------------------------------------------------------
# Template rendering
#
# Reads a template file and substitutes {{VAR}} placeholders with
# provided values. This replaces all inline heredoc usage.
# Template files are stored in src/templates/.
# ---------------------------------------------------------------------------

# Render a template file by substituting {{VAR}} placeholders.
# Params:
#   $1 - Path to the template file
#   $2 - Path to write the rendered output
#   $3,$4 - Pairs of VAR_NAME and VALUE for substitution
#            (e.g., "CODESERVER_BIN" "/usr/local/bin/code-server")
# Example:
#   render_template "templates/service.tpl" "/etc/systemd/system/x.service" \
#     CODESERVER_BIN "/usr/local/bin/code-server" NFT_BIN "/usr/sbin/nft"
render_template() {
  local template="$1"
  local target="$2"
  shift 2

  # Read the entire template file
  local content
  content=$(cat "$template")

  # Process variable substitution pairs
  # Each pair is: VAR_NAME VALUE
  while [[ $# -ge 2 ]]; do
    local var_name="$1"
    local var_value="$2"
    shift 2
    # Replace all occurrences of {{VAR_NAME}} with the value
    content="${content//\{\{${var_name}\}\}/${var_value}}"
  done

  # Write the rendered content to the target file
  echo "$content" > "$target"
}
