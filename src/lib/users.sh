#!/bin/bash
# users.sh v0.3 - User management

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

setup_user_environment() {
    local user="$1"
    
    log_info "Setting up environment for: $user"
    
    if ! user_exists "$user"; then
        log_warn "User does not exist: $user"
        return 1
    fi

    local home
    home=$(get_user_home "$user")
    [[ -d "$home" ]] || { log_warn "Home directory missing for $user"; return 1; }

    local group
    group=$(id -gn "$user")
    
    [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would setup $user"; return 0; }
    
    execute install -d -m 700 -o "$user" -g "$group" \
        "$home/.local/share/code-server/extensions" || return 1
    
    log_success "Environment ready for $user"
}

setup_all_users() {
    log_info "=== Setting up user environments ==="
    
    local users
    mapfile -t users < <(get_enabled_users)
    
    [[ ${#users[@]} -eq 0 ]] && { log_warn "No users to setup"; return 0; }
    
    log_info "Setting up ${#users[@]} user(s)"
    
    local failed=0
    for user in "${users[@]}"; do
        setup_user_environment "$user" || ((failed++))
    done
    
    [[ $failed -gt 0 ]] && { log_error "$failed user setup(s) failed"; return 1; }
    
    log_success "=== User environments ready ==="
}
