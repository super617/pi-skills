---
name: board-5g
description: "板端 5G 模块: RG520N 走 PCIe1 + MHI + QRTR(不是 USB QMI)。插了不识别/QRTR 没起来/拨号失败时用。含 remoteproc modem 状态、上电时序的固化位置、和 M.2 NVMe 二选一的约束。当前这台板没插模组。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [5g, modem, rg520n, pcie, mhi, qrtr, remoteproc, quectel-CM]
    related_skills: [board-overview, board-pcie, board-power, board-debug]
---

# 板端 5G（RG520N）

## 1. 数据通路

```
RG520N (M.2, PCIe1 0001:00:00.0)
   ├── PCIe 数据面
   └── MHI ──► QRTR（控制面，QMI over QRTR）
                  └── quectel-CM / quectel-qmi-proxy / ModemManager
SoC 侧: &remoteproc_mpss → firmware qcom/qcs6490/modem.mdt
```

**关键：这块板的 5G 不是 USB 模组**。不要拿 USB 那套 `/dev/ttyUSB*` + `AT` 口思路套。

板上有：`quectel-CM`（QConnectManager 1.6.7）、`quectel-qmi-proxy`、
`quectel-mbim-proxy`、`quectel-atc-proxy`、`modem-start-stop.service`。
**没有** `qrtr-lookup` / `mmcli`（ModemManager 未装）。

## 2. 当前这台板的状态（2026-11-13 实测）

```bash
lspci -nn | grep 0001        # 只有 0001:00:00.0 桥，下面没设备
ls /dev/mhi*                 # 不存在
ls /sys/class/wwan*          # 不存在
lsmod | grep -E 'pcie_mhi|qrtr'   # pcie_mhi 已加载, qrtr/qrtr_smd 已加载
```

`remoteproc` 状态：

```bash
for r in /sys/class/remoteproc/*; do
  echo "$(basename $r): $(cat $r/firmware 2>/dev/null) state=$(cat $r/state)"
done
```

实测：

```
remoteproc0: qcom/qcs6490/modem.mdt  state=offline     ← 调制解调器（5G 用这个）
remoteproc1: qcom/qcs6490/wpss.mbn   state=offline
remoteproc2: qcom/qcs6490/adsp.mdt   state=running
remoteproc3: qcom/qcs6490/cdsp.mdt   state=running
```

**`modem.mdt = offline` 是"没插 5G 模组"的正常状态**，不是故障。
插上模组后它会被拉起来（由 `modem-start-stop.service` 触发）。

## 3. 插上模组后的检查顺序

```bash
# 1) PCIe 枚举
lspci -nn | grep '^0001:01'
sudo dmesg | grep -iE 'pcie.*0001|mhi|link up'

# 2) MHI 节点
ls /dev/mhi*
sudo dmesg | grep -iE 'mhi'

# 3) QRTR
ls /dev/qrtr* /dev/qrtr-ns /dev/qrtr-tun 2>/dev/null
lsmod | grep qrtr

# 4) modem 固件拉起来
for r in /sys/class/remoteproc/*; do
  [ "$(cat $r/firmware 2>/dev/null)" = "qcom/qcs6490/modem.mdt" ] && echo "$r state=$(cat $r/state)"
done
# 手工拉（正常由 service 做）
sudo sh /etc/initscripts/start_stop_modem.sh start
sudo sh /etc/initscripts/start_stop_modem.sh stop

# 5) WWAN 接口
ip -br link | grep -E 'wwan|rmnet'
ls /sys/class/wwan* 2>/dev/null
```

## 4. 拨号

```bash
quectel-CM -h          # 看全部参数
quectel-CM -s <APN>    # 最常见：只给 APN
quectel-CM -s <APN> <user> <pass> 3      # APN + 账号 + MsChapV2
quectel-CM -4 -s <APN>                   # 强制 IPv4
quectel-CM -v -f /tmp/qcm.log -s <APN>   # 调试：verbose + 存日志
```

后台跑：

```bash
sudo systemctl cat quectel-cm@.service    # 模板单元
sudo systemctl start quectel-cm@<pdn>.service
journalctl -u quectel-cm@<pdn> -b --no-pager | tail -30
```

AT 通道（模组侧指令）走代理：

```bash
quectel-atc-proxy -d <atc_dev> -i <netcard>
quectel-qmi-proxy -d /dev/cdc-wdm0 -i wwan0
```

> 具体设备名随模组枚举结果变化，**先 `ls /dev | grep -E 'cdc-wdm|ttyUSB|mhi'` 确认**，
> 不要照抄默认值。

## 5. 上电时序（已固化，不要自己加 delay）

DTS/驱动里已经写死，改不了也不需要改：

```
tlmm24 (3V3 使能, pcie1_pwr_en_vreg) 拉高
  └─ delay 3000 ms
tlmm49 PWRKEY 脉冲 1000 ms（低有效）
  └─ PERST# (tlmm2) 释放
  └─ 等链路 10000 ms
  └─ 枚举 → MHI/QRTR
```

相关控制脚：`pwkey-gpios = tlmm49`、`perst-gpios = tlmm2`、3V3 `tlmm24`、
电平使能 `tlmm93`、`device_oe_en` `tlmm9`。

确认这些 regulator 上电：

```bash
for r in /sys/class/regulator/*; do
  n=$(cat $r/name 2>/dev/null)
  case "$n" in *pcie1*|*m2*|*M2*) echo "$n=$(cat $r/state 2>/dev/null)";; esac
done
```

## 6. 硬约束

1. **PCIe1 与 M.2 NVMe 二选一** —— 同一个物理插槽，插了 5G 就不能插 SSD。
2. **冷启动可能不认识卡**（history：`wait-for-link-ms` / `pwkey-pulse-ms` / `delay-ms`
   就是为这个调出来的）。现象：冷启动 `lspci` 空，热重启就有。
3. **空槽不能阻塞开机** —— PCIe 枚举改成延后执行，所以开机时 `lspci` 里 0001 下暂时空是正常的。
4. **供电要求**：5G 发射峰值电流大，Type-C 供电需 **9V/3A 或 5V/5A**。
   供电不足表现为：拨号成功但一发数据就掉线、或模组反复重启。
5. **热**：5G 发射会显著抬温，见 `board-fan` / `board-power` 的 BCL 部分。

## 7. 已知坑

| 现象 | 判据 | 处置 |
|---|---|---|
| `0001:00:00.0` 下无设备 | `lspci` 空 | 没插模组，或冷启动未枚举（重启再试） |
| 插了模组但无 `/dev/mhi*` | `dmesg \| grep mhi` 无输出 | PCIe 没链路；查供电/时序 |
| `modem.mdt` 一直 offline | remoteproc state | 手工 `start_stop_modem.sh start`；查固件是否存在 |
| 拨号成功但不通 | `ip -br link` 有 wwan 但无 IP | 查 APN/鉴权；`quectel-CM -v` |
| `mmcli: command not found` | ModemManager 未装 | 用 `quectel-CM` |
| `qrtr-lookup` 不存在 | 未装 iproute2 qrtr 工具 | 用 `ls /dev/qrtr*` + `dmesg` |
| `start_stop_modem.sh: [: start: unexpected operator` | 脚本用 `==`，被 `/bin/sh`(dash) 解析 | **无害**（脚本本身会走到正确分支之外），但说明脚本没在空槽下做清理 |

## 8. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- 当前**未插** 5G 模组：`lspci` 无 `0001:01:*`、无 `/dev/mhi*`、无 `/sys/class/wwan`
- `pcie_mhi` / `qrtr` / `qrtr_smd` 模块已加载
- `remoteproc0` = `qcom/qcs6490/modem.mdt`，`state=offline`
- `modem-start-stop.service` = active (exited)
- 工具：`quectel-CM` `quectel-qmi-proxy` `quectel-mbim-proxy` `quectel-atc-proxy` 存在；
  `mmcli`、`qrtr-lookup` 不存在
