---
name: board-wireless
description: "板端无线: QCA1023 SDIO Wi-Fi(ath11k, wlan0) + HCI UART 蓝牙(hci0, /dev/ttyHS1)。连不上 Wi-Fi/蓝牙起不来/扫描不到/配对失败时用。含 nmcli 全流程、蓝牙开机自动 attach 的现状、以及这块板的固件与天线相关坑。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [wifi, bluetooth, ath11k, qca1023, hciattach, nmcli, bluetoothctl, rfkill]
    related_skills: [board-overview, board-ethernet, board-debug]
---

# 板端无线（Wi-Fi + 蓝牙）

## 1. 硬件与驱动

| 功能 | 器件 | 总线 | 内核驱动 | 接口 |
|---|---|---|---|---|
| Wi-Fi | QCA1023 | **SDIO** | `ath11k` / `ath11k_ahb` + `wlan` (ar6k) | `wlan0`（另有 `p2p0`） |
| 蓝牙 | 同模块 | **HCI UART** `/dev/ttyHS1` @3000000 | `btqca` + `hci_uart` | `hci0` |

```bash
lsmod | grep -E 'ath11k|wlan|btqca|hci_uart'
# 实测: ath11k_ahb 28672 / ath11k 520192 / wlan 5824512 / mac80211 / cfg80211 / btqca / hci_uart
cat /sys/class/net/wlan0/address      # dc:2e:97:af:4d:75（这台板子）
hciconfig -a                          # hci0 Bus: UART, BD Address: 48:4C:AF:97:2E:DC
```

## 2. Wi-Fi 全流程

### 2.1 现状检查（三步，缺一不可）

```bash
# 1) 硬件开关（rfkill）
rfkill list
# wlan0 的 phy0 必须 soft=0 hard=0
for r in /sys/class/rfkill/*; do echo "$r $(cat $r/name) type=$(cat $r/type) soft=$(cat $r/soft) hard=$(cat $r/hard)"; done

# 2) NetworkManager 有没有管它
nmcli radio
# 实测: WIFI-HW enabled / WIFI enabled

# 3) 接口存在且 up
ip -br a show wlan0
```

本机实测：`wlan0` 存在但 `disconnected`（没连任何 AP），`rfkill` 都是 `soft=0 hard=0`。

### 2.2 扫描与连接

```bash
nmcli dev wifi list ifname wlan0          # 扫描
nmcli dev wifi rescan ifname wlan0        # 强制重扫
nmcli dev wifi connect "SSID" password "密码" ifname wlan0
nmcli dev wifi connect "SSID" ifname wlan0            # 开放网络
```

API 隐藏 SSID：

```bash
nmcli connection add type wifi con-name "hidden" ifname wlan0 ssid "" \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "密码"
nmcli connection modify hidden 802-11-wireless.hidden yes
nmcli connection up hidden
```

### 2.3 验证

```bash
nmcli -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS dev show wlan0
iw dev wlan0 link            # 期望: Connected to xx:xx  SSID  freq  signal
ping -c 3 192.168.1.1        # 网关
ping -c 3 114.114.114.114    # 出网
ping -c 3 www.baidu.com      # DNS
```

> `iw` 会打印
> `libnl-genl-3.so.200: no version information available (required by iw)`
> —— **这是噪音，不影响功能**，别当故障。

### 2.4 带宽/速率

```bash
iw dev wlan0 link | grep -E 'freq|signal|bitrate'
nmcli -f GENERAL.HWADDR dev show wlan0
nmcli connection show --active
```

## 3. 蓝牙

### 3.1 现状（本机实测，重要）

这块板的蓝牙**已经由固件自动拉起**，不需要手工 `hciattach`：

```bash
hciconfig -a
# hci0: Type: Primary  Bus: UART
#       BD Address: 48:4C:AF:97:2E:DC  ACL MTU: 1024:7  SCO MTU: 60:8
#       UP RUNNING
systemctl is-active bluetooth       # active
bluetoothctl show | head -8
# Powered: yes  PowerState: on  Name: quectelpi
```

板上装了 `hciattach` / `qcom-hciattach` / `btattach` / `btmgmt`，但**正常开机不需要手动跑**。
只有在客户端起不来、且确认是 HCI 没 attach 时才手工试：

```bash
# 仅在 hci0 不存在时用
sudo hciattach /dev/ttyHS1 qca 3000000 flow
```

> `bt-autoconnect.service` 实测是 **failed** 状态。它的作用是"重连已配对的蓝牙音频设备"
> —— 没配对过音频设备时失败是**预期**的，不影响蓝牙本身可用。
> 别把它当成蓝牙坏了。

### 3.2 配对与连接

```bash
bluetoothctl
# 里面依次:
power on
agent on
default-agent
scan on
# 找到目标 MAC 后
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
connect AA:BB:CC:DD:EE:FF
scan off
exit
```

非交互一行版：

```bash
bluetoothctl --timeout 20 scan on
bluetoothctl devices                       # 列出已知设备
bluetoothctl connect AA:BB:CC:DD:EE:FF
bluetoothctl info AA:BB:CC:DD:EE:FF        # 看 Connected / Paired / Trusted
```

### 3.3 射频开关

```bash
ls /sys/devices/platform/rfkill/
# bt_en  wlan_en  ← 两个 GPIO 使能
cat /sys/devices/platform/rfkill/bt_en
echo 1 | sudo tee /sys/devices/platform/rfkill/bt_en     # 上电
echo 0 | sudo tee /sys/devices/platform/rfkill/bt_en     # 下电
```

**下电再上电之后 `hci0` 会消失**，需要重新 attach（见 §3.1）。

### 3.4 验证外设输入（键鼠）

```bash
cat /proc/bus/input/devices | grep -A3 -i 'bluetooth'
sudo evtest                    # 选设备，按键看事件
```

## 4. 已知坑

| 现象 | 判据 | 处置 |
|---|---|---|
| `nmcli radio` 显示 WIFI disabled | `rfkill` soft=1 | `nmcli radio wifi on` 或 `rfkill unblock wifi` |
| 扫不到任何 AP | `wlan0` 存在但 `iw dev wlan0 link` Not connected | 查天线、查 `sudo dmesg \| grep ath11k`、增大扫描超时 |
| 连上没 IP | `nmcli dev show` 无 IP4.ADDRESS | DHCP 问题；`journalctl -u NetworkManager` |
| `iw` 报 libnl 版本警告 | 见 §2.3 | 忽略（噪音） |
| 蓝牙 `hci0` 不存在 | `ls /sys/class/bluetooth/` | `bt_en=1` 后手工 `hciattach` |
| `bt-autoconnect.service` failed | `systemctl status` | 没配对音频设备时的正常现象 |
| `bluetoothctl` 找不到设备 | 没做 `scan on`，或 agent 未开 | §3.2 完整流程 |
| 连上后立刻断 | 对端需要配对确认 | `trust` + `pair` 顺序别省 |

## 5. Wi-Fi 和蓝牙互干扰

同一模块、共用天线时 2.4G Wi-Fi + 蓝牙 A2DP 会互相抢带宽。
判据：`iw dev wlan0 link` 里 `signal` 掉 10 dBm 以上，同时蓝牙音频卡顿。
处置：Wi-Fi 连 5 GHz（`nmcli dev wifi list` 看 `FREQ`），或用 USB 蓝牙适配器。

## 6. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- Wi-Fi：`ath11k` + `ath11k_ahb` + `wlan` 已加载；`wlan0` MAC `dc:2e:97:af:4d:75`；
  状态 `disconnected`（未配置 AP）；`nmcli radio` → WIFI-HW enabled / WIFI enabled；
  rfkill `phy0 soft=0 hard=0`
- 蓝牙：`hci0` UART，MAC `48:4C:AF:97:2E:DC`，`UP RUNNING`，`bluetooth.service active`，
  `Powered: yes`，名 `quectelpi`；`bt-autoconnect.service` 为 failed（预期）
- 板上命令：`nmcli` `iw` `hciconfig` `bluetoothctl` `btmgmt` `hciattach` `qcom-hciattach`
  `btattach` 都有；`myftm`/`ath6kl-utils`（SDK 文档提到的射频产测工具）**未确认存在**
