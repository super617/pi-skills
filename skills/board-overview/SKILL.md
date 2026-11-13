---
name: board-overview
description: "Quectel PI H1 (QCS6490) 板端总览: 这块板是什么、现在跑的是 Debian 还是 Ubuntu、开机自检看什么、两套 OS 的工具差异表、skill 之间的分工。任何板端任务先读这个确认环境。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [board, overview, qcs6490, quectel, debian, ubuntu, self-check]
    related_skills: [board-debug, board-display, board-audio, board-gpio]
---

# 板端总览（先读这一节）

你做事的这台机器是 **Quectel PI H1**，SoC 是 QCS6490（QSM565DP-WF）。
你通过 pi 在**板子内部**运行，所以：

- **不要**提议 adb / 主机推文件 / 改主机代码。板子就是本机。
- **不要**提议 `bitbake` / 重新编译内核 / 烧录镜像。那是 SDK 主机的事，不在这台机器上。
- 你能做的：读 sysfs / procfs / debugfs、跑 `systemctl`、`journalctl`、v4l2、gst、
  pipewire、I2C、GPIO、NPU 推理。**先取证，再下结论。**

## 1. 先确认环境（每次会话第一条命令）

```bash
bash ~/.pi/agent/pi-skills/scripts/board-check.sh
```

它会打印：OS 与版本、内核版本、当前用户与权限、显示/音频/网络/存储/NPU 的可用性、
以及缺失的工具清单。**不要凭记忆假设工具存在**，以它的输出为准。

手工等价的最小集合：

```bash
cat /etc/os-release | head -3          # Debian 13 trixie / Ubuntu 26.04
uname -r                               # 6.6.116-qli-1.7-ver.1.1（随版本变化）
id                                     # ★ 决定哪些操作需要 sudo
who                                    # 桌面会话是不是有人登录
cat /proc/device-tree/model            # Quectel Technologies, Inc. QuecPi Alpha
```

### 用户与权限（实测，重要）

| 事实 | 影响 |
|---|---|
| 桌面用户是 `p`（uid 1001），组：`sudo audio video users input dialout` | 音视频/GPIO 多数不需要 root |
| `p` 有 sudo，但**需要密码** | 不要写 `sudo -n` 的自动化；`sudo -n cmd` 会直接失败 |
| 从 adb/串口进来的 shell 是 **root** | root 下跑 GUI 命令要自己设 `XDG_RUNTIME_DIR` / `DBUS_SESSION_BUS_ADDRESS` |
| `dmesg_restrict=1` | 普通用户 `dmesg` 会失败，需要 `sudo dmesg` |

### 桌面会话变量（root 下跑桌面相关命令必设）

```bash
# 桌面用户 p 的会话（uid 1001）
export XDG_RUNTIME_DIR=/run/user/1001
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus

# 以 p 身份跑一条命令
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
    wpctl status
```

音频（pipewire）、截图（portal）、weston/gnome 相关命令**没有这两个变量会直接报错**，
报错长这样：`Could not connect to PipeWire` / `XDG_RUNTIME_DIR is invalid or not set`。
看到这个先设变量，不要以为是服务没起。

## 2. OS 差异：Debian 13 vs Ubuntu 26.04

同一份 BSP 装在两种 rootfs 上。**大部分东西一样，工具集不一样**，这是最容易踩的坑。

| 能力 | Debian 13 (trixie) | Ubuntu 26.04 | 板端通用写法 |
|---|---|---|---|
| 桌面 | GNOME 48 / Wayland | GNOME（更新的版本）/ Wayland | 都走 `XDG_RUNTIME_DIR` |
| 音频控制 | `wpctl`（有），**`pactl` 没有** | `wpctl`（有），`pactl` 没有 | 一律用 `wpctl`，别写 `pactl list` |
| 截图 | 无 `gnome-screenshot`、无 `grim` | 同样没有 | 用 GNOME Screenshot **portal**（见 board-screenshot） |
| I2C 工具 | 无 `i2cdetect`/`i2cget` | 无 | `/sys/bus/i2c/devices/*/name`，或 `apt install i2c-tools` |
| GPIO 工具 | 无 `gpioset`/`gpioget`；有 `rgs` + `liblgpio.so.1` | 同 | `rgs`，或 python `periphery` |
| `curl` / `git` | 都有 | `curl` 有，**`git` 没有** | 用 `python3 -c` 的 urllib 代替 |
| python GTK | `python3-gi` + GTK4 + libadwaita | 同（版本更高） | 都可用 |
| 包管理 | `apt`（deb.debian.org 可达） | `apt` | 装工具前先问用户 |

其它一律按「一样」处理，但**别把上表背下来当结论**——用
`bash ~/.pi/agent/pi-skills/scripts/board-check.sh` 实测确认。

## 3. 这块板的硬件速览

| 子系统 | 器件 | 板端入口 |
|---|---|---|
| 显示 | **LT9611UXD**（HDMI 桥，I2C 0-0041）+ DSI 屏 `8.0inch-panel`（I2C 3-0045，触摸 GT911 3-0014） | `board-display` |
| 音频 | WCD9370（SoundWire）+ AW8010 功放 + LT9611 I2S；PAL → PipeWire | `board-audio` |
| 摄像头 | 双 MIPI-CSI，IMX219；camx(QMMF) 与 camss(V4L2) 两套栈 | `board-camera` |
| 以太网 | **YT6801（PCIe 网卡，不是 SoC 自带 PHY）** | `board-ethernet` |
| 无线 | QCA1023（SDIO Wi-Fi）+ HCI UART 蓝牙 | `board-wireless` |
| 存储 | UFS 115G（FORESEE C2G072）+ SD 卡 + 可选 M.2 NVMe | `board-storage` |
| 扩展口 | 40Pin：GPIO / I2C9 / SPI10 / UART12 / PWM / 3 路 ADC(1.8V max) | `board-gpio` |
| 算力 | Adreno GPU + CDSP NPU（HTP v68，12 TOPS）+ Venus VPU | `board-accel` |
| 电源 | PM7250B + PM7325 + PM8350C + PMK8350 | `board-power` |
| 风扇 | emc2303（`hwmon*/name == "pwmfan"`）+ `fan_ctrl.service` | `board-fan` |
| 5G | RG520N（PCIe + QRTR） | `board-5g` |
| USB | Type-C（USB3.1 + DP Alt，SGM7220 CC）+ CH334 HUB + `qusb` 复合模式 | `board-usb` |

## 4. 出问题时的固定顺序

不要一上来就猜。按这个顺序，每步都有客观判据：

1. **这个设备节点/服务存在吗** —— `ls`, `systemctl status`, `cat /sys/class/...`
2. **驱动加载了吗、probe 成功了吗** —— `sudo dmesg | grep -i <驱动名>`
3. **上层栈起来了吗** —— `journalctl -b --no-pager | grep -i <pal|pipewire|cam|agm>`
4. **配置对不对** —— 读 sysfs 里的当前值，别读文档里的默认值
5. **只有到这一步才看代码**

前四步都拿不到数据就别下结论，直接说「这条还没验证」。

## 5. 只读 / 有副作用的操作分级

| 级别 | 例子 | 做法 |
|---|---|---|
| 只读 | `cat`, `ls`, `dmesg`, `journalctl`, `wpctl status`, `v4l2-ctl --list-*` | 随便跑 |
| 短暂影响 | `aplay`/`tinyplay` 出声、开一次相机、截一张图 | 跑之前说一句要出声/占用相机 |
| 改状态但可回退 | 点 LED、拉 GPIO、切音频 sink、改音量、`echo 1 > bt_en` | 先给回退命令，再动手 |
| 可能挂死 | 切 USB 复合模式（`qusb setpid`）、DSI 面板重配、相机 + reboot | **必须先问用户**，并说明最坏情况 |

相机有个已复现的坑：**用过相机之后 reboot 会卡死**（详见 `board-camera`）。
所以「用完相机记得正常 stop 流」，不要直接断电。

## 6. 实测记录

- 环境：Debian 13 (trixie)，kernel `6.6.116-qli-1.7-ver.1.1`，GNOME Shell 48.7，Wayland
- 桌面用户 `p` (uid 1001)，`sudo` 需密码；adb shell 为 root
- 验证日期：2026-11-13
- 已实测结论：`pactl` 不存在 / `gnome-screenshot` 未装 / `i2cdetect` 未装 /
  `rgs` 存在但无 help 输出 / `liblgpio.so.1` 存在但无 `liblgpio.so` 开发软链 /
  `dmesg_restrict=1` / GNOME Screenshot portal 可用（`--interactive false` 直接出图）
