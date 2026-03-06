#!/bin/bash
# preflight.sh v0.3 - Preflight validation checks

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

check_platform() {
    log_info "Checking platform compatibility..."
    
    [[ ! -f /etc/os-release ]] && error_exit "Cannot determine OS: /etc/os-release not found"
    
    source /etc/os-release
    
    if [[ "$ID" != "debian" ]] && [[ "$ID" != "ubuntu" ]]; then
        error_exit "Unsupported OS: $ID (requires Debian or Ubuntu)"
    fi
    
    log_success "Platform: $PRETTY_NAME"
}

check_systemd_available() {
    log_info "Checking systemd..."

    if [[ "${WSCODE_SKIP_SYSTEMD_CHECK:-0}" == "1" ]]; then
        log_warn "Skipping systemd check (WSCODE_SKIP_SYSTEMD_CHECK=1)"
        return 0
    fi

    command_exists systemctl || error_exit "systemd required but systemctl not found"
    systemctl show --property=Version --value >/dev/null 2>&1 || error_exit "systemd not functional"

    log_success "systemd available"
}

check_network() {
    log_info "Checking network connectivity..."

    if [[ "${WSCODE_SKIP_NETWORK_CHECK:-0}" == "1" ]]; then
        log_warn "Skipping network check (WSCODE_SKIP_NETWORK_CHECK=1)"
        return 0
    fi
    
    if ! command_exists curl; then
        log_warn "curl not installed, installing..."
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates
    fi
    
    if ! curl -fsSL --connect-timeout 10 https://www.cloudflare.com/cdn-cgi/trace > /dev/null 2>&1; then
        error_exit "Network check failed: Cannot reach Cloudflare"
    fi
    
    log_success "Network connectivity OK"
}

check_ports() {
    log_info "Checking port availability..."
    
    local users
    mapfile -t users < <(get_enabled_users)
    
    [[ ${#users[@]} -eq 0 ]] && { log_warn "No users found"; return 0; }
    
    local issues=0
    for user in "${users[@]}"; do
        local port
        port=$(get_user_port "$user")

        if ! validate_port "$port"; then
            ((issues++))
            continue
        fi

        # Check if port is in use
        if command_exists ss && ss -lnt 2>/dev/null | grep -q ":${port} "; then
            log_warn "Port $port for user $user appears to be in use"
        fi
    done
    
    [[ $issues -gt 0 ]] && error_exit "$issues port validation error(s)"
    
    log_success "Port checks passed for ${#users[@]} user(s)"
}

check_dependencies() {
    log_info "Checking system dependencies..."
    
    local required_cmds=(bash awk grep sed mkdir chmod chown stat getent)
    local missing=0
    
    for cmd in "${required_cmds[@]}"; do
        if ! command_exists "$cmd"; then
            log_error "Required command missing: $cmd"
            ((missing++))
        fi
    done
    
    [[ $missing -gt 0 ]] && error_exit "$missing required command(s) missing"
    
    log_success "System dependencies OK"
}

check_user_list_files() {
    log_info "Checking user list files..."

    local allow_file deny_file
    allow_file=$(resolve_users_allow_file)
    deny_file=$(resolve_users_deny_file)

    if [[ ! -s "$allow_file" ]] && [[ "${WSCODE_ALLOW_PASSWD_DISCOVERY:-0}" != "1" ]]; then
        error_exit "Allowlist is required and must be non-empty: $allow_file"
    fi

    if [[ "$deny_file" == "$USERS_DENY_FILE" ]] && [[ ! -f "$deny_file" ]]; then
        log_warn "Denylist not found at $deny_file. Falling back to repository config if available."
    fi

    log_success "User list files checked"
}

run_preflight_checks() {
    log_info "=== Preflight checks ==="
    
    check_platform
    check_systemd_available
    check_dependencies
    check_network
    check_user_list_files
    load_config
    check_ports
    
    log_success "=== All preflight checks passed ==="
}
