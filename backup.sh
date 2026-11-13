#!/usr/bin/env bash
# VPS 加密备份：配置、WebDAV、恢复和 systemd 定时任务都在这一个脚本中。
set -Eeuo pipefail
umask 077

CONFIG_FILE=/etc/restic-rclone-backup.conf
SECRET_DIR=/etc/restic
INSTALL_PATH=/usr/local/sbin/restic-rclone-backup
CACHE_DIR=/var/cache/restic-rclone-backup
LOCK_FILE=/run/restic-rclone-backup/backup.lock
UNIT_DIR=/etc/systemd/system
TEMP_FILES=()

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "错误：$*" >&2; exit 1; }
cleanup() { if ((${#TEMP_FILES[@]})); then rm -f -- "${TEMP_FILES[@]}"; fi; }
trap cleanup EXIT

# 所有提问读取终端，不占用备份程序的标准输入。
ask() {
  printf '%s%s: ' "$1" "${2:+ [$2]}" >&3
  IFS= read -r REPLY <&3 || exit 0
  REPLY=${REPLY:-${2:-}}
}
confirm() { ask "$1（y/N）" n; [[ "$REPLY" == [yY] || "$REPLY" == [yY][eE][sS] ]]; }
read_secret() {
  printf '%s: ' "$1" >&3
  IFS= read -rs REPLY <&3 || exit 0
  printf '\n' >&3
}

private_file() {
  local owner mode mask=${2:-0077}
  [[ "$1" == /* && -f "$1" && ! -L "$1" ]] || die "文件必须为绝对路径的普通文件，不能是符号链接：$1"
  owner=$(stat -c '%u' -- "$1")
  mode=$(stat -c '%a' -- "$1")
  [[ "$owner" == 0 ]] && (( (8#$mode & mask) == 0 )) || die "文件必须归 root 所有且权限不能过宽：$1"
}

load_config() {
  RESTIC_REPOSITORY=''
  RESTIC_PASSWORD_FILE=$SECRET_DIR/restic-password
  RCLONE_CONFIG=$SECRET_DIR/rclone.conf
  RESTIC_HOST=$(hostname -s)
  BACKUP_PATHS=(/etc /root)
  BACKUP_OPTIONAL_PATHS=()
  CREDENTIAL_FILES=(/root/.config/rclone/rclone.conf)
  RESTIC_TAGS=(vps)
  RESTIC_EXCLUDE_FILE=''
  RESTIC_KEEP_DAILY=7
  RESTIC_KEEP_WEEKLY=5
  RESTIC_KEEP_MONTHLY=12
  RESTIC_KEEP_YEARLY=3
  RESTIC_FORGET_AFTER_BACKUP=true
  BACKUP_TIME=03:17
  PRUNE_TIME=04:17
  if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
    private_file "$CONFIG_FILE"
    # 配置是本脚本用 printf %q 生成的 root 私有 Bash 文件。
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  local temp key path
  temp=$(mktemp "$CONFIG_FILE.XXXXXX")
  TEMP_FILES+=("$temp")
  {
    printf '# 由 backup.sh 生成，root 所有，权限 600。\n'
    for key in RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RCLONE_CONFIG RESTIC_HOST \
      RESTIC_KEEP_DAILY RESTIC_KEEP_WEEKLY RESTIC_KEEP_MONTHLY RESTIC_KEEP_YEARLY \
      RESTIC_FORGET_AFTER_BACKUP RESTIC_EXCLUDE_FILE BACKUP_TIME PRUNE_TIME; do
      printf '%s=%q\n' "$key" "${!key}"
    done
    printf 'BACKUP_PATHS=(\n'
    for path in "${BACKUP_PATHS[@]}"; do printf '  %q\n' "$path"; done
    printf ')\nBACKUP_OPTIONAL_PATHS=('
    for path in "${BACKUP_OPTIONAL_PATHS[@]}"; do printf ' %q' "$path"; done
    printf ' )\nCREDENTIAL_FILES=('
    for path in "${CREDENTIAL_FILES[@]}"; do printf ' %q' "$path"; done
    printf ' )\nRESTIC_TAGS=('
    printf ' %q' "${RESTIC_TAGS[@]}"
    printf ' )\n'
  } >"$temp"
  mv -f -- "$temp" "$CONFIG_FILE"
}

require_config() { [[ -n "$RESTIC_REPOSITORY" ]] || die '请先在菜单中配置 WebDAV 和仓库'; }
need_dependencies() {
  local name
  for name in restic rclone flock; do
    command -v "$name" >/dev/null || die "缺少 $name，请先选择菜单 1 安装依赖并配置存储"
  done
}
install_dependencies() {
  local name
  local -a packages=()
  for name in restic rclone flock; do
    command -v "$name" >/dev/null && continue
    if [[ "$name" == flock ]]; then packages+=(util-linux); else packages+=("$name"); fi
  done
  ((${#packages[@]})) || return 0
  printf '需要安装：%s\n' "${packages[*]}"
  confirm '使用系统软件源安装这些依赖' || die '已取消安装'
  if command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null; then
    dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null; then
    yum install -y "${packages[@]}"
  else
    die '请先手动安装 restic、rclone、util-linux 和 openssl'
  fi
  need_dependencies
}

# 只在实际操作期间加锁，打开菜单或填写配置时不阻塞定时备份。
lock_operation() {
  local lock_dir
  lock_dir=$(dirname -- "$LOCK_FILE")
  [[ ! -L "$lock_dir" && ! -L "$LOCK_FILE" ]] || die '锁目录和锁文件不能是符号链接'
  install -d -o root -g root -m 0700 "$lock_dir"
  mkdir -p -- "$CACHE_DIR"
  exec 9>>"$LOCK_FILE"
  flock 9
}
repository_env() {
  require_config
  need_dependencies
  private_file "$RESTIC_PASSWORD_FILE"
  private_file "$RCLONE_CONFIG"
  [[ -s "$RESTIC_PASSWORD_FILE" ]] || die '仓库密码文件为空'
  [[ "$RESTIC_REPOSITORY" == rclone:* ]] || die '仓库地址必须以 rclone: 开头'
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RCLONE_CONFIG
  export RESTIC_CACHE_DIR=$CACHE_DIR
}
install_self() {
  [[ "$SELF" == "$INSTALL_PATH" ]] && return 0
  install -m 0750 -- "$SELF" "$INSTALL_PATH"
}

configure_storage() {
  local choice url vendor user password obscured remote repo_path candidate_config candidate_password
  # 重新配置后仍排除原凭据，避免旧副本进入 /root 等目录的备份。
  CREDENTIAL_FILES+=("$RCLONE_CONFIG" "$RESTIC_PASSWORD_FILE")
  install_dependencies
  [[ ! -L "$SECRET_DIR" ]] || die "$SECRET_DIR 不能是符号链接"
  install -d -m 0700 "$SECRET_DIR"
  printf '\n1) 直接配置 WebDAV\n2) 使用已有 rclone remote（也适用于其他云盘）\n'
  ask '选择存储方式' 1
  choice=$REPLY
  candidate_config=$RCLONE_CONFIG
  if [[ "$choice" == 1 ]]; then
    obscure_test=$(printf 'rclone-stdin-check' | rclone obscure - 2>/dev/null) || die 'rclone 版本过旧，请升级到支持 rclone obscure - 读取标准输入的版本后配置 WebDAV'
    [[ -n "$obscure_test" ]] || die '当前 rclone 不能安全处理 WebDAV 密码，请升级后重试'
    ask 'WebDAV 地址，例如 https://dav.example.com/dav/'
    url=$REPLY
    [[ "$url" == https://* && "$url" != *$'\r'* ]] || die '请输入 HTTPS WebDAV 地址'
    ask 'WebDAV 类型：other / nextcloud / owncloud' other
    vendor=$REPLY
    [[ "$vendor" == other || "$vendor" == nextcloud || "$vendor" == owncloud ]] || die '不支持的 WebDAV 类型'
    ask 'WebDAV 用户名'
    user=$REPLY
    [[ "$user" != *$'\r'* ]] || die '用户名中不能包含回车'
    read_secret 'WebDAV 密码或应用密码（输入不显示）'
    password=$REPLY
    [[ -n "$password" ]] || die 'WebDAV 密码不能为空'
    # 密码经 stdin 传入，避免出现在命令行参数中。obscure 是 rclone 配置格式，不是加密保险箱。
    obscured=$(printf '%s' "$password" | rclone obscure -)
    unset password REPLY
    candidate_config=$(mktemp "$SECRET_DIR/.rclone.XXXXXX")
    TEMP_FILES+=("$candidate_config")
    printf '[backup]\ntype = webdav\nurl = %s\nvendor = %s\nuser = %s\npass = %s\n' \
      "$url" "$vendor" "$user" "$obscured" >"$candidate_config"
    remote=backup
  elif [[ "$choice" == 2 ]]; then
    ask '已有 rclone 配置文件的绝对路径' /root/.config/rclone/rclone.conf
    private_file "$REPLY"
    CREDENTIAL_FILES+=("$REPLY")
    candidate_config=$(mktemp "$SECRET_DIR/.rclone.XXXXXX")
    TEMP_FILES+=("$candidate_config")
    cp -- "$REPLY" "$candidate_config"
    rclone --config "$candidate_config" listremotes
    ask 'remote 名称（不带末尾冒号）'
    remote=${REPLY%:}
    [[ "$remote" =~ ^[a-zA-Z0-9_.-]+$ ]] || die 'remote 名称只能包含字母、数字、点、下划线和短横线'
  else
    die '无效选项'
  fi
  log '测试远端连接……'
  rclone --config "$candidate_config" lsd "$remote:" >/dev/null
  ask '固定主机名（用于快照归类）' "$RESTIC_HOST"
  RESTIC_HOST=$REPLY
  [[ "$RESTIC_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die '主机名只能包含字母、数字、点、下划线和短横线'
  ask '专用远端仓库目录（不要以 / 开头）' "backups/$RESTIC_HOST/restic"
  repo_path=$REPLY
  [[ -n "$repo_path" && "$repo_path" != /* && "/$repo_path/" != *'/../'* && "/$repo_path/" != *'/./'* ]] || die '请使用非空的相对仓库路径，不包含 . 或 .. 路径段'
  RESTIC_REPOSITORY="rclone:$remote:$repo_path"

  candidate_password=$RESTIC_PASSWORD_FILE
  if [[ -e "$candidate_password" || -L "$candidate_password" ]]; then
    private_file "$candidate_password"
    log '保留现有 restic 密码，不会覆盖。连接其他已有仓库时必须使用该仓库的原密码。'
  else
    read_secret 'restic 仓库密码（已有仓库输入原密码；新仓库可留空自动生成）'
    password=$REPLY
    if [[ -z "$password" ]]; then
      command -v openssl >/dev/null || die '自动生成新仓库密码需要 openssl，请先安装 openssl 或输入自行生成的强密码'
      password=$(openssl rand -base64 48)
    else
      read_secret '再输入一次 restic 仓库密码'
      [[ "$password" == "$REPLY" ]] || die '两次密码不一致'
    fi
    candidate_password=$(mktemp "$SECRET_DIR/.password.XXXXXX")
    TEMP_FILES+=("$candidate_password")
    printf '%s\n' "$password" >"$candidate_password"
    unset password REPLY
  fi

  lock_operation
  printf '仓库：%s\n' "$RESTIC_REPOSITORY"
  if ! RESTIC_PASSWORD_FILE="$candidate_password" RCLONE_CONFIG="$candidate_config" \
    RESTIC_REPOSITORY="$RESTIC_REPOSITORY" restic cat config >/dev/null; then
    # Never leave a backup waiting on a person to answer an interactive prompt.
    flock -u 9
    exec 9>&-
    printf '仓库无法打开。若上方提示认证、网络或密码错误，请修正后重试。\n'
    ask '只有新仓库才需要初始化；输入 INIT 初始化，其他输入取消'
    [[ "$REPLY" == INIT ]] || die '已取消，原配置与密码未修改'
    lock_operation
    RESTIC_PASSWORD_FILE="$candidate_password" RCLONE_CONFIG="$candidate_config" \
      RESTIC_REPOSITORY="$RESTIC_REPOSITORY" restic init
  fi
  if [[ "$candidate_config" != "$RCLONE_CONFIG" ]]; then
    # 只替换本脚本的专用配置，不改动用户原有的 rclone 配置。
    RCLONE_CONFIG=$SECRET_DIR/rclone.conf
    [[ ! -L "$RCLONE_CONFIG" ]] || die '专用 rclone 配置不能是符号链接'
    mv -f -- "$candidate_config" "$RCLONE_CONFIG"
  fi
  if [[ "$candidate_password" != "$RESTIC_PASSWORD_FILE" ]]; then
    mv -f -- "$candidate_password" "$RESTIC_PASSWORD_FILE"
  fi
  save_config
  install_self
  printf '\n已保存配置。请把 %s 和 %s 安全另存到 VPS 之外。\n' "$RESTIC_PASSWORD_FILE" "$RCLONE_CONFIG"
  printf '接下来可设置备份目录，运行一次备份，再设置定时任务。\n'
}

configure_paths() {
  local path key
  local -a paths=()
  require_config
  printf '当前必需路径：\n'; printf '  %s\n' "${BACKUP_PATHS[@]}"
  if ((${#BACKUP_OPTIONAL_PATHS[@]})); then printf '旧版可选路径：\n'; printf '  %s\n' "${BACKUP_OPTIONAL_PATHS[@]}"; fi
  printf '逐行输入新的完整备份列表（支持空格），空行结束；直接空行保留原列表。\n'
  while :; do
    ask '备份路径'
    path=$REPLY
    [[ -n "$path" ]] || break
    [[ "$path" == /* && ( -e "$path" || -L "$path" ) ]] || { log '请填写存在的绝对路径'; continue; }
    paths+=("$path")
  done
  if ((${#paths[@]})); then BACKUP_PATHS=("${paths[@]}"); BACKUP_OPTIONAL_PATHS=(); fi
  for key in RESTIC_KEEP_DAILY RESTIC_KEEP_WEEKLY RESTIC_KEEP_MONTHLY RESTIC_KEEP_YEARLY; do
    case "$key" in
      RESTIC_KEEP_DAILY) path='保留日快照数' ;; RESTIC_KEEP_WEEKLY) path='保留周快照数' ;;
      RESTIC_KEEP_MONTHLY) path='保留月快照数' ;; RESTIC_KEEP_YEARLY) path='保留年快照数' ;;
    esac
    ask "$path" "${!key}"
    [[ "$REPLY" =~ ^[0-9]{1,5}$ ]] || die '请输入 0 到 99999 的整数'
    printf -v "$key" '%s' "$((10#$REPLY))"
  done
  validate_retention
  lock_operation
  save_config
  log '备份目录和保留策略已保存'
}

validate_retention() {
  local value total=0
  for value in "$RESTIC_KEEP_DAILY" "$RESTIC_KEEP_WEEKLY" "$RESTIC_KEEP_MONTHLY" "$RESTIC_KEEP_YEARLY"; do
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || die '保留数量必须是 0 到 99999 的整数'
    total=$((total + 10#$value))
  done
  (( total > 0 )) || die '至少保留一种快照'
}
forget_snapshots() {
  validate_retention
  restic forget --host "$RESTIC_HOST" --group-by host,paths \
    --keep-daily "$RESTIC_KEEP_DAILY" --keep-weekly "$RESTIC_KEEP_WEEKLY" \
    --keep-monthly "$RESTIC_KEEP_MONTHLY" --keep-yearly "$RESTIC_KEEP_YEARLY"
}
run_backup() {
  local path
  local -a paths=()
  local -a options=(--host "$RESTIC_HOST" --exclude "$SECRET_DIR" --exclude "$CONFIG_FILE*"
    --exclude "$RCLONE_CONFIG*" --exclude "$RESTIC_PASSWORD_FILE" --exclude "$CACHE_DIR"
    --exclude /proc --exclude /sys --exclude /dev --exclude /run --exclude /tmp --exclude /var/tmp)
  for path in "${BACKUP_PATHS[@]}"; do
    [[ "$path" == /* && ( -e "$path" || -L "$path" ) ]] || die "必需路径不存在或不是绝对路径：$path"
    paths+=("$path")
  done
  for path in "${BACKUP_OPTIONAL_PATHS[@]}"; do
    [[ -n "$path" ]] || continue
    [[ "$path" == /* ]] || die "可选路径必须是绝对路径：$path"
    if [[ -e "$path" || -L "$path" ]]; then paths+=("$path"); else log "跳过不存在的旧可选路径：$path"; fi
  done
  ((${#paths[@]})) || die '没有可备份的有效路径'
  for path in "${CREDENTIAL_FILES[@]}"; do options+=(--exclude "$path*"); done
  for path in "${RESTIC_TAGS[@]}"; do [[ -z "$path" ]] || options+=(--tag "$path"); done
  if [[ -n "$RESTIC_EXCLUDE_FILE" ]]; then private_file "$RESTIC_EXCLUDE_FILE" 0022; options+=(--exclude-file "$RESTIC_EXCLUDE_FILE"); fi
  validate_retention
  log "开始备份：$RESTIC_HOST"
  # restic 返回 3 也视为失败（有文件未备份），这时不执行自动保留清理。
  restic backup "${options[@]}" -- "${paths[@]}"
  if [[ "$RESTIC_FORGET_AFTER_BACKUP" == true ]]; then forget_snapshots; fi
  log '备份完成'
}

# systemd 文件在 VPS 上自动生成，不需要从 GitHub 下载模板。
configure_schedule() {
  local choice action unit calendar time
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die '定时任务需要正在运行的 systemd'
  printf '\n1) 设置/启用定时备份\n2) 停用定时备份和清理\n'
  ask '选择' 1
  choice=$REPLY
  if [[ "$choice" == 2 ]]; then
    systemctl disable --now restic-rclone-backup.timer restic-rclone-prune.timer
    log '已停用定时器，远端快照和本地密码均保留'
    return
  fi
  [[ "$choice" == 1 ]] || die '无效选项'
  repository_env
  ask '每日备份时间（VPS 本地时区，HH:MM）' "$BACKUP_TIME"
  BACKUP_TIME=$REPLY
  ask '每周日清理时间（HH:MM）' "$PRUNE_TIME"
  PRUNE_TIME=$REPLY
  for time in "$BACKUP_TIME" "$PRUNE_TIME"; do
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die '请输入正确的 24 小时时间，例如 03:17'
  done
  lock_operation
  restic cat config >/dev/null
  install_self
  save_config
  for action in backup prune; do
    unit=restic-rclone-$action
    if [[ "$action" == backup ]]; then calendar="*-*-* $BACKUP_TIME:00"; else calendar="Sun *-*-* $PRUNE_TIME:00"; fi
    cat >"$UNIT_DIR/$unit.service" <<UNIT
[Unit]
Description=VPS restic $action via rclone
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$INSTALL_PATH $action
TimeoutStartSec=infinity
UMask=0077
Nice=10
ProtectSystem=full
ProtectHome=read-only
NoNewPrivileges=true
UNIT
    cat >"$UNIT_DIR/$unit.timer" <<UNIT
[Unit]
Description=Scheduled VPS restic $action

[Timer]
OnCalendar=$calendar
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  done
  systemctl daemon-reload
  systemctl enable restic-rclone-backup.timer restic-rclone-prune.timer
  systemctl restart restic-rclone-backup.timer restic-rclone-prune.timer
  printf '已启用定时任务（随机延后最多 5 分钟）；VPS 时区：%s\n' "$(date +%Z)"
  systemctl list-timers --no-pager restic-rclone-backup.timer restic-rclone-prune.timer
}

restore_files() {
  local snapshot=${1:-} target=${2:-}
  if [[ -z "$snapshot" || -z "$target" ]]; then
    restic snapshots --host "$RESTIC_HOST"
    ask '快照 ID 或 latest' latest; snapshot=$REPLY
    ask '恢复到空目录的绝对路径（例如 /restore）'; target=$REPLY
  fi
  [[ "$snapshot" == latest || "$snapshot" =~ ^[a-fA-F0-9]{4,64}$ ]] || die '请输入快照 ID 或 latest'
  [[ "$target" == /* && ! -L "$target" ]] || die '恢复目录必须是绝对路径且不能是符号链接'
  lock_operation
  if [[ -e "$target" ]]; then
    [[ -d "$target" && -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die '为避免覆盖文件，只允许恢复到空目录或新目录'
  fi
  mkdir -p -- "$target"
  restic restore --host "$RESTIC_HOST" --target "$target" -- "$snapshot"
}
show_status() {
  printf '仓库：%s\n主机：%s\n' "${RESTIC_REPOSITORY:-尚未配置}" "$RESTIC_HOST"
  command -v systemctl >/dev/null || return 0
  systemctl list-timers --no-pager restic-rclone-backup.timer restic-rclone-prune.timer || true
  journalctl --no-pager -n 25 -u restic-rclone-backup.service -u restic-rclone-prune.service || true
}
menu() {
  local command
  while :; do
    printf '\n===== VPS 备份：restic + rclone =====\n'
    printf '1) 配置 WebDAV / 已有 rclone remote\n2) 设置备份目录和保留策略\n3) 设置 / 停用定时任务\n4) 立即备份\n5) 查看快照\n6) 检查仓库\n7) 恢复文件\n8) 查看任务状态和日志\n9) 清理远端无用数据\n0) 退出\n'
    ask '请选择'
    case "$REPLY" in
      1) command=setup ;; 2) command=paths ;; 3) command=schedule ;;
      4) command=backup ;; 5) command=snapshots ;; 6) command=check ;;
      7) command=restore ;; 8) command=status ;;
      9) confirm '清理已被保留策略移除的快照数据，继续' || continue; command=prune ;;
      0) return ;; *) printf '请选择 0 到 9。\n'; continue ;;
    esac
    # 子进程保留 set -e 的失败语义，单次操作出错后仍能回到菜单。
    if ! bash "$SELF" "$command"; then printf '\n操作未完成，请查看上方错误信息。\n'; fi
  done
}

main() {
  local command=${1:-menu}
  if [[ "$command" == help || "$command" == --help || "$command" == -h ]]; then
    printf '用法：sudo bash backup.sh [menu|setup|paths|schedule|backup|snapshots|check [--read-data]|restore [ID TARGET]|prune|status]\n'
    return
  fi
  [[ $(uname -s) == Linux ]] || die '请在 Linux VPS 上运行'
  ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die '需要 Bash 4.4 或更新版本'
  [[ $EUID -eq 0 ]] || die '请以 root 或 sudo 运行'
  SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
  [[ -f "$SELF" ]] || die '请先把 backup.sh 下载为本地文件再运行'
  case "$command" in
    menu|setup|paths|schedule|status|backup|snapshots|check|restore|prune) ;;
    *) die "未知命令：$command" ;;
  esac
  case "$command" in
    check) [[ $# -le 2 && ( $# -eq 1 || "$2" == --read-data ) ]] || die '用法：check [--read-data]' ;;
    restore) [[ $# -eq 1 || $# -eq 3 ]] || die '用法：restore [快照ID 恢复目录]' ;;
    *) [[ $# -le 1 ]] || die '命令参数过多' ;;
  esac
  load_config
  case "$command" in
    menu|setup|paths|schedule) exec 3<>/dev/tty ;;
    restore) if [[ $# -eq 1 ]]; then exec 3<>/dev/tty; fi ;;
  esac
  case "$command" in
    menu) menu ;; setup) configure_storage ;; paths) configure_paths ;;
    schedule) configure_schedule ;; status) show_status ;;
    *)
      repository_env
      [[ "$command" == restore ]] || lock_operation
      case "$command" in
        backup) run_backup ;; snapshots) restic snapshots --host "$RESTIC_HOST" ;;
        check) restic check "${@:2}" ;; restore) restore_files "${@:2}" ;; prune) restic prune ;;
      esac
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
