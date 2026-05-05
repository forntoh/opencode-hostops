# Security Notes

This project gives a container a controlled path to run selected host operations.

It improves safety compared to mounting `/var/run/docker.sock` directly into the container, but it is not a perfect sandbox. The security boundary is the allowlist in:

```text
/usr/local/sbin/opencode-host-helper
```

## Main protections

- OpenCode runs in a normal container, not privileged.
- The container does not mount `/var/run/docker.sock`.
- The container does not get raw host filesystem access.
- The container uses SSH only with a forced command.
- The SSH key cannot open an interactive shell.
- The restricted SSH user can only sudo the helper.
- The helper validates container names, app names, unit names, cron names, and app paths.
- Sensitive-looking files are refused by `hostctl app read`.
- Logs, inspect output, and Compose output are passed through basic redaction.

## Known limitations

- Redaction is best-effort only.
- Docker start/stop/restart is still powerful.
- Compose `config` output may still reveal non-standard secrets.
- If you add unsafe helper commands, you can accidentally give OpenCode broad root access.
- `hostctl app compose-all` can print lots of config. Review before sharing output.

## Recommended practice

- Keep write actions as `ask` in `config/opencode.json`.
- Add new commands one by one.
- Prefer specific actions over generic shell access.
- Never add a command that runs arbitrary user-provided shell strings.
- Keep OpenCode web UI behind LAN, VPN, Tailscale, or another private access method.
- Do not expose the OpenCode web UI directly to the internet.
