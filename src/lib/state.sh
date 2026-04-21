#!/bin/bash
# state.sh v0.5 - State file management for user tracking.
#
# Manages the active-users state file used by reload and uninstall
# to determine which users are currently configured.
#
# State file: /etc/webcode/active-users.state
# Format: one username per line (compatible with read_list_file()).
# Written after successful install/reload, read by reload/uninstall.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# State file path
# ---------------------------------------------------------------------------

# Get the path to the active users state file.
# Output:
#   Path to state file
get_state_file_path() {
  echo "${ACTIVE_STATE_FILE}"
}

# ---------------------------------------------------------------------------
# Reading state
# ---------------------------------------------------------------------------

# Read the active users state file into an array.
# Returns empty array if the state file does not exist (first install).
# Params:
#   $1 - Name of the array variable to populate (nameref)
read_active_state() {
  local -n _state_ref="$1"

  _state_ref=()

  # No state file means no users were previously installed
  [[ -f "$ACTIVE_STATE_FILE" ]] || return 0

  # Reuse the same parser as users.allow
  read_list_file "$ACTIVE_STATE_FILE" _state_ref
}

# ---------------------------------------------------------------------------
# Writing state
# ---------------------------------------------------------------------------

# Write the active users state file atomically.
# Writes to a temp file first, then moves to the final location.
# Params:
#   $@ - List of usernames to write
write_active_state() {
  local users=("$@")

  [[ ${#users[@]} -eq 0 ]] && return 0

  local state_file="$ACTIVE_STATE_FILE"
  local tmp_file="${state_file}.tmp"

  # Write header + users
  {
    echo "# webcode state - DO NOT EDIT"
    echo "# Updated: $(date -Iseconds)"
    for user in "${users[@]}"; do
      echo "$user"
    done
  } > "$tmp_file"

  # Atomic move
  mv "$tmp_file" "$state_file"
  chmod 600 "$state_file"
  chown root:root "$state_file"

  log_info "State file updated: $state_file (${#users[@]} user(s))"
}

# ---------------------------------------------------------------------------
# State diffing
# ---------------------------------------------------------------------------

# Diff two user lists to determine add/remove/keep sets.
# Uses associative arrays for O(n) lookup.
# Params:
#   $1 - Nameref to old users array
#   $2 - Nameref to new users array
#   $3 - Nameref to output: users to add
#   $4 - Nameref to output: users to remove
#   $5 - Nameref to output: unchanged users
diff_user_lists() {
  local -n _old_ref="$1"
  local -n _new_ref="$2"
  local -n _add_ref="$3"
  local -n _remove_ref="$4"
  local -n _keep_ref="$5"

  # Build lookup sets
  local -A old_set=()
  local -A new_set=()

  for u in "${_old_ref[@]:-}"; do old_set["$u"]=1; done
  for u in "${_new_ref[@]:-}"; do new_set["$u"]=1; done

  # Users in new but not in old -> add
  for u in "${_new_ref[@]:-}"; do
    [[ -z "${old_set[$u]:-}" ]] && _add_ref+=("$u")
  done

  # Users in old but not in new -> remove
  for u in "${_old_ref[@]:-}"; do
    [[ -z "${new_set[$u]:-}" ]] && _remove_ref+=("$u")
  done

  # Users in both -> unchanged
  for u in "${_new_ref[@]:-}"; do
    [[ -n "${old_set[$u]:-}" ]] && _keep_ref+=("$u")
  done
}

# ---------------------------------------------------------------------------
# State cleanup
# ---------------------------------------------------------------------------

# Remove the state file (used by uninstall).
clean_state_file() {
  if [[ -f "$ACTIVE_STATE_FILE" ]]; then
    rm -f "$ACTIVE_STATE_FILE"
    log_info "State file removed"
  fi
}
