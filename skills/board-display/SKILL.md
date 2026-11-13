---
name: board-display
description: "板端显示排查: HDMI 经 LT9611 桥(不是 SoC 原生)、怎么用 bridge_chains 判定哪条桥在点亮、DSI 屏与 HDMI 互斥、DP over Type-C、分辨率/EDID 读取、GStreamer 上屏 sink 选择。屏不亮/分辨率不对/黑屏时用。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [display, hdmi, dsi, lt9611, drm, edid, wayland, dp, gstreamer]
    related_skills: [board-overview, board-debug, board-screenshot, board-accel]
---

# 板端显示

## 1. 最容易搞错的一件事

**这块板的 HDMI 不是 SoC 原生输出**，路径是：

```
SoC DSI → LT9611（DSI→HDMI 桥，I2C 0x41 或 0x2b）→ HDMI 连接器 J2001
```

后果：sysfs 里 DRM 连接器的名字**不代表物理接口**，而且**不同内核版本名字不一样**。
本机实测（kernel 6.6.116）是 `card0-HDMI-A-1`；SDK 文档记录的旧内核（6.6.52）
是 `card0-DSI-1`。**永远不要按名字硬编码，先列出来。**

```bash
ls /sys/class/drm/
for c in /sys/class/drm/card*-*/status; do echo "$c = $(cat $c)"; done
```

## 2. 判定「到底哪条桥在点亮」—— 唯一可靠方法

```bash
sudo cat /sys/kernel/debug/dri/0/bridge_chains
```

本机实测输出（2026-11-13）：

```
encoder[31]
	bridge[0] type: 0, ops: 0x0
	bridge[1] type: 11, ops: 0x7, OF: .../hdmi-bridge@41:lontium,lt9611uxd
encoder[33]
	bridge[2] type: 10, ops: 0xd
	bridge[3] type: 0, ops: 0x0, OF: .../phy@88e8000:qcom,sc7280-qmp-usb3-dp-phy
	bridge[4] type: 10, ops: 0x4, OF: /pmic-glink/connector@0:usb-c-connector
encoder[36]
	bridge[5] type: 10, ops: 0xd
	bridge[6] type: 10, ops: 0x0, OF: /dp-connector:dp-connector
```

读法：

- `lt9611uxd` / `lt9611uxc` 出现 → 走 **HDMI 桥**
- `qmp-usb3-dp-phy` + `usb-c-connector` → 走 **DP over Type-C**
- `dp-connector` → DP/eDP

再看谁在用：

```bash
sudo cat /sys/kernel/debug/dri/0/clients
# command / dev / master / uid —— gnome-shell、firefox 之类出现说明桌面在这上面
```

> **两个 LT9611 变体的 dmesg 噪声不同版本不一样**，别当故障：
> - 本机（6.6.116）：`lt9611uxd 0-0041: MCU HPD ready` 正常，**UXD 在用**；
>   `lt9611uxc 0-002b: Waiting for LT9611UXD probe` 反复刷是**预期噪声**。
> - 旧内核（6.6.52，SDK 文档记录）：相反 —— UXD probe 失败，回退到 UXC。
>
> 判据只有一条：`bridge_chains` 里哪个 OF 节点在 encoder 链上。

## 3. 连接器与模式

```bash
# 当前接了什么
for c in /sys/class/drm/card0-*/status; do echo "$(basename $c) = $(cat $c 2>/dev/null)"; done

# 支持的模式（HDMI 显示器给的 EDID 模式）
head -20 /sys/class/drm/card0-HDMI-A-1/modes

# EDID 原始数据（256 字节 = 完整；0 字节 = 没读到）
wc -c < /sys/class/drm/card0-HDMI-A-1/edid
od -An -tx1 /sys/class/drm/card0-HDMI-A-1/edid | head -4

# 当前实际分辨率（fb 虚拟尺寸）
cat /sys/class/graphics/fb0/virtual_size      # "2560,1440" = WxH

# 桥当前协商出的时序（LT9611 自己报）
sudo dmesg | grep -iE 'hactive|vactive|framerate|vic'
```

本机实测：接了 2560×1440@60 的 HDMI 显示器，LT9611 报
`hactive=2560, vactive=1440, framerate=60`。

## 4. 两块屏互斥（改之前必须知道）

| 通道 | SoC 资源 | 备注 |
|---|---|---|
| MIPI DSI 屏（微雪 8.0"，1280×800@60） | **DSI0** | 触摸 GT911 在 `i2c3 0x14` |
| Micro HDMI（LT9611 桥） | **DSI1** | 桥在 `i2c0 0x2b`(UXC) / `0x41`(UXD) |

**两者共用 MDSS DSI 资源，只能二选一。** 厂商 DTS 注释明确写了：
接 LCD panel 时 LT9611 不 probe，避免整个声卡 probe defer 导致无声卡。

所以：**「HDMI 没输出」先确认是不是接了 DSI 屏**。两条都在时不是配置问题，是硬件互斥。

## 5. DSI 屏在本机的实际状态

```bash
ls /sys/bus/i2c/devices/ | grep -E '3-0045|3-0014'
cat /sys/bus/i2c/devices/3-0045/name        # 8.0inch-panel
cat /sys/bus/i2c/devices/3-0014/name        # gt911（触摸）
sudo dmesg | grep -iE 'ws_touchscreen|8inch|ws_panel'
```

本机实测（未接 DSI 屏，只接 HDMI）：

```
ws_touchscreen 3-0045: I2C read failed: -6
Didn't read REG_ID reg: -6 maybe panel is not connected
```

→ **`-6` (ENXIO) 是「没接这块屏」的预期结果，不是驱动坏了**。
DSI 屏接上后这两行会消失，`/sys/class/drm/` 会多出 DSI 连接器。

## 6. DP over Type-C

```bash
ls /sys/class/typec/
for t in /sys/class/typec/port*; do
  echo "$(basename $t) data_role=$(cat $t/data_role 2>/dev/null) power_role=$(cat $t/power_role 2>/dev/null)"
done
sudo dmesg | grep -iE 'typec|sgm7220|dp alt|qmp'
```

本机实测：`port0 data_role=host [device] power_role=source [sink]` → 当前是 host 侧供电。
接 DP 显示器后 `card0-DP-1` 会从 `disconnected` 变 `connected`。

## 7. 上屏：GStreamer sink 怎么选

板上同时有这几个 sink，**选错就是"能出帧但看不到"**：

```bash
export GST_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/gstreamer-1.0:/usr/lib/gstreamer-1.0
gst-inspect-1.0 waylandsink | grep -E 'Long-name|Rank'
gst-inspect-1.0 kmssink    | grep -E 'Long-name|Rank'
gst-inspect-1.0 | grep -iE 'waylandsink|kmssink|gtkwaylandsink'
```

| sink | 适用 | 注意 |
|---|---|---|
| `waylandsink` | GNOME/Wayland 桌面里播放 | 需要 `WAYLAND_DISPLAY` + `XDG_RUNTIME_DIR` |
| `kmssink` | 没桌面、直接占 DRM | 会抢屏，桌面会退到别的输出 |
| `gtkwaylandsink` | GTK 应用内嵌 | 少见 |
| `autovideosink` | 让它自己挑 | 桌面里通常选到 waylandsink |

root shell 里播放必须先设会话变量，否则 `autovideosink` 会挑到 kmssink 或直接失败：

```bash
export XDG_RUNTIME_DIR=/run/user/1001
export WAYLAND_DISPLAY=wayland-0
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
```

## 8. 硬解播放（VPU）

板上有 `v4l2h264dec` / `v4l2h265dec`（Venus），**没有软件解码器**（`avdec_h264` 缺失）：

```bash
gst-launch-1.0 -e filesrc location=/home/p/test.mp4 ! qtdemux ! h264parse \
    ! v4l2h264dec capture-io-mode=5 output-io-mode=5 ! videoconvert ! autovideosink
```

怎么证明真走了硬解、没偷偷软解 → 见 `board-accel`。

## 9. 已知坑

| 现象 | 判据 | 处置 |
|---|---|---|
| HDMI 无输出 | `bridge_chains` 里没有 lt9611 | 查 `i2c0` 上 0x41/0x2b 是否 probe；查 `enable-gpios` 5V |
| 分辨率不对 | `fb0/virtual_size` vs `modes` 首行 | Wayland 下由合成器决定；不要手改 sysfs |
| 插拔后不亮 | LT9611 需要 ≥5s 间隔 | 等 5 秒再插 |
| `edid` 是 0 字节 | `wc -c` | 显示器没给 EDID / 线材只过 TMDS；换线 |
| DSI 屏不亮 | `dmesg \| grep ws_touchscreen` 报 `-6` | 物理没接或 FPC 未插好 |
| 截图黑屏 | — | 见 `board-screenshot`，锁屏时截不到 |

## 10. 实测记录

- 2026-11-13，Debian 13，kernel `6.6.116-qli-1.7-ver.1.1`，GNOME 48.7 / Wayland
- 物理接的是 HDMI 显示器（2560×1440@60），DSI 屏未接
- 连接器：`card0-HDMI-A-1=connected`，`card0-DP-1/DP-2=disconnected`，
  `card0-Writeback-1=unknown`；**没有 DSI 连接器节点**（屏未接）
- 活跃桥：`encoder[31] → bridge[1] OF: hdmi-bridge@41:lontium,lt9611uxd`
- EDID 256 字节有效；`fb0/virtual_size = 2560,1440`
- 无 `/sys/class/backlight/`（DSI 屏未接时的正常现象）
- `modetest` 未安装；`v4l2-ctl`、`gst-inspect-1.0` 可用
