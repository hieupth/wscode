#!/bin/bash
# rollback.sh v0.4 - Backup management and rollback functionality.
#
# Handles:
#   - Listing available backups (stored in state/backups/)
#   - Restoring files from a specific backup
#   - Automatic rollback to the latest backup on failure
#   - Cleaning up old backups (keeping only N most recent)
#
# Backup directory structure:
#   state/backups/{TIMESTAMP}/etc/systemd/system/...
#   state/backups/{TIMESTAMP}/etc/cloudflared/...
#   state/backups/{TIMESTAMP}/etc/webcode/...
# Files are stored with their full original path preserved under the
# backup directory, making restoration straightforward.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Backup listing
# ---------------------------------------------------------------------------

# List all available backups with their timestamps.
# Backups are named by timestamp (YYYYMMDD_HHMMSS format).
list_backups() {
  log_info "Available backups:"

  # No backups directory means no backups exist
  [[ ! -d "$BACKUP_DIR" ]] && { log_info "  None"; return 0; }

  local count=0
  for backup in "$BACKUP_DIR"/*; do
    # Only count directories (each backup is a directory)
    [[ -d "$backup" ]] && { echo "  - $(basename "$backup")"; ((count++)); }
  done

  [[ $count -eq 0 ]] && log_info "  None"
}

# ---------------------------------------------------------------------------
# Latest backup detection
# ---------------------------------------------------------------------------

# Find the most recent backup by timestamp.
# Since timestamps are in YYYYMMDD_HHMMSS format, string comparison
# is sufficient to determine chronological order.
# Output:
#   Timestamp of the latest backup
# Returns:
#   0 if a backup is found, 1 if no backups exist
get_latest_backup() {
  [[ ! -d "$BACKUP_DIR" ]] && return 1

  local latest=""
  for backup in "$BACKUP_DIR"/*; do
    [[ -d "$backup" ]] && {
      local ts
      ts=$(basename "$backup")
      # String comparison works because timestamps sort lexicographically
      [[ -z "$latest" || "$ts" > "$latest" ]] && latest="$ts"
    }
  done

  [[ -n "$latest" ]] && { echo "$latest"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# File restoration
# ---------------------------------------------------------------------------

# Restore all files from a specific backup to their original locations.
# Each file in the backup directory is at its original path relative
# to the backup root (e.g., backup/etc/systemd/system/x.service -> /etc/systemd/system/x.service).
# Params:
#   $1 - Backup timestamp to restore from
# Returns:
#   0 on success, 1 if no files were restored
rollback_to_backup() {
  local ts="$1"

  log_info "Rolling back to: $ts"

  local backup_path="${BACKUP_DIR}/${ts}"

  # Verify the backup directory exists
  [[ ! -d "$backup_path" ]] && error_exit "Backup not found: $backup_path"

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would rollback"; return 0; }

  local restored=0

  # Restore code-server systemd service template
  [[ -f "${backup_path}/etc/systemd/system/code-server@.service" ]] && {
    cp -a "${backup_path}/etc/systemd/system/code-server@.service" /etc/systemd/system/
    log_info "Restored code-server@.service"
    ((restored++))
  }

  # Restore code-server local override
  [[ -f "${backup_path}/etc/systemd/system/code-server@.service.d/local.conf" ]] && {
    mkdir -p /etc/systemd/system/code-server@.service.d
    cp -a "${backup_path}/etc/systemd/system/code-server@.service.d/local.conf" \
      /etc/systemd/system/code-server@.service.d/local.conf
    log_info "Restored code-server local override"
    ((restored++))
  }

  # Restore code-server hardening override
  [[ -f "${backup_path}/etc/systemd/system/code-server@.service.d/hardening.conf" ]] && {
    mkdir -p /etc/systemd/system/code-server@.service.d
    cp -a "${backup_path}/etc/systemd/system/code-server@.service.d/hardening.conf" \
      /etc/systemd/system/code-server@.service.d/hardening.conf
    log_info "Restored code-server hardening override"
    ((restored++))
  }

  # Restore cloudflared hardening override
  [[ -f "${backup_path}/etc/systemd/system/cloudflared.service.d/hardening.conf" ]] && {
    mkdir -p /etc/systemd/system/cloudflared.service.d
    cp -a "${backup_path}/etc/systemd/system/cloudflared.service.d/hardening.conf" \
      /etc/systemd/system/cloudflared.service.d/hardening.conf
    log_info "Restored cloudflared hardening override"
    ((restored++))
  }

  # Restore webcode ACL service
  [[ -f "${backup_path}/etc/systemd/system/webcode-acl.service" ]] && {
    cp -a "${backup_path}/etc/systemd/system/webcode-acl.service" /etc/systemd/system/
    log_info "Restored webcode ACL service"
    ((restored++))
  }

  # Restore cloudflared configuration
  [[ -f "${backup_path}/etc/cloudflared/config.yml" ]] && {
    mkdir -p /etc/cloudflared
    cp -a "${backup_path}/etc/cloudflared/config.yml" /etc/cloudflared/
    log_info "Restored cloudflared config"
    ((restored++))
  }

  # Restore webcode ACL nftables rules
  [[ -f "${backup_path}/etc/webcode/acl.nft" ]] && {
    mkdir -p /etc/webcode
    cp -a "${backup_path}/etc/webcode/acl.nft" /etc/webcode/
    log_info "Restored localhost ACL rules"
    ((restored++))
  }

  # No files were restored — backup might be empty or corrupted
  [[ $restored -eq 0 ]] && { log_warn "No files restored"; return 1; }

  # Reload systemd and restart affected services
  systemctl daemon-reload
  systemctl restart webcode-acl.service || true
  systemctl restart cloudflared || true

  log_success "Rollback complete: $restored file(s)"
}

# ---------------------------------------------------------------------------
# Automatic rollback
# ---------------------------------------------------------------------------

# Perform automatic rollback to the latest available backup.
# Cleans up DNS routes before restoring files to avoid orphaned records.
# Typically called from the cleanup trap in webcode.sh when the
# installation fails.
# Returns:
#   0 on success, 1 if no backups available or rollback fails
auto_rollback() {
  log_info "Attempting automatic rollback..."

  # Clean up DNS routes first (uses current config to find hostnames)
  # This removes CNAME records that point to this machine's tunnel,
  # preventing orphaned DNS records after rollback.
  if [[ -n "${CF_API_TOKEN:-}" ]] && [[ -n "${CF_ZONE_ID:-}" ]]; then
    cleanup_all_dns_routes || log_warn "DNS cleanup failed during rollback (manual cleanup may be needed)"
  else
    log_warn "CF_API_TOKEN/CF_ZONE_ID not set — skipping DNS cleanup. Remove DNS records manually if needed."
  fi

  # Find the latest backup
  local latest
  latest=$(get_latest_backup) || { log_error "No backups available"; return 1; }

  log_info "Using backup: $latest"
  rollback_to_backup "$latest"
}

# ---------------------------------------------------------------------------
# Backup cleanup
# ---------------------------------------------------------------------------

# Remove old backups, keeping only the N most recent.
# Prevents unbounded disk usage from accumulating backups.
# Params:
#   $1 - Number of backups to keep (default: 5)
clean_old_backups() {
  local keep="${1:-5}"

  log_info "Cleaning old backups (keeping last $keep)..."

  # Nothing to clean if no backups directory
  [[ ! -d "$BACKUP_DIR" ]] && { log_info "No backups to clean"; return 0; }

  # Collect all backup timestamps
  local -a backups=()
  for backup in "$BACKUP_DIR"/*; do
    [[ -d "$backup" ]] && backups+=("$(basename "$backup")")
  done

  # No cleanup needed if we have fewer than the keep limit
  [[ ${#backups[@]} -le $keep ]] && { log_info "Only ${#backups[@]} backup(s), no cleanup needed"; return 0; }

  # Sort oldest first (lexicographic sort works for YYYYMMDD_HHMMSS)
  IFS=$'\n' backups=($(sort <<<"${backups[*]}"))
  unset IFS

  # Calculate how many old backups to remove
  local to_remove=$((${#backups[@]} - keep))
  local removed=0

  # Remove the oldest backups
  for ((i=0; i<to_remove; i++)); do
    local backup_path="${BACKUP_DIR}/${backups[$i]}"

    # In dry-run mode, just log what would be removed
    [[ $DRY_RUN -eq 1 ]] && log_info "[DRY-RUN] Would remove: ${backups[$i]}" || {
      rm -rf "$backup_path"
      log_info "Removed: ${backups[$i]}"
    }

    ((removed++))
  done

  log_success "Cleaned $removed old backup(s)"
}
