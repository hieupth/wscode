#!/bin/bash
# setup.sh v0.3 - Main installer for wscode

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library files
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"
source "${SCRIPT_DIR}/lib/install.sh"
source "${SCRIPT_DIR}/lib/users.sh"
source "${SCRIPT_DIR}/lib/services.sh"
source "${SCRIPT_DIR}/lib/acl.sh"
source "${SCRIPT_DIR}/lib/cloudflared.sh"
source "${SCRIPT_DIR}/lib/verify.sh"
source "${SCRIPT_DIR}/lib/rollback.sh"

# Usage information
usage() {
    cat <<EOF
wscode Installer v${VERSION}

Usage: sudo bash src/setup.sh [OPTIONS]

Options:
  --apply          Apply installation (default)
  --dry-run        Preview without making changes
  --verify-only    Only run verification
  --rollback       Rollback to latest backup
  --list-backups   List available backups
  --debug          Enable debug output
  --help           Show this help

Examples:
  sudo bash src/setup.sh                    # Run installation
  sudo bash src/setup.sh --dry-run          # Preview changes
  sudo bash src/setup.sh --verify-only      # Check current setup
  sudo bash src/setup.sh --rollback         # Restore from backup

Configuration:
  Edit /etc/wscode/config.env before running
  Optional allow/deny lists:
    /etc/wscode/users.allow
    /etc/wscode/users.deny
  See config/settings.env.example for template

Changes in v0.3:
  - FEAT: Move source tree under src/
  - FEAT: Enforce localhost port ACL via nftables (default simple mode)
  - FEAT: Persist ACL with systemd wscode-acl.service
  - FEAT: Require explicit user allowlist for safer defaults

Changes in v0.2:
  - FIX: Validate secure permissions before sourcing env files
  - FIX: Resolve user home via getent (no hardcoded /home/%i)
  - FIX: Rollback restores override files without destructive directory wipe
  - FEAT: Cloudflared hardening loaded from template
  - FEAT: Mapping consistency checks for hostname/port collisions
  - FEAT: Configurable paths via env:
        WSCODE_CONFIG_FILE
        WSCODE_USERS_ALLOW
        WSCODE_USERS_DENY

EOF
    exit 0
}

# Parse arguments
MODE="apply"
ROLLBACK_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) MODE="apply"; shift ;;
        --dry-run) DRY_RUN=1; MODE="apply"; shift ;;
        --verify-only) MODE="verify"; shift ;;
        --rollback) ROLLBACK_MODE=1; shift ;;
        --list-backups) MODE="list-backups"; shift ;;
        --debug) DEBUG_MODE=1; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Trap for cleanup and error handling
cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]] && [[ $MODE == "apply" ]] && [[ $DRY_RUN -eq 0 ]]; then
        log_error "Installation failed with exit code $exit_code"
        
        # Attempt automatic rollback
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

# Main execution
main() {
    log_info "=========================================="
    log_info "wscode - VS Code on server"
    log_info "Version ${VERSION}"
    log_info "=========================================="
    log_info ""
    
    # Check root
    check_root
    
    # Handle different modes
    case "$MODE" in
        list-backups)
            list_backups
            exit 0
            ;;
        verify)
            log_info "Running verification only..."
            run_verification
            exit $?
            ;;
        apply)
            # Handle rollback
            if [[ $ROLLBACK_MODE -eq 1 ]]; then
                auto_rollback
                exit $?
            fi
            
            # Run preflight checks
            run_preflight_checks
            
            if [[ $DRY_RUN -eq 1 ]]; then
                log_info ""
                log_info "=== DRY RUN MODE ==="
                log_info "No changes will be made to the system"
                log_info ""
            fi
            
            # Install dependencies
            install_all
            
            # Setup user environments
            setup_all_users
            
            # Setup code-server services
            setup_code_server_services

            # Enforce localhost user-to-port ACL
            setup_local_port_acl
            
            # Setup cloudflared
            setup_cloudflared
            
            if [[ $DRY_RUN -eq 0 ]]; then
                log_info ""
                log_info "=== Running post-installation verification ==="
                
                # Run verification
                if run_verification; then
                    log_success ""
                    log_success "=========================================="
                    log_success "Installation completed successfully!"
                    log_success "=========================================="
                    log_success ""
                    
                    # Show summary
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
                    
                    # Clean old backups
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

# Run main function
main "$@"
