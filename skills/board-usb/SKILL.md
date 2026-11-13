---
name: board-usb
description: "板端 USB: Type-C(USB3.1 + DP Alt Mode, SGM7220 CC 控制器)、USB-A 口经 CH334 HUB、以及 qusb 复合模式切换(ADB/RNDIS/DIAG/MASS_STORAGE 等 PID)。A 口不识别/切换模式后 ADB 掉线/想开 RNDIS 网口/UVC 摄像头模式时用。⚠️ 切模式可能断掉自己的连接,先读再动。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [usb, typec, qusb, gadget, adb, rndis, composite, dp-alt, xhci]
    related_skills: [board-overview, board-power, board-display, board-debug]
---

# 板端 USB

## 1. 三条 USB 通路（别混）

| 通路 | 控制器 | 方向 | 说明 |
|---|---|---|---|
| **Type-C** | `a600000.usb`（dwc3-qcom, gadget） | 从机（device） | 复合设备：ADB / DIAG / RNDIS / NCM / UAC2 / UVC / 大容量存储；同时支持 **DP Alt Mode** |
| **USB-A ×N** | `8c00000.usb`（xhci-hcd） | 主机（host） | 经 **CH334 HUB**；实测挂着键盘鼠标 |
| **DP over Type-C** | `phy@88e8000`（QMP USB3-DP PHY） | 视频输出 | 见 `board-display` |

```bash
ls /sys/class/udc/                    # 只有一个: a600000.usb
cat /sys/class/udc/a600000.usb/state  # configured
lsusb -t                              # 看 USB-A 侧拓扑
```

实测 USB-A 拓扑：

```
/:  Bus 001.Port 001: root_hub (xhci-hcd/1p, 480M)
    |__ Port 001: Dev 002  Class=Hub (hub/4p, 480M)     ← CH334
        |__ Port 001: Dev 006  usbhid (1.5M)            ← 鼠标
        |__ Port 002: Dev 005  usbhid (12M) ×3 if       ← 键盘
```

## 2. `qusb`：复合模式切换

`qusb` 是这块板管理 Type-C gadget 组合的工具。

```bash
qusb help
```

```
Usage: qusb [bind] [unbind] [showpid] [help]
            [setpid [-p] <PID>] [persist <PID>]

bind     - Binds configfs with USB gadget.
unbind   - stops/unbinds USB gadget.
setpid   - Sets the composition to given value.
    -p   - Set the composition as default (persist).
showpid  - Lists the available USB compositions.
persist  - Sets the composition as default from next reboot.
```

### 2.1 可用组合（`qusb showpid` 实测全表）

| PID | 组合 |
|---|---|
| `A4A1` | NCM |
| `4EE7` | ADB |
| `900E` | DIAG |
| `901C` | DIAG,UAC2 |
| `901D` | DIAG,ADB |
| `9015` | MASS_STORAGE,ADB |
| `9024` | RNDIS,ADB |
| `902A` | RNDIS,MASS_STORAGE |
| `902B` | RNDIS,ADB,MASS_STORAGE |
| `902C` | RNDIS,DIAG |
| `902D` | RNDIS,DIAG,ADB |
| `902F` | RNDIS,DIAG,MASS_STORAGE |
| `908C` | NCM,ADB |
| `90CA` | DIAG,UAC2,ADB |
| `90CB` | DIAG,UVC,ADB |
| `90CC` | DIAG,UAC2,UVC,ADB |
| `90DF` | DIAG,UVC |
| `90E0` | DIAG,UAC2,UVC |
| `9135` | DIAG,QDSS,ADB |
| `9136` | DIAG,QDSS |
| `F000` | MASS_STORAGE |
| `F00E` | RNDIS |

### 2.2 当前状态

```bash
qusb showpid | head -3
cat /sys/kernel/config/usb_gadget/adb/idVendor    # 0x05c6
cat /sys/kernel/config/usb_gadget/adb/idProduct   # 0x902d
# 0x902d = RNDIS,DIAG,ADB
ls /sys/kernel/config/usb_gadget/adb/functions/
# 实测: ecm.ecm ffs.dun mass_storage.0 qdss.qdss ffs.diag ffs.usb0 ncm.0 rndis.rndis
```

### 2.3 切换（**危险操作，先读 §3**）

```bash
# 临时切（重启恢复）
sudo qusb setpid 9024          # RNDIS,ADB

# 临时切 + 设为默认
sudo qusb setpid -p 9024

# 只设下次开机的默认（本次不变）
sudo qusb persist 9024
```

## 3. ⚠️ 切模式会断掉你现在的连接

**如果 ADB / RNDIS 是你跟板子唯一的通道，切换会立刻断开**，而且新模式下可能连不回来
（比如切到 `F000` 只有大容量存储，ADB 没了）。

安全做法：

1. **先确认有没有第二条通道**（串口 console / 网口 ssh / HDMI 上的终端）。
2. 没有第二条通道时，**不要自己切**；必须让用户在场，并说明最坏情况。
3. 切之前记下当前 PID，给回退命令：

```bash
CUR=$(cat /sys/kernel/config/usb_gadget/adb/idProduct)   # 0x902d
echo "当前: $CUR ；回退: sudo qusb setpid ${CUR#0x}"
```

4. 切完 `lsusb`（主机侧）或 `cat /sys/class/udc/a600000.usb/state`（板侧）验证。

> 硬复位：**断电重上电**一定能回到 `persist` 的默认组合。
> 这也意味着：**没设过 `persist` 之前，切换是断电可恢复的。**

## 4. RNDIS / NCM：把 Type-C 当网口

切到含 `RNDIS` 的 PID 后（如 `902D`、`9024`），板上会多一个 `usb0`：

```bash
ip -br link | grep usb
nmcli dev status | grep usb      # 实测: usb0 ethernet unmanaged
```

`unmanaged` 是 NetworkManager 没接管它（板上默认不配置），手工配：

```bash
sudo ip addr add 192.168.42.1/24 dev usb0
sudo ip link set usb0 up
ip -br a show usb0
```

主机侧（Linux）会看到一张 usb 网卡，同网段配 `192.168.42.2/24` 即可互通。

## 5. ADB

```bash
# 板侧
cat /sys/kernel/config/usb_gadget/adb/idProduct     # 必须是 0x902d 之类含 ADB 的
ls /sys/kernel/config/usb_gadget/adb/functions/     # 应有 ffs.usb0 / ffs.diag / ffs.dun
systemctl is-active usb                # adbd 相关服务
ps aux | grep -c adbd
```

主机侧 `adb devices` 能看到即可。**不要重复 unplug/plug**，先看 PID 对不对。

## 6. UVC（把板子当 USB 摄像头）

含 `UVC` 的组合：`90CB` `90CC` `90DF` `90E0`。
切过去后板子作为 USB 摄像头设备出现在主机上。
板上有 `gst-ai-usb-camera-app`（预览用）。

## 7. USB-A 口不识别设备

```bash
lsusb                       # 看设备在不在
lsusb -t                    # 看挂在哪个 hub 端口
sudo dmesg | grep -iE 'usb .*new .*device|usbhid|xhci' | tail -20
```

实测 HUB 是 **CH334**（`1a86:8091`）。

| 现象 | 判据 | 方向 |
|---|---|---|
| 设备完全没出现 | `dmesg` 无 `new ... device` | 供电/线材/HUB 端口 |
| 出现但驱动没绑 | `lsusb` 有，无对应 `/dev` | 缺驱动，看 `dmesg` |
| 随机掉线 | `dmesg` 有 `disconnect` | 供电不足（A 口总电流有限） |

## 8. 已知坑

| 现象 | 原因 | 处置 |
|---|---|---|
| 切 PID 后 ADB 掉了 | 新模式不含 ADB | 断电重上电回到默认；或串口/网口切回 |
| `usb0` 一直 `unmanaged` | NM 没接管 | 手工 `ip addr add` |
| `qusb: Invalid command` | 子命令拼错 | `qusb help` |
| `lsusb` 在板侧看不到自己 | 板子是 device，不是 host | 在**主机**侧看 |
| USB-A 设备供电不足 | A 口总电流有限 | 用带供电的 HUB |
| `/sys/class/udc/` 空 | gadget 驱动没起 | 查 `dmesg \| grep dwc3`，`qusb bind` |

## 9. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- `ls /sys/class/udc/` → `a600000.usb`，`state=configured`
- 当前 PID `0x902d`（RNDIS,DIAG,ADB），idVendor `0x05c6`
- configfs functions：`ecm.ecm ffs.dun mass_storage.0 qdss.qdss ffs.diag ffs.usb0 ncm.0 rndis.rndis`
- `qusb showpid` 列出 22 种组合（见 §2.1）
- USB-A 侧：`xhci-hcd/1p` → CH334 HUB(4p) → 键盘+鼠标
- `usb0` 在 `nmcli dev status` 里是 `unmanaged`
