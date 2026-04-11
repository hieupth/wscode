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
| alice | 1000 | 21000 | alice.domain.com |
| bob | 1001 | 21001 | bob.domain.com |
| charlie | 1002 | 21002 | charlie.domain.com |

**Benefits:**
- Deterministic - same user always gets same port
- No collision - UIDs are unique, ports are unique
- Zero config - calculated at runtime, no storage needed

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
└────────────────────────────────────────────────────────────┘
```

## Project Structure

```
webcode/
├── src/
│   ├── setup.sh          # Entry point
│   ├── test.sh           # Test suite
│   ├── lib/              # All modules (OS-agnostic)
│   ├── templates/        # Template files (no inline heredocs)
│   └── scripts/          # Docker test scripts
├── config/               # Config examples
├── deprecated/           # Old bash scripts (to remove)
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
sudo ./src/setup.sh

# 4. Verify
sudo ./src/setup.sh --verify-only
```

## Docker Testing

```bash
# Debian test
docker build -f Dockerfile.debian -t webcode:debian .
docker run --rm -v /path/to/creds.json:/etc/webcode/creds.json:ro webcode:debian

# Manjaro test
docker build -f Dockerfile.manjaro -t webcode:manjaro .
docker run --rm -v /path/to/creds.json:/etc/webcode/creds.json:ro webcode:manjaro
```

## License

[Apache License 2.0](LICENSE)

Copyright &copy; 2025 [Hieu Pham](https://github.com/hieupth). All rights reserved.
