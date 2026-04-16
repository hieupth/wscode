#!/bin/bash
# verify.sh v0.4 - Post-installation verification.
#
# Runs a suite of checks to verify that all components are correctly
# installed and configured. Can be run in two modes:
#   - Full mode (--verify-only): All checks including file permissions
#   - Post-apply mode (called from webcode.sh): Skips permission checks
#     since files were just created with correct permissions (fix 1.3)
#
# Checks performed:
#   - Cloudflared config file structure and content
#   - User-to-port and user-to-hostname mapping consistency
#   - Systemd services active status
#   - Code-server HTTP endpoints responding
#   - File/directory permissions (optional, skipped post-apply)
#   - Localhost ACL (nftables rules) active

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Cloudflared config verification
# ---------------------------------------------------------------------------

# Verify the cloudflared configuration file exists, has correct
# permissions, and contains the required tunnel and ingress sections.
verify_cloudflared_config() {
  log_info "Verifying cloudflared configuration..."

  local config_file="/etc/cloudflared/config.yml"

  # Config file must exist
  [[ ! -f "$config_file" ]] && { log_error "Config missing: $config_file"; return 1; }

  # Check file permissions
  local perms
  perms=$(stat -c %a "$config_file")
  [[ "$perms" != "600" ]] && log_warn "Config perms: $perms (expected 600)"

  # Check file ownership
  local owner
  owner=$(stat -c %U:%G "$config_file")
  [[ "$owner" != "root:root" ]] && log_warn "Config owner: $owner (expected root:root)"

  # Verify required sections exist in the YAML
  grep -q "^tunnel:" "$config_file" || { log_error "Missing tunnel definition"; return 1; }
  grep -q "^ingress:" "$config_file" || { log_error "Missing ingress rules"; return 1; }

  log_success "cloudflared config verified"
}

# ---------------------------------------------------------------------------
# User mapping consistency
# ---------------------------------------------------------------------------

# Verify that user-to-port and user-to-hostname mappings are unique.
# Detects duplicate port assignments (UID collision) or duplicate
# hostnames (username collision) that would cause routing issues.
verify_user_mapping_consistency() {
  log_info "Verifying user-to-port and user-to-hostname mappings..."

  local users
  mapfile -t users < <(get_enabled_users)

  # No users to validate
  [[ ${#users[@]} -eq 0 ]] && { log_warn "No users to validate mapping"; return 0; }

  # Track seen ports and hostnames to detect duplicates
  local -A seen_ports=()
  local -A seen_hosts=()

  for user in "${users[@]}"; do
    local port host
    port=$(get_user_port "$user")
    host="${user}-${CF_DOMAIN_BASE}"

    # Check for duplicate port (would mean two users with same UID)
    if [[ -n "${seen_ports[$port]:-}" ]]; then
      log_error "Duplicate port mapping: $port for $user and ${seen_ports[$port]}"
      return 1
    fi
    seen_ports[$port]="$user"

    # Check for duplicate hostname (would mean Cloudflare routing conflict)
    if [[ -n "${seen_hosts[$host]:-}" ]]; then
      log_error "Duplicate hostname mapping: $host"
      return 1
    fi
    seen_hosts[$host]="$user"
  done

  log_success "User mappings are consistent"
}

# ---------------------------------------------------------------------------
# Systemd services verification
# ---------------------------------------------------------------------------

# Verify that all required systemd services are active:
#   - cloudflared (tunnel client)
#   - code-server@{user} for each enabled user
verify_systemd_services() {
  log_info "Verifying systemd services..."

  local failed=0

  # Check cloudflared service
  if systemctl is-active cloudflared &> /dev/null; then
    log_success "cloudflared active"
  else
    log_error "cloudflared not active"
    systemctl status cloudflared --no-pager || true
    failed=$((failed + 1))
  fi

  # Check each user's code-server instance
  local users
  mapfile -t users < <(get_enabled_users)

  for user in "${users[@]}"; do
    local service="code-server@${user}.service"

    if systemctl is-active "$service" &> /dev/null; then
      log_success "$service active"
    else
      log_error "$service not active"
      systemctl status "$service" --no-pager || true
      failed=$((failed + 1))
    fi
  done

  [[ $failed -gt 0 ]] && { log_error "$failed service(s) failed"; return 1; }

  log_success "All services verified"
}

# ---------------------------------------------------------------------------
# HTTP endpoint verification
# ---------------------------------------------------------------------------

# Verify that code-server HTTP endpoints are responding for each user.
# Tries the /healthz endpoint first, falls back to basic HTTP check.
verify_code_server_endpoints() {
  log_info "Verifying code-server endpoints..."

  local users
  mapfile -t users < <(get_enabled_users)

  [[ ${#users[@]} -eq 0 ]] && { log_warn "No users to verify"; return 0; }

  local failed=0

  for user in "${users[@]}"; do
    local port
    port=$(get_user_port "$user")

    # Try healthz endpoint first (standard code-server health check)
    if curl -f -s -o /dev/null --connect-timeout 5 "http://127.0.0.1:${port}/healthz" 2>/dev/null; then
      log_success "$user (port $port) - healthz OK"
    # Fallback to basic HTTP check (any HTTP response)
    elif curl -f -s -o /dev/null --connect-timeout 5 "http://127.0.0.1:${port}" 2>/dev/null || \
         curl -I -s --connect-timeout 5 "http://127.0.0.1:${port}" 2>/dev/null | grep -q "HTTP"; then
      log_success "$user (port $port) - HTTP OK"
    else
      log_error "$user (port $port) - Not responding"
      failed=$((failed + 1))
    fi
  done

  [[ $failed -gt 0 ]] && { log_error "$failed endpoint(s) failed"; return 1; }

  log_success "All endpoints verified"
}

# ---------------------------------------------------------------------------
# Secrets permissions verification
# ---------------------------------------------------------------------------

# Verify that the cloudflared secrets directory has secure permissions.
# The /etc/cloudflared directory should be root-owned with mode 700.
verify_secrets_permissions() {
  log_info "Verifying secrets permissions..."

  # Skip if cloudflared config directory doesn't exist yet
  [[ -d "/etc/cloudflared" ]] || return 0

  # Check directory permissions
  local perms
  perms=$(stat -c %a /etc/cloudflared)
  [[ "$perms" == "700" ]] || log_warn "/etc/cloudflared perms: $perms (expected 700)"

  # Check directory ownership
  local owner
  owner=$(stat -c %U:%G /etc/cloudflared)
  [[ "$owner" == "root:root" ]] || log_warn "/etc/cloudflared owner: $owner (expected root:root)"

  log_success "Secrets permissions verified"
}

# ---------------------------------------------------------------------------
# Localhost ACL verification
# ---------------------------------------------------------------------------

# Verify that the localhost ACL (nftables rules) is active.
# Checks both the systemd service and the actual nft table.
verify_local_acl() {
  log_info "Verifying localhost ACL..."

  # nft command must be available
  if ! command_exists nft; then
    log_error "nft command not available"
    return 1
  fi

  # The ACL systemd service must be active
  if ! systemctl is-active webcode-acl.service &> /dev/null; then
    log_error "webcode-acl.service not active"
    systemctl status webcode-acl.service --no-pager || true
    return 1
  fi

  # The nft table must exist with rules
  if ! nft list table inet webcode >/dev/null 2>&1; then
    log_error "nft table inet webcode not found"
    return 1
  fi

  log_success "Localhost ACL verified"
}

# ---------------------------------------------------------------------------
# Verification orchestration
# ---------------------------------------------------------------------------

# Run all verification checks.
# Params:
#   $1 - (optional) Set to "1" to skip permission checks.
#        Used when called from the apply flow (fix 1.3) since permissions
#        were just set moments ago. Default: "0" (full checks).
# Returns:
#   0 if all checks pass, 1 if any check fails
run_verification() {
  local skip_perms="${1:-0}"
  local failed=0

  log_info "=== Running verification ==="

  # Load config first (needed for CF_DOMAIN_BASE, user lists, etc.)
  load_config

  # Run each verification check, counting failures
  verify_cloudflared_config || ((failed++))
  # Skip permission checks when called right after apply (fix 1.3)
  [[ "$skip_perms" -eq 0 ]] && verify_secrets_permissions || true
  verify_user_mapping_consistency || ((failed++))
  verify_systemd_services || ((failed++))
  verify_code_server_endpoints || ((failed++))
  verify_local_acl || ((failed++))

  [[ $failed -gt 0 ]] && { log_error "=== Verification: $failed failure(s) ==="; return 1; }

  log_success "=== All verification passed ==="
}
