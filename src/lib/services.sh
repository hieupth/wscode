#!/bin/bash
# services.sh v0.4 - Systemd service management for code-server.
#
# Generates and installs systemd service files for code-server instances.
# Each user gets their own code-server@{username}.service instance.
#
# Simplified from v0.3: Only one code path (template-based), removed
# the deb package template detection branch (fix 1.1). The template
# file src/templates/code-server@.service.tpl is always used.
#
# Services managed:
#   - code-server@.service (template instance for all users)
#   - Hardening overrides for security

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Service template installation
# ---------------------------------------------------------------------------

# Install the code-server systemd service template.
# Uses src/templates/code-server@.service.tpl with {{CODESERVER_BIN}}
# substitution. This creates a single template that systemd instantiates
# for each user (code-server@alice.service, code-server@bob.service, etc.)
install_code_server_service() {
  log_info "Installing code-server systemd service..."

  # In dry-run mode, skip binary detection (code-server may not be installed yet)
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[DRY-RUN] Would install code-server@.service"
    return 0
  fi

  # Find the code-server binary path
  local codeserver_bin
  codeserver_bin=$(detect_codeserver_binary) || error_exit "code-server binary not found"

  # Template and target paths
  local template_file="${TEMPLATE_DIR}/code-server@.service.tpl"
  local service_file="/etc/systemd/system/code-server@.service"

  # Verify template exists
  [[ -f "$template_file" ]] || error_exit "Template not found: $template_file"

  # Back up existing service file if present
  [[ -f "$service_file" ]] && backup_file "$service_file"

  # Render the template with the actual binary path
  render_template "$template_file" "$service_file" \
    CODESERVER_BIN "$codeserver_bin"

  chmod 644 "$service_file"
  log_success "Installed systemd service: $service_file"
}

# ---------------------------------------------------------------------------
# Hardening overrides
# ---------------------------------------------------------------------------

# Install security hardening overrides for code-server services.
# These restrict what code-server processes can do:
# memory limits, filesystem access, capabilities, etc.
# The overrides come from src/templates/code-server@.override-hardening.conf.tpl
install_code_server_hardening() {
  log_info "Installing code-server hardening overrides..."

  local template_file="${TEMPLATE_DIR}/code-server@.override-hardening.conf.tpl"
  local override_dir="/etc/systemd/system/code-server@.service.d"
  local override_file="${override_dir}/hardening.conf"

  # Hardening template is optional — warn if missing but don't fail
  if [[ ! -f "$template_file" ]]; then
    log_warn "Hardening template not found: $template_file"
    return 0
  fi

  # Back up existing override if present
  [[ -f "$override_file" ]] && backup_file "$override_file"

  # In dry-run mode, just log what would be done
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[DRY-RUN] Would install $override_file"
    return 0
  fi

  # Copy the hardening template directly (no variable substitution needed)
  mkdir -p "$override_dir"
  cp "$template_file" "$override_file"
  chmod 644 "$override_file"

  log_success "Hardening overrides installed"
}

# ---------------------------------------------------------------------------
# Per-user service enablement
# ---------------------------------------------------------------------------

# Enable and start code-server for a specific user.
# Creates the systemd instance code-server@{user}.service.
# Params:
#   $1 - Username to enable code-server for
# Returns:
#   0 on success, 1 on failure (e.g., user doesn't exist, service fails to start)
enable_code_server_for_user() {
  local user="$1"

  log_info "Enabling code-server for user: $user"

  # Verify user exists on the system
  if ! user_exists "$user"; then
    log_error "User $user does not exist"
    return 1
  fi

  # Validate the port assignment for this user
  local port
  port=$(get_user_port "$user")
  validate_port "$port"

  local service="code-server@${user}.service"

  # In dry-run mode, just log what would be done
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[DRY-RUN] Would enable and start $service"
    return 0
  fi

  # Enable the service (start on boot)
  if ! systemctl is-enabled "$service" &> /dev/null; then
    systemctl enable "$service"
    log_debug "Enabled $service"
  fi

  # Start or restart the service
  if systemctl is-active "$service" &> /dev/null; then
    systemctl restart "$service"
    log_debug "Restarted $service"
  else
    systemctl start "$service"
    log_debug "Started $service"
  fi

  # Brief wait for the service to initialize
  sleep 2

  # Verify the service is running
  if ! systemctl is-active "$service" &> /dev/null; then
    log_error "Failed to start $service"
    systemctl status "$service" --no-pager || true
    return 1
  fi

  log_success "code-server enabled and running for $user"
  return 0
}

# ---------------------------------------------------------------------------
# Service setup orchestration
# ---------------------------------------------------------------------------

# Set up code-server services for all enabled users.
# Installs the service template, hardening overrides, daemon-reloads,
# then enables/starts a service instance for each user.
setup_code_server_services() {
  log_info "=== Setting up code-server services ==="

  # Install the shared service template and hardening
  install_code_server_service
  install_code_server_hardening

  # Reload systemd to pick up the new/changed service files
  if [[ $DRY_RUN -eq 0 ]]; then
    systemctl daemon-reload
  fi

  # Get all enabled users
  local users
  mapfile -t users < <(get_enabled_users)

  if [[ ${#users[@]} -eq 0 ]]; then
    log_warn "No users to enable code-server for"
    return 0
  fi

  log_info "Enabling code-server for ${#users[@]} user(s)"

  # Enable service for each user, tracking failures
  local failed=0
  for user in "${users[@]}"; do
    if ! enable_code_server_for_user "$user"; then
      ((failed++))
    fi
  done

  if [[ $failed -gt 0 ]]; then
    log_error "Failed to enable code-server for $failed user(s)"
    return 1
  fi

  log_success "=== code-server services setup completed ==="
  return 0
}
