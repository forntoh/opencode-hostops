# Customization Guide

The main file to customize is:

```text
scripts/host/opencode-host-helper
```

After installation, the live copy is:

```text
/usr/local/sbin/opencode-host-helper
```

## Adding a new command group

Add a function:

```bash
backup_cmd() {
  local action="${1:-}"
  shift || true

  case "$action" in
    status)
      # safe read-only command here
      ;;
    *)
      echo "Usage: backup status"
      exit 1
      ;;
  esac
}
```

Then register it in `dispatch()`:

```bash
backup) backup_cmd "$@" ;;
```

Then add matching OpenCode permissions in `config/opencode.json`:

```json
"hostctl backup status": "allow"
```

And add it to `workspace/SERVER-RUNBOOK.md` so OpenCode knows how to use it.

## Rules for safe commands

Validate all user-controlled arguments.

Good:

```bash
[[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid name"
```

Avoid arbitrary shell evaluation:

```bash
# Bad
bash -c "$user_input"
```

Avoid arbitrary paths unless you verify they stay inside the allowed root:

```bash
target="$(realpath -m "$base/$rel")"
[[ "$target" == "$base" || "$target" == "$base/"* ]] || die "Path escapes base"
```

## Approval levels

Use the OpenCode config to decide what should be automatic and what should ask.

Usually safe to allow:

- listing containers
- listing app folders
- health summaries
- failed services
- disk usage

Should ask:

- logs
- inspect output
- restart/stop/start
- Compose config
- reading files
- cron create/update/delete

Should usually be denied:

- raw `docker run`
- raw `sudo`
- arbitrary file deletion
- arbitrary chmod/chown
- editing `/etc/*`
- mounting host root into a container
