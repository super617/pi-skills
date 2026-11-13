---
name: board-storage
description: "板端存储: UFS 115G(btrfs 根分区) / SD 卡(SDR104 200MHz) / M.2 NVMe 的识别、挂载、测速。卡挂不上/容量不对/写保护/读写慢时用。板上没有 fio/hdparm/smartctl,测速用 dd + oflag=direct。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [storage, ufs, sd, nvme, btrfs, ext4, mount, dd, benchmark]
    related_skills: [board-overview, board-pcie, board-debug]
---

# 板端存储

## 1. 这块板上的存储设备

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
```

本机实测：

```
NAME          SIZE TYPE FSTYPE MOUNTPOINT      LABEL
sda         116.1G disk
├─sda1        512M part vfat                     ← boot/EFI
├─sda2         30M part ext4   /var/persist      persist
└─sda3      115.5G part btrfs  /  + /mnt/top     ← 根分区
mmcblk1      29.7G disk
└─mmcblk1p1  29.7G part exfat  /media/p/SDCARD
zram0         5.3G disk [SWAP]
```

| 设备 | 型号 | 说明 |
|---|---|---|
| UFS `sda` | **FORESEE C2G072**，rev `0016` | 系统盘，115.5G btrfs |
| SD `mmcblk1` | **SK32G**（32G） | SDR104 模式 |
| NVMe | 当前**未插** | 插上后是 `nvme0n1`，见 `board-pcie` |

`sdb`/`sdc`/`sdd`/`sde`/`sdf` 是 UFS 里的**其它 LUN**（分区表碎片），不是独立磁盘，别动。

## 2. 认设备

```bash
# UFS
cat /sys/block/sda/device/{vendor,model,rev}     # FORESEE / C2G072 / 0016
ls /sys/bus/platform/devices/ | grep ufs         # 1d84000.ufs
cat /sys/class/scsi_host/host0/proc_name         # ufshcd

# SD 卡
cat /sys/class/mmc_host/mmc1/mmc1:aaaa/uevent
# MMC_TYPE=SD  MMC_NAME=SK32G
sudo cat /sys/kernel/debug/mmc1/ios
# clock: 202000000 Hz      ← 200 MHz
# bus width: 2 (4 bits)
# timing spec: 6 (sd uhs SDR104)   ← 最高档
# signal voltage: 1 (1.80 V)

# NVMe（插了才有）
lspci -nn | grep -i non-volatile
ls /dev/nvme* 2>/dev/null
```

`timing spec: sd uhs SDR104` = SD 卡跑在最高速度模式，这是正常状态。

## 3. 挂载

### 3.1 看现状

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /
cat /proc/mounts | grep -E 'sda|mmcblk'
df -h / /var/persist /media/p/SDCARD
```

> ★ **`/etc/fstab` 在这份镜像上是空的**（只有一行 `# UNCONFIGURED FSTAB FOR BASE SYSTEM`）。
> 跑去 `cat /etc/fstab` 找挂载点会什么也看不到。一切都是 **systemd mount unit**：
> ```bash
> systemctl status var-persist.mount --no-pager
> #   Where: /var/persist
> #   What:  /dev/sda2
> systemctl list-units --type=mount --no-pager
> ```
> 所以添永久挂载不是改 fstab，而是加 `.mount` 单元（或先问用户想用哪种方式）。

### 3.2 手工挂一个分区

```bash
sudo mkdir -p /mnt/mydisk
sudo blkid /dev/mmcblk1p1                       # 先确认类型
sudo mount -o rw,uid=1001,gid=1001 /dev/mmcblk1p1 /mnt/mydisk
findmnt /mnt/mydisk
sudo umount /mnt/mydisk
```

exfat/ntfs 需要对应驱动：

```bash
dpkg -l | grep -E 'exfat|ntfs' | head
# 板上已有 exfat 支持（SD 卡自动挂上了）
```

### 3.3 SD 卡自动挂载

桌面下由 udisks2 自动挂到 `/media/<user>/<LABEL>`：

```bash
systemctl is-active udisks2         # active
ls /media/p/                        # SDCARD
sudo systemctl status udisks2 --no-pager | head -5
```

插卡没自动挂 → 先 `dmesg` 看有没有识别：

```bash
sudo dmesg | grep -iE 'mmc|sdhci|card' | tail -20
```

## 4. 测速（板上没有 fio/hdparm）

**必须带 `oflag=direct`/`iflag=direct`**，否则测的是 page cache：

```bash
# UFS 写（200 MB）
sudo dd if=/dev/zero of=/tmp/ddtest bs=1M count=200 oflag=direct
sudo rm -f /tmp/ddtest

# UFS 读
sudo dd if=/dev/sda3 of=/dev/null bs=1M count=200 iflag=direct

# SD 卡（先确认 mount 点）
sudo dd if=/dev/zero of=/media/p/SDCARD/ddtest bs=1M count=200 oflag=direct
sudo rm -f /media/p/SDCARD/ddtest
```

实测基线（2026-11-13，UFS btrfs）：

| 操作 | 结果 |
|---|---|
| 写 200 MB `oflag=direct` | **103 MB/s** |
| 读 200 MB `iflag=direct` | **363 MB/s** |

明显低于这个量级再怀疑设备/文件系统。

> 想装 fio 测 IOPS：`sudo apt install -y fio`（装前问用户）。
> 没有 fio 时的随机读写近似：`dd if=/dev/urandom of=x bs=4k count=10000 oflag=direct`。

## 5. 空间与清理

```bash
df -h /
sudo du -sh /var/log /var/cache/apt /tmp 2>/dev/null | sort -h
sudo journalctl --disk-usage
sudo journalctl --vacuum-size=200M
```

btrfs 特有：

```bash
sudo btrfs filesystem usage /
sudo btrfs filesystem show /
# 清理旧的快照/子卷前先问用户，别自己删
```

> 实测 btrfs 根分区 `FS bytes used 14.35GiB / devid 1 size 115.53GiB`。
> btrfs 的 `df` 报告和实际可用空间会不一致，以 `btrfs filesystem usage` 为准。

## 6. 只读 / 写保护

```bash
# SD 卡物理写保护开关
cat /sys/block/mmcblk1/ro            # 1 = 只读
# 解除（软件层）
sudo blockdev --setrw /dev/mmcblk1

# 文件系统挂载为 ro
findmnt -no OPTIONS /media/p/SDCARD
```

## 7. NVMe / M.2

当前这块板**没插 NVMe**（`lspci` 里只有 PCIe1 桥）。插上后：

```bash
lspci -nn | grep -i 'non-volatile'
ls /dev/nvme*
lsblk | grep nvme
cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed   # 注意设备号会变
```

没有 `nvme-cli`（`nvme list` 不可用），用 `lsblk` + `cat /sys/block/nvme0n1/...`。
装：`sudo apt install -y nvme-cli`。

## 8. 已知坑

| 现象 | 原因 | 处置 |
|---|---|---|
| `dd` 测出来 2 GB/s | 没加 `oflag=direct`，测的是缓存 | §4 |
| SD 卡插入无反应 | 未识别 | `sudo dmesg \| grep -i mmc` 看有没有 `card` |
| SD 卡自动挂载失败 | udisks2 或文件系统不支持 | `udisksctl mount -b /dev/mmcblk1p1` 看报错 |
| `df` 显示空间和实际不符 | btrfs | 用 `btrfs filesystem usage` |
| `sdb`~`sdf` 想当独立盘用 | 它们是 UFS 的 LUN | 不要格式化 |
| `nvme list: command not found` | 没装 nvme-cli | §7 |
| `/tmp` 占满 | tmpfs 或根分区 | `df -h /tmp`；`rm -rf /tmp/*` 前先确认 |

## 9. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- UFS：`FORESEE C2G072` rev `0016`，`/sys/bus/platform/devices/1d84000.ufs`
- 分区：`sda1` vfat 512M / `sda2` ext4 30M `/var/persist` / `sda3` btrfs 115.5G `/` + `/mnt/top`
- SD：`SK32G`，`SDR104`，200 MHz，4-bit，1.8 V，exfat 挂在 `/media/p/SDCARD`
- dd 基线：写 103 MB/s（`oflag=direct`），读 363 MB/s（`iflag=direct`）
- `fio` / `hdparm` / `ioping` / `smartctl` / `nvme` **均未安装**；`dd` / `btrfs` 有
- `udisks2` active；NVMe 当前未插
