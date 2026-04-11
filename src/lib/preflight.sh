#!/bin/bash
# preflight.sh v0.4 - Preflight validation checks.
#
# Runs a series of checks before installation to verify the system
# meets all requirements. Each check function validates one aspect:
#   - Platform: OS family (Debian/Arch) and architecture (amd64/arm64)
#   - Systemd: Required for service management
#   - Dependencies: Required system commands
#   - Network: Connectivity to Cloudflare
#   - User lists: Allow/deny files exist and are valid
#   - Ports: Port assignments are valid and not conflicting
#
# All checks must pass before installation proceeds.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Platform check
# ---------------------------------------------------------------------------

# Verify the platform is supported.
# Accepts Debian family (debian, ubuntu, raspbian) and
# Arch family (arch, manjaro, endeavourOS) on amd64 or arm64.
# The detect_distro_family() and detect_arch() calls will exit
# with an error if the OS or architecture is unsupported.
check_platform() {
  log_info "Checking platform compatibility..."

  # detect_distro_family exits with error for unsupported distros
  local family
  family=$(detect_distro_family)

  # detect_arch exits with error for unsupported architectures
  local arch
  arch=$(detect_arch)

  # Display the distribution name for informational purposes
  eval "$(grep -E "^PRETTY_NAME=" /etc/os-release)"
  log_success "Platform: $PRETTY_NAME (family: $family, arch: $arch)"
}

# ---------------------------------------------------------------------------
# Systemd check
# ---------------------------------------------------------------------------

# Verify that systemd is available and functional.
# All service management (code-server, cloudflared, ACL) depends on systemd.
# Can be skipped with WEBCODE_SKIP_SYSTEMD_CHECK=1 (for testing).
check_systemd_available() {
  log_info "Checking systemd..."

  # Allow skipping for environments without systemd (e.g., Docker, CI)
  if [[ "${WEBCODE_SKIP_SYSTEMD_CHECK:-0}" == "1" ]]; then
    log_warn "Skipping systemd check (WEBCODE_SKIP_SYSTEMD_CHECK=1)"
    return 0
  fi

  # Verify systemctl binary exists
  command_exists systemctl || error_exit "systemd required but systemctl not found"

  # Verify systemd is actually running and functional
  systemctl show --property=Version --value >/dev/null 2>&1 || error_exit "systemd not functional"

  log_success "systemd available"
}

# ---------------------------------------------------------------------------
# Network check
# ---------------------------------------------------------------------------

# Verify network connectivity by reaching Cloudflare.
# If curl is not installed, attempts to install it first using
# the OS package manager (so this check also validates pkg_* works).
# Can be skipped with WEBCODE_SKIP_NETWORK_CHECK=1 (for testing).
check_network() {
  log_info "Checking network connectivity..."

  # Allow skipping for isolated environments (e.g., air-gapped, CI)
  if [[ "${WEBCODE_SKIP_NETWORK_CHECK:-0}" == "1" ]]; then
    log_warn "Skipping network check (WEBCODE_SKIP_NETWORK_CHECK=1)"
    return 0
  fi

  # Install curl if missing — needed for the connectivity test
  # and also for binary downloads later in install.sh
  if ! command_exists curl; then
    log_warn "curl not installed, installing..."
    execute pkg_update_index
    pkg_install curl
    pkg_install ca-certificates
  fi

  # Test connectivity to Cloudflare
  # This endpoint returns diagnostic info and is always available
  if ! curl -fsSL --connect-timeout 10 https://www.cloudflare.com/cdn-cgi/trace > /dev/null 2>&1; then
    error_exit "Network check failed: Cannot reach Cloudflare"
  fi

  log_success "Network connectivity OK"
}

# ---------------------------------------------------------------------------
# Port availability check
# ---------------------------------------------------------------------------

# Verify that port assignments for all enabled users are valid
# and not already in use by other processes.
# Port formula: 20000 + UID (must be <= 65535)
check_ports() {
  log_info "Checking port availability..."

  # Get all enabled users
  local users
  mapfile -t users < <(get_enabled_users)

  # No users is not necessarily an error, but worth noting
  [[ ${#users[@]} -eq 0 ]] && { log_warn "No users found"; return 0; }

  local issues=0

  for user in "${users[@]}"; do
    local port
    port=$(get_user_port "$user")

    # Validate port number is in acceptable range
    if ! validate_port "$port"; then
      ((issues++))
      continue
    fi

    # Check if another process is already listening on this port
    # Uses ss (from iproute2) which is available on all supported distros
    if command_exists ss && ss -lnt 2>/dev/null | grep -q ":${port} "; then
      log_warn "Port $port for user $user appears to be in use"
    fi
  done

  [[ $issues -gt 0 ]] && error_exit "$issues port validation error(s)"

  log_success "Port checks passed for ${#users[@]} user(s)"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

# Verify that all required system commands are available.
# These are basic POSIX/Linux utilities that should exist on any
# minimal installation, but we check anyway for safety.
check_dependencies() {
  log_info "Checking system dependencies..."

  # Commands that must be available for webcode to function
  local required_cmds=(bash awk grep sed mkdir chmod chown stat getent)
  local missing=0

  for cmd in "${required_cmds[@]}"; do
    if ! command_exists "$cmd"; then
      log_error "Required command missing: $cmd"
      ((missing++))
    fi
  done

  [[ $missing -gt 0 ]] && error_exit "$missing required command(s) missing"

  log_success "System dependencies OK"
}

# ---------------------------------------------------------------------------
# User list file check
# ---------------------------------------------------------------------------

# Verify that user allow/deny list files exist and are valid.
# The allow file is required (unless auto-discovery is enabled).
# The deny file is optional.
check_user_list_files() {
  log_info "Checking user list files..."

  local allow_file deny_file
  allow_file=$(resolve_users_allow_file)
  deny_file=$(resolve_users_deny_file)

  # Allow file must exist and be non-empty (unless auto-discovery is enabled)
  if [[ ! -s "$allow_file" ]] && [[ "${WEBCODE_ALLOW_PASSWD_DISCOVERY:-0}" != "1" ]]; then
    error_exit "Allowlist is required and must be non-empty: $allow_file"
  fi

  # Deny file is optional — just warn if the system default is missing
  if [[ "$deny_file" == "$USERS_DENY_FILE" ]] && [[ ! -f "$deny_file" ]]; then
    log_warn "Denylist not found at $deny_file. Falling back to repository config if available."
  fi

  log_success "User list files checked"
}

# ---------------------------------------------------------------------------
# Preflight orchestration
# ---------------------------------------------------------------------------

# Run all preflight checks in the correct order.
# Order matters: platform first (to verify OS support), then
# systemd, then dependencies (which may need the OS info),
# then network, then user lists (which need config),
# then ports (which need the user list).
run_preflight_checks() {
  log_info "=== Preflight checks ==="

  check_platform
  check_systemd_available
  check_dependencies
  check_network
  check_user_list_files
  load_config
  check_ports

  log_success "=== All preflight checks passed ==="
}
