# Command Reference

All OpenCode host operations should go through `hostctl`.

## Health

```bash
hostctl health summary
hostctl health disk
hostctl health memory
hostctl health services
hostctl health docker
hostctl health network
```

## Docker

```bash
hostctl docker list
hostctl docker all
hostctl docker unhealthy
hostctl docker status <container>
hostctl docker logs <container> [lines]
hostctl docker inspect <container>
hostctl docker stats
hostctl docker start <container>
hostctl docker stop <container>
hostctl docker restart <container>
```

## AppData / Compose apps

```bash
hostctl app list
hostctl app inventory
hostctl app sizes
hostctl app size <app>
hostctl app ps <app>
hostctl app logs <app> [lines]
hostctl app config <app>
hostctl app compose <app>
hostctl app compose-all
hostctl app ls <app> [relative-path]
hostctl app tree <app> [depth]
hostctl app read <app> <relative-file> [lines]
hostctl app grep <app> <pattern> [relative-path]
hostctl app start <app>
hostctl app stop <app>
hostctl app restart <app>
hostctl app update <app>
```

## Cron

```bash
hostctl cron list
hostctl cron system
hostctl cron show <name>
hostctl cron create <name> "<5-field-schedule>" <allowed-command...>
hostctl cron update <name> "<5-field-schedule>" <allowed-command...>
hostctl cron delete <name>
```

Allowed cron payloads:

```bash
docker start <container>
docker stop <container>
docker restart <container>
app start <app>
app stop <app>
app restart <app>
app update <app>
health summary
```

## System

```bash
hostctl system failed-services
hostctl system timers
hostctl system journal <unit.service> [lines]
```
