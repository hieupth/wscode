#!/bin/bash
# webcode.sh v0.5 - CLI entry point for webcode management.
#
# Provides subcommand-based interface for managing multi-user
# VS Code server instances with Cloudflare Tunnel.
#
# Commands:
#   install     - Full installation (preflight, install, configure, verify)
#   reload      - Apply users.allow changes (add/remove DNS, services, ACL)
#   uninstall   - Remove all webcode managed resources
#   verify      - Verify installation status
#   rollback    - Restore from latest backup
#   list-backups - Show available backups

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all library modules
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"
source "${SCRIPT_DIR}/lib/install.sh"
source "${SCRIPT_DIR}/lib/users.sh"
source "${SCRIPT_DIR}/lib/services.sh"
source "${SCRIPT_DIR}/lib/acl.sh"
source "${SCRIPT_DIR}/lib/cloudflared.sh"
source "${SCRIPT_DIR}/lib/verify.sh"
source "${SCRIPT_DIR}/lib/rollback.sh"

# ---------------------------------------------------------------------------
# Usage display
# ---------------------------------------------------------------------------

usage() {
  cat "${SCRIPT_DIR}/templates/usage-cli.txt"
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

COMMAND=""
DEBUG_MODE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)        DEBUG_MODE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --help|-h)      usage ;;
    install|reload|uninstall|verify|rollback|list-backups)
      COMMAND="$1"; shift ;;
    *)              echo "Unknown option or command: $1"; usage ;;
  esac
done

[[ -z "$COMMAND" ]] && usage

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]] && [[ "$COMMAND" == "install" ]] && [[ $DRY_RUN -eq 0 ]]; then
    log_error "Installation failed with exit code $exit_code"
    if [[ -d "$BACKUP_DIR" ]] && [[ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
      log_info "Attempting automatic rollback..."
      if auto_rollback; then
        log_info "Rollback completed. System restored to previous state."
      else
        log_error "Rollback failed. Manual intervention may be required."
      fi
    else
      log_warn "No backups available for automatic rollback"
    fi
  fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Command: install
# ---------------------------------------------------------------------------

cmd_install() {
  log_info "=========================================="
  log_info "webcode install"
  log_info "Version ${VERSION}"
  log_info "=========================================="
  log_info ""

  check_root

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info ""
    log_info "=== DRY RUN MODE ==="
    log_info "No changes will be made to the system"
    log_info ""
  fi

  # Step 1: Preflight checks
  run_preflight_checks

  # Step 2: Install dependencies
  install_all

  # Step 3: Set up user environments
  setup_all_users

  # Step 4: Configure systemd services
  setup_code_server_services

  # Step 5: Apply localhost ACL
  setup_local_port_acl

  # Step 6: Configure cloudflared tunnel + DNS routes
  setup_cloudflared

  # Step 7: Write state file
  if [[ $DRY_RUN -eq 0 ]]; then
    local users
    mapfile -t users < <(get_enabled_users)
    write_active_state "${users[@]}"
  fi

  # Step 8: Verify
  if [[ $DRY_RUN -eq 0 ]]; then
    log_info ""
    log_info "=== Running post-installation verification ==="
    if run_verification 1; then
      log_success ""
      log_success "=========================================="
      log_success "Installation completed successfully!"
      log_success "=========================================="
      log_success ""

      local users
      mapfile -t users < <(get_enabled_users)
      log_info "Summary:"
      log_info "  - ${#users[@]} user(s) configured"
      log_info "  - code-server instances running on localhost"
      log_info "  - localhost ACL active (user to own port only)"
      log_info "  - cloudflared tunnel active"
      log_info "  - DNS routes created"
      log_info ""
      log_info "Next steps:"
      log_info "  1. Configure Cloudflare Access policies if needed"
      log_info "  2. Test access at https://<username>-${CF_DOMAIN_BASE}"
      log_info ""

      clean_old_backups 5
    else
      log_warn "Verification found issues. Please review the output above."
      exit 1
    fi
  else
    log_info ""
    log_info "=== DRY RUN COMPLETED ==="
    log_info "Run without --dry-run to apply changes"
  fi
}

# ---------------------------------------------------------------------------
# Command: reload
# ---------------------------------------------------------------------------

cmd_reload() {
  log_info "=========================================="
  log_info "webcode reload"
  log_info "=========================================="
  log_info ""

  check_root
  load_config

  # Read current state (users previously configured)
  local -a old_users=()
  read_active_state old_users

  # Read desired state (from users.allow)
  local -a new_users=()
  mapfile -t new_users < <(get_enabled_users)

  # Diff
  local -a to_add=()
  local -a to_remove=()
  local -a to_keep=()
  diff_user_lists old_users new_users to_add to_remove to_keep

  # Report changes
  if [[ ${#to_add[@]} -eq 0 ]] && [[ ${#to_remove[@]} -eq 0 ]]; then
    log_info "No changes detected. All ${#new_users[@]} user(s) up to date."
    exit 0
  fi

  [[ ${#to_add[@]} -gt 0 ]] && log_info "Users to add: ${to_add[*]}"
  [[ ${#to_remove[@]} -gt 0 ]] && log_info "Users to remove: ${to_remove[*]}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[DRY-RUN] Would apply the above changes"
    exit 0
  fi

  # Remove users
  for user in "${to_remove[@]}"; do
    disable_code_server_for_user "$user"
    delete_user_dns_route "$user"
  done

  # Add users
  for user in "${to_add[@]}"; do
    setup_user_environment "$user"
    enable_code_server_for_user "$user"
    create_user_dns_route "$user"
  done

  # If any changes, regenerate shared configs and restart
  if [[ ${#to_add[@]} -gt 0 ]] || [[ ${#to_remove[@]} -gt 0 ]]; then
    generate_cloudflared_config
    restart_cloudflared
    setup_local_port_acl
    systemctl daemon-reload
  fi

  # Update state file
  write_active_state "${new_users[@]}"

  log_success ""
  log_success "=========================================="
  log_success "Reload completed!"
  log_success "=========================================="
  log_info "  - Added: ${#to_add[@]} user(s)"
  log_info "  - Removed: ${#to_remove[@]} user(s)"
  log_info "  - Total: ${#new_users[@]} user(s)"
}

# ---------------------------------------------------------------------------
# Command: uninstall
# ---------------------------------------------------------------------------

cmd_uninstall() {
  log_info "=========================================="
  log_info "webcode uninstall"
  log_info "=========================================="
  log_info ""

  check_root

  # Load config if available (for DNS cleanup)
  if [[ -f "$CONFIG_FILE" ]]; then
    load_config

    # Read active users for DNS cleanup
    local -a active_users=()
    read_active_state active_users

    # Delete all DNS routes
    if [[ ${#active_users[@]} -gt 0 ]]; then
      cleanup_all_dns_routes
    fi
  else
    log_warn "Config file not found. Skipping DNS cleanup."
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[DRY-RUN] Would remove all services and configuration"
    exit 0
  fi

  # Stop and disable all code-server instances
  log_info "Stopping code-server instances..."
  for service in $(systemctl list-units --type=service --all 'code-server@*' 2>/dev/null | grep -oP 'code-server@\K[^.]+' || true); do
    disable_code_server_for_user "$service"
  done

  # Stop and disable cloudflared
  log_info "Stopping cloudflared..."
  systemctl stop cloudflared 2>/dev/null || true
  systemctl disable cloudflared 2>/dev/null || true

  # Stop and disable ACL
  log_info "Stopping ACL service..."
  systemctl stop webcode-acl.service 2>/dev/null || true
  systemctl disable webcode-acl.service 2>/dev/null || true

  # Remove nft table
  nft delete table inet webcode 2>/dev/null || true

  # Remove systemd unit files
  log_info "Removing service files..."
  rm -f /etc/systemd/system/code-server@.service
  rm -rf /etc/systemd/system/code-server@.service.d
  rm -f /etc/systemd/system/cloudflared.service
  rm -rf /etc/systemd/system/cloudflared.service.d
  rm -f /etc/systemd/system/webcode-acl.service

  # Remove generated configs
  log_info "Removing generated configs..."
  rm -f /etc/cloudflared/config.yml
  rm -f /etc/webcode/acl.nft
  rm -f "$ACTIVE_STATE_FILE"

  # Reload systemd
  systemctl daemon-reload

  log_success ""
  log_success "=========================================="
  log_success "Uninstall completed!"
  log_success "=========================================="
  log_info ""
  log_info "Removed:"
  log_info "  - All DNS CNAME records (Cloudflare)"
  log_info "  - All code-server service instances"
  log_info "  - cloudflared service and config"
  log_info "  - ACL service and nftables rules"
  log_info ""
  log_info "Preserved (not removed):"
  log_info "  - code-server binary (/usr/local/lib/code-server)"
  log_info "  - cloudflared binary (/usr/local/bin/cloudflared)"
  log_info "  - User home directories and extensions"
  log_info "  - Config files (/etc/webcode/config.env, creds.json)"
  log_info "  - System packages"
}

# ---------------------------------------------------------------------------
# Command: verify
# ---------------------------------------------------------------------------

cmd_verify() {
  check_root
  run_verification 0
}

# ---------------------------------------------------------------------------
# Command: rollback
# ---------------------------------------------------------------------------

cmd_rollback() {
  check_root
  auto_rollback
}

# ---------------------------------------------------------------------------
# Command: list-backups
# ---------------------------------------------------------------------------

cmd_list_backups() {
  check_root
  list_backups
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

case "$COMMAND" in
  install)       cmd_install ;;
  reload)        cmd_reload ;;
  uninstall)     cmd_uninstall ;;
  verify)        cmd_verify ;;
  rollback)      cmd_rollback ;;
  list-backups)  cmd_list_backups ;;
esac
