#!/bin/bash
# acl.sh v0.4 - Localhost port ACL for user isolation.
#
# Generates and applies nftables rules to enforce localhost port isolation:
#   - Each user can only connect to their own code-server port (20000 + UID)
#   - Root can connect to all ports (needed for cloudflared tunnel and health checks)
#   - Cloudflared user (if it exists) can connect to all ports (tunnel routing)
#   - All other cross-user connections on the 20000-65535 range are rejected
#
# The ACL is persisted as a systemd service (webcode-acl.service) so it
# survives reboots. All generated content comes from template files (no heredocs).

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Output path for the nftables rules file
readonly ACL_FILE="/etc/webcode/acl.nft"

# Systemd service that applies the ACL on boot
readonly ACL_SERVICE="/etc/systemd/system/webcode-acl.service"

# ---------------------------------------------------------------------------
# Cloudflared UID detection
# ---------------------------------------------------------------------------

# Detect the UID of the cloudflared system user.
# The cloudflared service needs access to all user ports for tunnel routing.
# Returns 0 if cloudflared runs as root (no separate user needed).
# Output:
#   UID of cloudflared user, or 0 if no separate cloudflared user exists
detect_cloudflared_uid() {
  if id cloudflared >/dev/null 2>&1; then
    id -u cloudflared
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# ACL rule generation
# ---------------------------------------------------------------------------

# Generate nftables ACL rules for the given user list.
# Uses the template file src/templates/acl.nft.tpl with variable substitution.
# The template contains the static rule structure; this function provides
# the dynamic per-user rules and cloudflared UID.
# Params:
#   $@ - List of usernames to generate rules for
# Output:
#   Complete nftables ruleset (written to ACL_FILE)
generate_acl_rules() {
  local users=("$@")

  # Get cloudflared UID for the tunnel access rule
  local cloudflared_uid
  cloudflared_uid=$(detect_cloudflared_uid)

  # Build per-user rules as a string
  # Each user gets: accept connections from their UID to their port only
  local user_rules=""
  local user uid port
  for user in "${users[@]}"; do
    uid=$(id -u "$user")
    port=$(get_user_port "$user")
    user_rules+="    meta skuid ${uid} ip daddr 127.0.0.1 tcp dport ${port} accept"$'\n'
    user_rules+="    meta skuid ${uid} ip6 daddr ::1 tcp dport ${port} accept"$'\n'
  done

  # Build cloudflared rules (only if cloudflared has its own UID)
  local cloudflared_rules=""
  if [[ "$cloudflared_uid" != "0" ]]; then
    cloudflared_rules+="    meta skuid ${cloudflared_uid} ip daddr 127.0.0.1 tcp dport 20000-65535 accept"$'\n'
    cloudflared_rules+="    meta skuid ${cloudflared_uid} ip6 daddr ::1 tcp dport 20000-65535 accept"$'\n'
  fi

  # Render the template with all variables
  local template_file="${TEMPLATE_DIR}/acl.nft.tpl"
  if [[ -f "$template_file" ]]; then
    # Use template file approach
    local content
    content=$(cat "$template_file")
    content="${content//\{\{CLOUDFLARED_RULES\}\}/${cloudflared_rules}}"
    content="${content//\{\{USER_RULES\}\}/${user_rules}}"
    echo "$content"
  else
    error_exit "ACL template not found: $template_file"
  fi
}

# ---------------------------------------------------------------------------
# ACL systemd service installation
# ---------------------------------------------------------------------------

# Install the systemd service unit that applies ACL rules on boot.
# Uses src/templates/webcode-acl.service.tpl template.
# Params:
#   $1 - Path to the nft binary (for the ExecStart commands)
install_acl_service_unit() {
  local nft_bin="$1"

  # Back up existing service file if present
  if [[ -f "$ACL_SERVICE" ]]; then
    backup_file "$ACL_SERVICE"
  fi

  # Render the service template
  local template_file="${TEMPLATE_DIR}/webcode-acl.service.tpl"
  if [[ -f "$template_file" ]]; then
    render_template "$template_file" "$ACL_SERVICE" \
      NFT_BIN "$nft_bin" \
      ACL_FILE "$ACL_FILE"
  else
    error_exit "ACL service template not found: $template_file"
  fi

  chmod 644 "$ACL_SERVICE"
}

# ---------------------------------------------------------------------------
# ACL setup orchestration
# ---------------------------------------------------------------------------

# Set up the complete localhost port ACL system.
# 1. Generates nftables rules from the user list
# 2. Writes rules to /etc/webcode/acl.nft
# 3. Installs the webcode-acl.service systemd unit
# 4. Applies rules immediately and enables the service for boot
setup_local_port_acl() {
  log_info "Setting up localhost ACL..."

  # Get all enabled users for rule generation
  local users
  mapfile -t users < <(get_enabled_users)

  # Must have at least one user to generate rules
  [[ ${#users[@]} -gt 0 ]] || error_exit "No users found for ACL generation"

  # In dry-run mode, just log what would be done
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[DRY-RUN] Would generate ${ACL_FILE} and webcode-acl.service"
    return 0
  fi

  # Find the nft binary
  local nft_bin
  nft_bin=$(command -v nft || true)
  [[ -n "$nft_bin" ]] || error_exit "nft command not found. Install nftables package."

  # Ensure the config directory exists
  ensure_dir /etc/webcode 0700 root:root

  # Back up existing ACL file if present
  if [[ -f "$ACL_FILE" ]]; then
    backup_file "$ACL_FILE"
  fi

  # Generate and write the nftables rules
  generate_acl_rules "${users[@]}" > "$ACL_FILE"
  chmod 600 "$ACL_FILE"
  chown root:root "$ACL_FILE"

  # Install the systemd service unit from template
  install_acl_service_unit "$nft_bin"

  # Apply rules immediately:
  # 1. Remove any existing table (clean slate)
  # 2. Load the new rules
  nft delete table inet webcode 2>/dev/null || true
  nft -f "$ACL_FILE"

  # Reload systemd and enable the ACL service
  systemctl daemon-reload
  systemctl enable webcode-acl.service >/dev/null
  systemctl restart webcode-acl.service

  # Verify the service started successfully
  systemctl is-active webcode-acl.service >/dev/null 2>&1 || {
    log_error "webcode-acl.service is not active"
    systemctl status webcode-acl.service --no-pager || true
    return 1
  }

  log_success "Localhost ACL is active for ${#users[@]} user(s)"
}
