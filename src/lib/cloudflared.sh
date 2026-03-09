#!/bin/bash
# cloudflared.sh v0.3 - Cloudflared configuration

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

generate_cloudflared_config() {
    log_info "Generating cloudflared configuration..."
    
    local config_file="/etc/cloudflared/config.yml"
    
    [[ -f "$config_file" ]] && backup_file "$config_file"
    
    local users
    mapfile -t users < <(get_enabled_users)

    [[ ${#users[@]} -gt 0 ]] || error_exit "No eligible users found for cloudflared ingress rules"

    local config_content="tunnel: ${CF_TUNNEL_NAME}"$'\n'
    [[ -n "${CF_CREDENTIALS_FILE:-}" ]] && config_content+="credentials-file: ${CF_CREDENTIALS_FILE}"$'\n'

    config_content+=$'\n'"ingress:"$'\n'
    
    for user in "${users[@]}"; do
        local port=$(get_user_port "$user")
        config_content+="  - hostname: ${user}.${CF_DOMAIN_BASE}"$'\n'
        config_content+="    service: http://127.0.0.1:${port}"$'\n'
    done
    
    config_content+="  - service: http_status:404"$'\n'
    
    [[ $DRY_RUN -eq 1 ]] && {
        log_info "[DRY-RUN] Would write config"
        log_debug "$config_content"
        return 0
    }

    ensure_dir /etc/cloudflared 0700 root:root

    echo "$config_content" > "$config_file"
    chmod 600 "$config_file"
    chown root:root "$config_file"
    
    log_success "Config generated for ${#users[@]} user(s)"
}

install_cloudflared_service() {
    log_info "Installing cloudflared service..."
    
    [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install service"; return 0; }
    
    if ! systemctl list-unit-files | grep -q "^cloudflared.service"; then
        if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
            cloudflared service install "$CF_TUNNEL_TOKEN"
        else
            cloudflared service install
        fi
    fi
    
    local override_dir="/etc/systemd/system/cloudflared.service.d"
    local override_file="${override_dir}/hardening.conf"
    local template_file="${TEMPLATE_DIR}/cloudflared.override-hardening.conf.tpl"

    if [[ -f "$override_file" ]]; then
        backup_file "$override_file"
    fi

    mkdir -p "$override_dir"
    if [[ -f "$template_file" ]]; then
        cp "$template_file" "$override_file"
    else
        log_warn "Hardening template missing: $template_file"
        return 0
    fi
    chmod 644 "$override_file"
}

restart_cloudflared() {
    log_info "Restarting cloudflared..."
    
    [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would restart"; return 0; }
    
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl restart cloudflared

    # Wait for service to be fully started (Type=simple doesn't notify)
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if systemctl is-active cloudflared &> /dev/null; then
            # Additional check: verify tunnel is registered
            if journalctl -u cloudflared.service --since "5 seconds ago" | grep -q "Registered tunnel connection"; then
                log_success "cloudflared running and tunnel connected"
                return 0
            fi
        fi
        sleep 1
        ((waited++))
    done

    # Final check
    systemctl is-active cloudflared &> /dev/null || { log_error "Failed to start"; return 1; }
    
    log_success "cloudflared running"
}

setup_cloudflared() {
    log_info "=== Setting up cloudflared ==="
    
    generate_cloudflared_config
    install_cloudflared_service
    restart_cloudflared
    
    log_success "=== cloudflared setup complete ==="
}
