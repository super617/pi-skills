---
name: board-fan
description: "板端风扇与温控: 板载 PWM 风扇走 pwmfan hwmon + fan_ctrl.service(每 5 秒按 CPU 温度调 PWM)。风扇不转/一直全速/转速读不到/想临时手动调速时用。含实测阈值表(40/60/75°C → 0/85/170/255)。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [fan, thermal, pwm, hwmon, emc2303, cooling, temperature]
    related_skills: [board-overview, board-power, board-gpio, board-debug]
---

# 板端风扇 / 温控

## 1. 硬件与软件

板载风扇由 **emc2303**（风扇控制器，I2C `1-002c`）驱动，暴露成 hwmon，
**名字是 `pwmfan`**（不是 "emc2303"，也不是 "fan"）。

```
emc2303 (i2c1 0x2c)
  └── hwmon (name=pwmfan)
        ├── pwm1            (0-255，写这个调速)
        ├── pwm1_enable     (1 = 允许软件控制)
        └── fan1_input      (实际转速 RPM)
```

控速脚本：`/usr/sbin/fan_ctrl.sh`，由 `fan_ctrl.service` 每 5 秒跑一次。

```bash
systemctl status fan_ctrl --no-pager | head -5
systemctl cat fan_ctrl.service | grep ExecStart
# ExecStart=/bin/bash -c "while true; do /usr/sbin/fan_ctrl.sh; sleep 5; done"
```

## 2. 找到 hwmon 节点（不要硬编码 hwmonN）

`hwmonX` 的编号**每次开机都会变**，必须按 `name` 找：

```bash
for d in /sys/class/hwmon/hwmon*; do
  [ "$(cat $d/name 2>/dev/null)" = "pwmfan" ] && echo "FAN=$d"
done
```

本机实测：`/sys/class/hwmon/hwmon30`

```bash
FAN=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name 2>/dev/null)" = pwmfan ] && echo $d; done)
cat $FAN/pwm1           # 85    ← 当前 PWM 值
cat $FAN/pwm1_enable    # 1     ← 软件控制已开
cat $FAN/fan1_input     # 0     ← 转速 RPM（实测读到 0，见 §5）
```

## 3. 调温策略（读自 `/usr/sbin/fan_ctrl.sh`）

| CPU 温度 | PWM | 说明 |
|---|---|---|
| < 40 °C | **0** | 停转 |
| 40 ~ 60 °C | **85** | 低速 |
| 60 ~ 75 °C | **170** | 中速 |
| ≥ 75 °C | **255** | 全速 |

另外有**启动冲击**：从 0 起转时先给 `255` 跑 **1 秒**（`KICKSTART_PWM=255`），
避免高启动阈值风扇转不起来。

温度读的是 `/sys/class/thermal/thermal_zone11/temp`（`pm7325-thermal`）。
**注意：脚本里是硬编码的 zone11，不是 cpu 温度 zone。**

实测当时：`pwm1=85`，说明 CPU 温度在 **40~60 °C** 区间，与 `thermal_zone11` 一致。

## 4. 手动调速（临时，会被 service 覆盖）

```bash
FAN=$(for d in /sys/class/hwmon/hwmon*; do [ "$(cat $d/name 2>/dev/null)" = pwmfan ] && echo $d; done)

# 先停掉自动控制，否则 5 秒后被改回
sudo systemctl stop fan_ctrl

echo 1   | sudo tee $FAN/pwm1_enable    # 允许软件控制
echo 255 | sudo tee $FAN/pwm1           # 全速
echo 0   | sudo tee $FAN/pwm1           # 停
cat $FAN/fan1_input                      # 看转速

# 恢复自动
sudo systemctl start fan_ctrl
```

**一定要恢复 `systemctl start fan_ctrl`**，否则温度上去风扇不转。

## 5. `fan1_input` 读到 0 的含义

实测 `fan1_input=0`，但 PWM=`85`。这说明两种可能：

1. 风扇没接 / 接的型号没有 TACH 输出；
2. TACH 线没插（4-pin 风扇的第 3 脚）。

**判据**：`pwm1` 有值且能改 → 控制链路正常；`fan1_input` 恒 0 → TACH 侧没信号。
不能凭 `fan1_input=0` 判断"风扇不转"。

想确认风扇真的在转，只能**物理观察/听声音**，或用 `board-power` 的温度表看
温度是否随负载上升后回落。

## 6. 温度监控（配合风扇判断）

```bash
# CPU 温度（fan_ctrl.sh 实际读的那个）
cat /sys/class/thermal/thermal_zone11/temp        # millidegree

# 全表
for z in /sys/class/thermal/thermal_zone*/; do
  t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null)
  [ -n "$t" ] && echo "$t = $((v/1000)) C"
done | sort

# 或按 hwmon
for h in /sys/class/hwmon/hwmon*; do
  n=$(cat $h/name 2>/dev/null)
  case "$n" in *thermal*) echo "$n=$(cat $h/temp1_input 2>/dev/null)";; esac
done
```

## 7. 工厂模式下风扇不受控（重要）

`fan_ctrl.service` 有硬条件：

```
ConditionPathExists=/var/persist/fct_done_flag
```

```bash
ls -l /var/persist/fct_done_flag
# 存在 = 正常模式（风扇自动控速）
# 不存在 = 工厂模式（风扇由 AT+FANON/FANOFF 独占控制，温控服务不起）
```

**报警**：如果用户说"风扇不转"，先看这个 flag 在不在：

```bash
[ -f /var/persist/fct_done_flag ] && echo NORMAL || echo FACTORY
```

工厂模式下 `systemctl status fan_ctrl` 会显示 `inactive (dead)` /
`Condition check resulted in ... being skipped`，**这是设计如此**，不是故障。

## 8. 已知坑

| 现象 | 判据 | 处置 |
|---|---|---|
| 风扇不转 | 先看 `fct_done_flag` | 工厂模式 → 正常；正常模式 → 查 `pwm1` 值 |
| 风扇一直全速 | `pwm1=255` 且温度 >75 | 看是什么在吃 CPU；`top` |
| `fan1_input` 恒 0 | TACH 无信号 | 不代表风扇不转，见 §5 |
| 手动改 `pwm1` 5 秒后复原 | `fan_ctrl.service` 在跑 | 先 `systemctl stop fan_ctrl` |
| `hwmon1/pwm1` 写了没反应 | 找错了 hwmon（编号会变） | 按 `name=pwmfan` 找 |
| `fan_ctrl.sh` 报 `PWM file not writable` | 没用 root | `sudo` |

## 9. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- 风扇 hwmon：`/sys/class/hwmon/hwmon30`，`name=pwmfan`
- 实测值：`pwm1=85`，`pwm1_enable=1`，`fan1_input=0`
- `fan_ctrl.service` = active (running)，ExecStart 为 while+sleep 5
- 阈值（读自脚本）：`LOW=40000 MID=60000 HIGH=75000`，
  `PWM_OFF=0 PWM_LOW=85 PWM_MID=170 PWM_HIGH=255 KICKSTART=255/1s`
- 温度源：`/sys/class/thermal/thermal_zone11/temp`（`pm7325-thermal`，硬编码）
- `/var/persist/fct_done_flag` **存在** → 当前是正常模式
- emc2303 在 `i2c1 0x2c`（`/sys/bus/i2c/devices/1-002c/name`）
