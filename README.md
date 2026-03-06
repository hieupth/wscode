# Web Server Code

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

### Deployment Modes

- **Simple (default)**: shared host + `--auth none` + Cloudflare Access, with mandatory Linux ACL to block cross-user access to `127.0.0.1:20000+uid`.
- **High Security**: Python controller + Docker per user (isolated runtime, workspace, and network policy).

### System Overview (Simple Mode)

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
wscode/
├── src/              # All source code
│   ├── setup.sh
│   ├── test.sh
│   ├── lib/
│   ├── templates/
│   └── scripts/
├── config/           # Config examples
└── specs/            # Architecture docs
```

## Requirements

- Debian/Ubuntu with systemd
- Cloudflare account with Tunnel configured
- Domain on Cloudflare

## License

[Apache License 2.0](LICENSE)

Copyright &copy; 2025 [Hieu Pham](https://github.com/hieupth). All rights reserved.
