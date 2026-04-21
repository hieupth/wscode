# acl.nft.tpl - nftables localhost port ACL template
#
# This template generates nftables rules that enforce user isolation
# on localhost. Each user can only connect to their own code-server port.
#
# Template variables:
#   CLOUDFLARED_RULES - Rules for cloudflared UID (empty if running as root)
#   USER_RULES        - Per-user accept rules (generated dynamically)

table inet webcode {
  chain output {
    type filter hook output priority 0; policy accept;

    # Allow established/related connections (responses to permitted requests).
    # Without this, server response packets to client ephemeral ports in the
    # 20000-65535 range would be rejected by the default deny rule below.
    ct state established,related accept

    # Root always needs local access for operations and health checks.
    # This includes cloudflared tunnel routing and system monitoring.
    meta skuid 0 ip daddr 127.0.0.1 tcp dport 20000-65535 accept
    meta skuid 0 ip6 daddr ::1 tcp dport 20000-65535 accept

    # Cloudflared tunnel needs access to all user ports for routing.
    # Only present when cloudflared runs as a dedicated system user.
{{CLOUDFLARED_RULES}}
    # Per-user rules: each user can only connect to their own port.
    # Port = 20000 + UID (e.g., UID 1000 -> port 21000)
{{USER_RULES}}
    # Default deny: reject all other cross-user localhost connections
    # in the managed port range (20000-65535).
    ip daddr 127.0.0.1 tcp dport 20000-65535 reject with icmpx type admin-prohibited
    ip6 daddr ::1 tcp dport 20000-65535 reject with icmpx type admin-prohibited
  }
}
