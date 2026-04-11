# webcode

> **Source of truth**: [README.md](README.md)

This file is for Claude Code context. For project documentation, see README.md.

## Quick Reference

- **Config**: `/etc/webcode/config.env`
- **Install**: `sudo ./src/setup.sh`
- **Verify**: `sudo ./src/setup.sh --verify-only`
- **Dry-run**: `sudo ./src/setup.sh --dry-run`

## Project Structure

```
webcode/
├── src/
│   ├── setup.sh          # Entry point
│   ├── test.sh           # Test suite
│   ├── lib/              # All modules
│   │   ├── common.sh     # Logging, config, OS/arch detection, pkg helpers, template rendering
│   │   ├── install.sh    # Binary downloads (code-server, cloudflared) + pkg management
│   │   ├── preflight.sh  # Preflight checks
│   │   ├── users.sh      # User environment setup
│   │   ├── services.sh   # Systemd service management
│   │   ├── acl.sh        # nftables localhost ACL
│   │   ├── cloudflared.sh # Cloudflared config + service
│   │   ├── verify.sh     # Post-install verification
│   │   └── rollback.sh   # Backup/rollback
│   ├── templates/        # All template files (no inline heredocs)
│   └── scripts/          # Docker test scripts
├── config/               # Config examples
├── deprecated/           # Old bash scripts (to remove)
└── specs/                # Architecture docs
```

## Supported Platforms

- **OS**: Debian, Ubuntu, Raspbian, Manjaro, Arch, EndeavourOS
- **Arch**: amd64 (x86_64), arm64 (aarch64)

## Coding Conventions

- **Indent**: 2 spaces (no tabs)
- **Comments**: Detailed — every function documented
- **No inline heredocs**: All generated content in template files under `src/templates/`
- **Template variables**: `{{VAR_NAME}}` format, rendered by `render_template()`
