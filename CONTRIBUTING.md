# Contributing

Pull requests are welcome.

Good contributions include:

- new safe `hostctl` command groups
- better validation
- better redaction
- support for more AppData layouts
- backup verification commands
- VPN/qBittorrent checks
- Pi-hole checks
- Cloudflare tunnel diagnostics
- improved documentation

Before opening a PR, check:

1. Does the command validate every argument?
2. Can a path escape the intended directory?
3. Does the output need redaction?
4. Should the OpenCode permission be `allow`, `ask`, or `deny`?
5. Is the command specific, or does it accidentally create a root shell?
6. Does the README or runbook need an update?

Run syntax checks before committing:

```bash
bash -n scripts/install.sh
bash -n scripts/host/opencode-host-helper
bash -n scripts/host/opencode-ssh-entrypoint
bash -n scripts/host/hostctl-host-wrapper
bash -n scripts/host/opencode-container-launcher
bash -n scripts/container/hostctl
```
