# System Architecture Specs - webcode

## Scope

This document defines the architecture for multi-user `code-server` behind Cloudflare.

## Architecture (Simple Mode)

```
Browser
  -> Cloudflare Access Policy
  -> Cloudflare Tunnel (cloudflared, root)
  -> http://127.0.0.1:(20000 + uid)
  -> code-server@<user>.service (User=<user>, --auth none)
```

## Supported Platforms

- **OS**: Debian, Ubuntu, Raspbian, Manjaro, Arch, EndeavourOS
- **Architecture**: amd64 (x86_64), arm64 (aarch64)

## Security Goals

1. Each user only accesses their own IDE.
2. No direct public exposure of `code-server`.
3. Secrets are root-owned and minimally readable.
4. Operational model is reproducible and verifiable.

## Threat Model Assumptions

1. Attackers may be authenticated users on the same host.
2. Cloudflare Access policy can be misconfigured by operators.
3. Local users do not have root privileges.
4. Root compromise is out-of-scope for tenant isolation and treated as full compromise.

## Mandatory Controls

1. **Per-user process identity**
   - `code-server` instance must run as `User=%i`.
   - User home and extension dirs must be `0700`.
2. **Strict user enrollment**
   - Only explicit allowlist (`users.allow`).
   - Disable implicit discovery from `/etc/passwd` in production.
3. **Cloudflare Access policy**
   - Per-hostname policy (e.g., `alice.domain.com` only `alice@company.com`).
   - Default deny, no broad `Everyone` policy.
4. **Linux localhost port authorization (critical)**
   - Enforce that UID `U` can only connect to TCP port `20000 + U`.
   - Allow root/system UIDs required for `cloudflared` and health checks.
   - Deny all other UID-to-port combinations for loopback destinations.

## Port Authorization Design

Use `nftables` to gate outbound loopback connections.

Policy intent:

1. `uid=0` (root) can connect to all managed IDE ports.
2. `uid=U` can connect only to `port=(20000+U)`.
3. Any non-root uid connecting to another user's managed port is rejected.
4. Apply to both IPv4 `127.0.0.1` and IPv6 `::1`.

## Component Installation

All components are installed via binary download from GitHub releases:

| Component | Source | Path |
|---|---|---|
| code-server | `github.com/coder/code-server/releases` | `/usr/local/lib/code-server/` |
| cloudflared | `github.com/cloudflare/cloudflared/releases` | `/usr/local/bin/cloudflared` |

System packages (curl, nftables, jq, etc.) are installed via the OS package manager:
- Debian/Ubuntu: `apt-get`
- Manjaro/Arch: `pacman`

## Authentication

Cloudflared tunnel authentication uses credentials JSON file only.
Token-based authentication is not supported.

Config (`/etc/webcode/config.env`):
- `CF_TUNNEL_NAME` - Tunnel name
- `CF_DOMAIN_BASE` - Base domain
- `CF_CREDENTIALS_FILE` - Path to credentials JSON

## Verification Requirements

1. Positive test: `sudo -u alice curl 127.0.0.1:21000` succeeds.
2. Negative test: `sudo -u alice curl 127.0.0.1:21001` fails.
3. Root test: `curl 127.0.0.1:21001` from root succeeds (for tunnel path).
4. Access test: external access still requires Cloudflare Access identity match.

## Residual Risks

1. Shared kernel remains a single trust boundary.
2. Root-level services can still access all user ports.
3. Misconfigured firewall rules can re-open cross-user access.

## References

- [code-server guide](https://coder.com/docs/code-server/guide)
- [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare Access policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)
- [nftables wiki](https://wiki.nftables.org/)
