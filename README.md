# webcode

Self-hosted VS Code for teams, secured by Cloudflare Tunnel.

## Architecture

### Core Design: User-to-Port Mapping

```
port = 20000 + uid
```

Each user gets a deterministic port based on their UID:

| User | UID | Port | URL |
|------|-----|------|-----|
| alice | 1000 | 21000 | alice-manjaropc.example.com |
| bob | 1001 | 21001 | bob-manjaropc.example.com |

**Benefits:**
- Deterministic - same user always gets same port
- No collision - UIDs are unique, ports are unique
- Zero config - calculated at runtime, no storage needed

### Domain Pattern

```
{username}-{machine}.{zone}
```

Per-user DNS CNAME records are created/deleted automatically via Cloudflare API.

### System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        User Browser                         │
└─────────────────────────┬───────────────────────────────────┘
                          │ HTTPS
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                   Cloudflare Edge                           │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐  │
│  │   Access    │───▶│   Tunnel    │◀───│  Zero Trust     │  │
│  │   Policy    │    │   Endpoint  │    │  Authentication │  │
│  └─────────────┘    └──────┬──────┘    └─────────────────┘  │
└────────────────────────────┼────────────────────────────────┘
                             │ Encrypted tunnel
                             ▼
┌────────────────────────────────────────────────────────────┐
│                     Target Server                          │
│  ┌─────────────────┐         ┌─────────────────────────┐   │
│  │ cloudflared     │────────▶│ code-server (localhost) │   │
│  │ systemd service │         │ :20000+ (bind 127.0.0.1)│   │
│  └─────────────────┘         └─────────────────────────┘   │
│  ┌─────────────────┐                                       │
│  │ nftables ACL    │  User isolation (own port only)       │
│  └─────────────────┘                                       │
└────────────────────────────────────────────────────────────┘
```

## Project Structure

```
webcode/
├── src/
│   ├── webcode.sh        # CLI entry point
│   ├── test.sh           # Test suite
│   ├── lib/              # All modules (OS-agnostic)
│   │   ├── common.sh     # Logging, config, OS/arch detection
│   │   ├── state.sh      # State file management, user diffing
│   │   ├── install.sh    # Binary downloads (code-server, cloudflared)
│   │   ├── preflight.sh  # Preflight checks
│   │   ├── users.sh      # User environment setup
│   │   ├── services.sh   # Systemd service management
│   │   ├── acl.sh        # nftables localhost ACL
│   │   ├── cloudflared.sh # Tunnel config + DNS route management
│   │   ├── verify.sh     # Post-install verification
│   │   └── rollback.sh   # Backup/rollback
│   ├── templates/        # Template files (no inline heredocs)
│   └── scripts/          # Docker test scripts
├── config/               # Config examples
└── specs/                # Architecture docs
```

## Supported Platforms

- **OS**: Debian, Ubuntu, Raspbian, Manjaro, Arch, EndeavourOS
- **Architecture**: amd64 (x86_64), arm64 (aarch64)

## Requirements

- Linux with systemd
- Cloudflare account with Tunnel configured
- Domain on Cloudflare
- Tunnel credentials JSON file
- Cloudflare API token (Zone:DNS:Edit permission)

## Quick Start

```bash
# 1. Configure
sudo mkdir -p /etc/webcode
sudo cp config/settings.env.example /etc/webcode/config.env
sudo cp your-tunnel-creds.json /etc/webcode/creds.json
sudo chmod 600 /etc/webcode/config.env /etc/webcode/creds.json
sudo chown root:root /etc/webcode/config.env /etc/webcode/creds.json

# 2. Add users
echo "alice" | sudo tee /etc/webcode/users.allow

# 3. Install
sudo ./src/webcode.sh install

# 4. Verify
sudo ./src/webcode.sh verify
```

## CLI Commands

```bash
sudo ./src/webcode.sh install          # Full installation
sudo ./src/webcode.sh reload           # Apply users.allow changes
sudo ./src/webcode.sh uninstall        # Remove everything
sudo ./src/webcode.sh verify           # Check installation
sudo ./src/webcode.sh install --dry-run # Preview changes
```

### Adding a new user

```bash
echo "newuser" | sudo tee -a /etc/webcode/users.allow
sudo ./src/webcode.sh reload
```

### Removing a user

```bash
# Remove from allow list, then reload
sudo sed -i '/username/d' /etc/webcode/users.allow
sudo ./src/webcode.sh reload
```

## Docker Testing

```bash
# Debian smoke test
docker build -f Dockerfile.debian -t webcode:debian .
docker run --rm -v /path/to/creds.json:/etc/webcode/creds.json:ro webcode:debian

# Manjaro smoke test
docker build -f Dockerfile.manjaro -t webcode:manjaro .
docker run --rm -v /path/to/creds.json:/etc/webcode/creds.json:ro webcode:manjaro

# Full integration test (code-server + cloudflared + curl)
CF_TUNNEL_NAME="your-tunnel" \
CF_DOMAIN_BASE="your-domain" \
CF_TUNNEL_ID="your-tunnel-id" \
CREDS_FILE="/path/to/creds.json" \
src/scripts/docker-integration-run.sh
```

## License

[Apache License 2.0](LICENSE)

Copyright &copy; 2025 [Hieu Pham](https://github.com/hieupth). All rights reserved.
