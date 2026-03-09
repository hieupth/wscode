# cloudflared hardening overrides v0.3

[Service]
# Override Type=notify to Type=simple because cloudflared doesn't send sd_notify
Type=simple

# Basic hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadOnlyPaths=/
ReadWritePaths=/etc/cloudflared
CapabilityBoundingSet=
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectClock=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallArchitectures=native
ProtectHostname=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6
