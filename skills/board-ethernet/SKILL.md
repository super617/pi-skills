---
name: board-ethernet
description: "板端以太网: 这块板没有 SoC 自带 PHY,用的是 YT6801 PCIe 千兆网卡(0000:01:00.0)。网口不通/掉速/RJ45 灯不亮/吞吐低时用。含 PCIe 链路速率解读、ethtool 诊断、iperf3 测速、以及'ping 不通'的分层排查。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [ethernet, rj45, yt6801, pcie, ethtool, iperf3, network, nmcli]
    related_skills: [board-overview, board-pcie, board-debug, board-wireless]
---

# 板端以太网

## 1. 硬件事实（先纠正一个常见误解）

这块板**没有 SoC 自带的 RGMII PHY**。以太网是：

```
SoC PCIe0 ──► YT6801（Motorcomm 千兆网卡芯片，PCIe 设备）──► RJ45 J（带 LED）
```

```bash
lspci -nn | grep -i ethernet
# 0000:01:00.0 Ethernet controller [0200]: Motorcomm ... YT6801 ... [1f0a:6801] (rev 03)
ethtool -i eth0
# driver: yt6801 / version: 1.0.27 / bus-info: 0000:01:00.0
```

**后果**：网口有问题先看 **PCIe 链路**，不是 PHY 寄存器。
PCIe 没枚举 → 网卡根本不存在 → `eth0` 也不会出现。

## 2. 三层排查顺序（每层都有独立判据）

### 第 1 层：PCIe 有没有枚举

```bash
lspci -nn | grep -i 1f0a
# 期望: 0000:01:00.0 ... [1f0a:6801]
# 没有 → PCIe 或供电问题，看 board-pcie
```

```bash
# 链路速率（YT6801 是 PCIe 2.0 x1，2.5 GT/s 是正常值，不是降速）
cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed    # 2.5 GT/s PCIe
cat /sys/bus/pci/devices/0000:01:00.0/current_link_width    # 1
```

> **别把 `2.5 GT/s x1` 当成故障**。这块板网卡就是跑 PCIe 2.0 x1：
> `LnkCap: Speed 2.5GT/s, Width x1`，`LnkSta` 与之相同 = 已达到上限。
> 千兆以太网只需要 ~1 Gbps，2.5 GT/s × 1 lane = 2 Gbps 有效带宽，够用。

### 第 2 层：驱动绑定 + 网络接口

```bash
lsmod | grep yt6801
ls /sys/class/net/          # 期望有 eth0（另有 lo / wlan0 / p2p0 / usb0 / p2p-dev-wlan0）
ethtool -i eth0             # 确认 bus-info 对得上
sudo dmesg | grep -iE 'yt6801|1f0a:6801'
```

### 第 3 层：链路 + 地址

```bash
ethtool eth0 | grep -E 'Speed|Duplex|Link detected|Auto-negotiation'
# 实测接千兆交换机: Speed: 1000Mb/s  Duplex: Full  Link detected: yes
cat /sys/class/net/eth0/carrier        # 1 = 有载波
cat /sys/class/net/eth0/operstate      # up
ip -br a show eth0
nmcli dev status
```

## 3. 灯不亮

RJ45 有两个灯（link/act 与 speed），由 YT6801 直接驱动，**没有独立 sysfs 节点**。

```bash
# 唯一能间接确认的办法：链路状态 + 计数器
ethtool eth0 | grep -E 'Speed|Link detected'
ethtool -S eth0 | head -20
```

| 现象 | 判据 | 方向 |
|---|---|---|
| 灯全灭 + `Link detected: no` | `carrier=0` | 线/对端/PHY 自协商 |
| 灯亮但 ping 不通 | `Link detected: yes`，`ip a` 无地址 | 上层配置（见 §4） |
| 灯闪但丢包 | `ethtool -S` 里 errs/drop 增长 | 线材质量、对端、MTU |
| `Speed: 100Mb/s` | 协商降速 | 线材只通 2 对，或对端百兆 |

## 4. ping 不通的分层排查

```bash
# 1) 本机地址
ip -br a show eth0
# 2) 邻居表（ARP 有没有通）
ip neigh show dev eth0
# 3) 默认路由
ip route
# 4) 物理层到对端
ping -c 3 -I eth0 <网关>
# 5) DNS 单独一层
ping -c 3 114.114.114.114
ping -c 3 www.baidu.com
```

NetworkManager 是这块板的网络管理：

```bash
nmcli dev status
nmcli connection show
nmcli -f ipv4.method,ipv4.addresses connection show 'Wired connection 1'

# 手动配静态 IP
sudo nmcli connection modify 'Wired connection 1' \
    ipv4.method manual ipv4.addresses 192.168.1.50/24 ipv4.gateway 192.168.1.1
sudo nmcli connection up 'Wired connection 1'
```

> **DHCP 没拿到地址**时先看 `journalctl -u NetworkManager -b --no-pager | tail -30`，
> 不要先怀疑网卡。实测本机 `usb0` 是 unmanaged 的（USB gadget），与 eth0 无关。

## 5. 吞吐测试

```bash
# 板上没装 iperf3 服务端也能跑客户端
command -v iperf3            # 实测: 已安装

# 板子做客户端，PC 做服务端
iperf3 -c <PC_IP> -t 10 -P 4

# 板子做服务端
iperf3 -s
# PC: iperf3 -c <板子IP> -t 10 -P 4
```

实测基线（千兆直连、`-P 4`）：expect ≈ **900+ Mbit/s**。
明显低于 800 Mbit/s 就不是"正常波动"，要查：

```bash
# CPU 是否成为瓶颈（单核打满常见于小包）
top -b -n1 | head -12
# 重传 / 错误
ethtool -S eth0 | grep -iE 'err|drop|retry'
ss -s
```

## 6. 网卡统计怎么读

```bash
ethtool -S eth0
```

实测字段样例：

```
tx_bytes: 13411439        tx_packets: 139100
tx_bytes_good / tx_packets_good
tx_unicast_packets: 138927   tx_broadcast_packets: 0
tx_broadcast_packets_good: 22      ← 注意：有些 xx_broadcast_packets 恒 0，另有 _good 版才准
```

`ethtool --show-priv-flags eth0` 这块驱动**不支持**（返回 `netlink error: Operation not supported`），
别去调私有 flag。

## 7. 已知坑

| 现象 | 原因 | 处置 |
|---|---|---|
| 完全没 `eth0` | PCIe 没枚举 | 看 `board-pcie`；`lspci` 有没有 1f0a:6801 |
| 时有时无 | PCIe 供电/复位时序 | `lspci` 反复查；看 `dmesg` 有没有 link down |
| `LnkSta: 2.5GT/s x1` 以为是降速 | 本来就是 PCIe 2.0 x1 | 不是故障 |
| `ethtool --show-priv-flags` 报错 | 驱动不支持 | 忽略 |
| `ethtool -S` 某个 `*_broadcast_packets` 恒 0 | 计数器本身是这样实现的 | 看 `*_good` |
| ping 网关通、DNS 不通 | 只配了 IP 没配 DNS | `nmcli ... ipv4.dns` |

## 8. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- `lspci`：`0000:01:00.0 [1f0a:6801] YT6801`，`driver: yt6801 version 1.0.27`
- PCIe 链路：`LnkCap 2.5GT/s x1`，`LnkSta 2.5GT/s x1`（已达上限）
- `eth0`：`Speed 1000Mb/s / Full / Link detected: yes / Auto-negotiation: on`
- `nmcli dev`：`eth0 ethernet connected (Wired connection 1)`，`usb0 ethernet unmanaged`
- `iperf3` 已安装；`/sys/class/net/eth0/` 下**没有** LED 相关节点
