#!/bin/bash
# rollback.sh v0.3 - Backup and rollback

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

list_backups() {
    log_info "Available backups:"
    
    [[ ! -d "$BACKUP_DIR" ]] && { log_info "  None"; return 0; }
    
    local count=0
    for backup in "$BACKUP_DIR"/*; do
        [[ -d "$backup" ]] && { echo "  - $(basename "$backup")"; ((count++)); }
    done
    
    [[ $count -eq 0 ]] && log_info "  None"
}

get_latest_backup() {
    [[ ! -d "$BACKUP_DIR" ]] && return 1
    
    local latest=""
    for backup in "$BACKUP_DIR"/*; do
        [[ -d "$backup" ]] && {
            local ts=$(basename "$backup")
            [[ -z "$latest" || "$ts" > "$latest" ]] && latest="$ts"
        }
    done
    
    [[ -n "$latest" ]] && { echo "$latest"; return 0; }
    return 1
}

rollback_to_backup() {
    local ts="$1"
    
    log_info "Rolling back to: $ts"
    
    local backup_path="${BACKUP_DIR}/${ts}"
    
    [[ ! -d "$backup_path" ]] && error_exit "Backup not found: $backup_path"
    
    [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would rollback"; return 0; }
    
    local restored=0
    
    # Restore systemd files
    [[ -f "${backup_path}/etc/systemd/system/code-server@.service" ]] && {
        cp -a "${backup_path}/etc/systemd/system/code-server@.service" /etc/systemd/system/
        log_info "Restored code-server@.service"
        ((restored++))
    }

    [[ -f "${backup_path}/etc/systemd/system/code-server@.service.d/local.conf" ]] && {
        mkdir -p /etc/systemd/system/code-server@.service.d
        cp -a "${backup_path}/etc/systemd/system/code-server@.service.d/local.conf" \
            /etc/systemd/system/code-server@.service.d/local.conf
        log_info "Restored code-server local override"
        ((restored++))
    }

    [[ -f "${backup_path}/etc/systemd/system/code-server@.service.d/hardening.conf" ]] && {
        mkdir -p /etc/systemd/system/code-server@.service.d
        cp -a "${backup_path}/etc/systemd/system/code-server@.service.d/hardening.conf" \
            /etc/systemd/system/code-server@.service.d/hardening.conf
        log_info "Restored code-server hardening override"
        ((restored++))
    }

    [[ -f "${backup_path}/etc/systemd/system/cloudflared.service.d/hardening.conf" ]] && {
        mkdir -p /etc/systemd/system/cloudflared.service.d
        cp -a "${backup_path}/etc/systemd/system/cloudflared.service.d/hardening.conf" \
            /etc/systemd/system/cloudflared.service.d/hardening.conf
        log_info "Restored cloudflared hardening override"
        ((restored++))
    }

    [[ -f "${backup_path}/etc/systemd/system/wscode-acl.service" ]] && {
        cp -a "${backup_path}/etc/systemd/system/wscode-acl.service" /etc/systemd/system/
        log_info "Restored wscode ACL service"
        ((restored++))
    }

    [[ -f "${backup_path}/etc/cloudflared/config.yml" ]] && {
        mkdir -p /etc/cloudflared
        cp -a "${backup_path}/etc/cloudflared/config.yml" /etc/cloudflared/
        log_info "Restored cloudflared config"
        ((restored++))
    }

    [[ -f "${backup_path}/etc/wscode/acl.nft" ]] && {
        mkdir -p /etc/wscode
        cp -a "${backup_path}/etc/wscode/acl.nft" /etc/wscode/
        log_info "Restored localhost ACL rules"
        ((restored++))
    }
    
    [[ $restored -eq 0 ]] && { log_warn "No files restored"; return 1; }
    
    systemctl daemon-reload
    systemctl restart wscode-acl.service || true
    systemctl restart cloudflared || true

    log_success "Rollback complete: $restored file(s)"
}

auto_rollback() {
    log_info "Attempting automatic rollback..."
    
    local latest
    latest=$(get_latest_backup) || { log_error "No backups available"; return 1; }
    
    log_info "Using backup: $latest"
    rollback_to_backup "$latest"
}

clean_old_backups() {
    local keep="${1:-5}"
    
    log_info "Cleaning old backups (keeping last $keep)..."
    
    [[ ! -d "$BACKUP_DIR" ]] && { log_info "No backups to clean"; return 0; }
    
    local -a backups=()
    for backup in "$BACKUP_DIR"/*; do
        [[ -d "$backup" ]] && backups+=("$(basename "$backup")")
    done
    
    [[ ${#backups[@]} -le $keep ]] && { log_info "Only ${#backups[@]} backup(s), no cleanup needed"; return 0; }
    
    # Sort (oldest first)
    IFS=$'\n' backups=($(sort <<<"${backups[*]}"))
    unset IFS
    
    local to_remove=$((${#backups[@]} - keep))
    local removed=0
    
    for ((i=0; i<to_remove; i++)); do
        local backup_path="${BACKUP_DIR}/${backups[$i]}"
        
        [[ $DRY_RUN -eq 1 ]] && log_info "[DRY-RUN] Would remove: ${backups[$i]}" || {
            rm -rf "$backup_path"
            log_info "Removed: ${backups[$i]}"
        }
        
        ((removed++))
    done
    
    log_success "Cleaned $removed old backup(s)"
}
