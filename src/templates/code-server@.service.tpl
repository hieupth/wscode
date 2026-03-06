# code-server systemd template v0.2
# This template is used when deb package template is not available

[Unit]
Description=code-server for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=%i

# Pre-flight validation
ExecStartPre=/bin/bash -c 'id %i > /dev/null || exit 1'
ExecStartPre=/bin/bash -c 'uid=$(id -u %i); [ $((20000 + uid)) -le 65535 ] || exit 1'
ExecStartPre=/bin/bash -c 'home=$(getent passwd %i | cut -d: -f6); [ -n "$home" ] || exit 1; mkdir -p "$home/.local/share/code-server/extensions"'

# Start code-server with dynamic port
# {{CODESERVER_BIN}} will be substituted with actual binary path
ExecStart=/bin/bash -c 'home=$(getent passwd %i | cut -d: -f6); uid=$(id -u %i); port=$((20000 + uid)); exec {{CODESERVER_BIN}} --bind-addr 127.0.0.1:${port} --auth none --user-data-dir "$home/.local/share/code-server" --extensions-dir "$home/.local/share/code-server/extensions"'

# Restart policy
Restart=on-failure
RestartSec=10
StartLimitInterval=350
StartLimitBurst=10

[Install]
WantedBy=multi-user.target
