#!/bin/bash
# acl.sh v0.3 - Localhost port ACL for user isolation

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

readonly ACL_FILE="/etc/wscode/acl.nft"
readonly ACL_SERVICE="/etc/systemd/system/wscode-acl.service"

detect_cloudflared_uid() {
    if id cloudflared >/dev/null 2>&1; then
        id -u cloudflared
    else
        echo 0
    fi
}

generate_acl_rules() {
    local users=("$@")
    local cloudflared_uid
    cloudflared_uid=$(detect_cloudflared_uid)

    cat <<'EOF'
table inet wscode {
  chain output {
    type filter hook output priority 0; policy accept;
EOF

    # Root always needs local access for operations and health checks.
    cat <<'EOF'
    meta skuid 0 ip daddr 127.0.0.1 tcp dport 20000-65535 accept
    meta skuid 0 ip6 daddr ::1 tcp dport 20000-65535 accept
EOF

    if [[ "$cloudflared_uid" != "0" ]]; then
        echo "    meta skuid ${cloudflared_uid} ip daddr 127.0.0.1 tcp dport 20000-65535 accept"
        echo "    meta skuid ${cloudflared_uid} ip6 daddr ::1 tcp dport 20000-65535 accept"
    fi

    local user uid port
    for user in "${users[@]}"; do
        uid=$(id -u "$user")
        port=$(get_user_port "$user")
        echo "    meta skuid ${uid} ip daddr 127.0.0.1 tcp dport ${port} accept"
        echo "    meta skuid ${uid} ip6 daddr ::1 tcp dport ${port} accept"
    done

    cat <<'EOF'
    ip daddr 127.0.0.1 tcp dport 20000-65535 reject with icmpx type admin-prohibited
    ip6 daddr ::1 tcp dport 20000-65535 reject with icmpx type admin-prohibited
  }
}
EOF
}

install_acl_service_unit() {
    local nft_bin="$1"

    if [[ -f "$ACL_SERVICE" ]]; then
        backup_file "$ACL_SERVICE"
    fi

    cat > "$ACL_SERVICE" <<EOF
[Unit]
Description=Apply wscode localhost ACL
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=-${nft_bin} delete table inet wscode
ExecStart=${nft_bin} -f ${ACL_FILE}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$ACL_SERVICE"
}

setup_local_port_acl() {
    log_info "Setting up localhost ACL..."

    local users
    mapfile -t users < <(get_enabled_users)

    [[ ${#users[@]} -gt 0 ]] || error_exit "No users found for ACL generation"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[DRY-RUN] Would generate ${ACL_FILE} and wscode-acl.service"
        return 0
    fi

    local nft_bin
    nft_bin=$(command -v nft || true)
    [[ -n "$nft_bin" ]] || error_exit "nft command not found. Install nftables package."

    if [[ -f "$ACL_FILE" ]]; then
        backup_file "$ACL_FILE"
    fi

    ensure_dir /etc/wscode 0700 root:root
    generate_acl_rules "${users[@]}" > "$ACL_FILE"
    chmod 600 "$ACL_FILE"
    chown root:root "$ACL_FILE"

    install_acl_service_unit "$nft_bin"

    # Refresh rules now and persist with systemd.
    nft delete table inet wscode 2>/dev/null || true
    nft -f "$ACL_FILE"

    systemctl daemon-reload
    systemctl enable wscode-acl.service >/dev/null
    systemctl restart wscode-acl.service

    systemctl is-active wscode-acl.service >/dev/null 2>&1 || {
        log_error "wscode-acl.service is not active"
        systemctl status wscode-acl.service --no-pager || true
        return 1
    }

    log_success "Localhost ACL is active for ${#users[@]} user(s)"
}
