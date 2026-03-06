#!/bin/bash
# install.sh v0.3 - Install dependencies and packages

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

install_basic_deps() {
    log_info "Installing basic dependencies..."
    
    execute apt-get update -qq
    
    local packages=(curl ca-certificates bash jq gawk iproute2 gnupg lsb-release wget nftables)
    for pkg in "${packages[@]}"; do
        if ! dpkg -l 2>/dev/null | grep -q "^ii  $pkg "; then
            log_info "Installing $pkg..."
            execute apt-get install -y -qq "$pkg"
        else
            log_debug "$pkg already installed"
        fi
    done
    
    log_success "Basic dependencies installed"
}

install_code_server() {
    log_info "Installing code-server..."
    
    # Check if already installed
    if command_exists code-server; then
        local version
        version=$(code-server --version 2>&1 | head -1 | awk '{print $1}')
        log_info "code-server already installed: $version"
        
        # Verify binary path
        local bin_path
        bin_path=$(detect_codeserver_binary)
        log_info "code-server binary: $bin_path"
        
        # Check version compatibility
        if version_compare "$version" "lt" "$MIN_CODESERVER_VERSION"; then
            log_warn "code-server $version < $MIN_CODESERVER_VERSION (minimum)"
            log_warn "Upgrade recommended but will proceed with current version"
        fi
        
        return 0
    fi
    
    [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install code-server"; return 0; }
    
    log_info "Downloading and installing code-server..."
    
    # Download and run official install script
    local install_script="/tmp/code-server-install-${TIMESTAMP}.sh"
    curl -fsSL https://code-server.dev/install.sh -o "$install_script"
    
    # Run installer with standalone method (most reliable)
    bash "$install_script" --method=standalone --prefix=/usr/local
    
    # Verify installation
    if ! command_exists code-server; then
        error_exit "code-server installation failed"
    fi
    
    local version
    version=$(code-server --version 2>&1 | head -1 | awk '{print $1}')
    log_success "code-server installed: $version"
    
    # Verify binary location
    local bin_path
    bin_path=$(detect_codeserver_binary)
    log_info "code-server binary: $bin_path"
    
    # Clean up
    rm -f "$install_script"
}

install_cloudflared() {
    log_info "Installing cloudflared..."
    
    if command_exists cloudflared; then
        local version
        version=$(cloudflared --version 2>&1 | head -1 | awk '{print $3}' || echo "unknown")
        log_info "cloudflared already installed: $version"
        return 0
    fi
    
    [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install cloudflared"; return 0; }
    
    log_info "Adding Cloudflare repository..."
    
    # Add GPG key
    mkdir -p /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/cloudflare-main.gpg ]]; then
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /etc/apt/keyrings/cloudflare-main.gpg
    fi
    
    # Add repository
    if [[ ! -f /etc/apt/sources.list.d/cloudflared.list ]]; then
        echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | \
            tee /etc/apt/sources.list.d/cloudflared.list
    fi
    
    # Update and install
    apt-get update -qq
    apt-get install -y -qq cloudflared
    
    # Verify installation
    if ! command_exists cloudflared; then
        error_exit "cloudflared installation failed"
    fi
    
    local version
    version=$(cloudflared --version 2>&1 | head -1 | awk '{print $3}')
    log_success "cloudflared installed: $version"
}

install_all() {
    log_info "=== Starting installation ==="
    
    install_basic_deps
    install_code_server
    install_cloudflared
    
    log_success "=== Installation completed ==="
}
