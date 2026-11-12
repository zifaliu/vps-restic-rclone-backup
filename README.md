# VPS 每日备份：restic + rclone

用 restic 加密、去重备份 VPS 文件，再通过 rclone 上传到云存储。项目包含交互式安装器和 systemd 每日备份/每周 prune 定时器。

## 一键交互安装

前置条件：Linux VPS 使用 systemd，已有可交互的 root/sudo 终端。安装器可尝试通过 apt、dnf、yum 或 apk 安装依赖，也可以在提示时选择取消并自行安装。首次安装前，建议先用 root 配好 rclone remote；安装器也可在默认位置没有配置时打开 `rclone config`。

先在 GitHub 创建仓库并上传本项目。把下面两处 `zifaliu/vps-restic-rclone-backup` 改成实际仓库，再把 `main` 改成你准备使用的分支或固定 commit。正式 VPS 建议固定 commit，避免以后仓库更新改变安装内容。

```bash
curl -fsSL https://raw.githubusercontent.com/zifaliu/vps-restic-rclone-backup/main/install.sh | sudo bash -s -- --source-url https://raw.githubusercontent.com/zifaliu/vps-restic-rclone-backup/main
```

安装器会交互式选择 rclone 配置、remote、仓库目录、主机名、备份目录和保留策略。它会生成 restic 密码，提示你把密码另存到 VPS 之外；明确确认后才会初始化远端仓库。首次备份成功后才允许启用每日备份和每周 prune 定时器。后续在终端直接运行已安装的命令会打开交互式维护菜单；systemd 定时任务则执行明确的 `backup` 操作。若不想使用管道安装，可先下载并审阅 `install.sh`，再以 root 执行：

```bash
sudo bash install.sh --source-url https://raw.githubusercontent.com/zifaliu/vps-restic-rclone-backup/main
```

从源代码目录运行时，安装器会直接使用同目录的项目文件，不需要 `--source-url`。

安装完成后，直接运行命令会打开交互式维护菜单；systemd 定时任务使用显式的 `backup` 子命令，不会进入菜单：

```bash
sudo /usr/local/sbin/restic-rclone-backup
```

## 配置和安全

- 支持使用 systemd 的 Linux VPS。备份程序需要 `restic`、`rclone`、`flock`；安装器还使用 `openssl`、`curl` 和 `systemctl`。
- rclone remote 必须能访问；推荐为每台 VPS 分配独立的远端仓库路径。
- restic 密码文件、rclone 配置和备份配置必须是 root 所有、非符号链接，且不可被 group/other 访问。备份程序会自动排除密码文件、rclone 配置和自身配置文件。
- 请将 restic 密码及恢复所需的 rclone 凭据安全保存在 VPS 之外。丢失 restic 密码将无法解密仓库；替换已有密码会使旧仓库无法读取。
- 默认备份 `/etc` 和 `/root`，其余路径由你在向导中添加。避免直接备份正在写入的数据库数据目录；MySQL/MariaDB、PostgreSQL 等应使用原生导出或具备一致性保证的备份方式。
- 向导可启用示例排除规则。排除路径不会出现在快照中；请在使用前审阅 `/etc/restic/excludes.txt`。
- 通过远程 shell 管道以 root 执行代码有明显信任风险。先审阅脚本，优先使用固定 commit URL，并只从自己控制或信任的仓库安装。

## 定时和运维

每日定时器按 VPS 本地时间约 03:17 执行，随机延迟最多 30 分钟；每周日约 04:17 运行 prune，也有最多 30 分钟随机延迟。`Persistent=true` 会在机器启动后补跑错过的定时任务。

```bash
sudo systemctl list-timers restic-rclone-backup.timer restic-rclone-prune.timer
sudo systemctl start restic-rclone-backup.service
sudo journalctl -u restic-rclone-backup.service --since today
sudo systemctl start restic-rclone-prune.service
sudo /usr/local/sbin/restic-rclone-backup snapshots
sudo /usr/local/sbin/restic-rclone-backup check
sudo /usr/local/sbin/restic-rclone-backup check --read-data
```

`check --read-data` 会读取仓库全部数据，可能耗费较多时间和流量。备份后应用 `forget` 保留策略；独立的每周任务执行 `prune` 回收不再引用的数据。

## 恢复

先恢复到独立目录，检查结果后再手动复制到系统路径：

```bash
sudo mkdir -p /restore
sudo /usr/local/sbin/restic-rclone-backup restore latest /restore
```

`latest` 会限定到当前配置的主机名。不要未经检查就覆盖运行中的系统目录。只有成功完成恢复测试，备份方案才算验证过。

## 手动安装和配置

如果不使用安装向导，可按以下步骤安装：

```bash
sudo install -o root -g root -m 0750 backup.sh /usr/local/sbin/restic-rclone-backup
sudo install -d -o root -g root -m 0700 /etc/restic
sudo install -o root -g root -m 0600 backup.conf.example /etc/restic-rclone-backup.conf
sudo sh -c 'umask 077; openssl rand -base64 48 > /etc/restic/restic-password'
```

编辑 `/etc/restic-rclone-backup.conf`，确认 `RESTIC_REPOSITORY`、rclone 配置路径和备份路径。初始化远端仓库并运行首次备份：

```bash
sudo /usr/local/sbin/restic-rclone-backup init
sudo /usr/local/sbin/restic-rclone-backup backup
sudo /usr/local/sbin/restic-rclone-backup snapshots
```

安装并启用 systemd 定时器：

```bash
sudo install -o root -g root -m 0644 restic-rclone-backup.service restic-rclone-backup.timer restic-rclone-prune.service restic-rclone-prune.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now restic-rclone-backup.timer restic-rclone-prune.timer
```
