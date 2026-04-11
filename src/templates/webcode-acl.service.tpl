# webcode-acl.service.tpl - Systemd service for applying localhost ACL on boot
#
# This is a oneshot service that loads the nftables rules from the
# ACL file. It runs after network is online to ensure nftables is ready.
#
# Template variables:
#   {{NFT_BIN}}  - Path to the nft binary (e.g., /usr/sbin/nft)
#   {{ACL_FILE}} - Path to the nftables rules file (e.g., /etc/webcode/acl.nft)

[Unit]
Description=Apply webcode localhost ACL
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Remove any existing table first (clean slate on each boot)
ExecStartPre=-{{NFT_BIN}} delete table inet webcode
# Load the ACL rules
ExecStart={{NFT_BIN}} -f {{ACL_FILE}}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
