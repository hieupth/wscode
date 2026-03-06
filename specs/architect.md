# System Architecture Specs - Web Server Code

## Scope

This document defines two deployable architectures for multi-user `code-server` behind Cloudflare:

1. **Version A (Simple)**: shared host, `--auth none`, strict Linux authorization on localhost ports.
2. **Version B (High Security)**: Python control plane + Docker per user.

Both versions keep Cloudflare Tunnel + Access as external entrypoint.

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

## Version A - Simple (Shared Host + auth none + Linux Port ACL)

### Architecture

```
Browser
  -> Cloudflare Access Policy
  -> Cloudflare Tunnel (cloudflared, root)
  -> http://127.0.0.1:(20000 + uid)
  -> code-server@<user>.service (User=<user>, --auth none)
```

### Mandatory Controls

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

### Port Authorization Design

Use `nftables` (preferred) or `iptables owner` match to gate outbound loopback connections.

Policy intent:

1. `uid=0` (root) can connect to all managed IDE ports.
2. `uid=U` can connect only to `port=(20000+U)`.
3. Any non-root uid connecting to another user's managed port is rejected.
4. Apply to both IPv4 `127.0.0.1` and IPv6 `::1` if enabled.

Example `nftables` model (conceptual):

```nft
table inet wscode {
  chain output {
    type filter hook output priority 0; policy accept;

    # Root/system access for tunnel and ops checks
    meta skuid 0 ip daddr 127.0.0.1 tcp dport 20000-65535 accept

    # Per-user allow rules (generated from allowlist)
    meta skuid 1000 ip daddr 127.0.0.1 tcp dport 21000 accept
    meta skuid 1001 ip daddr 127.0.0.1 tcp dport 21001 accept

    # Block cross-user localhost access
    ip daddr 127.0.0.1 tcp dport 20000-65535 reject
  }
}
```

### Verification Requirements

1. Positive test: `sudo -u alice curl 127.0.0.1:21000` succeeds.
2. Negative test: `sudo -u alice curl 127.0.0.1:21001` fails.
3. Root test: `curl 127.0.0.1:21001` from root succeeds (for tunnel path).
4. Access test: external access still requires Cloudflare Access identity match.

### Residual Risks

1. Shared kernel remains a single trust boundary.
2. Root-level services can still access all user ports.
3. Misconfigured firewall rules can re-open cross-user access.

### Suitable Use

1. Internal teams with moderate trust between local users.
2. Small deployments needing low operational complexity.

## Version B - High Security (Python + Docker per User)

### Architecture

```
Browser
  -> Cloudflare Access
  -> Cloudflare Tunnel
  -> Python wscode-controller (state + reconciliation)
  -> user container: code-server (one container per user)
  -> isolated workspace volume per user
```

### Core Components

1. **wscode-controller (Python, systemd service)**
   - Reads desired users from allowlist/config.
   - Creates/updates/removes per-user containers.
   - Generates ingress map and local ACL policy.
   - Performs health checks and drift reconciliation.
2. **Docker runtime**
   - One container per user, fixed UID/GID mapping.
   - No shared user home between containers.
3. **Cloudflared**
   - Routes `user.domain.com` to user container endpoint.
4. **State store**
   - SQLite or file state (user -> container id -> endpoint -> last reconcile).

### Container Security Baseline

1. Run as non-root user in container (`--user <uid>:<gid>`).
2. `--cap-drop=ALL`, `--security-opt=no-new-privileges:true`.
3. Read-only rootfs (`--read-only`) plus explicit writable mounts.
4. Per-user workspace volume only (`/srv/wscode/workspaces/<user>`).
5. Resource limits (`--memory`, `--cpus`, `--pids-limit`).
6. No Docker socket mounted inside user containers.
7. Use default seccomp/AppArmor profile or stricter custom profile.
8. Prefer rootless Docker or `userns-remap` when operationally possible.

### Network Isolation Baseline

1. Containers are reachable only from localhost or private bridge endpoint.
2. Host firewall permits:
   - `cloudflared` service UID -> container service ports.
   - admin/root as required.
3. Deny direct user shell access to other users' container endpoints.
4. Optional: per-user bridge networks with explicit egress policies.

### Identity and Access

1. Cloudflare Access remains primary identity gate (OIDC/SAML).
2. Per-user hostname policy binding is mandatory.
3. Optionally keep code-server local auth as second factor (`password`) for defense in depth.

### Operational Workflow

1. Add user to allowlist.
2. Controller allocates container and workspace.
3. Controller updates tunnel ingress + ACL rules.
4. Health check passes and user endpoint becomes available.
5. On user removal, controller archives workspace and tears down runtime.

### Residual Risks

1. Container escape risk still exists (reduced, not zero).
2. Docker daemon compromise can impact all tenants.
3. Strongest isolation for untrusted tenants is still VM-per-user.

### Suitable Use

1. Teams requiring stronger tenant separation than shared host.
2. Environments expecting scale-out automation and policy enforcement.

## Decision Matrix

| Criterion | Version A | Version B |
|----------|-----------|-----------|
| Implementation speed | Fast | Medium |
| Ops complexity | Low | Medium-High |
| User isolation strength | Medium | High (relative to shared host) |
| Blast radius | Higher | Lower |
| Recommended for untrusted users | No | Yes (or VM-per-user for stricter needs) |

## Recommended Adoption Path

1. Immediate hardening: implement Version A with mandatory Linux port ACL.
2. Migration target: Version B for production multi-tenant environments.
3. If tenant trust is very low: plan VM-per-user as next step beyond Docker.

## References

- [code-server guide](https://coder.com/docs/code-server/guide)
- [code-server FAQ](https://coder.com/docs/code-server/FAQ)
- [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare Access policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)
- [Cloudflare self-hosted app protection](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- [Docker Engine security](https://docs.docker.com/engine/security/)
- [Docker rootless mode](https://docs.docker.com/engine/security/rootless/)
- [nftables wiki](https://wiki.nftables.org/)
- [`iptables-extensions` owner match](https://man7.org/linux/man-pages/man8/iptables-extensions.8.html)
