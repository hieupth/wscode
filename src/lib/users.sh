#!/bin/bash
# users.sh v0.4 - User environment setup.
#
# Creates the directory structure needed by code-server for each user.
# Specifically, creates the extensions directory under each user's
# home directory with proper ownership and permissions.
#
# This module is OS-agnostic — it only uses standard Linux utilities
# (mkdir, chmod, chown, getent) that are available everywhere.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# Single user setup
# ---------------------------------------------------------------------------

# Set up the code-server environment for a single user.
# Creates ~/.local/share/code-server/extensions with mode 700,
# owned by the user. This directory is where code-server stores
# installed extensions.
# Params:
#   $1 - Username to set up
# Returns:
#   0 on success, 1 on failure (user doesn't exist, home missing)
setup_user_environment() {
  local user="$1"

  log_info "Setting up environment for: $user"

  # Verify the user exists on the system
  if ! user_exists "$user"; then
    log_warn "User does not exist: $user"
    return 1
  fi

  # Get the user's home directory
  local home
  home=$(get_user_home "$user")
  [[ -d "$home" ]] || { log_warn "Home directory missing for $user"; return 1; }
  log_info "Home directory: $home"

  # Get the user's primary group for ownership
  local group
  group=$(id -gn "$user")
  log_info "User group: $group"

  # In dry-run mode, just log what would be done
  [[ $DRY_RUN -eq 1 ]] && { log_info "[DRY-RUN] Would setup $user"; return 0; }

  # Create the extensions directory with secure permissions
  # Mode 700 ensures only the user can access their extensions
  local cs_dir="$home/.local/share/code-server"
  local ext_dir="$cs_dir/extensions"
  log_info "Creating extensions directory: $ext_dir"
  execute mkdir -p "$ext_dir"
  execute chown -R "$user:$group" "$cs_dir"
  execute chmod 700 "$ext_dir"

  log_success "Environment ready for $user"
}

# ---------------------------------------------------------------------------
# All users setup
# ---------------------------------------------------------------------------

# Set up code-server environments for all enabled users.
# Iterates through the enabled user list and sets up each one,
# tracking failures to report at the end.
setup_all_users() {
  log_info "=== Setting up user environments ==="

  local users
  mapfile -t users < <(get_enabled_users)

  # No users to set up
  [[ ${#users[@]} -eq 0 ]] && { log_warn "No users to setup"; return 0; }

  log_info "Setting up ${#users[@]} user(s)"

  # Set up each user, counting failures
  local failed=0
  for user in "${users[@]}"; do
    setup_user_environment "$user" || ((failed++))
  done

  # Report failures
  [[ $failed -gt 0 ]] && { log_error "$failed user setup(s) failed"; return 1; }

  log_success "=== User environments ready ==="
}
