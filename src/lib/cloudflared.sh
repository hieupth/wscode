#!/bin/bash
# cloudflared.sh v0.4 - Cloudflared tunnel configuration and service setup.
#
# Generates the cloudflared configuration file (YAML) with ingress rules
# for each enabled user, and installs/manages the cloudflared systemd service.
#
# Authentication is via credentials JSON file only (CF_CREDENTIALS_FILE).
# Token-based authentication was removed (fix 1.6) for consistency and
# simplicity.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Configuration generation
# ---------------------------------------------------------------------------

# Generate the cloudflared configuration YAML file.
# Creates ingress rules mapping each user's subdomain to their
# localhost code-server port:
#   alice.code.example.com -> http://127.0.0.1:21000
#   bob.code.example.com   -> http://127.0.0.1:21001
#   (catch-all)            -> http_status:404
#
# The config file is written to /etc/cloudflared/config.yml with
# root:root ownership and mode 600 (secrets-protected).
generate_cloudflared_config() {
  log_info "Generating cloudflared configuration..."

  local config_file="/etc/cloudflared/config.yml"

  # Back up existing config if present
  [[ -f "$config_file" ]] && backup_file "$config_file"

  # Get all enabled users for ingress rule generation
  local users
  mapfile -t users < <(get_enabled_users)

  # Must have at least one user to generate meaningful ingress rules
  [[ ${#users[@]} -gt 0 ]] || error_exit "No eligible users found for cloudflared ingress rules"

  # Build the YAML configuration
  # Structure:
  #   tunnel: <tunnel_name>
  #   credentials-file: <path_to_creds>
  #   ingress:
  #     - hostname: <user>.<domain> -> http://127.0.0.1:<port>
  #     - service: http_status:404  (catch-all, required by cloudflared)
  local config_content="tunnel: ${CF_TUNNEL_NAME}"$'\n'
  config_content+="credentials-file: ${CF_CREDENTIALS_FILE}"$'\n'
  config_content+=$'\n'"ingress:"$'\n'

  # Generate an ingress rule for each user
  for user in "${users[@]}"; do
    local port
    port=$(get_user_port "$user")
    config_content+="  - hostname: ${user}.${CF_DOMAIN_BASE}"$'\n'
    config_content+="    service: http://127.0.0.1:${port}"$'\n'
  done

  # Catch-all rule — cloudflared requires exactly one at the end
  config_content+="  - service: http_status:404"$'\n'

  # In dry-run mode, just log what would be written
  [[ $DRY_RUN -eq 1 ]] && {
    log_info "[DRY-RUN] Would write config"
    log_debug "$config_content"
    return 0
  }

  # Ensure the cloudflared config directory exists with secure permissions
  ensure_dir /etc/cloudflared 0700 root:root

  # Write the configuration file with strict permissions
  echo "$config_content" > "$config_file"
  chmod 600 "$config_file"
  chown root:root "$config_file"

  log_success "Config generated for ${#users[@]} user(s)"
}

# ---------------------------------------------------------------------------
# Service installation
# ---------------------------------------------------------------------------

# Install the cloudflared systemd service.
# Uses `cloudflared service install` which creates the service unit.
# Then applies security hardening overrides from template.
install_cloudflared_service() {
  log_info "Installing cloudflared service..."

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install service"; return 0; }

  # Install the service using cloudflared's built-in installer
  # No token needed — authentication is via credentials-file in config.yml
  if ! systemctl list-unit-files | grep -q "^cloudflared.service"; then
    cloudflared service install
  fi

  # Apply security hardening overrides from template
  local override_dir="/etc/systemd/system/cloudflared.service.d"
  local override_file="${override_dir}/hardening.conf"
  local template_file="${TEMPLATE_DIR}/cloudflared.override-hardening.conf.tpl"

  # Back up existing override if present
  if [[ -f "$override_file" ]]; then
    backup_file "$override_file"
  fi

  # Copy the hardening template (no variable substitution needed)
  mkdir -p "$override_dir"
  if [[ -f "$template_file" ]]; then
    cp "$template_file" "$override_file"
  else
    log_warn "Hardening template missing: $template_file"
    return 0
  fi
  chmod 644 "$override_file"
}

# ---------------------------------------------------------------------------
# Service restart with health check
# ---------------------------------------------------------------------------

# Restart cloudflared and wait for it to establish a tunnel connection.
# After restarting, polls journalctl for up to 30 seconds to confirm
# the tunnel registration succeeded.
restart_cloudflared() {
  log_info "Restarting cloudflared..."

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would restart"; return 0; }

  # Reload systemd (to pick up override changes) and restart the service
  systemctl daemon-reload
  systemctl enable cloudflared
  systemctl restart cloudflared

  # Wait for the service to fully start and register the tunnel.
  # cloudflared uses Type=simple (or notify), so the service may report
  # "active" before the tunnel is actually connected.
  local max_wait=30
  local waited=0
  while [[ $waited -lt $max_wait ]]; do
    if systemctl is-active cloudflared &> /dev/null; then
      # Check journalctl for the tunnel registration message
      if journalctl -u cloudflared.service --since "5 seconds ago" | grep -q "Registered tunnel connection"; then
        log_success "cloudflared running and tunnel connected"
        return 0
      fi
    fi
    sleep 1
    ((waited++))
  done

  # Final check — service might be running even if we didn't catch the log
  systemctl is-active cloudflared &> /dev/null || { log_error "Failed to start"; return 1; }

  log_success "cloudflared running"
}

# ---------------------------------------------------------------------------
# Cloudflared setup orchestration
# ---------------------------------------------------------------------------

# Set up cloudflared completely: config, service, and restart.
setup_cloudflared() {
  log_info "=== Setting up cloudflared ==="

  generate_cloudflared_config
  install_cloudflared_service
  restart_cloudflared

  log_success "=== cloudflared setup complete ==="
}
