#!/bin/bash
# verify.sh v0.3 - Enhanced verification

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

verify_code_server_endpoints() {
    log_info "Verifying code-server endpoints..."
    
    local users
    mapfile -t users < <(get_enabled_users)
    
    [[ ${#users[@]} -eq 0 ]] && { log_warn "No users to verify"; return 0; }
    
    local failed=0
    
    for user in "${users[@]}"; do
        local port
        port=$(get_user_port "$user")
        
        # Try healthz endpoint first (if exists)
        if curl -f -s -o /dev/null --connect-timeout 5 "http://127.0.0.1:${port}/healthz" 2>/dev/null; then
            log_success "✓ $user (port $port) - healthz OK"
        # Fallback to basic HTTP check
        elif curl -f -s -o /dev/null --connect-timeout 5 "http://127.0.0.1:${port}" 2>/dev/null || \
             curl -I -s --connect-timeout 5 "http://127.0.0.1:${port}" 2>/dev/null | grep -q "HTTP"; then
            log_success "✓ $user (port $port) - HTTP OK"
        else
            log_error "✗ $user (port $port) - Not responding"
            ((failed++))
        fi
    done
    
    [[ $failed -gt 0 ]] && { log_error "$failed endpoint(s) failed"; return 1; }
    
    log_success "All endpoints verified"
}

verify_systemd_services() {
    log_info "Verifying systemd services..."
    
    local failed=0
    
    # Check cloudflared
    if systemctl is-active cloudflared &> /dev/null; then
        log_success "✓ cloudflared active"
    else
        log_error "✗ cloudflared not active"
        systemctl status cloudflared --no-pager || true
        ((failed++))
    fi
    
    # Check code-server instances
    local users
    mapfile -t users < <(get_enabled_users)
    
    for user in "${users[@]}"; do
        local service="code-server@${user}.service"
        
        if systemctl is-active "$service" &> /dev/null; then
            log_success "✓ $service active"
        else
            log_error "✗ $service not active"
            systemctl status "$service" --no-pager || true
            ((failed++))
        fi
    done
    
    [[ $failed -gt 0 ]] && { log_error "$failed service(s) failed"; return 1; }
    
    log_success "All services verified"
}

verify_cloudflared_config() {
    log_info "Verifying cloudflared configuration..."
    
    local config_file="/etc/cloudflared/config.yml"
    
    [[ ! -f "$config_file" ]] && { log_error "Config missing: $config_file"; return 1; }
    
    local perms
    perms=$(stat -c %a "$config_file")
    [[ "$perms" != "600" ]] && log_warn "Config perms: $perms (expected 600)"

    local owner
    owner=$(stat -c %U:%G "$config_file")
    [[ "$owner" != "root:root" ]] && log_warn "Config owner: $owner (expected root:root)"

    grep -q "^tunnel:" "$config_file" || { log_error "Missing tunnel definition"; return 1; }
    grep -q "^ingress:" "$config_file" || { log_error "Missing ingress rules"; return 1; }
    
    log_success "cloudflared config verified"
}

verify_user_mapping_consistency() {
    log_info "Verifying user-to-port and user-to-hostname mappings..."

    local users
    mapfile -t users < <(get_enabled_users)

    [[ ${#users[@]} -eq 0 ]] && { log_warn "No users to validate mapping"; return 0; }

    local -A seen_ports=()
    local -A seen_hosts=()

    for user in "${users[@]}"; do
        local port host
        port=$(get_user_port "$user")
        host="${user}.${CF_DOMAIN_BASE}"

        if [[ -n "${seen_ports[$port]:-}" ]]; then
            log_error "Duplicate port mapping: $port for $user and ${seen_ports[$port]}"
            return 1
        fi
        seen_ports[$port]="$user"

        if [[ -n "${seen_hosts[$host]:-}" ]]; then
            log_error "Duplicate hostname mapping: $host"
            return 1
        fi
        seen_hosts[$host]="$user"
    done

    log_success "User mappings are consistent"
}

verify_secrets_permissions() {
    log_info "Verifying secrets permissions..."
    
    [[ -d "/etc/cloudflared" ]] || return 0
    
    local perms=$(stat -c %a /etc/cloudflared)
    [[ "$perms" == "700" ]] || log_warn "/etc/cloudflared perms: $perms (expected 700)"
    
    local owner=$(stat -c %U:%G /etc/cloudflared)
    [[ "$owner" == "root:root" ]] || log_warn "/etc/cloudflared owner: $owner (expected root:root)"
    
    log_success "Secrets permissions verified"
}

verify_local_acl() {
    log_info "Verifying localhost ACL..."

    if ! command_exists nft; then
        log_error "nft command not available"
        return 1
    fi

    if ! systemctl is-active wscode-acl.service &> /dev/null; then
        log_error "wscode-acl.service not active"
        systemctl status wscode-acl.service --no-pager || true
        return 1
    fi

    if ! nft list table inet wscode >/dev/null 2>&1; then
        log_error "nft table inet wscode not found"
        return 1
    fi

    log_success "Localhost ACL verified"
}

run_verification() {
    log_info "=== Running verification ==="
    
    local failed=0
    
    load_config
    verify_cloudflared_config || ((failed++))
    verify_user_mapping_consistency || ((failed++))
    verify_systemd_services || ((failed++))
    verify_code_server_endpoints || ((failed++))
    verify_secrets_permissions || ((failed++))
    verify_local_acl || ((failed++))
    
    [[ $failed -gt 0 ]] && { log_error "=== Verification: $failed failure(s) ==="; return 1; }
    
    log_success "=== All verification passed ==="
}
