# opencode-hostops

Run OpenCode in a container while giving it a controlled, auditable way to inspect and operate a Linux home server.

This project is useful for ZimaOS, CasaOS, and other Docker-based home servers where applications are stored in app folders such as `/DATA/AppData/<app>`. The default paths target ZimaOS-style installations, but they can be changed during installation.

The goal is not to give OpenCode unrestricted root access. The goal is to provide a small host operations gateway that OpenCode can use for common server tasks.

```text
OpenCode container
  ↓
hostctl
  ↓
forced SSH command
  ↓
opencode-host-helper
  ↓
allowlisted host operations
```

OpenCode can inspect containers, read Compose files, manage selected cron jobs, restart known services, and check system health without mounting the Docker socket directly into the OpenCode container.

---

## What this guide sets up

After installation, the server will have:

- an OpenCode container running the OpenCode web UI
- a restricted host user called `opencode-host`
- a generic command gateway called `hostctl`
- a host helper script that validates and runs approved operations
- OpenCode permissions that allow safe read-only commands and ask before service-changing commands
- a host-side `opencode` wrapper, so OpenCode can be launched from the host terminal without entering the container

OpenCode will be able to run commands such as:

```bash
hostctl health summary
hostctl app inventory
hostctl app compose immich
hostctl docker list
hostctl docker restart sonarr
hostctl cron create restart-flaresolverr "0 4 * * *" docker restart flaresolverr
```

When a task is outside the allowlisted gateway, OpenCode is instructed to print the exact command a person should run manually on the host and then wait for the output to be pasted back.

---

## Safety model

This project intentionally avoids:

- mounting `/var/run/docker.sock` into the OpenCode container
- running the OpenCode container in privileged mode
- giving OpenCode a raw SSH shell on the host
- giving OpenCode unrestricted `sudo`
- allowing arbitrary `docker run`
- allowing arbitrary host file writes
- allowing arbitrary `rm`, `chmod`, `chown`, or mount operations

The main security boundary is `scripts/host/opencode-host-helper`. Any operation added there should validate arguments, restrict paths, and avoid turning into a generic root shell.

This is not a perfect sandbox. It is a practical home-server operations gateway. If unsafe commands are added to the helper, the isolation becomes weaker.

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/forntoh/opencode-hostops/main/scripts/install.sh | sudo bash
```

The installer will prompt for the main settings. Press Enter to keep each default value.

On hosts with read-only system paths such as some ZimaOS installs, the installer automatically falls back to writable paths under `APP_DIR` for the helper scripts, launcher, and Docker config.

With custom paths:

```bash
curl -fsSL https://raw.githubusercontent.com/forntoh/opencode-hostops/main/scripts/install.sh | \
  sudo APP_DIR=/DATA/AppData/opencode \
       APP_ROOT=/DATA/AppData \
       OPENCODE_PORT=4096 \
       CONTAINER_NAME=opencode \
       bash
```

For local testing after cloning the repository:

```bash
sudo ./scripts/install.sh
```

This local installer flow uses the same interactive prompts and defaults.

Rerunning the installer is safe for normal updates and retries. It rewrites the generated config files, rebuilds and restarts the container, and keeps the existing app data under `APP_DIR`. It does not delete your workspace, config, or state directories.

If the installer falls back to an existing account because the host cannot create a dedicated `opencode-host` user, rerunning it will keep using that fallback account until the host paths become writable or you choose different settings.

The installer will create the app directory, install the host gateway scripts, configure the restricted SSH user, create the OpenCode container files, build the container, and print the generated web password at the end.

Open the web UI at:

```text
http://YOUR-SERVER-IP:4096
```

---

## Manual installation guide

Use the manual guide when the setup needs to be reviewed or changed before installation.

### 1. Create the OpenCode app directory

```bash
sudo mkdir -p /DATA/AppData/opencode/{config,share,state,workspace,ssh}
sudo chown -R "$USER":"$USER" /DATA/AppData/opencode
cd /DATA/AppData/opencode
```

### 2. Generate the SSH key used by the container

```bash
ssh-keygen -t ed25519 -f /DATA/AppData/opencode/ssh/id_ed25519 -N ""
chmod 700 /DATA/AppData/opencode/ssh
chmod 600 /DATA/AppData/opencode/ssh/id_ed25519
```

This key is used only by the OpenCode container to reach the restricted host gateway.

### 3. Configure the managed app root

```bash
sudo tee /etc/opencode-hostops.env >/dev/null <<'ENV'
OPENCODE_APP_ROOT=/DATA/AppData
ENV
sudo chmod 644 /etc/opencode-hostops.env
```

Change `/DATA/AppData` if applications are stored somewhere else.

### 4. Install the host scripts

From the repository root:

```bash
sudo install -m 755 scripts/host/opencode-host-helper /usr/local/sbin/opencode-host-helper
sudo install -m 755 scripts/host/opencode-ssh-entrypoint /usr/local/sbin/opencode-ssh-entrypoint
sudo install -m 755 scripts/host/hostctl-host-wrapper /usr/local/bin/hostctl
sudo install -m 755 scripts/host/opencode-container-launcher /usr/local/bin/opencode
```

`hostctl` can now be used directly on the host:

```bash
hostctl health summary
hostctl app inventory
hostctl docker list
```

### 5. Create the restricted host user

```bash
sudo useradd -m -s /bin/bash opencode-host 2>/dev/null || true
sudo mkdir -p /home/opencode-host/.ssh
sudo chmod 700 /home/opencode-host/.ssh

PUB="$(cat /DATA/AppData/opencode/ssh/id_ed25519.pub)"

sudo tee /home/opencode-host/.ssh/authorized_keys >/dev/null <<'AUTHORIZED_KEYS'
command="/usr/local/sbin/opencode-ssh-entrypoint",no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty REPLACE_WITH_PUBLIC_KEY
AUTHORIZED_KEYS

sudo sed -i "s|REPLACE_WITH_PUBLIC_KEY|$PUB|" /home/opencode-host/.ssh/authorized_keys
sudo chown -R opencode-host:opencode-host /home/opencode-host/.ssh
sudo chmod 600 /home/opencode-host/.ssh/authorized_keys
```

The forced command prevents this SSH key from opening a normal shell.

### 6. Allow only the helper through sudo

```bash
sudo tee /etc/sudoers.d/opencode-hostops >/dev/null <<'SUDOERS'
opencode-host ALL=(root) NOPASSWD: /usr/local/sbin/opencode-host-helper *
SUDOERS

sudo chmod 440 /etc/sudoers.d/opencode-hostops
sudo visudo -cf /etc/sudoers.d/opencode-hostops
```

The restricted user can only run `opencode-host-helper` through sudo.

### 7. Copy the container files

```bash
cp scripts/container/hostctl /DATA/AppData/opencode/hostctl
chmod +x /DATA/AppData/opencode/hostctl

cp docker/Dockerfile /DATA/AppData/opencode/Dockerfile
cp docker/docker-compose.yml /DATA/AppData/opencode/docker-compose.yml
cp config/opencode.json /DATA/AppData/opencode/config/opencode.json
cp workspace/SERVER-RUNBOOK.md /DATA/AppData/opencode/workspace/SERVER-RUNBOOK.md
```

### 8. Create the SSH config used by the container

```bash
cat > /DATA/AppData/opencode/ssh/config <<'SSHCONFIG'
Host hostops
  HostName host.docker.internal
  User opencode-host
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts
  RequestTTY no
SSHCONFIG

chmod 600 /DATA/AppData/opencode/ssh/config
```

### 9. Create the OpenCode environment file

```bash
cat > /DATA/AppData/opencode/.env <<'ENV'
OPENCODE_SERVER_USERNAME=opencode
OPENCODE_SERVER_PASSWORD=change-this-to-a-long-random-password
OPENCODE_PORT=4096
OPENCODE_CONTAINER_NAME=opencode
TZ=Europe/Berlin
PUID=1000
PGID=1000
ENV

chmod 600 /DATA/AppData/opencode/.env
```

Change `OPENCODE_SERVER_PASSWORD` before starting the container.

### 10. Start OpenCode

```bash
cd /DATA/AppData/opencode
docker compose up -d --build
```

Open:

```text
http://YOUR-SERVER-IP:4096
```

---

## Running OpenCode from the host terminal

The installer and manual setup both install a host wrapper at `/usr/local/bin/opencode`.

Run OpenCode without entering the container:

```bash
opencode
```

Show the web URL:

```bash
opencode web-url
```

This wrapper does not install OpenCode on the host. It starts the container if needed and then executes OpenCode inside it.

---

<details>

<summary>Using OpenCode Naturally</summary>

## Using OpenCode naturally

Talk to OpenCode in plain language.

It should use the `hostctl` gateway internally when it needs host access, but you generally should not need to type the raw `hostctl` commands yourself.

### Server health

```text
Give me a quick health summary of this server, including disk, memory, and container status.

Check whether anything on this server looks unhealthy.

Please investigate why the root filesystem is full, but do not delete anything yet.
```

### Docker containers

```text
Show me all running containers and tell me if any look unhealthy.

Please inspect the flaresolverr container and summarize why it is restarting.

Check the logs for crontab-ui and tell me why it is unhealthy.

Restart the flaresolverr container after explaining what you are about to do.
```

### AppData apps

```text
What apps do you see under AppData on this machine? Give me a short inventory.

Please inspect the slskd AppData folder, find slskd.yml, and review its config.

Check the Immich app folder and show me the Compose configuration it is using.

Look through the Duplicati app data and list any sqlite, db, json, or xml files you find under config.

Please check why the Sonarr app is failing, and summarize the relevant logs and configuration.
```

### Documents, Downloads, Media, Backup, and Scripts

```text
Please inspect the Scripts directory and list the shell scripts you find.

Look in Downloads and summarize the newest files.

Show me the top-level folders under Media.

Search the Backup directory for sqlite files and tell me what is there.

Find any NZB files in Downloads.
```

### Scheduling and automation

```text
List the OpenCode-managed cron jobs on this server.

Create a weekly maintenance job to update Sonarr every Sunday at 3 AM, but explain the change before doing it.

Show me the system timers and failed services.
```

### When you do want the raw command names

OpenCode should use `hostctl` internally for host access. The main command groups available through the tool are:

```text
health
docker
app
documents
downloads
media
backup
scripts
cron
system
```

The full command reference lives in `docs/COMMANDS.md`.

</details>

---

<details>

<summary>How OpenCode should handle blocked tasks</summary>

## How OpenCode should handle blocked tasks

The included runbook tells OpenCode not to bypass `hostctl`.

When a task cannot be completed through the gateway, OpenCode should respond with a manual command instead:

```text
I cannot run this directly from the container.

Run this on the host:

sudo journalctl -u docker.service -n 300 --no-pager

Paste the output back here and I will continue.
```

This keeps the workflow useful while avoiding unrestricted host access.

</details>

---

<details>

<summary>Common workflows</summary>

## Common workflows

### Inspect all managed apps

```text
What apps do you see under AppData on this machine? Give me a short inventory.
```

### Review every Compose file

```text
Please review every Compose file you can find under AppData and summarize anything unusual.
```

### Check why an app is failing

```text
Please check why the Immich app is failing and summarize its status, logs, and Compose configuration.
```

### Restart a container

```text
Please restart the flaresolverr container, but explain what you are about to do first.
```

### Restart an app stack

```text
Please restart the Sonarr app stack after explaining why that is the right next step.
```

### Update an app stack

```text
Please update the Prowlarr app stack, but summarize what will change before doing it.
```

### Create a scheduled maintenance job

```text
Please create a weekly maintenance job to update Sonarr every Sunday at 3 AM, but explain the schedule and action before making the change.
```

</details>

---

<details>

<summary>Customization guide</summary>

## Customization guide

Most changes should happen in `scripts/host/opencode-host-helper`.

Good additions are specific, validated operations, such as:

- restart a known systemd service
- check a specific backup folder
- validate VPN routing for qBittorrent
- check Cloudflare tunnel logs
- check Pi-hole DNS status
- verify a known backup job

Risky additions include:

- arbitrary `docker run`
- arbitrary shell commands
- arbitrary root file editing
- arbitrary deletion
- host root mounts
- commands that accept unvalidated paths

After changing host commands, also update:

- `config/opencode.json`, so OpenCode knows whether the command is allowed, denied, or requires approval
- `workspace/SERVER-RUNBOOK.md`, so OpenCode knows when to use the command
- `docs/COMMANDS.md`, if the command should be documented

More details are in `docs/CUSTOMIZATION.md` and `docs/SECURITY.md`.

</details>

---

## Updating an existing installation

After pulling changes from the repository:

```bash
sudo ./scripts/install.sh
```

Then rebuild the OpenCode container if Docker files or container-side scripts changed:

```bash
cd /DATA/AppData/opencode
docker compose up -d --build
```

---

## Uninstall

Stop and remove the container:

```bash
cd /DATA/AppData/opencode
docker compose down
```

Remove installed host files:

```bash
sudo rm -f /usr/local/bin/hostctl
sudo rm -f /usr/local/bin/opencode
sudo rm -f /usr/local/sbin/opencode-host-helper
sudo rm -f /usr/local/sbin/opencode-ssh-entrypoint
sudo rm -f /etc/sudoers.d/opencode-hostops
sudo rm -f /etc/opencode-hostops.env
sudo userdel opencode-host 2>/dev/null || true
```

Remove the app directory only when the data is no longer needed:

```bash
sudo rm -rf /DATA/AppData/opencode
```

Be careful with the final command.

---

## Contributing

Pull requests are welcome for new safe command groups, documentation improvements, and support for different home-server layouts.

Before adding a host operation, check that:

1. the operation is allowlisted rather than generic
2. all arguments are validated
3. paths cannot escape the intended directory
4. secrets are redacted where possible
5. the command cannot become a root shell
6. OpenCode permissions are updated appropriately
7. the runbook explains when to use the command
