---
name: board-pcie
description: "板端 PCIe / M.2: PCIe0 挂 YT6801 网卡、PCIe1 是 M.2 FPC(可插 NVMe 或 5G 模块)。设备不识别/链路速率疑问/M.2 供电与复位/热插拔没反应时用。含 lspci 正确解读、regulator 状态、以及这块板的 2.5GT/s 是上限不是降速。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [pcie, m2, nvme, lspci, regulator, link-speed, yt6801, rg520n]
    related_skills: [board-overview, board-ethernet, board-storage, board-5g, board-debug]
---

# 板端 PCIe / M.2

## 1. 两个 PCIe 控制器，用途不同

```bash
lspci -nn
```

本机实测：

```
0000:00:00.0 PCI bridge: Qualcomm ... SM8250 PCIe Root Complex [17cb:010b]
0000:01:00.0 Ethernet controller: Motorcomm ... YT6801 [1f0a:6801] (rev 03)
0001:00:00.0 PCI bridge: Qualcomm ... SM8250 PCIe Root Complex [17cb:010b]
```

| 控制器 | 下游设备 | 说明 |
|---|---|---|
| **`0000:00:00.0`** | `0000:01:00.0` = YT6801 网卡 | **板载，不可插拔** |
| **`0001:00:00.0`** | 当前**空**（没插设备） | **M.2 FPC 插槽**：NVMe SSD 或 5G 模块 |

所以 `0001:00:00.0` 下面没设备**是正常的**，这块板当前没插 M.2 卡。

## 2. 链路速率：2.5 GT/s x1 是上限，不是降速

这是这块板最容易被误判成故障的地方。

```bash
for d in /sys/bus/pci/devices/*; do
  n=$(basename $d)
  echo "$n $(cat $d/class) spd=$(cat $d/current_link_speed 2>/dev/null) w=$(cat $d/current_link_width 2>/dev/null)"
done
```

实测：

```
0000:00:00.0 class=0x060400 speed=2.5 GT/s PCIe width=1
0000:01:00.0 class=0x020000 speed=2.5 GT/s PCIe width=1
0001:00:00.0 class=0x060400 speed=2.5 GT/s PCIe width=1
```

```bash
lspci -s 0000:01:00.0 -vv | grep -E 'LnkCap|LnkSta'
# LnkCap: Port #0, Speed 2.5GT/s, Width x1, ASPM L1
# LnkSta: Speed 2.5GT/s, Width x1
```

**判据**：`LnkSta` == `LnkCap` → 已达上限，正常。
只有 `LnkSta` < `LnkCap`（比如 Cap 是 8GT/s、Sta 是 2.5GT/s）才是真降速。

千兆网卡跑 PCIe 2.0 x1（2.5 GT/s ≈ 2 Gbps 有效）足够，不需要更高。

## 3. M.2 插槽的供电与复位（排查"插了不识别"）

这块板的 M.2 相关 regulator：

```bash
for r in /sys/class/regulator/*; do
  n=$(cat $r/name 2>/dev/null)
  case "$n" in *m2*|*M2*|*pcie1*|*12*) echo "$n state=$(cat $r/state 2>/dev/null)";; esac
done
```

实测存在的相关轨：

```
pcie1_pwr_en_vreg    state=enabled     ← M.2 主供电使能
rtl8111h_3v3_vreg    state=enabled
wifi_3v3_vreg        state=enabled
lt9611_3v3_vreg      state=enabled
```

`pcie1_pwr_en_vreg` 是 **M.2 的电源使能**，`enabled` 才对。

## 4. 插了设备但没识别：分层排查

```bash
# 1) 控制器本身在不在
lspci -nn | grep 0001:00:00.0

# 2) 下游有没有东西
lspci -nn -s 0001:00:00.0 -vv | grep -A3 'Secondary bus'
lspci -nn | grep '^0001:01'

# 3) 内核有没有看到 link up
sudo dmesg | grep -iE 'pcie.*0001|pcie1|link up|link down|mhi'

# 4) 供电
cat /sys/class/regulator/*/name | paste -d' ' - <(cat /sys/class/regulator/*/state 2>/dev/null) | grep pcie1

# 5) 复位 / 重新扫描
echo 1 | sudo tee /sys/bus/pci/rescan
lspci -nn     # 再看一次

# 6) 运行时电源管理是否把它挂起了
cat /sys/bus/pci/devices/0001:00:00.0/power/runtime_status    # 实测: active
```

## 5. NVMe SSD

```bash
lspci -nn | grep -i 'non-volatile'
ls /dev/nvme* 2>/dev/null
lsblk | grep nvme
```

没有 `nvme` 命令（`nvme-cli` 未装）。装：

```bash
sudo apt install -y nvme-cli
sudo nvme list
sudo nvme smart-log /dev/nvme0
```

挂载见 `board-storage` §3。

## 6. 5G 模块（RG520N）走 M.2

RG520N 也插在 PCIe1 上，但走的是 **MHI**（Modem Host Interface）而不是标准 PCIe 设备：

```bash
lsmod | grep -E 'pcie_mhi|mhi|qrtr'
# 实测: pcie_mhi 176128 / qrtr_smd / qrtr

ls /dev/mhi* 2>&1
# 实测: 不存在 —— 当前没插 5G 模块

systemctl status modem-start-stop --no-pager | head -5
```

5G 上电时序、QRTR 连接、控制面细节见 `board-5g`。

## 7. ASPM 与省电

```bash
lspci -vv -s 0000:01:00.0 | grep -E 'ASPM|L1'
cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null
```

ASPM L1 打开时，空闲链路会进入低功耗，**某些设备在这种状态下会偶发掉线**。
如果 NVMe/网卡偶发消失，先关 ASPM 验证（需要改内核参数，属于重启级操作，先问用户）。

## 8. 已知坑

| 现象 | 判据 | 处置 |
|---|---|---|
| `0001:00:00.0` 下没设备 | 就是没插 M.2 卡 | 正常 |
| 以为 `2.5 GT/s x1` 降速 | `LnkSta` == `LnkCap` | 已达上限，不是故障 |
| 插了 NVMe 但 `lspci` 没出现 | 下游 bus 无设备 | 查 `pcie1_pwr_en_vreg`、重新上电 |
| `rescan` 后出现又消失 | 供电不足或 ASPM | 关 ASPM、查 12V/3.3V |
| 5G 模块插了但 `/dev/mhi*` 没出现 | MHI 未枚举 | 见 `board-5g` 的上电时序 |
| `nvme: command not found` | 未装 nvme-cli | `apt install nvme-cli` |

## 9. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- `lspci`：3 个设备（0000:00:00.0 桥、0000:01:00.0 YT6801、0001:00:00.0 桥）
- 全部 `2.5 GT/s x1`，`LnkCap` 也是 `2.5GT/s x1`
- `pcie1_pwr_en_vreg` = `enabled`；`0001:00:00.0/power/runtime_status` = `active`
- 无 `/dev/nvme*`、无 `/dev/mhi*`、无 `/sys/class/wwan`（M.2 当前空）
- `nvme-cli` / `smartctl` 未安装
