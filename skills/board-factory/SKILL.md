---
name: board-factory
description: "板端工厂模式(产测模式): 0 字节标记文件 /var/persist/fct_done_flag 决定整机走产测还是出货。含四条交叉判据、进入/退出方法、AT 口(ttyGS0/ttyACM)只在工厂模式出现、MAC/NV 写号文件位置、persist 被擦后怎么恢复。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [factory, fct, 产测, atci, mac, nv_data, persist, typec_ucsi]
    related_skills: [board-overview, board-usb, board-power, board-fan]
---

# 工厂模式（产测模式）

**一个 0 字节的标记文件决定整机行为**：

```bash
ls /var/persist/fct_done_flag
# 存在 → 正常（出货）模式
# 不存在 → 工厂（产测）模式  ← ★ 注意是"文件不在 = 工厂"
```

本机当前：**文件存在** → 正常模式。

## 1. 四条交叉判据（别只看一条）

```bash
# 1) 标记文件
ls -l /var/persist/fct_done_flag 2>/dev/null || echo "NO_FLAG → FACTORY"

# 2) typec_ucsi 的 fct_client 参数
cat /sys/module/typec_ucsi/parameters/fct_client     # Y=工厂 N=正常

# 3) atci 服务（工厂模式才需要跑）
systemctl is-active atci       # 工厂: active  正常: inactive

# 4) 风扇温控（工厂模式下不跑，避免和 AT+FANON 抢 PWM）
systemctl is-active fan_ctrl   # 工厂: inactive 正常: active

# 5) AT 串口节点（仅工厂模式出现）
ls /dev/ttyGS0                 # 板上 gadget 串口
ls /dev/ttyACM*                # 主机侧看到的 AT 口
```

本机实测（正常模式）：

```
/var/persist/fct_done_flag  存在（0 字节，root:root）
fct_client                  N
atci                        inactive（enabled，被 Condition 拦住）
fan_ctrl                    active
/dev/ttyGS0                 不存在
/dev/ttyACM*                不存在
```

## 2. 两种模式的行为差异

| 组件 | 工厂模式（flag 缺失） | 正常模式（flag 存在） |
|---|---|---|
| `atci.service` | **active**（AT 指令守护） | inactive（`ConditionPathExists=!flag` 拦住） |
| `fan_ctrl.service` | **inactive**（风扇由 AT 独占） | active（按温度调 PWM） |
| `/dev/ttyGS0` | 存在（gadget 串口） | 不存在 |
| `/dev/ttyACM*`（主机侧） | 存在 | 不存在 |
| `fct_client` | `Y` | `N` |
| 启动速度 | 慢（等 AT 初始化） | 快 |

## 3. 进入 / 退出工厂模式

```bash
# 进入（删除 flag）—— 需要 root
sudo rm -f /var/persist/fct_done_flag
sudo sync
sudo reboot

# 退出（建 flag）
sudo touch /var/persist/fct_done_flag
sudo sync
# 退出时要把 AT 独占的风扇控制交回温控
sudo systemctl start fan_ctrl
```

> **`/var/persist` 是独立分区**（`/dev/sda2`，ext4，30M）。
> 刷机/重烧镜像**不一定**清掉它，但手工 `mkfs` 或全盘擦除会。
> 所以"刷完机风扇不转/AT 起不来"先查这个文件。

## 4. 写号数据在哪

```bash
ls -la /var/persist/
```

实测内容：

| 文件 | 内容 |
|---|---|
| `mac_addr` | **`DC:2E:97:AF:4E:A2`**（写号的 MAC，注意与 `wlan0` 的 `dc:2e:97:af:4d:75` 不同） |
| `NV_data/` | NV 数据目录 |
| `fct_done_flag` | 产测完成标记 |
| `hs/` `probe/` | 产测辅助文件 |
| `qpi-config.ini.uart4on.bak` | UART4 打开时的配置备份 |
| `powerwatch.sh` `ocp-stress/` | 电源监控/压力测试 |

```bash
# 读当前写号的 MAC
cat /var/persist/mac_addr
# 对比实际网卡 MAC
cat /sys/class/net/wlan0/address
cat /sys/class/net/eth0/address
hciconfig hci0 | grep 'BD Address'
```

## 5. AT 通道（只在工厂模式）

```bash
# 板侧 gadget 串口
ls -l /dev/ttyGS0

# atci 守护
systemctl status atci --no-pager
ls -l /usr/sbin/atcid /usr/sbin/atci_init.sh
tail -30 /var/log/atci* 2>/dev/null || journalctl -u atci -b --no-pager | tail -30
```

主机侧（工厂模式下）：

```bash
# 主机上
ls /dev/ttyACM*        # 通常是 ttyACM1 是 AT 口，ttyACM0 是 CH340
```

> **正常模式下 `/dev/ttyACM*` 不存在是正常的**，不要去"修"它。

## 6. persist 全擦后的恢复

如果 `/var/persist` 被清空（换板、误 `mkfs`）：

1. 没有 `fct_done_flag` → **开机就进工厂模式**（这是设计的安全默认）
2. 风扇不转（`fan_ctrl` 被 Condition 拦住）→ **不是故障**
3. AT 口出现 → 需要用产测流程重新写号
4. `mac_addr` 丢失 → 网卡会用芯片的默认 MAC，**与标签不符**

恢复顺序：

```bash
# 1) 先确认 mount 正常
mount | grep persist
ls -la /var/persist/

# 2) 补回写号数据（值从标签/产测记录来，不要自己编）
sudo sh -c 'echo "DC:2E:97:AF:4E:A2" > /var/persist/mac_addr'

# 3) 标记产测完成
sudo touch /var/persist/fct_done_flag
sudo sync

# 4) 把风扇交回温控
sudo systemctl start fan_ctrl
systemctl is-active fan_ctrl        # active 才算恢复
```

## 7. 已知坑

| 现象 | 判据 | 处置 |
|---|---|---|
| 风扇不转 | `[ -f /var/persist/fct_done_flag ]` 为假 | 工厂模式，正常；或补 flag |
| 开机很慢 | `atci` active | 工厂模式在跑 AT 初始化 |
| 找不到 `/dev/ttyACM*` | 正常模式 | **正常**，别修 |
| `atci` 显示 inactive 但 enabled | `ConditionPathExists=!flag` | 正常模式下的预期 |
| 刷完机网络 MAC 变了 | `/var/persist/mac_addr` 和 `wlan0` 不一致 | 工厂写号没做，或 persist 被清 |
| `fct_client = N` 却进不了正常模式 | flag 文件在不在 | 两者要一起看 |

> **`mac_addr` 与 `wlan0` 的 MAC 不同是实测事实**（`DC:2E:97:AF:4E:A2` vs
> `dc:2e:97:af:4d:75`）。不要以为写号文件等于网卡实际 MAC —— 以太网/蓝牙/Wi-Fi
> 各自从不同地方取 MAC。

## 8. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- `/var/persist/fct_done_flag` **存在**（0 字节，root:root，日期 May 30 2025）→ 正常模式
- `fct_client = N`；`atci` = inactive（enabled）；`fan_ctrl` = active
- 无 `/dev/ttyGS0`、无 `/dev/ttyACM*`
- `/var/persist/mac_addr` = `DC:2E:97:AF:4E:A2`；
  `wlan0` = `dc:2e:97:af:4d:75`；`hci0` = `48:4C:AF:97:2E:DC`
- `/var/persist` 挂载点 `/dev/sda2`，ext4，30M
