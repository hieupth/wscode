# webcode

> **Source of truth**: [README.md](README.md)

This file is for Claude Code context. For project documentation, see README.md.

## Quick Reference

- **Config**: `/etc/webcode/config.env`
- **Install**: `sudo ./src/webcode.sh install`
- **Reload**: `sudo ./src/webcode.sh reload` (after editing users.allow)
- **Uninstall**: `sudo ./src/webcode.sh uninstall`
- **Verify**: `sudo ./src/webcode.sh verify`
- **Dry-run**: append `--dry-run` to any command

## Project Structure

```
webcode/
├── src/
│   ├── webcode.sh        # CLI entry point (install, reload, uninstall)
│   ├── test.sh           # Test suite
│   ├── lib/              # All modules
│   │   ├── common.sh     # Logging, config, OS/arch detection, pkg helpers, template rendering
│   │   ├── state.sh      # State file management (active-users tracking, diff)
│   │   ├── install.sh    # Binary downloads (code-server, cloudflared) + pkg management
│   │   ├── preflight.sh  # Preflight checks
│   │   ├── users.sh      # User environment setup
│   │   ├── services.sh   # Systemd service management (enable/disable per user)
│   │   ├── acl.sh        # nftables localhost ACL
│   │   ├── cloudflared.sh # Cloudflared config + DNS route management + service
│   │   ├── verify.sh     # Post-install verification
│   │   └── rollback.sh   # Backup/rollback (includes DNS cleanup)
│   ├── templates/        # All template files (no inline heredocs)
│   └── scripts/          # Docker test scripts
├── config/               # Config examples
└── specs/                # Architecture docs
```

## Supported Platforms

- **OS**: Debian, Ubuntu, Raspbian, Manjaro, Arch, EndeavourOS
- **Arch**: amd64 (x86_64), arm64 (aarch64)

## Domain Pattern

- **Format**: `{user}-{machine}.{zone}` (e.g., `alice-manjaropc.example.com`)
- **DNS**: Per-user CNAME records created/deleted via Cloudflare API
- **Username restriction**: No hyphens allowed (rejected by `is_valid_username()`)

## Coding Conventions

- **Indent**: 2 spaces (no tabs)
- **Comments**: Detailed — every function documented
- **No inline heredocs**: All generated content in template files under `src/templates/`
- **Template variables**: `{{VAR_NAME}}` format, rendered by `render_template()`
