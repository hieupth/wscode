#!/bin/bash
# cloudflared.sh v0.5 - Cloudflared tunnel configuration, DNS route
# management, and service setup.
#
# Generates the cloudflared configuration file (YAML) with ingress rules
# for each enabled user, creates DNS CNAME records via Cloudflare API,
# and installs/manages the cloudflared systemd service.
#
# Authentication:
#   - Tunnel: credentials JSON file (CF_CREDENTIALS_FILE)
#   - DNS API: Cloudflare API token (CF_API_TOKEN) with Zone:DNS:Edit
#
# Domain pattern: {user}-{machine}.{zone}
#   e.g., alice-manjaropc.example.com -> http://127.0.0.1:21000
#
# DNS records are created per-user (CNAME -> tunnel) and cleaned up
# on rollback to avoid orphaned records.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Tunnel ID extraction
# ---------------------------------------------------------------------------

# Extract the tunnel UUID from the credentials JSON file.
# The credentials file contains a TunnelID field that is needed for
# DNS CNAME targets (<tunnel-id>.cfargotunnel.com).
# Output:
#   Tunnel UUID string
get_tunnel_id() {
  [[ -f "${CF_CREDENTIALS_FILE}" ]] || error_exit "Credentials file not found: ${CF_CREDENTIALS_FILE}"
  jq -r '.TunnelID' "${CF_CREDENTIALS_FILE}"
}

# ---------------------------------------------------------------------------
# Cloudflare API helpers
# ---------------------------------------------------------------------------

# Make a GET request to the Cloudflare API.
# Params:
#   $1 - API endpoint path (e.g., "dns_records?name=foo.example.com")
# Output:
#   JSON response body
cf_api_get() {
  local endpoint="$1"
  curl -sf -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/${endpoint}"
}

# Make a POST request to the Cloudflare API.
# Params:
#   $1 - API endpoint path
#   $2 - JSON request body
# Output:
#   JSON response body
cf_api_post() {
  local endpoint="$1"
  local data="$2"
  curl -sf -X POST \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/${endpoint}"
}

# Make a DELETE request to the Cloudflare API.
# Params:
#   $1 - API endpoint path (including record ID)
# Output:
#   JSON response body
cf_api_delete() {
  local endpoint="$1"
  curl -sf -X DELETE \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/${endpoint}"
}

# ---------------------------------------------------------------------------
# DNS route management
# ---------------------------------------------------------------------------

# Create a DNS CNAME record for a user's subdomain.
# Points {user}-{CF_DOMAIN_BASE} to the tunnel's edge address.
# Idempotent — skips if the record already exists and is correct.
# Params:
#   $1 - Username
# Returns:
#   0 on success, 1 on failure
create_user_dns_route() {
  local user="$1"
  local hostname="${user}-${CF_DOMAIN_BASE}"
  local tunnel_id
  tunnel_id=$(get_tunnel_id)
  local tunnel_target="${tunnel_id}.cfargotunnel.com"

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && {
    log_info "[DRY-RUN] Would create DNS: $hostname -> $tunnel_target"
    return 0
  }

  # Check if a CNAME record already exists for this hostname
  local existing
  existing=$(cf_api_get "dns_records?name=${hostname}&type=CNAME") || true
  local count
  count=$(echo "$existing" | jq -r '.result | length' 2>/dev/null || echo "0")

  if [[ "$count" -gt 0 ]]; then
    # Verify the existing record points to the correct tunnel
    local current_target
    current_target=$(echo "$existing" | jq -r '.result[0].content')
    if [[ "$current_target" == "$tunnel_target" ]]; then
      log_debug "DNS route already exists: $hostname"
      return 0
    else
      log_warn "DNS record $hostname points to $current_target (expected $tunnel_target), updating..."
      # Delete the incorrect record before recreating
      local record_id
      record_id=$(echo "$existing" | jq -r '.result[0].id')
      cf_api_delete "dns_records/${record_id}" >/dev/null || true
    fi
  fi

  # Create the CNAME record via Cloudflare API
  local response
  response=$(cf_api_post "dns_records" \
    "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${tunnel_target}\",\"proxied\":true}")

  if echo "$response" | jq -r '.success' | grep -q 'true'; then
    log_success "DNS route created: $hostname -> $tunnel_target"
  else
    log_error "Failed to create DNS route: $hostname"
    echo "$response" | jq -r '.errors[]?.message // "Unknown error"' >&2
    return 1
  fi
}

# Delete the DNS CNAME record for a user's subdomain.
# Skips silently if the record doesn't exist.
# Params:
#   $1 - Username
# Returns:
#   0 on success, 1 on failure
delete_user_dns_route() {
  local user="$1"
  local hostname="${user}-${CF_DOMAIN_BASE}"

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && {
    log_info "[DRY-RUN] Would delete DNS: $hostname"
    return 0
  }

  # Find matching CNAME records
  local existing
  existing=$(cf_api_get "dns_records?name=${hostname}&type=CNAME") || true
  local count
  count=$(echo "$existing" | jq -r '.result | length' 2>/dev/null || echo "0")

  if [[ "$count" -eq 0 ]]; then
    log_debug "DNS route not found (already clean): $hostname"
    return 0
  fi

  # Delete each matching record
  local record_ids
  mapfile -t record_ids < <(echo "$existing" | jq -r '.result[].id')
  local failed=0

  for record_id in "${record_ids[@]}"; do
    local response
    response=$(cf_api_delete "dns_records/${record_id}")
    if echo "$response" | jq -r '.success' | grep -q 'true'; then
      log_info "DNS route deleted: $hostname (record $record_id)"
    else
      log_error "Failed to delete DNS record: $record_id"
      ((failed++))
    fi
  done

  [[ $failed -gt 0 ]] && return 1
  log_success "DNS route cleaned up: $hostname"
}

# Create DNS routes for all enabled users.
# Called during setup to ensure each user has a resolvable subdomain.
create_all_dns_routes() {
  log_info "Creating DNS routes..."

  local users
  mapfile -t users < <(get_enabled_users)
  [[ ${#users[@]} -eq 0 ]] && { log_warn "No users for DNS routes"; return 0; }

  local failed=0
  for user in "${users[@]}"; do
    if ! create_user_dns_route "$user"; then
      ((failed++))
    fi
  done

  [[ $failed -gt 0 ]] && { log_error "$failed DNS route(s) failed"; return 1; }
  log_success "DNS routes created for ${#users[@]} user(s)"
}

# Delete DNS routes for all enabled users.
# Called during rollback/cleanup to remove orphaned DNS records.
cleanup_all_dns_routes() {
  log_info "Cleaning up DNS routes..."

  local users
  mapfile -t users < <(get_enabled_users)
  [[ ${#users[@]} -eq 0 ]] && { log_info "No users to clean up"; return 0; }

  local failed=0
  for user in "${users[@]}"; do
    if ! delete_user_dns_route "$user"; then
      ((failed++))
    fi
  done

  [[ $failed -gt 0 ]] && { log_error "$failed DNS route cleanup(s) failed"; return 1; }
  log_success "DNS routes cleaned up for ${#users[@]} user(s)"
}

# Create DNS routes for an explicit list of users.
# Used by reload when adding new users.
# Params:
#   $@ - List of usernames
create_dns_routes_for_users() {
  local users=("$@")
  [[ ${#users[@]} -eq 0 ]] && return 0

  local failed=0
  for user in "${users[@]}"; do
    create_user_dns_route "$user" || ((failed++))
  done
  [[ $failed -gt 0 ]] && return 1
  log_success "DNS routes created for ${#users[@]} added user(s)"
}

# Delete DNS routes for an explicit list of users.
# Used by reload when removing users, and by uninstall.
# Params:
#   $@ - List of usernames
cleanup_dns_routes_for_users() {
  local users=("$@")
  [[ ${#users[@]} -eq 0 ]] && return 0

  local failed=0
  for user in "${users[@]}"; do
    delete_user_dns_route "$user" || ((failed++))
  done
  [[ $failed -gt 0 ]] && return 1
  log_success "DNS routes deleted for ${#users[@]} removed user(s)"
}

# ---------------------------------------------------------------------------
# Configuration generation
# ---------------------------------------------------------------------------

# Generate the cloudflared configuration YAML file.
# Creates ingress rules mapping each user's subdomain to their
# localhost code-server port:
#   alice-manjaropc.example.com -> http://127.0.0.1:21000
#   bob-manjaropc.example.com   -> http://127.0.0.1:21001
#   (catch-all)                -> http_status:404
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

  # Extract tunnel ID from credentials file for the tunnel: field
  local tunnel_id
  tunnel_id=$(get_tunnel_id)

  # Build the YAML configuration
  # Structure:
  #   tunnel: <tunnel_id>
  #   credentials-file: <path_to_creds>
  #   ingress:
  #     - hostname: <user>-<domain> -> http://127.0.0.1:<port>
  #     - service: http_status:404  (catch-all, required by cloudflared)
  local config_content="tunnel: ${tunnel_id}"$'\n'
  config_content+="credentials-file: ${CF_CREDENTIALS_FILE}"$'\n'
  config_content+=$'\n'"ingress:"$'\n'

  # Generate an ingress rule for each user
  for user in "${users[@]}"; do
    local port
    port=$(get_user_port "$user")
    config_content+="  - hostname: ${user}-${CF_DOMAIN_BASE}"$'\n'
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
  if [[ -f /etc/systemd/system/cloudflared.service ]]; then
    log_info "cloudflared service already installed, skipping install"
  else
    # Uninstall any remnants (cloudflared-update.service) that block reinstall
    cloudflared service uninstall 2>/dev/null || true
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
    waited=$((waited + 1))
  done

  # Final check — service might be running even if we didn't catch the log
  systemctl is-active cloudflared &> /dev/null || { log_error "Failed to start"; return 1; }

  log_success "cloudflared running"
}

# ---------------------------------------------------------------------------
# Cloudflared setup orchestration
# ---------------------------------------------------------------------------

# Set up cloudflared completely: config, DNS routes, service, and restart.
setup_cloudflared() {
  log_info "=== Setting up cloudflared ==="

  generate_cloudflared_config
  create_all_dns_routes
  install_cloudflared_service
  restart_cloudflared

  log_success "=== cloudflared setup complete ==="
}
