# VPS 备份：restic + rclone

**只下载一个 `backup.sh`，在中文菜单里配置 WebDAV、备份目录和定时任务。** restic 负责加密和增量去重，rclone 负责上传。脚本自动生成本机配置和 systemd 任务，不需要安装器、配置模板或另外下载其他脚本。

适用于使用 **systemd、Bash 4.4+** 的 Linux VPS。以 root 或 sudo 运行；缺少依赖时，菜单会询问是否通过 apt、dnf 或 yum 安装 `restic`、`rclone`、`util-linux`。自动生成新仓库密码时还需要 `openssl`。WebDAV 配置需要支持 `rclone obscure -` 的 rclone；过旧版本会提示升级。已在 Debian 12 容器中验证，发行版软件源缺包时需要自行安装。

## 开始使用

下载并运行（可先打开脚本审阅；生产环境也可以将 URL 中的 `main` 替换为固定 commit）：

```bash
curl -fL https://raw.githubusercontent.com/zifaliu/vps-restic-rclone-backup/main/backup.sh -o backup.sh && sudo bash backup.sh
```

菜单：

```text
1) 配置 WebDAV / 已有 rclone remote
2) 设置备份目录和保留策略
3) 设置 / 停用定时任务
4) 立即备份
5) 查看快照
6) 检查仓库
7) 恢复文件
8) 查看任务状态和日志
9) 清理远端无用数据
0) 退出
```

首次建议按 **1 → 2 → 4 → 3** 操作：

- **配置 WebDAV**：填写 HTTPS 地址、服务类型、用户名和应用密码，脚本测试连接。已有其他类型的 rclone remote 也可以直接选用。
- **设置仓库密码**：新仓库可留空随机生成；接入已有仓库要输入原密码。已有密码文件会一直保留。只有明确输入 `INIT` 才会初始化仓库，网络或密码错误时应取消并修正配置。
- **设置备份目录**：逐行输入路径，支持空格；空行结束。不修改时保留当前目录，初始为 `/etc` 和 `/root`。所有配置路径都必须存在，缺失会报错，不会静默漏备份。
- **设置定时任务**：填写每日备份时间及每周日清理时间，均按 VPS 本地时区。默认分别是 `03:17` 和 `04:17`，随机延后最多 5 分钟；关机错过的任务开机后补跑。菜单也可停用任务。

保存存储配置后，脚本自动安装到 `/usr/local/sbin/restic-rclone-backup`。以后打开菜单：

```bash
sudo restic-rclone-backup
```

## 备份和恢复

备份为加密增量快照，未变化的内容会去重。默认保留 **7 个日快照、5 个周快照、12 个月快照、3 个年快照**（可以重叠）。只在备份完整成功后应用保留策略；每周日 `prune` 回收不再引用的数据。菜单中的手动清理也只回收已不被快照引用的内容。

恢复选菜单 7，填写快照 ID 或 `latest`，以及一个新目录或空目录，例如 `/restore`。脚本拒绝恢复到已有文件的目录，避免直接覆盖运行中的系统。恢复后先检查内容，再自行复制到需要的位置。

以下是供定时任务和排障使用的命令，平时直接使用菜单即可：

```bash
sudo restic-rclone-backup backup
```

```bash
sudo restic-rclone-backup snapshots
```

```bash
sudo restic-rclone-backup check --read-data
```

```bash
sudo restic-rclone-backup restore latest /restore
```

`check --read-data` 会下载读取仓库全部内容，可能耗费较多流量。普通检查在菜单 6；备份与清理操作使用同一把本机锁，避免同时执行，空闲菜单不会占锁。

## 配置文件与注意事项

脚本只需一份，但运行时仍需把配置、密码和定时任务保存在 VPS 上：

| 文件 | 用途 |
| --- | --- |
| `/etc/restic-rclone-backup.conf` | 备份路径、仓库、保留策略、执行时间 |
| `/etc/restic/rclone.conf` | 由菜单生成的专用云盘凭据 |
| `/etc/restic/restic-password` | restic 仓库密码 |
| `/etc/systemd/system/restic-rclone-{backup,prune}.{service,timer}` | 脚本自动生成的定时任务 |

配置和密码为 root 私有文件。WebDAV 密码输入时不显示，rclone 的 `obscure` 仅是可逆混淆，不能代替文件权限。不要将生产配置和密码上传 GitHub。脚本备份时排除自身配置、`/etc/restic`、实际使用的凭据、缓存，以及 `/proc`、`/sys`、`/dev`、`/run`、`/tmp`、`/var/tmp`；其他目录（如 `/mnt`、`/var/lib`）是否备份由你选择。

**务必在 VPS 之外安全保存 restic 密码和 rclone 凭据，并实际测试一次恢复。** 密码丢失无法解密。直接备份运行中的数据库文件不能保证一致性，MySQL/PostgreSQL 等应先导出，再备份导出文件。

升级时下载新版 `backup.sh` 再运行即可；旧配置和已有密码会保留，菜单 3 可重新生成定时任务。旧版的 `BACKUP_OPTIONAL_PATHS` 仍保持可选，不存在时跳过；菜单 2 输入新的完整路径列表后会改为统一路径列表。旧版单独的 `install.sh` 和模板已由本脚本取代。
