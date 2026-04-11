#!/bin/bash
# setup.sh v0.4 - Main installer for webcode
#
# Entry point that orchestrates the entire installation:
#   1. Preflight checks (OS, systemd, network, users, ports)
#   2. Install dependencies (packages, code-server, cloudflared)
#   3. Set up user environments (extension directories)
#   4. Configure systemd services (code-server instances)
#   5. Apply localhost ACL (nftables port isolation)
#   6. Configure cloudflared tunnel (ingress rules)
#   7. Verify everything works
#
# Supports multiple modes:
#   --apply         Full installation (default)
#   --dry-run       Preview without making changes
#   --verify-only   Only run verification checks
#   --rollback      Restore from latest backup
#   --list-backups  Show available backups

set -euo pipefail

# Get the directory where this script lives.
# All relative paths are resolved from here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all library modules.
# Each module is independent and only depends on common.sh.
source "${SCRIPT_DIR}/lib/common.sh"
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

# Show help text from the usage template file.
# This avoids inline heredoc — the help text is in src/templates/usage.txt.
usage() {
  cat "${SCRIPT_DIR}/templates/usage.txt"
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

MODE="apply"
ROLLBACK_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        MODE="apply"; shift ;;
    --dry-run)      DRY_RUN=1; MODE="apply"; shift ;;
    --verify-only)  MODE="verify"; shift ;;
    --rollback)     ROLLBACK_MODE=1; shift ;;
    --list-backups) MODE="list-backups"; shift ;;
    --debug)        DEBUG_MODE=1; shift ;;
    --help|-h)      usage ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

# Automatic rollback on failure.
# If the installation exits with a non-zero code during apply mode
# (not dry-run), attempt to restore the system to its previous state
# using the latest backup.
cleanup() {
  local exit_code=$?

  if [[ $exit_code -ne 0 ]] && [[ $MODE == "apply" ]] && [[ $DRY_RUN -eq 0 ]]; then
    log_error "Installation failed with exit code $exit_code"

    # Attempt automatic rollback if backups exist
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
# Main execution
# ---------------------------------------------------------------------------

main() {
  log_info "=========================================="
  log_info "webcode - VS Code on server"
  log_info "Version ${VERSION}"
  log_info "=========================================="
  log_info ""

  # All operations require root privileges
  check_root

  # Dispatch based on the selected mode
  case "$MODE" in
    # List available backups and exit
    list-backups)
      list_backups
      exit 0
      ;;

    # Run verification only — no changes to the system
    verify)
      log_info "Running verification only..."
      run_verification 0
      exit $?
      ;;

    # Apply installation (or dry-run preview)
    apply)
      # Handle rollback request
      if [[ $ROLLBACK_MODE -eq 1 ]]; then
        auto_rollback
        exit $?
      fi

      # Step 1: Run preflight checks
      run_preflight_checks

      # Announce dry-run mode if active
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info ""
        log_info "=== DRY RUN MODE ==="
        log_info "No changes will be made to the system"
        log_info ""
      fi

      # Step 2: Install all dependencies
      install_all

      # Step 3: Set up user environments (extension dirs)
      setup_all_users

      # Step 4: Configure systemd services for code-server
      setup_code_server_services

      # Step 5: Apply localhost port ACL for user isolation
      setup_local_port_acl

      # Step 6: Configure cloudflared tunnel
      setup_cloudflared

      # Step 7: Verify the installation (skip perm checks — just set them)
      if [[ $DRY_RUN -eq 0 ]]; then
        log_info ""
        log_info "=== Running post-installation verification ==="

        if run_verification 1; then
          log_success ""
          log_success "=========================================="
          log_success "Installation completed successfully!"
          log_success "=========================================="
          log_success ""

          # Show installation summary
          local users
          mapfile -t users < <(get_enabled_users)

          log_info "Summary:"
          log_info "  - Installer version: ${VERSION}"
          log_info "  - ${#users[@]} user(s) configured"
          log_info "  - code-server instances running on localhost"
          log_info "  - localhost ACL active (user to own port only)"
          log_info "  - cloudflared tunnel active"
          log_info ""
          log_info "Next steps:"
          log_info "  1. Ensure DNS is configured for *.${CF_DOMAIN_BASE}"
          log_info "  2. Configure Cloudflare Access for *.${CF_DOMAIN_BASE}"
          log_info "  3. Test access at https://<username>.${CF_DOMAIN_BASE}"
          log_info ""

          # Clean up old backups (keep 5 most recent)
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
      ;;
  esac
}

# Run the main function
main "$@"
