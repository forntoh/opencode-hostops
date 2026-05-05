#!/usr/bin/env bash
set -Eeuo pipefail

# opencode-hostops self-contained installer.
# Defaults target ZimaOS/CasaOS-style AppData layouts, but most paths are configurable.

APP_DIR="${APP_DIR:-/DATA/AppData/opencode}"
APP_ROOT="${APP_ROOT:-/DATA/AppData}"
HOST_USER="${HOST_USER:-opencode-host}"
CONTAINER_NAME="${CONTAINER_NAME:-opencode}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
TZ_VALUE="${TZ_VALUE:-Europe/Berlin}"
INSTALL_OPENCODE_LAUNCHER="${INSTALL_OPENCODE_LAUNCHER:-true}"
OPENCODE_LAUNCHER_PATH="${OPENCODE_LAUNCHER_PATH:-/usr/local/bin/opencode}"
HOSTCTL_PATH="${HOSTCTL_PATH:-/usr/local/bin/hostctl}"
HOST_HELPER_PATH="${HOST_HELPER_PATH:-/usr/local/sbin/opencode-host-helper}"
SSH_ENTRYPOINT_PATH="${SSH_ENTRYPOINT_PATH:-/usr/local/sbin/opencode-ssh-entrypoint}"
CONFIG_PATH="${CONFIG_PATH:-/etc/opencode-hostops.env}"
TTY_READY=false

init_prompt_tty() {
  if exec 3<>/dev/tty; then
    TTY_READY=true
  fi
}

can_prompt() {
  [[ "$TTY_READY" == "true" ]]
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

tty_print() {
  local message="$1"
  if can_prompt; then
    printf '%b' "$message" >&3
  fi
}

prompt_with_default() {
  local label="$1"
  local current="$2"
  local input

  if ! can_prompt; then
    printf '%s' "$current"
    return 0
  fi

  tty_print "$label [$current]: "
  IFS= read -r -u 3 input || input=""
  if [[ -z "$input" ]]; then
    printf '%s' "$current"
  else
    printf '%s' "$input"
  fi
}

prompt_password() {
  local current="$1"
  local input

  if ! can_prompt; then
    printf '%s' "$current"
    return 0
  fi

  tty_print "Web UI password [press Enter to use generated password]: "
  IFS= read -r -u 3 input || input=""
  if [[ -z "$input" ]]; then
    printf '%s' "$current"
  else
    printf '%s' "$input"
  fi
}

prompt_bool() {
  local label="$1"
  local current="$2"
  local input normalized suffix

  if ! can_prompt; then
    printf '%s' "$current"
    return 0
  fi

  if [[ "$(lower "$current")" == "true" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi

  while true; do
    tty_print "$label [$suffix]: "
    IFS= read -r -u 3 input || input=""
    normalized="$(lower "$input")"

    if [[ -z "$normalized" ]]; then
      printf '%s' "$current"
      return 0
    fi

    case "$normalized" in
      true|false)
        printf '%s' "$normalized"
        return 0
        ;;
      y|yes)
        printf '%s' "true"
        return 0
        ;;
      n|no)
        printf '%s' "false"
        return 0
        ;;
    esac

    tty_print "Please enter true/false or yes/no.\n"
  done
}

require_number() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "$name must be numeric: $value" >&2
    exit 1
  }
}

require_bool() {
  local name="$1"
  local value

  value="$(lower "$2")"

  case "$value" in
    true|false)
      return 0
      ;;
    *)
      echo "$name must be true or false: $2" >&2
      exit 1
      ;;
  esac
}

collect_install_settings() {
  local generated_password="$1"

  if can_prompt; then
    tty_print "OpenCode hostops installer\n"
    tty_print "Press Enter to accept the value in brackets.\n\n"
  fi

  APP_DIR="$(prompt_with_default "App directory" "$APP_DIR")"
  APP_ROOT="$(prompt_with_default "App root" "$APP_ROOT")"
  HOST_USER="$(prompt_with_default "Restricted host user" "$HOST_USER")"
  CONTAINER_NAME="$(prompt_with_default "Container name" "$CONTAINER_NAME")"
  OPENCODE_PORT="$(prompt_with_default "Web UI port" "$OPENCODE_PORT")"
  TZ_VALUE="$(prompt_with_default "Timezone" "$TZ_VALUE")"
  APP_OWNER_UID="$(prompt_with_default "App owner UID" "$APP_OWNER_UID")"
  APP_OWNER_GID="$(prompt_with_default "App owner GID" "$APP_OWNER_GID")"
  OPENCODE_PASSWORD="$(prompt_password "$generated_password")"
  INSTALL_OPENCODE_LAUNCHER="$(prompt_bool "Install opencode launcher" "$INSTALL_OPENCODE_LAUNCHER")"

  require_number "OPENCODE_PORT" "$OPENCODE_PORT"
  require_number "PUID" "$APP_OWNER_UID"
  require_number "PGID" "$APP_OWNER_GID"
  require_bool "INSTALL_OPENCODE_LAUNCHER" "$INSTALL_OPENCODE_LAUNCHER"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root, for example: sudo $0"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

path_writable_or_creatable() {
  local path="$1"
  local dir

  dir="$(dirname "$path")"
  while [[ ! -d "$dir" && "$dir" != "/" ]]; do
    dir="$(dirname "$dir")"
  done

  [[ -w "$dir" ]]
}

pick_install_path() {
  local label="$1"
  local preferred="$2"
  local fallback="$3"

  if path_writable_or_creatable "$preferred"; then
    printf '%s' "$preferred"
  else
    printf 'Using %s at %s because %s is not writable.\n' "$label" "$fallback" "$preferred" >&2
    printf '%s' "$fallback"
  fi
}

generate_password() {
  if command_exists openssl; then
    openssl rand -base64 24 | tr -d '\n'
  else
    od -An -N 16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command_exists docker-compose; then
    docker-compose "$@"
  else
    echo "Docker Compose is required: install docker compose or docker-compose." >&2
    exit 1
  fi
}

need_root

if ! command_exists docker; then
  echo "Docker is required before installing opencode-hostops." >&2
  exit 1
fi

if ! command_exists ssh-keygen; then
  echo "ssh-keygen is required before installing opencode-hostops." >&2
  exit 1
fi

init_prompt_tty

APP_OWNER_UID="${PUID:-${SUDO_UID:-1000}}"
APP_OWNER_GID="${PGID:-${SUDO_GID:-1000}}"
OPENCODE_PASSWORD="${OPENCODE_SERVER_PASSWORD:-$(generate_password)}"
HOST_USER_HOME=""
HOST_USER_GROUP=""
HOST_USER_FALLBACKED=false
DOCKER_CONFIG_PATH="${DOCKER_CONFIG:-/root/.docker}"

collect_install_settings "$OPENCODE_PASSWORD"

mkdir -p "$APP_DIR"/{config,share,state,workspace,ssh}

CONFIG_PATH="$(pick_install_path "config file" "$CONFIG_PATH" "$APP_DIR/config/opencode-hostops.env")"
HOST_HELPER_PATH="$(pick_install_path "host helper" "$HOST_HELPER_PATH" "$APP_DIR/bin/opencode-host-helper")"
SSH_ENTRYPOINT_PATH="$(pick_install_path "SSH entrypoint" "$SSH_ENTRYPOINT_PATH" "$APP_DIR/bin/opencode-ssh-entrypoint")"
HOSTCTL_PATH="$(pick_install_path "hostctl wrapper" "$HOSTCTL_PATH" "$APP_DIR/bin/hostctl")"
HOST_USER_HOME="$(pick_install_path "host user home" "/home/$HOST_USER" "$APP_DIR/system/$HOST_USER-home")"
DOCKER_CONFIG_PATH="$(pick_install_path "docker config" "$DOCKER_CONFIG_PATH" "$APP_DIR/system/docker-config")"
if [[ "$INSTALL_OPENCODE_LAUNCHER" == "true" ]]; then
  OPENCODE_LAUNCHER_PATH="$(pick_install_path "opencode launcher" "$OPENCODE_LAUNCHER_PATH" "$APP_DIR/bin/opencode")"
fi

if ! id "$HOST_USER" >/dev/null 2>&1 && [[ "$HOST_USER_HOME" == "$APP_DIR/system/$HOST_USER-home" ]]; then
  if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    printf 'Using existing sudo user %s because a dedicated host user cannot be created on this read-only system.\n' "$SUDO_USER" >&2
    HOST_USER="$SUDO_USER"
    HOST_USER_HOME="$(getent passwd "$HOST_USER" | cut -d: -f6)"
    HOST_USER_FALLBACKED=true
  else
    printf 'Using root because a dedicated host user cannot be created on this read-only system.\n' >&2
    HOST_USER="root"
    HOST_USER_HOME="$(getent passwd root | cut -d: -f6)"
    HOST_USER_FALLBACKED=true
  fi
fi

if id "$HOST_USER" >/dev/null 2>&1; then
  existing_home="$(getent passwd "$HOST_USER" | cut -d: -f6)"
  if [[ -n "$existing_home" ]] && ! path_writable_or_creatable "$existing_home/.ssh"; then
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$HOST_USER" != "$SUDO_USER" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
      printf 'Using existing sudo user %s because %s has an unwritable home directory.\n' "$SUDO_USER" "$HOST_USER" >&2
      HOST_USER="$SUDO_USER"
      HOST_USER_HOME="$(getent passwd "$HOST_USER" | cut -d: -f6)"
      HOST_USER_FALLBACKED=true
    elif [[ "$HOST_USER" != "root" ]]; then
      printf 'Using root because %s has an unwritable home directory.\n' "$HOST_USER" >&2
      HOST_USER="root"
      HOST_USER_HOME="$(getent passwd root | cut -d: -f6)"
      HOST_USER_FALLBACKED=true
    fi
  else
    HOST_USER_HOME="$existing_home"
  fi
fi

HOST_USER_GROUP="$(id -gn "$HOST_USER")"
mkdir -p "$DOCKER_CONFIG_PATH"
export DOCKER_CONFIG="$DOCKER_CONFIG_PATH"

ensure_parent_dir "$CONFIG_PATH"
cat > "$CONFIG_PATH" <<EOF
OPENCODE_APP_ROOT=${APP_ROOT}
EOF
chmod 644 "$CONFIG_PATH"

ensure_parent_dir "$HOST_HELPER_PATH"
cat > "$HOST_HELPER_PATH" <<'HOST_HELPER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Optional host-wide configuration written by scripts/install.sh.
HOSTOPS_CONFIG_PATH="__CONFIG_PATH__"
export DOCKER_CONFIG="__DOCKER_CONFIG_PATH__"

if [[ -f "$HOSTOPS_CONFIG_PATH" ]]; then
  # shellcheck disable=SC1091
  source "$HOSTOPS_CONFIG_PATH"
fi

APP_ROOT="${OPENCODE_APP_ROOT:-/DATA/AppData}"
CRON_PREFIX="/etc/cron.d/opencode-"
CRON_LOG="/var/log/opencode-managed-cron.log"

# Print errors in a predictable format so OpenCode can explain them clearly.
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Best-effort redaction for logs, inspect output, Compose YAML, and config output.
# This is not a replacement for never printing secrets, but it reduces accidental leaks.
redact() {
  sed -E \
    -e 's/((PASS|PASSWORD|PASSWD|TOKEN|SECRET|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|AUTH)[A-Za-z0-9_.-]*[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1<redacted>/Ig' \
    -e 's/("(pass(word)?|passwd|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth)[^"]*"[[:space:]]*:[[:space:]]*")[^"]+"/\1<redacted>"/Ig'
}

valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$ ]]
}

valid_cron_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
}

valid_unit() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_.@-]+\.(service|timer)$ ]]
}

compose_file_for_dir() {
  local dir="$1"
  local f

  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$dir/$f" ]]; then
      printf '%s' "$dir/$f"
      return 0
    fi
  done

  return 1
}

list_compose_dirs() {
  find "$APP_ROOT" -mindepth 2 -maxdepth 4 -type f \
    \( -name docker-compose.yml -o -name docker-compose.yaml -o -name compose.yml -o -name compose.yaml \) \
    -printf '%h\n' 2>/dev/null | sort -u
}

app_dir() {
  local app="${1:-}"
  valid_name "$app" || die "Invalid app name: $app"

  local direct="$APP_ROOT/$app"
  local root_real
  root_real="$(realpath "$APP_ROOT")"

  if [[ -d "$direct" ]] && compose_file_for_dir "$direct" >/dev/null 2>&1; then
    local direct_real
    direct_real="$(realpath "$direct")"
    [[ "$direct_real" == "$root_real"/* ]] || die "App path escapes APP_ROOT"
    printf '%s' "$direct_real"
    return 0
  fi

  local matches=()
  local d
  while IFS= read -r d; do
    if [[ "$(basename "$d")" == "$app" ]]; then
      matches+=("$(realpath "$d")")
    fi
  done < <(list_compose_dirs)

  if [[ "${#matches[@]}" -eq 0 ]]; then
    die "App folder not found or has no Compose file: $app"
  fi

  if [[ "${#matches[@]}" -gt 1 ]]; then
    echo "Multiple matching app folders found:" >&2
    printf '  %s\n' "${matches[@]}" >&2
    die "Use a unique folder name."
  fi

  [[ "${matches[0]}" == "$root_real"/* ]] || die "App path escapes APP_ROOT"
  printf '%s' "${matches[0]}"
}

safe_app_path() {
  local app="$1"
  local rel="${2:-.}"
  local dir target

  dir="$(app_dir "$app")"

  [[ "$rel" != /* ]] || die "Path must be relative to the app folder"
  [[ "$rel" != *$'\0'* ]] || die "Invalid path"

  target="$(realpath -m "$dir/$rel")"

  if [[ "$target" != "$dir" && "$target" != "$dir/"* ]]; then
    die "Path escapes app folder"
  fi

  printf '%s' "$target"
}

forbidden_sensitive_path() {
  local path_lc
  path_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$path_lc" in
    *.env|*.env.*|*/.env|*/.env.*|*secret*|*password*|*token*|*private*key*|*.pem|*.key|*.crt|*.p12|*.sqlite|*.sqlite3|*.db)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

compose_cmd() {
  local dir="$1"
  shift
  cd "$dir"

  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    die "Neither docker compose nor docker-compose is available"
  fi
}

safe_container() {
  local c="${1:-}"
  valid_name "$c" || die "Invalid container name: $c"
  docker container inspect "$c" >/dev/null 2>&1 || die "Container not found: $c"
  printf '%s' "$c"
}

docker_cmd() {
  local action="${1:-}"
  shift || true

  case "$action" in
    list)
      docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
      ;;

    all)
      docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
      ;;

    unhealthy)
      docker ps --filter health=unhealthy --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
      ;;

    status)
      local c
      c="$(safe_container "${1:-}")"
      docker inspect --format 'Name={{.Name}}
Image={{.Config.Image}}
Status={{.State.Status}}
Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}
Started={{.State.StartedAt}}
RestartCount={{.RestartCount}}' "$c"
      ;;

    logs)
      local c lines
      c="$(safe_container "${1:-}")"
      lines="${2:-200}"
      [[ "$lines" =~ ^[0-9]+$ ]] || die "Lines must be a number"
      [[ "$lines" -le 5000 ]] || lines=5000
      docker logs --tail "$lines" "$c" 2>&1 | redact
      ;;

    inspect)
      local c
      c="$(safe_container "${1:-}")"
      docker inspect "$c" | redact
      ;;

    start|stop|restart)
      local c
      c="$(safe_container "${1:-}")"
      docker "$action" "$c"
      docker ps -a --filter "name=$c" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
      ;;

    stats)
      docker stats --no-stream
      ;;

    *)
      cat <<HELP
Usage:
  docker list
  docker all
  docker unhealthy
  docker status <container>
  docker logs <container> [lines]
  docker inspect <container>
  docker start <container>
  docker stop <container>
  docker restart <container>
  docker stats
HELP
      exit 1
      ;;
  esac
}

app_cmd() {
  local action="${1:-}"
  shift || true

  case "$action" in
    list)
      while IFS= read -r d; do
        basename "$d"
      done < <(list_compose_dirs)
      ;;

    inventory)
      printf 'APP\tSIZE\tCOMPOSE_FILE\n'
      while IFS= read -r d; do
        local app size compose
        app="$(basename "$d")"
        size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
        compose="$(compose_file_for_dir "$d")"
        printf '%s\t%s\t%s\n' "$app" "${size:-?}" "$compose"
      done < <(list_compose_dirs)
      ;;

    sizes)
      du -xh --max-depth=1 "$APP_ROOT" 2>/dev/null | sort -h
      ;;

    size)
      local dir
      dir="$(app_dir "${1:-}")"
      du -xh --max-depth=2 "$dir" 2>/dev/null | sort -h
      ;;

    ps)
      local dir
      dir="$(app_dir "${1:-}")"
      compose_cmd "$dir" ps
      ;;

    logs)
      local dir lines
      dir="$(app_dir "${1:-}")"
      lines="${2:-200}"
      [[ "$lines" =~ ^[0-9]+$ ]] || die "Lines must be a number"
      [[ "$lines" -le 5000 ]] || lines=5000
      compose_cmd "$dir" logs --tail "$lines" 2>&1 | redact
      ;;

    config)
      local dir
      dir="$(app_dir "${1:-}")"
      compose_cmd "$dir" config | redact
      ;;

    compose)
      local dir file
      dir="$(app_dir "${1:-}")"
      file="$(compose_file_for_dir "$dir")"
      echo "### $file"
      cat "$file" | redact
      ;;

    compose-all)
      while IFS= read -r d; do
        local file
        file="$(compose_file_for_dir "$d")"
        echo
        echo "### APP: $(basename "$d")"
        echo "### FILE: $file"
        cat "$file" | redact
      done < <(list_compose_dirs)
      ;;

    ls)
      local target
      target="$(safe_app_path "${1:-}" "${2:-.}")"
      ls -lah "$target"
      ;;

    tree)
      local app depth dir
      app="${1:-}"
      depth="${2:-2}"
      [[ "$depth" =~ ^[0-9]+$ ]] || die "Depth must be a number"
      [[ "$depth" -le 5 ]] || depth=5
      dir="$(app_dir "$app")"

      find "$dir" -maxdepth "$depth" \
        \( -path '*/node_modules' -o -path '*/.git' -o -path '*/cache' -o -path '*/Cache' \) -prune -o \
        -printf '%M %10s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | head -500
      ;;

    read)
      local app rel lines target
      app="${1:-}"
      rel="${2:-}"
      lines="${3:-300}"

      [[ -n "$rel" ]] || die "Usage: app read <app> <relative-file> [lines]"
      [[ "$lines" =~ ^[0-9]+$ ]] || die "Lines must be a number"
      [[ "$lines" -le 2000 ]] || lines=2000

      target="$(safe_app_path "$app" "$rel")"
      [[ -f "$target" ]] || die "Not a file: $rel"

      if forbidden_sensitive_path "$target"; then
        die "Refusing to read sensitive-looking file: $rel"
      fi

      if ! grep -Iq . "$target"; then
        die "Refusing to print binary file: $rel"
      fi

      echo "### $target"
      head -n "$lines" "$target" | redact
      ;;

    grep)
      local app pattern target
      app="${1:-}"
      pattern="${2:-}"
      [[ -n "$pattern" ]] || die "Usage: app grep <app> <pattern> [relative-path]"
      target="$(safe_app_path "$app" "${3:-.}")"

      grep -RInI \
        --exclude='.env' \
        --exclude='.env.*' \
        --exclude='*.db' \
        --exclude='*.sqlite' \
        --exclude='*.sqlite3' \
        --exclude='*.pem' \
        --exclude='*.key' \
        --exclude='*.crt' \
        --exclude-dir='node_modules' \
        --exclude-dir='.git' \
        --exclude-dir='cache' \
        --exclude-dir='Cache' \
        -- "$pattern" "$target" 2>/dev/null | head -300 | redact
      ;;

    start|stop|restart)
      local dir
      dir="$(app_dir "${1:-}")"
      compose_cmd "$dir" "$action"
      compose_cmd "$dir" ps
      ;;

    update)
      local dir
      dir="$(app_dir "${1:-}")"
      compose_cmd "$dir" pull
      compose_cmd "$dir" up -d --remove-orphans
      compose_cmd "$dir" ps
      ;;

    *)
      cat <<HELP
Usage:
  app list
  app inventory
  app sizes
  app size <app>
  app ps <app>
  app logs <app> [lines]
  app config <app>
  app compose <app>
  app compose-all
  app ls <app> [relative-path]
  app tree <app> [depth]
  app read <app> <relative-file> [lines]
  app grep <app> <pattern> [relative-path]
  app start <app>
  app stop <app>
  app restart <app>
  app update <app>
HELP
      exit 1
      ;;
  esac
}

valid_schedule() {
  local schedule="${1:-}"
  [[ "$(awk '{print NF}' <<< "$schedule")" -eq 5 ]] || die "Cron schedule must have exactly 5 fields"
  [[ "$schedule" =~ ^[A-Za-z0-9*/,_\ -]+$ ]] || die "Cron schedule contains unsupported characters"
}

cron_file() {
  local name="${1:-}"
  valid_cron_name "$name" || die "Invalid cron job name: $name"
  printf '%s%s' "$CRON_PREFIX" "$name"
}

cron_safe_command() {
  [[ $# -ge 2 ]] || die "Cron command is too short"

  case "${1:-}:${2:-}" in
    docker:start|docker:stop|docker:restart)
      [[ $# -eq 3 ]] || die "Cron docker command must be: docker start|stop|restart <container>"
      safe_container "$3" >/dev/null
      ;;

    app:start|app:stop|app:restart|app:update)
      [[ $# -eq 3 ]] || die "Cron app command must be: app start|stop|restart|update <app>"
      app_dir "$3" >/dev/null
      ;;

    health:summary)
      [[ $# -eq 2 ]] || die "Cron health summary takes no extra arguments"
      ;;

    *)
      die "This command is not allowed in cron: $*"
      ;;
  esac
}

cron_cmd() {
  local action="${1:-}"
  shift || true

  case "$action" in
    list)
      shopt -s nullglob
      local found=0
      for f in "${CRON_PREFIX}"*; do
        found=1
        echo "### $(basename "$f" | sed 's/^opencode-//')"
        grep -v '^#' "$f" | sed '/^\s*$/d' | redact
        echo
      done
      [[ "$found" -eq 1 ]] || echo "No OpenCode-managed cron jobs found."
      ;;

    system)
      {
        echo "### /etc/crontab"
        cat /etc/crontab 2>/dev/null || true

        echo
        echo "### /etc/cron.d"
        for f in /etc/cron.d/*; do
          [[ -f "$f" ]] || continue
          echo
          echo "--- $f"
          cat "$f"
        done

        echo
        echo "### Root crontab"
        crontab -l -u root 2>/dev/null || echo "No root crontab or not available."
      } | redact
      ;;

    show)
      local f
      f="$(cron_file "${1:-}")"
      [[ -f "$f" ]] || die "Cron job not found: ${1:-}"
      cat "$f" | redact
      ;;

    create|update)
      local name schedule f
      name="${1:-}"
      schedule="${2:-}"
      shift 2 || die "Usage: cron $action <name> '<schedule>' <allowed-command...>"

      valid_cron_name "$name" || die "Invalid cron job name"
      valid_schedule "$schedule"
      [[ $# -gt 0 ]] || die "Missing cron command"
      cron_safe_command "$@"

      f="$(cron_file "$name")"
      touch "$CRON_LOG"
      chmod 644 "$CRON_LOG"

      {
        echo "# Managed by opencode-hostops. Do not edit manually."
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        printf '%s root /usr/local/sbin/opencode-host-helper --cron-run ' "$schedule"
        printf '%q ' "$@"
        printf '>> %q 2>&1\n' "$CRON_LOG"
      } > "$f"

      chmod 644 "$f"
      echo "Wrote $f"
      ;;

    delete)
      local f
      f="$(cron_file "${1:-}")"
      [[ -f "$f" ]] || die "Cron job not found: ${1:-}"
      rm -f "$f"
      echo "Deleted $f"
      ;;

    *)
      cat <<HELP
Usage:
  cron list
  cron system
  cron show <name>
  cron create <name> "<5-field-schedule>" <allowed-command...>
  cron update <name> "<5-field-schedule>" <allowed-command...>
  cron delete <name>

Allowed cron commands:
  docker start <container>
  docker stop <container>
  docker restart <container>
  app start <app>
  app stop <app>
  app restart <app>
  app update <app>
  health summary
HELP
      exit 1
      ;;
  esac
}

health_cmd() {
  local action="${1:-summary}"

  case "$action" in
    summary)
      echo "### Host"
      hostname
      uptime || true

      echo
      echo "### Disk"
      df -h / /DATA 2>/dev/null || df -h

      echo
      echo "### Memory"
      free -h || true

      echo
      echo "### Failed systemd services"
      systemctl --failed --no-pager || true

      echo
      echo "### Docker containers"
      docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
      ;;

    disk)
      df -h
      echo
      echo "### AppData folder sizes"
      du -xh --max-depth=1 "$APP_ROOT" 2>/dev/null | sort -h || true
      ;;

    memory)
      free -h || true
      echo
      ps aux --sort=-%mem | head -15 || true
      ;;

    services)
      systemctl --failed --no-pager || true
      ;;

    docker)
      docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
      echo
      docker stats --no-stream || true
      ;;

    network)
      ip -br addr || true
      echo
      ss -tulpn | head -100 || true
      ;;

    *)
      cat <<HELP
Usage:
  health summary
  health disk
  health memory
  health services
  health docker
  health network
HELP
      exit 1
      ;;
  esac
}

system_cmd() {
  local action="${1:-}"
  shift || true

  case "$action" in
    failed-services)
      systemctl --failed --no-pager || true
      ;;

    timers)
      systemctl list-timers --all --no-pager || true
      ;;

    journal)
      local unit lines
      unit="${1:-}"
      lines="${2:-200}"

      valid_unit "$unit" || die "Invalid unit name. Example: docker.service"
      [[ "$lines" =~ ^[0-9]+$ ]] || die "Lines must be a number"
      [[ "$lines" -le 5000 ]] || lines=5000

      journalctl -u "$unit" -n "$lines" --no-pager | redact
      ;;

    *)
      cat <<HELP
Usage:
  system failed-services
  system timers
  system journal <unit.service> [lines]
HELP
      exit 1
      ;;
  esac
}

dispatch() {
  local group="${1:-}"
  shift || true

  case "$group" in
    docker) docker_cmd "$@" ;;
    app) app_cmd "$@" ;;
    cron) cron_cmd "$@" ;;
    health) health_cmd "$@" ;;
    system) system_cmd "$@" ;;
    *)
      cat <<HELP
Allowed command groups:
  docker ...
  app ...
  cron ...
  health ...
  system ...
HELP
      exit 1
      ;;
  esac
}

if [[ "${1:-}" == "--cron-run" ]]; then
  shift
  cron_safe_command "$@"
  dispatch "$@"
  exit 0
fi

dispatch "$@"
HOST_HELPER_EOF
sed -i "s|__CONFIG_PATH__|$(escape_sed_replacement "$CONFIG_PATH")|g" "$HOST_HELPER_PATH"
sed -i "s|__DOCKER_CONFIG_PATH__|$(escape_sed_replacement "$DOCKER_CONFIG_PATH")|g" "$HOST_HELPER_PATH"
chmod 755 "$HOST_HELPER_PATH"

ensure_parent_dir "$SSH_ENTRYPOINT_PATH"
cat > "$SSH_ENTRYPOINT_PATH" <<'SSH_ENTRYPOINT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Forced-command SSH entrypoint.
# The container sends base64-encoded argv so we don't need to parse shell strings.
cmd="${SSH_ORIGINAL_COMMAND:-}"

if [[ -z "$cmd" ]]; then
  echo "No command provided. Use hostctl."
  exit 2
fi

if [[ "$cmd" != args64:* ]]; then
  echo "Rejected. Use hostctl."
  exit 2
fi

payload="${cmd#args64:}"

decoded="$(printf '%s' "$payload" | base64 -d 2>/dev/null)" || {
  echo "Invalid payload"
  exit 2
}

args=()

while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  arg="$(printf '%s' "$line" | base64 -d 2>/dev/null)" || {
    echo "Invalid argument encoding"
    exit 2
  }
  args+=("$arg")
done <<< "$decoded"

[[ "${#args[@]}" -gt 0 ]] || {
  echo "No command arguments"
  exit 2
}

exec sudo /usr/local/sbin/opencode-host-helper "${args[@]}"
SSH_ENTRYPOINT_EOF
chmod 755 "$SSH_ENTRYPOINT_PATH"

ensure_parent_dir "$HOSTCTL_PATH"
cat > "$HOSTCTL_PATH" <<'HOST_WRAPPER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Host-side convenience command. This lets you run the same gateway manually.
exec sudo /usr/local/sbin/opencode-host-helper "$@"
HOST_WRAPPER_EOF
chmod 755 "$HOSTCTL_PATH"

if [[ "$INSTALL_OPENCODE_LAUNCHER" == "true" ]]; then
  ensure_parent_dir "$OPENCODE_LAUNCHER_PATH"
  cat > "$OPENCODE_LAUNCHER_PATH" <<'OPENCODE_LAUNCHER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Host-side launcher for OpenCode running inside the container.
# This does not install OpenCode on the host.
APP_DIR="${OPENCODE_CONTAINER_APP_DIR:-/DATA/AppData/opencode}"
CONTAINER="${OPENCODE_CONTAINER_NAME:-opencode}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker start "$CONTAINER" >/dev/null
  else
    cd "$APP_DIR"
    if docker compose version >/dev/null 2>&1; then
      docker compose up -d --build
    else
      docker-compose up -d --build
    fi
  fi
fi

if [[ "${1:-}" == "web-url" ]]; then
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "OpenCode web UI: http://${ip:-YOUR-ZIMA-IP}:4096"
  exit 0
fi

if [[ -t 0 && -t 1 ]]; then
  exec docker exec -it -w /workspace "$CONTAINER" opencode "$@"
else
  exec docker exec -i -w /workspace "$CONTAINER" opencode "$@"
fi
OPENCODE_LAUNCHER_EOF
  chmod 755 "$OPENCODE_LAUNCHER_PATH"
fi

cat > "$APP_DIR/hostctl" <<'CONTAINER_HOSTCTL_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Container-side host operations gateway.
# It talks to the host via a forced SSH command and passes argv safely as base64.

if [[ "$#" -eq 0 ]]; then
  echo "Usage: hostctl <group> <command> [args...]"
  echo
  echo "Examples:"
  echo "  hostctl health summary"
  echo "  hostctl app inventory"
  echo "  hostctl app compose immich"
  echo "  hostctl docker list"
  exit 1
fi

tmp=""

for arg in "$@"; do
  tmp+="$(printf '%s' "$arg" | base64 -w0)"
  tmp+=$'\n'
done

payload="$(printf '%s' "$tmp" | base64 -w0)"

exec ssh hostops "args64:$payload"
CONTAINER_HOSTCTL_EOF
chmod 755 "$APP_DIR/hostctl"

cat > "$APP_DIR/Dockerfile" <<'DOCKERFILE_EOF'
FROM node:22-bookworm

ARG PUID=1000
ARG PGID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    curl \
    git \
    jq \
    less \
    nano \
    openssh-client \
    procps \
    ripgrep \
  && npm install --global opencode-ai \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY hostctl /usr/local/bin/hostctl
RUN chmod +x /usr/local/bin/hostctl

RUN set -eux; \
  if getent group "${PGID}" >/dev/null; then \
    group_name="$(getent group "${PGID}" | cut -d: -f1)"; \
  else \
    groupadd -g "${PGID}" opencode; \
    group_name="opencode"; \
  fi; \
  useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash opencode; \
  mkdir -p \
    /workspace \
    /home/opencode/.config/opencode \
    /home/opencode/.local/share/opencode \
    /home/opencode/.local/state/opencode \
    /home/opencode/.ssh; \
  chown -R opencode:"${PGID}" /workspace /home/opencode

USER opencode
WORKDIR /workspace

ENTRYPOINT ["opencode"]
CMD ["web", "--hostname", "0.0.0.0", "--port", "4096"]
DOCKERFILE_EOF

cat > "$APP_DIR/docker-compose.yml" <<'COMPOSE_EOF'
name: opencode-hostops

services:
  opencode:
    image: opencode-hostops:latest
    build:
      context: .
      dockerfile: Dockerfile
      args:
        PUID: ${PUID:-1000}
        PGID: ${PGID:-1000}
    container_name: ${OPENCODE_CONTAINER_NAME:-opencode}
    restart: unless-stopped

    env_file:
      - .env

    environment:
      TZ: ${TZ:-Europe/Berlin}

    labels:
      icon: https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/opencode-dark.svg

    command:
      - web
      - --hostname
      - 0.0.0.0
      - --port
      - "4096"

    ports:
      - "${OPENCODE_PORT:-4096}:4096"

    extra_hosts:
      - "host.docker.internal:host-gateway"

    volumes:
      - ./config:/home/opencode/.config/opencode
      - ./share:/home/opencode/.local/share/opencode
      - ./state:/home/opencode/.local/state/opencode
      - ./workspace:/workspace
      - ./ssh:/home/opencode/.ssh:ro

    security_opt:
      - no-new-privileges:true

    cap_drop:
      - ALL
COMPOSE_EOF

cat > "$APP_DIR/config/opencode.json" <<'CONFIG_EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "share": "disabled",
  "snapshot": false,
  "instructions": ["/workspace/SERVER-RUNBOOK.md"],

  "permission": {
    "*": "ask",

    "bash": {
      "*": "ask",

      "hostctl health summary": "allow",
      "hostctl health disk": "allow",
      "hostctl health memory": "allow",
      "hostctl health services": "allow",
      "hostctl health docker": "allow",
      "hostctl health network": "ask",

      "hostctl docker list": "allow",
      "hostctl docker all": "allow",
      "hostctl docker unhealthy": "allow",
      "hostctl docker status *": "allow",
      "hostctl docker logs *": "ask",
      "hostctl docker inspect *": "ask",
      "hostctl docker stats": "allow",
      "hostctl docker start *": "ask",
      "hostctl docker stop *": "ask",
      "hostctl docker restart *": "ask",

      "hostctl app list": "allow",
      "hostctl app inventory": "allow",
      "hostctl app sizes": "allow",
      "hostctl app size *": "allow",
      "hostctl app ps *": "allow",
      "hostctl app logs *": "ask",
      "hostctl app config *": "ask",
      "hostctl app compose *": "ask",
      "hostctl app compose-all": "ask",
      "hostctl app ls *": "ask",
      "hostctl app tree *": "ask",
      "hostctl app read *": "ask",
      "hostctl app grep *": "ask",
      "hostctl app start *": "ask",
      "hostctl app stop *": "ask",
      "hostctl app restart *": "ask",
      "hostctl app update *": "ask",

      "hostctl cron list": "allow",
      "hostctl cron system": "ask",
      "hostctl cron show *": "allow",
      "hostctl cron create *": "ask",
      "hostctl cron update *": "ask",
      "hostctl cron delete *": "ask",

      "hostctl system failed-services": "allow",
      "hostctl system timers": "allow",
      "hostctl system journal *": "ask",

      "docker *": "deny",
      "docker-compose *": "deny",
      "sudo *": "deny",
      "ssh *": "deny",
      "rm *": "deny",
      "chmod *": "deny",
      "chown *": "deny",
      "mount *": "deny"
    },

    "edit": {
      "*": "ask",
      "/host/**": "deny"
    },

    "read": {
      "*": "allow",
      "*.env": "deny",
      "*.env.*": "deny",
      "**/secrets/**": "deny"
    }
  }
}
CONFIG_EOF

cat > "$APP_DIR/workspace/SERVER-RUNBOOK.md" <<'RUNBOOK_EOF'
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

## AppData / Compose app commands

Use these for app folders under `/DATA/AppData`, or the configured `APP_ROOT`.

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
- `hostctl app grep <app> <pattern> [relative-path]`
- `hostctl app start <app>`
- `hostctl app stop <app>`
- `hostctl app restart <app>`
- `hostctl app update <app>`

Examples:

- `hostctl app inventory`
- `hostctl app compose immich`
- `hostctl app compose-all`
- `hostctl app tree homeassistant 3`
- `hostctl app read nginxproxymanager docker-compose.yml`

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
RUNBOOK_EOF

if [[ ! -f "$APP_DIR/ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -f "$APP_DIR/ssh/id_ed25519" -N "" >/dev/null
fi
chmod 700 "$APP_DIR/ssh"
chmod 600 "$APP_DIR/ssh/id_ed25519"
chmod 644 "$APP_DIR/ssh/id_ed25519.pub"

cat > "$APP_DIR/ssh/config" <<EOF
Host hostops
  HostName host.docker.internal
  User ${HOST_USER}
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts
  RequestTTY no
EOF
chmod 600 "$APP_DIR/ssh/config"

cat > "$APP_DIR/.env" <<EOF
OPENCODE_SERVER_USERNAME=opencode
OPENCODE_SERVER_PASSWORD=${OPENCODE_PASSWORD}
OPENCODE_PORT=${OPENCODE_PORT}
OPENCODE_CONTAINER_NAME=${CONTAINER_NAME}
TZ=${TZ_VALUE}
PUID=${APP_OWNER_UID}
PGID=${APP_OWNER_GID}
EOF
chmod 600 "$APP_DIR/.env"

# Create restricted host user.
if ! id "$HOST_USER" >/dev/null 2>&1; then
  mkdir -p "$HOST_USER_HOME"
  useradd -M -b "$(dirname "$HOST_USER_HOME")" -d "$HOST_USER_HOME" -s /bin/bash "$HOST_USER"
else
  HOST_USER_HOME="$(getent passwd "$HOST_USER" | cut -d: -f6)"
fi

mkdir -p "$HOST_USER_HOME/.ssh"
chown "$HOST_USER:$HOST_USER_GROUP" "$HOST_USER_HOME"
chmod 700 "$HOST_USER_HOME/.ssh"
PUB="$(cat "$APP_DIR/ssh/id_ed25519.pub")"
AUTHORIZED_KEYS_PATH="$HOST_USER_HOME/.ssh/authorized_keys"
AUTHORIZED_KEY_LINE="command=\"$SSH_ENTRYPOINT_PATH\",no-agent-forwarding,no-X11-forwarding,no-port-forwarding,no-pty $PUB"
touch "$AUTHORIZED_KEYS_PATH"
if ! grep -Fqx "$AUTHORIZED_KEY_LINE" "$AUTHORIZED_KEYS_PATH"; then
  printf '%s\n' "$AUTHORIZED_KEY_LINE" >> "$AUTHORIZED_KEYS_PATH"
fi
chown -R "$HOST_USER:$HOST_USER_GROUP" "$HOST_USER_HOME/.ssh"
chmod 600 "$AUTHORIZED_KEYS_PATH"

cat > /etc/sudoers.d/opencode-hostops <<EOF
${HOST_USER} ALL=(root) NOPASSWD: ${HOST_HELPER_PATH} *
EOF
chmod 440 /etc/sudoers.d/opencode-hostops
visudo -cf /etc/sudoers.d/opencode-hostops >/dev/null

chown -R "$APP_OWNER_UID:$APP_OWNER_GID" "$APP_DIR"

cd "$APP_DIR"
compose_cmd up -d --build

echo
printf '%s\n' "opencode-hostops installed."
printf '%s\n' "App directory: $APP_DIR"
printf '%s\n' "App root inspected by hostctl: $APP_ROOT"
echo
printf '%s\n' "Host integration:"
printf '%s\n' "Config file: $CONFIG_PATH"
printf '%s\n' "Host helper: $HOST_HELPER_PATH"
printf '%s\n' "SSH entrypoint: $SSH_ENTRYPOINT_PATH"
printf '%s\n' "Hostctl wrapper: $HOSTCTL_PATH"
printf '%s\n' "Docker config: $DOCKER_CONFIG_PATH"
printf '%s\n' "Restricted host user home: $HOST_USER_HOME"
if [[ "$HOST_USER_FALLBACKED" == "true" ]]; then
  printf '%s\n' "Restricted host user: $HOST_USER (existing account fallback on read-only host)"
else
  printf '%s\n' "Restricted host user: $HOST_USER"
fi
if [[ "$INSTALL_OPENCODE_LAUNCHER" == "true" ]]; then
  printf '%s\n' "OpenCode launcher: $OPENCODE_LAUNCHER_PATH"
fi
echo
printf '%s\n' "OpenCode web UI: http://<your-host-ip>:$OPENCODE_PORT"
printf '%s\n' "Username: opencode"
printf '%s\n' "Password: $OPENCODE_PASSWORD"
echo
printf '%s\n' "Test commands:"
printf '%s\n' "  $HOSTCTL_PATH health summary"
printf '%s\n' "  $HOSTCTL_PATH app inventory"
printf '%s\n' "  docker exec -it $CONTAINER_NAME hostctl docker list"
if [[ "$INSTALL_OPENCODE_LAUNCHER" == "true" ]]; then
  printf '%s\n' "  $OPENCODE_LAUNCHER_PATH web-url"
  printf '%s\n' "  $OPENCODE_LAUNCHER_PATH"
fi
