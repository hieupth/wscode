# code-server hardening overrides v0.2

[Service]
# Basic hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=%h

# SUID/SGID restrictions
RestrictSUIDSGID=true

# Kernel protections
LockPersonality=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectClock=true
ProtectControlGroups=true

# Namespace restrictions
RestrictNamespaces=true

# Network restrictions
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Process visibility
ProtectProc=invisible
ProcSubset=pid

# Resource limits
MemoryMax=2G
CPUQuota=200%
TasksMax=512

# Additional protections
ProtectHostname=true
RestrictRealtime=true
