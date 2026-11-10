#!/usr/bin/env bash
# Weekly Uptime Kuma + Traefik maintenance.
# Creates a consistent backup BEFORE updating Ubuntu packages.
set -Eeuo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/uptime-kuma}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/uptime-kuma}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
LOG_FILE="${LOG_FILE:-/var/log/uptime-kuma-maintenance.log}"
LOCK_FILE="/run/lock/uptime-kuma-maintenance.lock"
RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/uptime-kuma-restic.env}"
RESTIC_ENABLED=true
AUTO_INSTALL_RESTIC=false
AUTO_INIT_RESTIC=false
RESTIC_DRY_RUN=false
RESTIC_DRY_RUN_FLAG=""

usage() {
    cat <<USAGE
Usage: sudo ${SCRIPT_NAME} [OPTIONS]

Create and verify a local project archive, optionally upload it with Restic,
then perform Ubuntu package maintenance.

Options:
  --skip-restic       Local backup only. Skip every Restic-related operation.
  --install-restic    Install Restic automatically through APT if it is missing.
  --init-restic       Attempt to initialize the configured repository, then
                      verify it. Existing accessible repositories are reused.
  --dry-run           Preview backups that will be deleted when running `restic forget`.
                      No files will be modified.
  -h, --help          Show this help.

Default behaviour (no options): local backup + Restic upload.

Examples:
  sudo ${SCRIPT_NAME}
  sudo ${SCRIPT_NAME} --skip-restic
  sudo ${SCRIPT_NAME} --install-restic
  sudo ${SCRIPT_NAME} --init-restic
  sudo ${SCRIPT_NAME} --install-restic --init-restic
  sudo ${SCRIPT_NAME} --dry-run

Environment overrides:
  DEPLOY_DIR, BACKUP_DIR, LOG_FILE, RESTIC_ENV_FILE
USAGE
}

while (($#)); do
    case "$1" in
        --skip-restic)
            RESTIC_ENABLED=false
            ;;
        --install-restic)
            AUTO_INSTALL_RESTIC=true
            ;;
        --init-restic)
            AUTO_INIT_RESTIC=true
            ;;
        --dry-run)
            RESTIC_DRY_RUN=true
            RESTIC_DRY_RUN_FLAG="--dry-run"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

log() {
    printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

install -d -m 0750 "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1

install -d -m 0755 /run/lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another maintenance run is active; exiting."
    exit 0
fi

containers_stopped=false
temporary_backup=""
compose_file="$DEPLOY_DIR/compose.yaml"

restart_services_if_needed() {
    if [[ "$containers_stopped" == true ]]; then
        log "Attempting to restart Compose services after backup..."
        if (cd "$DEPLOY_DIR" && docker compose start); then
            containers_stopped=false
            log "Compose services started."
        else
            log "ERROR: Failed to restart Compose services; manual investigation required."
            return 1
        fi
    fi
}

cleanup() {
    local status=$?
    if [[ -n "$temporary_backup" && -f "$temporary_backup" ]]; then
        rm -f "$temporary_backup"
    fi
    if [[ "$containers_stopped" == true ]]; then
        restart_services_if_needed || true
    fi
    exit "$status"
}
trap cleanup EXIT

log "===== Maintenance started ====="
log "Deployment: $DEPLOY_DIR"
log "Backup directory: $BACKUP_DIR"

if [[ ! -d "$DEPLOY_DIR" ]]; then
    log "ERROR: Deployment directory does not exist."
    exit 1
fi

for path in "$compose_file" "$DEPLOY_DIR/.env" "$DEPLOY_DIR/uptime-kuma-data" "$DEPLOY_DIR/letsencrypt" "$DEPLOY_DIR/letsencrypt/acme.json"; do
    if [[ ! -e "$path" ]]; then
        log "ERROR: Required path is missing: $path"
        exit 1
    fi
done

command -v docker >/dev/null 2>&1 || { log "ERROR: Docker not found."; exit 1; }
docker compose version >/dev/null 2>&1 || { log "ERROR: Docker Compose plugin not found."; exit 1; }
systemctl is-active --quiet docker || { log "ERROR: Docker service is not active."; exit 1; }
(cd "$DEPLOY_DIR" && docker compose config --quiet) || { log "ERROR: Compose configuration is invalid."; exit 1; }

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 1 )); then
    log "ERROR: RETENTION_DAYS must be a positive integer."
    exit 1
fi

if [[ "$RESTIC_ENABLED" == true ]]; then
    if [[ ! -r "$RESTIC_ENV_FILE" ]]; then
        log "ERROR: Restic configuration is missing or unreadable: $RESTIC_ENV_FILE"
        log "Configure Restic - for encrypted S3-compatible storage backups - before enabling scheduled maintenance, or run with --skip-restic for local-only backups."
        exit 1
    fi

    # This file must be root-owned and writable only by root because it contains
    # the S3 secret access key & key ID and the Restic repository encryption password.
    if [[ "$(stat -c '%U' "$RESTIC_ENV_FILE")" != "root" ]]; then
        log "ERROR: $RESTIC_ENV_FILE must be owned by root."
        exit 1
    fi
    mode="$(stat -c '%a' "$RESTIC_ENV_FILE")"
    if (( ( 8#$mode & 077 ) != 0 )); then
        log "ERROR: $RESTIC_ENV_FILE permissions are too broad; use chmod 600."
        exit 1
    fi

    set -a
    # shellcheck disable=SC1090
    source "$RESTIC_ENV_FILE"
    set +a

    for variable in RESTIC_REPOSITORY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD; do
        if [[ -z "${!variable:-}" ]]; then
            log "ERROR: $variable is missing from $RESTIC_ENV_FILE."
            exit 1
        fi
    done

    if ! command -v restic >/dev/null 2>&1; then
        install_restic=false
        if [[ "$AUTO_INSTALL_RESTIC" == true ]]; then
            install_restic=true
        elif [[ -t 0 ]]; then
            printf 'Restic is not installed. Install it now using APT? [y/N] ' >&2
            read -r answer
            case "$answer" in
                y|Y|yes|YES|Yes) install_restic=true ;;
                *) install_restic=false ;;
            esac
        fi

        if [[ "$install_restic" != true ]]; then
            log "ERROR: Restic is not installed. Install it with 'sudo apt install -y restic', rerun with --install-restic, or use --skip-restic for local-only backups."
            exit 1
        fi

        command -v apt-get >/dev/null 2>&1 || { log "ERROR: APT is unavailable; cannot install Restic automatically."; exit 1; }
        log "Installing Restic using APT..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y restic
        command -v restic >/dev/null 2>&1 || { log "ERROR: Restic installation did not provide the restic command."; exit 1; }
    fi

    init_restic=false
    if [[ "$AUTO_INIT_RESTIC" == true ]]; then
        init_restic=true
    fi

    # A successful 'cat config' proves that the remote repository exists,
    # is initialized, and can be opened with the supplied credentials/password.
    # Never initialize automatically: that should be an explicit setup action.
    log "Checking that the Restic repository is initialized and accessible..."
    if ! restic cat config >/dev/null 2>&1; then
        if [[ "$init_restic" != true ]]; then
            log "ERROR: Restic cannot open the configured repository. It may not be initialized, or the repository, credentials, network, or password may be incorrect."
            log "For a new repository, initialize it explicitly with: sudo bash -c 'set -a; source $RESTIC_ENV_FILE; set +a; restic init'"
            log "Then verify access with: sudo bash -c 'set -a; source $RESTIC_ENV_FILE; set +a; restic snapshots'"
            exit 1
        fi

        # Auto-initialize repository if it doesn't exist
        log "Restic repository configuration not found. Initializing..."
        restic init
    fi
    log "Restic repository check passed."
fi

install -d -m 0700 "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="$BACKUP_DIR/uptime-kuma-$timestamp.tar.gz"
temporary_backup="$backup_file.tmp"

if [[ "$RESTIC_DRY_RUN" == false ]]; then
    # Stop services briefly so the SQLite database (if used) and ACME state are copied consistently.
    log "Stopping Compose services for backup..."
    # Set this first so the EXIT trap attempts a restart even if stop partially fails.
    containers_stopped=true
    (cd "$DEPLOY_DIR" && docker compose stop)
fi

log "Creating backup archive..."
tar --exclude='./.git' -czf "$temporary_backup" -C "$DEPLOY_DIR" compose.yaml .env uptime-kuma-data letsencrypt
chmod 0600 "$temporary_backup"
mv "$temporary_backup" "$backup_file"
log "Local backup created: $backup_file"
tar -tzf "$backup_file" >/dev/null
log "Local backup archive integrity check passed."
if [[ "$RESTIC_DRY_RUN" == true ]]; then
    rm -f "$backup_file"
fi
temporary_backup=""

if [[ "$RESTIC_DRY_RUN" == false ]]; then
    log "Starting Compose services..."
    (cd "$DEPLOY_DIR" && docker compose start)
    containers_stopped=false

    expected_services="$(cd "$DEPLOY_DIR" && docker compose config --services)"
    for service in $expected_services; do
        container_id="$(cd "$DEPLOY_DIR" && docker compose ps --status running -q "$service")"
        if [[ -z "$container_id" ]]; then
            log "ERROR: Service '$service' is not running after backup."
            exit 1
        fi
        container_name="$(docker inspect --format='{{.Name}}' "$container_id" | sed 's|^\/||')"
        container_health_status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container_id")"
        if [[ "$container_health_status" == "unhealthy" ]]; then
            log "ERROR: Container '$container_name' is unhealthy after backup."
            exit 1
        elif [[ "$container_health_status" == "no-healthcheck" ]]; then
            # Container doesn't have a healthcheck defined in compose.yaml,
            # fall back to checking if the container is simply running
            container_running="$(docker inspect --format='{{.State.Running}}' "$container_id")"
            if [[ "$container_running" != "true" ]]; then
                log "ERROR: Container '$container_name' has no healthcheck and is not running after backup."
                exit 1
            fi
        fi
    done
    log "All Compose services are running after backup."
fi

# Upload only after the services are back online, so a slow internet connection
# does not extend the monitoring outage.
if [[ "$RESTIC_ENABLED" == true ]]; then
    if [[ "$RESTIC_DRY_RUN" == false ]]; then
        log "Uploading encrypted backup to S3 compatible storage service using Restic..."
        restic backup "$backup_file" --tag uptime-kuma --host "$(hostname -f 2>/dev/null || hostname)"
    fi

    log "Applying ${RETENTION_DAYS}-day retention to off-site Restic snapshots..."
    restic forget --tag uptime-kuma --group-by host,tags --keep-within "${RETENTION_DAYS}d" $RESTIC_DRY_RUN_FLAG --prune
    log "Off-site backup upload and retention completed."
else
    log "Restic operations skipped. Local backup is available at: $backup_file"
fi

if [[ "$RESTIC_DRY_RUN" == true ]]; then
    log "===== Maintenance dry run completed successfully ====="
    exit 0
fi

log "Updating Ubuntu package indexes..."
apt-get update

log "Upgrading installed Ubuntu packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

log "Removing packages no longer required..."
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y

log "Checking Docker and Compose after package updates..."
systemctl is-active --quiet docker
(cd "$DEPLOY_DIR" && docker compose up -d)

for service in $expected_services; do
    container_id="$(cd "$DEPLOY_DIR" && docker compose ps --status running -q "$service")"
    if [[ -z "$container_id" ]]; then
        log "ERROR: Service '$service' is not running after package updates."
        exit 1
    fi
done
log "All Compose services are running after package updates."

# Local retention applies in either mode, but only after the current backup,
# service checks, and maintenance steps have completed successfully.
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'uptime-kuma-*.tar.gz' \
    -mmin "+$((RETENTION_DAYS * 24 * 60))" -print -delete

if [[ -f /var/run/reboot-required ]]; then
    log "WARNING: A reboot is required. No automatic reboot was performed."
    if [[ -f /var/run/reboot-required.pkgs ]]; then
        cat /var/run/reboot-required.pkgs
    fi
else
    log "No reboot-required flag is present."
fi

log "===== Maintenance completed successfully ====="
