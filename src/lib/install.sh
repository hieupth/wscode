#!/bin/bash
# install.sh v0.4 - Install all dependencies, code-server, and cloudflared.
#
# This module handles the entire installation pipeline:
#   1. System package dependencies (via pkg_* helpers from common.sh)
#   2. code-server (binary download from GitHub releases)
#   3. cloudflared (binary download from GitHub releases)
#
# Both code-server and cloudflared are installed via binary download,
# making the process OS-agnostic. The only OS-specific part is the
# system package management (apt-get vs pacman), which is abstracted
# by the pkg_* functions in common.sh.
#
# Binary downloads support both amd64 and arm64 architectures
# via the detect_arch() function.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Main install orchestration
# ---------------------------------------------------------------------------

# Install all components in the correct order.
# 1. System packages (OS-specific via pkg_* helpers)
# 2. code-server (binary download from GitHub releases)
# 3. cloudflared (binary download from GitHub releases)
install_all() {
  log_info "=== Starting installation ==="

  # Step 1: Install system packages needed by webcode
  # This includes curl for downloads, nftables for ACL, jq for JSON parsing, etc.
  install_basic_deps

  # Step 2: Install code-server IDE
  # Downloaded as a tarball from GitHub releases, extracted to /usr/local/lib/code-server
  install_code_server

  # Step 3: Install cloudflared tunnel client
  # Downloaded as a single binary from GitHub releases to /usr/local/bin
  install_cloudflared

  log_success "=== Installation completed ==="
}

# ---------------------------------------------------------------------------
# System package dependencies
# ---------------------------------------------------------------------------

# Install required system packages using the OS package manager.
# Uses pkg_* helpers which abstract apt-get (Debian) and pacman (Arch).
# Skips packages that are already installed.
install_basic_deps() {
  log_info "Installing basic dependencies..."

  # Update the package index first to ensure we have latest metadata
  execute pkg_update_index

  # Get the list of required packages for this distro
  local -a packages=()
  mapfile -t packages < <(get_required_packages)

  # Install each missing package
  for pkg in "${packages[@]}"; do
    if pkg_is_installed "$pkg"; then
      log_debug "$pkg already installed"
    else
      log_info "Installing $pkg..."
      pkg_install "$pkg"
    fi
  done

  log_success "Basic dependencies installed"
}

# ---------------------------------------------------------------------------
# code-server installation
#
# Downloads the latest release from GitHub as a tarball and installs
# to /usr/local/lib/code-server with a symlink in /usr/local/bin.
#
# The tarball structure is:
#   code-server-{VERSION}-linux-{ARCH}/
#     bin/code-server
#     lib/
#     ...
# ---------------------------------------------------------------------------

# Install code-server from GitHub releases.
# If already installed, checks version and warns if below minimum.
install_code_server() {
  log_info "Installing code-server..."

  # Check if code-server is already installed
  if command_exists code-server; then
    local version
    version=$(code-server --version 2>&1 | head -1 | awk '{print $1}')
    log_info "code-server already installed: $version"

    # Verify binary is accessible
    local bin_path
    bin_path=$(detect_codeserver_binary)
    log_info "code-server binary: $bin_path"

    # Check minimum version requirement
    if version_compare "$version" "lt" "$MIN_CODESERVER_VERSION"; then
      log_warn "code-server $version < $MIN_CODESERVER_VERSION (minimum recommended)"
    fi
    return 0
  fi

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install code-server"; return 0; }

  # Detect architecture for the correct download URL
  local arch
  arch=$(detect_arch)
  log_info "Downloading code-server (${arch})..."

  # Create a secure temporary directory for the download
  local tmp_dir
  tmp_dir=$(mktemp -d "/tmp/code-server-install-XXXXXX")

  # Resolve the latest code-server version via GitHub API
  # Asset naming convention: code-server-{VERSION}-linux-{ARCH}.tar.gz
  local latest_version
  latest_version=$(curl -fsSL "https://api.github.com/repos/coder/code-server/releases/latest" \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"v?([^"]+)".*/\1/')
  [[ -n "$latest_version" ]] || error_exit "Failed to resolve latest code-server version"

  # Download the latest release tarball from GitHub
  # URL format: code-server-{VERSION}-linux-{ARCH}.tar.gz
  curl -fsSL -o "${tmp_dir}/code-server.tar.gz" \
    "https://github.com/coder/code-server/releases/download/v${latest_version}/code-server-${latest_version}-linux-${arch}.tar.gz"

  # Extract the tarball
  tar -xzf "${tmp_dir}/code-server.tar.gz" -C "$tmp_dir"

  # Find the extracted directory (named code-server-{VERSION}-linux-{ARCH}/)
  local extracted_dir
  extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "code-server-*" | head -1)
  [[ -n "$extracted_dir" ]] || error_exit "Failed to extract code-server archive"

  # Install: copy to /usr/local/lib and create symlink in /usr/local/bin
  cp -r "${extracted_dir}/" /usr/local/lib/code-server
  ln -sf /usr/local/lib/code-server/bin/code-server /usr/local/bin/code-server

  # Verify installation succeeded
  if ! command_exists code-server; then
    error_exit "code-server installation failed"
  fi

  local version
  version=$(code-server --version 2>&1 | head -1 | awk '{print $1}')
  log_success "code-server installed: $version"

  # Clean up temporary files
  rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# cloudflared installation
#
# Downloads the latest release binary from GitHub directly to
# /usr/local/bin/cloudflared. This is a single static binary,
# no package manager needed.
# ---------------------------------------------------------------------------

# Install cloudflared from GitHub releases.
# If already installed, reports the current version.
install_cloudflared() {
  log_info "Installing cloudflared..."

  # Check if cloudflared is already installed
  if command_exists cloudflared; then
    local version
    version=$(cloudflared --version 2>&1 | head -1 | awk '{print $3}' || echo "unknown")
    log_info "cloudflared already installed: $version"
    return 0
  fi

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install cloudflared"; return 0; }

  # Detect architecture for the correct download URL
  local arch
  arch=$(detect_arch)
  log_info "Downloading cloudflared (${arch})..."

  # Download the latest binary from GitHub releases
  # URL format: cloudflared-linux-{arch} (single binary, no tarball)
  curl -fsSL -o /usr/local/bin/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

  # Make the binary executable
  chmod 755 /usr/local/bin/cloudflared

  # Verify installation succeeded
  if ! command_exists cloudflared; then
    error_exit "cloudflared installation failed"
  fi

  local version
  version=$(cloudflared --version 2>&1 | head -1 | awk '{print $3}')
  log_success "cloudflared installed: $version"
}
