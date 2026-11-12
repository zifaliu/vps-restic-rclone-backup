#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CONFIG_FILE="${RESTIC_RCLONE_CONFIG:-/etc/restic-rclone-backup.conf}"

usage() {
  cat <<'USAGE'
Usage:
  restic-rclone-backup                  Open the interactive menu
  restic-rclone-backup [backup]
  restic-rclone-backup init
  restic-rclone-backup forget
  restic-rclone-backup prune
  restic-rclone-backup check [--read-data]
  restic-rclone-backup snapshots
  restic-rclone-backup restore <snapshot-id|latest> <target-directory>
  restic-rclone-backup help

Commands:
  backup     Back up configured paths, then apply retention (default)
  init       Initialize the remote repository; run once before the first backup
  forget     Apply snapshot retention rules
  prune      Reclaim storage from data no longer referenced by snapshots
  check      Check repository indexes; add --read-data for a full data read
  snapshots  List snapshots for the configured host
  restore    Restore a snapshot into a new/existing target directory
USAGE
}

if [[ "${1:-}" == help || "${1:-}" == -h || "${1:-}" == --help ]]; then
  usage
  exit 0
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

on_error() {
  local status=$?
  local line=${BASH_LINENO[0]:-unknown}
  log "ERROR: command failed at line ${line} (exit ${status})"
  exit "$status"
}

if [[ ! -f "$CONFIG_FILE" || -L "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
  fail "configuration must be a readable regular file, not a symlink: $CONFIG_FILE"
fi
[[ $(id -u) -eq 0 ]] || fail "run this command as root"

config_owner=$(stat -c '%u' -- "$CONFIG_FILE") || fail "cannot inspect config ownership"
config_mode=$(stat -c '%a' -- "$CONFIG_FILE") || fail "cannot inspect config permissions"
[[ "$config_owner" == 0 ]] || fail "configuration must be owned by root: $CONFIG_FILE"
(( (8#$config_mode & 0077) == 0 )) || fail "configuration must not be group/other accessible: $CONFIG_FILE"

# The configuration is a root-managed Bash file and must not be writable by untrusted users.
source "$CONFIG_FILE"
trap on_error ERR

: "${RESTIC_REPOSITORY:?Set RESTIC_REPOSITORY in $CONFIG_FILE}"
: "${RESTIC_PASSWORD_FILE:?Set RESTIC_PASSWORD_FILE in $CONFIG_FILE}"
: "${RCLONE_CONFIG:?Set RCLONE_CONFIG in $CONFIG_FILE}"
: "${RESTIC_HOST:=$(hostname -f 2>/dev/null || hostname)}"
: "${RESTIC_CACHE_DIR:=/var/cache/restic-rclone-backup}"
: "${RESTIC_EXCLUDE_FILE:=}"
: "${RESTIC_KEEP_DAILY:=7}"
: "${RESTIC_KEEP_WEEKLY:=5}"
: "${RESTIC_KEEP_MONTHLY:=12}"
: "${RESTIC_KEEP_YEARLY:=3}"
: "${RESTIC_FORGET_AFTER_BACKUP:=true}"
: "${RESTIC_LOCK_FILE:=/run/lock/restic-rclone-backup.lock}"

[[ "$RESTIC_REPOSITORY" == rclone:* ]] || fail "RESTIC_REPOSITORY must use the rclone backend"
[[ "$RESTIC_PASSWORD_FILE" == /* ]] || fail "RESTIC_PASSWORD_FILE must be an absolute path"
[[ "$RCLONE_CONFIG" == /* ]] || fail "RCLONE_CONFIG must be an absolute path"

validate_secret_file() {
  local label=$1
  local path=$2
  local owner mode

  [[ -f "$path" && ! -L "$path" ]] || fail "$label is missing or not a regular file: $path"
  owner=$(stat -c '%u' -- "$path") || fail "cannot inspect $label ownership: $path"
  mode=$(stat -c '%a' -- "$path") || fail "cannot inspect $label permissions: $path"
  [[ "$owner" == 0 ]] || fail "$label must be owned by root: $path"
  (( (8#$mode & 0077) == 0 )) || fail "$label must not be group/other accessible: $path"
}

validate_managed_file() {
  local label=$1
  local path=$2
  local owner mode

  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || fail "$label must be a readable regular file: $path"
  owner=$(stat -c '%u' -- "$path") || fail "cannot inspect $label ownership: $path"
  mode=$(stat -c '%a' -- "$path") || fail "cannot inspect $label permissions: $path"
  [[ "$owner" == 0 ]] || fail "$label must be owned by root: $path"
  (( (8#$mode & 0022) == 0 )) || fail "$label must not be group/other writable: $path"
}

backups_decl=$(declare -p BACKUP_PATHS 2>/dev/null || true)
if [[ "$backups_decl" != 'declare -a '* || ${#BACKUP_PATHS[@]} -eq 0 ]]; then
  fail "BACKUP_PATHS must be a non-empty indexed Bash array in $CONFIG_FILE"
fi
optional_decl=$(declare -p BACKUP_OPTIONAL_PATHS 2>/dev/null || true)
if [[ -n "$optional_decl" && "$optional_decl" != 'declare -a '* ]]; then
  fail "BACKUP_OPTIONAL_PATHS must be an indexed Bash array in $CONFIG_FILE"
fi

for value in "$RESTIC_KEEP_DAILY" "$RESTIC_KEEP_WEEKLY" "$RESTIC_KEEP_MONTHLY" "$RESTIC_KEEP_YEARLY"; do
  [[ $value =~ ^(0|[1-9][0-9]*)$ ]] || fail "retention values must be non-negative integers"
done
(( RESTIC_KEEP_DAILY + RESTIC_KEEP_WEEKLY + RESTIC_KEEP_MONTHLY + RESTIC_KEEP_YEARLY > 0 )) \
  || fail "at least one RESTIC_KEEP_* retention value must be greater than zero"
[[ "$RESTIC_FORGET_AFTER_BACKUP" == true || "$RESTIC_FORGET_AFTER_BACKUP" == false ]] \
  || fail "RESTIC_FORGET_AFTER_BACKUP must be true or false"

export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RCLONE_CONFIG RESTIC_CACHE_DIR

for binary in restic rclone flock; do
  command -v "$binary" >/dev/null 2>&1 || fail "required command not found: $binary"
done

validate_secret_file "restic password file" "$RESTIC_PASSWORD_FILE"
[[ -s "$RESTIC_PASSWORD_FILE" ]] || fail "password file is empty: $RESTIC_PASSWORD_FILE"
validate_secret_file "rclone config" "$RCLONE_CONFIG"
if [[ -n "$RESTIC_EXCLUDE_FILE" ]]; then
  validate_managed_file "exclude file" "$RESTIC_EXCLUDE_FILE"
fi

mkdir -p "$(dirname "$RESTIC_LOCK_FILE")" "$RESTIC_CACHE_DIR"
export RESTIC_RCLONE_CONFIG=$CONFIG_FILE

run_forget() {
  log "Applying retention: daily=$RESTIC_KEEP_DAILY weekly=$RESTIC_KEEP_WEEKLY monthly=$RESTIC_KEEP_MONTHLY yearly=$RESTIC_KEEP_YEARLY"
  restic forget \
    --host "$RESTIC_HOST" \
    --keep-daily "$RESTIC_KEEP_DAILY" \
    --keep-weekly "$RESTIC_KEEP_WEEKLY" \
    --keep-monthly "$RESTIC_KEEP_MONTHLY" \
    --keep-yearly "$RESTIC_KEEP_YEARLY"
}

run_prune() {
  log "Pruning unreferenced repository data"
  restic prune
}

run_backup() {
  local -a args=(
    backup --host "$RESTIC_HOST"
    --exclude "$RESTIC_PASSWORD_FILE"
    --exclude "$RCLONE_CONFIG"
    --exclude "$CONFIG_FILE"
  )
  local path

  for path in "${BACKUP_PATHS[@]}"; do
    [[ "$path" == /* ]] || fail "required backup paths must be absolute: $path"
    [[ -e "$path" || -L "$path" ]] || fail "required backup path does not exist: $path"
    args+=("$path")
  done

  if [[ -n "$optional_decl" ]]; then
    for path in "${BACKUP_OPTIONAL_PATHS[@]}"; do
      [[ -n "$path" ]] || continue
      [[ "$path" == /* ]] || fail "optional backup paths must be absolute: $path"
      [[ -e "$path" || -L "$path" ]] || { log "Skipping absent optional path: $path"; continue; }
      args+=("$path")
    done
  fi

  if declare -p RESTIC_TAGS >/dev/null 2>&1; then
    for tag in "${RESTIC_TAGS[@]}"; do
      [[ -n "$tag" ]] || continue
      args+=(--tag "$tag")
    done
  fi

  if [[ -n "$RESTIC_EXCLUDE_FILE" ]]; then
    args+=(--exclude-file "$RESTIC_EXCLUDE_FILE")
  fi

  log "Starting backup for host $RESTIC_HOST"
  restic "${args[@]}"

  if [[ "$RESTIC_FORGET_AFTER_BACKUP" == true ]]; then
    run_forget
  else
    log "Skipping retention because RESTIC_FORGET_AFTER_BACKUP=false"
  fi

  log "Backup command completed; run prune periodically to reclaim remote storage"
}

interactive_menu() {
  local choice snapshot target

  [[ -r /dev/tty && -w /dev/tty ]] || fail "no command supplied and no interactive terminal is available"
  while :; do
    printf '\nrestic+rclone backup menu\n'
    printf '1) Run backup\n2) List snapshots\n3) Check repository\n4) Restore snapshot\n5) Apply retention\n6) Prune repository\n0) Exit\n'
    printf 'Select an action: '
    IFS= read -r choice </dev/tty || return 0
    case "$choice" in
      1) "$0" backup ;;
      2) "$0" snapshots ;;
      3)
        printf 'Read all repository data? (y/N): '
        IFS= read -r choice </dev/tty || return 0
        if [[ "${choice,,}" == y || "${choice,,}" == yes ]]; then
          "$0" check --read-data
        else
          "$0" check
        fi
        ;;
      4)
        "$0" snapshots
        printf 'Snapshot ID or latest: '
        IFS= read -r snapshot </dev/tty || return 0
        printf 'Restore target directory: '
        IFS= read -r target </dev/tty || return 0
        [[ -n "$snapshot" && "$target" == /* ]] || { log "Snapshot and absolute restore target are required"; continue; }
        "$0" restore "$snapshot" "$target"
        ;;
      5) "$0" forget ;;
      6) "$0" prune ;;
      0) return 0 ;;
      *) log "Choose one of the listed actions" ;;
    esac
  done
}

command_name=${1:-}
if [[ -z "$command_name" ]]; then
  interactive_menu
  exit $?
fi
exec 9>"$RESTIC_LOCK_FILE"
log "Waiting for backup lock: $RESTIC_LOCK_FILE"
flock 9
case "$command_name" in
  backup)
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    run_backup
    ;;
  init)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    log "Initializing repository: $RESTIC_REPOSITORY"
    restic init
    ;;
  forget)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    run_forget
    ;;
  prune)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    run_prune
    ;;
  check)
    shift
    [[ $# -le 1 ]] || { usage >&2; exit 2; }
    if [[ $# -eq 1 && "$1" != --read-data ]]; then
      usage >&2
      exit 2
    fi
    restic check "$@"
    ;;
  snapshots)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    restic snapshots --host "$RESTIC_HOST"
    ;;
  restore)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    log "Restoring snapshot $2 to $3"
    restic restore --host "$RESTIC_HOST" --target "$3" "$2"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
