# HomeLab Host Operations Runbook

You are managing a home server from inside a container.

Use `hostctl` for all server operations.

Do not use raw `ssh`, `sudo`, `docker`, `docker compose`, `rm`, `chmod`, `chown`, or direct host filesystem writes.

## Manual escalation protocol

If a task cannot be completed through `hostctl`, do not try to bypass the restriction.

Instead, reply with:

1. What you need to do.
2. Why `hostctl` cannot do it.
3. The exact command the user should run on the host.
4. What output the user should paste back.

Use this format:

```text
I cannot run this directly from the container.

Run this on the host:

<command>

Paste the output back here and I will continue.
```

Prefer read-only diagnostic commands first. Do not suggest destructive commands unless clearly necessary.

## Health commands

- `hostctl health summary`
- `hostctl health disk`
- `hostctl health memory`
- `hostctl health services`
- `hostctl health docker`
- `hostctl health network`

## Docker container commands

- `hostctl docker list`
- `hostctl docker all`
- `hostctl docker unhealthy`
- `hostctl docker status <container>`
- `hostctl docker logs <container> [lines]`
- `hostctl docker inspect <container>`
- `hostctl docker stats`
- `hostctl docker start <container>`
- `hostctl docker stop <container>`
- `hostctl docker restart <container>`
- `hostctl docker builder-prune`
- `hostctl docker image-prune`

## AppData / Compose app commands

Use these for app folders under `/DATA/AppData`, or the configured `APP_ROOT`.

Commands like `app ls`, `app tree`, `app read`, `app find`, and `app grep` work for plain app folders even if the Compose file lives elsewhere.

Commands like `app ps`, `app logs`, `app config`, `app compose`, `app start`, `app stop`, `app restart`, and `app update` resolve the Compose file automatically:

1. Check the compose registry at `APP_DIR/config/compose-registry.conf` for an explicit entry
2. Fall back to an in-folder Compose file under `APP_ROOT/<app>/`
3. Auto-discover via `docker inspect` label and cache the result in the registry

If none of these work, use `app register <app> <path>` to set the path explicitly.

- `hostctl app list`
- `hostctl app inventory`
- `hostctl app sizes`
- `hostctl app size <app>`
- `hostctl app ps <app>`
- `hostctl app logs <app> [lines]`
- `hostctl app config <app>`
- `hostctl app compose <app>`
- `hostctl app compose-all`
- `hostctl app ls <app> [relative-path]`
- `hostctl app tree <app> [depth]`
- `hostctl app read <app> <relative-file> [lines]`
- `hostctl app find <app> <filename-pattern> [relative-path]`
- `hostctl app grep <app> <pattern> [relative-path]`
- `hostctl app start <app>`
- `hostctl app stop <app>`
- `hostctl app restart <app>`
- `hostctl app update <app>`
- `hostctl app register <app> <path-to-docker-compose.yml>`

Examples:

- `hostctl app inventory`
- `hostctl app compose immich`
- `hostctl app compose-all`
- `hostctl app tree homeassistant 3`
- `hostctl app read nginxproxymanager docker-compose.yml`
- `hostctl app find duplicati "*.sqlite" config`
- `hostctl app register sonarr /var/lib/casaos/apps/sonarr/docker-compose.yml`

## /DATA content commands

These are read-only inspection commands for the fixed `/DATA` roots outside AppData.

- `hostctl documents ls [relative-path]`
- `hostctl documents tree [relative-path] [depth]`
- `hostctl documents read <relative-file> [lines]`
- `hostctl documents find <filename-pattern> [relative-path]`
- `hostctl documents grep <pattern> [relative-path]`
- `hostctl documents stat [relative-path]`
- `hostctl documents du [relative-path] [depth]`
- `hostctl documents recent [relative-path] [count]`

- `hostctl downloads ls [relative-path]`
- `hostctl downloads tree [relative-path] [depth]`
- `hostctl downloads read <relative-file> [lines]`
- `hostctl downloads find <filename-pattern> [relative-path]`
- `hostctl downloads grep <pattern> [relative-path]`
- `hostctl downloads stat [relative-path]`
- `hostctl downloads du [relative-path] [depth]`
- `hostctl downloads recent [relative-path] [count]`

- `hostctl media ls [relative-path]`
- `hostctl media tree [relative-path] [depth]`
- `hostctl media read <relative-file> [lines]`
- `hostctl media find <filename-pattern> [relative-path]`
- `hostctl media grep <pattern> [relative-path]`
- `hostctl media stat [relative-path]`
- `hostctl media du [relative-path] [depth]`
- `hostctl media recent [relative-path] [count]`

- `hostctl backup ls [relative-path]`
- `hostctl backup tree [relative-path] [depth]`
- `hostctl backup read <relative-file> [lines]`
- `hostctl backup find <filename-pattern> [relative-path]`
- `hostctl backup grep <pattern> [relative-path]`
- `hostctl backup stat [relative-path]`
- `hostctl backup du [relative-path] [depth]`
- `hostctl backup recent [relative-path] [count]`

- `hostctl scripts ls [relative-path]`
- `hostctl scripts tree [relative-path] [depth]`
- `hostctl scripts read <relative-file> [lines]`
- `hostctl scripts find <filename-pattern> [relative-path]`
- `hostctl scripts grep <pattern> [relative-path]`
- `hostctl scripts stat [relative-path]`
- `hostctl scripts du [relative-path] [depth]`
- `hostctl scripts recent [relative-path] [count]`

Examples:

- `hostctl documents ls`
- `hostctl downloads find "*.nzb"`
- `hostctl media tree Movies 2`
- `hostctl backup stat nightly`
- `hostctl scripts read maintenance/cleanup.sh`

## Cron commands

Only manage OpenCode-created cron jobs.

- `hostctl cron list`
- `hostctl cron system`
- `hostctl cron show <name>`
- `hostctl cron create <name> "<5-field-schedule>" <allowed-command...>`
- `hostctl cron update <name> "<5-field-schedule>" <allowed-command...>`
- `hostctl cron delete <name>`

Allowed cron actions:

- `docker start <container>`
- `docker stop <container>`
- `docker restart <container>`
- `app start <app>`
- `app stop <app>`
- `app restart <app>`
- `app update <app>`
- `health summary`

Examples:

- `hostctl cron create restart-flaresolverr "0 4 * * *" docker restart flaresolverr`
- `hostctl cron create weekly-sonarr-update "0 3 * * 0" app update sonarr`
- `hostctl cron delete restart-flaresolverr`

## System commands

- `hostctl system failed-services`
- `hostctl system timers`
- `hostctl system journal <unit.service> [lines]`

For destructive or service-changing actions, explain the action first and ask for approval.
