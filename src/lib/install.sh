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
# Internal helpers
# ---------------------------------------------------------------------------

# Clean up a temporary directory.
# Safe to call with an empty variable — does nothing if arg is unset or empty.
# Params:
#   $1 - Temp directory path (may be empty)
_cleanup_tmp_dir() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"
}

# Exit with error, cleaning up temp directory first.
# Params:
#   $1 - Temp directory to clean (empty = skip)
#   $2 - Error message
_install_error_exit() {
  local tmp="${1:-}"
  local msg="$2"
  _cleanup_tmp_dir "$tmp"
  error_exit "$msg"
}

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
  CURRENT_STAGE="install_basic_deps"
  install_basic_deps

  # Step 2: Install code-server IDE
  # Downloaded as a tarball from GitHub releases, extracted to /usr/local/lib/code-server
  CURRENT_STAGE="install_code_server"
  install_code_server

  # Step 3: Install cloudflared tunnel client
  # Downloaded as a single binary from GitHub releases to /usr/local/bin
  CURRENT_STAGE="install_cloudflared"
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

  # Detect distro family for logging (debian or arch)
  local family
  family=$(detect_distro_family)
  log_info "Detected distro family: $family"

  # Update the package index first to ensure we have latest metadata
  log_info "Updating package index..."
  execute pkg_update_index
  log_info "Package index updated"

  # Get the list of required packages for this distro
  local -a packages=()
  mapfile -t packages < <(get_required_packages)
  log_info "Required packages (${#packages[@]}): ${packages[*]}"

  # Install each missing package
  local already_installed=0
  local newly_installed=0
  for pkg in "${packages[@]}"; do
    if pkg_is_installed "$pkg"; then
      log_info "$pkg already installed, skipping"
      already_installed=$((already_installed + 1))
    else
      log_info "Installing $pkg..."
      pkg_install "$pkg"
      newly_installed=$((newly_installed + 1))
    fi
  done

  log_success "Basic dependencies installed (${newly_installed} new, ${already_installed} already present)"
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

  # Check if code-server is already installed AND functional
  if [[ -x /usr/local/lib/code-server/bin/code-server ]] && /usr/local/lib/code-server/bin/code-server --version &>/dev/null; then
    local version
    version=$(/usr/local/lib/code-server/bin/code-server --version 2>&1 | head -1 | awk '{print $1}')
    log_info "code-server already installed: $version"

    local bin_path
    bin_path=$(detect_codeserver_binary)
    log_info "code-server binary: $bin_path"

    # Check minimum version requirement
    if version_compare "$version" "lt" "$MIN_CODESERVER_VERSION"; then
      log_warn "code-server $version < $MIN_CODESERVER_VERSION (minimum recommended)"
    fi
    return 0
  fi

  # Binary exists but broken — clean up before reinstalling
  if [[ -d /usr/local/lib/code-server ]] || [[ -L /usr/local/bin/code-server ]]; then
    log_warn "code-server installation exists but is not functional, reinstalling"
    rm -rf /usr/local/lib/code-server
    rm -f /usr/local/bin/code-server
  fi

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install code-server"; return 0; }

  # Detect architecture for the correct download URL
  local arch
  arch=$(detect_arch)
  log_info "Detected architecture: $(uname -m) -> $arch"

  # Create a secure temporary directory for the download
  local tmp_dir
  tmp_dir=$(mktemp -d "/tmp/code-server-install-XXXXXX")
  log_info "Temp directory: $tmp_dir"

  # Resolve the latest code-server version via GitHub API
  # Asset naming convention: code-server-{VERSION}-linux-{ARCH}.tar.gz
  log_info "Resolving latest code-server version via GitHub API..."
  local latest_version
  latest_version=$(curl -fsSL "https://api.github.com/repos/coder/code-server/releases/latest" \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"v?([^"]+)".*/\1/') \
    || _install_error_exit "$tmp_dir" "Failed to resolve latest code-server version (check network or GitHub API rate limit)"
  [[ -n "$latest_version" ]] || _install_error_exit "$tmp_dir" "Failed to parse code-server version from GitHub API response"
  log_info "Latest code-server version: $latest_version"

  # Download the latest release tarball from GitHub
  # URL format: code-server-{VERSION}-linux-{ARCH}.tar.gz
  local download_url="https://github.com/coder/code-server/releases/download/v${latest_version}/code-server-${latest_version}-linux-${arch}.tar.gz"
  log_info "Downloading: $download_url"
  curl -fsSL -o "${tmp_dir}/code-server.tar.gz" "$download_url" \
    || _install_error_exit "$tmp_dir" "Failed to download code-server from $download_url (HTTP error or network issue)"

  local file_size
  file_size=$(stat -c %s "${tmp_dir}/code-server.tar.gz" 2>/dev/null || echo "unknown")
  log_info "Downloaded code-server tarball (${file_size} bytes)"

  # Extract the tarball
  log_info "Extracting code-server archive..."
  tar -xzf "${tmp_dir}/code-server.tar.gz" -C "$tmp_dir" \
    || _install_error_exit "$tmp_dir" "Failed to extract code-server archive (download may be corrupt)"

  # Find the extracted directory (named code-server-{VERSION}-linux-{ARCH}/)
  # Use -mindepth 1 to skip the tmp_dir itself (whose name also matches code-server-*)
  local extracted_dir
  extracted_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -name "code-server-*" | head -1)
  [[ -n "$extracted_dir" ]] || _install_error_exit "$tmp_dir" "Failed to find extracted code-server directory in $tmp_dir"
  log_info "Extracted directory: $extracted_dir"
  log_info "Contents: $(ls "$extracted_dir")"

  # Verify the binary exists in the extracted archive before installing
  if [[ ! -x "${extracted_dir}/bin/code-server" ]]; then
    log_info "bin/ contents: $(ls "${extracted_dir}/bin/" 2>/dev/null || echo 'bin/ not found')"
    _install_error_exit "$tmp_dir" "code-server binary not found in archive at ${extracted_dir}/bin/code-server"
  fi

  # Ensure target directories exist
  mkdir -p /usr/local/lib
  mkdir -p /usr/local/bin

  # Install: copy to /usr/local/lib and create symlink in /usr/local/bin
  log_info "Installing code-server to /usr/local/lib/code-server"
  cp -r "${extracted_dir}" /usr/local/lib/code-server
  log_info "Installed contents: $(ls /usr/local/lib/code-server/)"
  log_info "bin/ contents: $(ls -la /usr/local/lib/code-server/bin/)"
  ln -sf /usr/local/lib/code-server/bin/code-server /usr/local/bin/code-server
  log_info "Symlink created: /usr/local/bin/code-server -> /usr/local/lib/code-server/bin/code-server"

  # Verify installation: check files directly (not PATH-dependent)
  if [[ ! -x /usr/local/lib/code-server/bin/code-server ]]; then
    _install_error_exit "$tmp_dir" "code-server binary not found or not executable at /usr/local/lib/code-server/bin/code-server"
  fi
  if [[ ! -L /usr/local/bin/code-server ]]; then
    _install_error_exit "$tmp_dir" "Symlink not created at /usr/local/bin/code-server"
  fi

  local version
  version=$(/usr/local/bin/code-server --version 2>&1 | head -1)
  log_info "code-server --version output: $version"
  version=$(echo "$version" | awk '{print $1}')
  log_success "code-server installed: $version"

  # Warn if /usr/local/bin is not in PATH
  if ! command_exists code-server; then
    log_warn "/usr/local/bin is not in PATH — code-server installed but may not be accessible from all shells"
    log_warn "Current PATH: $PATH"
  fi

  # Clean up temporary files
  _cleanup_tmp_dir "$tmp_dir"
}

# ---------------------------------------------------------------------------
# cloudflared installation
#
# Downloads the latest release binary from GitHub directly to
# /usr/local/bin/cloudflared. This is a single static binary,
# no package manager needed.
# ---------------------------------------------------------------------------

# Install cloudflared from GitHub releases.
# If already installed and functional, reports the current version.
install_cloudflared() {
  log_info "Installing cloudflared..."

  # Check if cloudflared is already installed AND functional
  if [[ -x /usr/local/bin/cloudflared ]] && /usr/local/bin/cloudflared --version &>/dev/null; then
    local version
    version=$(/usr/local/bin/cloudflared --version 2>&1 | head -1 | awk '{print $3}' || echo "unknown")
    log_info "cloudflared already installed: $version"
    return 0
  fi

  # Binary exists but broken — remove before reinstalling
  if [[ -f /usr/local/bin/cloudflared ]]; then
    log_warn "cloudflared binary exists but is not functional, reinstalling"
    rm -f /usr/local/bin/cloudflared
  fi

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would install cloudflared"; return 0; }

  # Detect architecture for the correct download URL
  local arch
  arch=$(detect_arch)
  log_info "Detected architecture: $(uname -m) -> $arch"

  # Ensure /usr/local/bin exists BEFORE download
  mkdir -p /usr/local/bin

  # Download the latest binary to temp file first, then move atomically
  # This prevents partial downloads from corrupting the installed binary
  local download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  log_info "Downloading: $download_url"
  local tmp_file
  tmp_file=$(mktemp "/tmp/cloudflared-install-XXXXXX")
  curl -fsSL -o "$tmp_file" "$download_url" \
    || { rm -f "$tmp_file"; error_exit "Failed to download cloudflared from $download_url (HTTP error or network issue)"; }

  local file_size
  file_size=$(stat -c %s "$tmp_file" 2>/dev/null || echo "unknown")
  log_info "Downloaded cloudflared binary (${file_size} bytes)"

  # Move to final location and make executable
  mv "$tmp_file" /usr/local/bin/cloudflared
  chmod 755 /usr/local/bin/cloudflared
  log_info "Set cloudflared permissions: 755"

  # Verify installation: check file directly (not PATH-dependent)
  if [[ ! -x /usr/local/bin/cloudflared ]]; then
    error_exit "cloudflared binary not found or not executable at /usr/local/bin/cloudflared"
  fi

  local version
  version=$(/usr/local/bin/cloudflared --version 2>&1 | head -1)
  log_info "cloudflared --version output: $version"
  version=$(echo "$version" | awk '{print $3}')
  log_success "cloudflared installed: $version"

  # Warn if /usr/local/bin is not in PATH
  if ! command_exists cloudflared; then
    log_warn "/usr/local/bin is not in PATH — cloudflared installed but may not be accessible from all shells"
    log_warn "Current PATH: $PATH"
  fi
}
