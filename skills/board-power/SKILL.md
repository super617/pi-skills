---
name: board-power
description: "板端电源/PMIC: 三色 LED(red/green/blue)、电源键与复位键(pmic_pwrkey/pmic_resin)、RTC(PMK8350)、温度监控全表、BCL 电池电流限制、充电器与 USB PD 状态。点灯/读温度/查按键/RTC 校时/限流相关时用。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [pmic, power, led, rtc, thermal, bcl, charger, pd, gpio-keys]
    related_skills: [board-overview, board-fan, board-gpio, board-debug]
---

# 板端电源 / PMIC

## 1. PMIC 组成

| PMIC | 职责 |
|---|---|
| **PM7250B** | 主 PMIC，charger / BCL / GPIO |
| **PM7325** | VADC（3 路 ADC）、部分 LDO |
| **PM8350C** | PWM（4 路，含板载风扇）、LED、热 |
| **PMK8350** | RTC |

```bash
# 每个 PMIC 的 die 温度（iio:device0 是 pm7250b，device1 是 pm7325/pmk8350）
for d in /sys/bus/iio/devices/iio:device*; do
  echo "== $(basename $d) $(cat $d/name)"
  ls $d | grep -E 'in_temp.*input'
done
```

## 2. 三色 LED

```bash
ls /sys/class/leds/
# 实测: red  green  blue  + input13::*（键盘灯）+ mmc0:: mmc1::
```

| LED | max_brightness | 实测当前值 |
|---|---|---|
| `red` | 511 | 511（全亮） |
| `green` | 511 | 0 |
| `blue` | 511 | 255 |

### 2.1 点灯

```bash
# 定值亮度（0 ~ max_brightness）
echo 100 | sudo tee /sys/class/leds/red/brightness
# 熄灭
echo 0 | sudo tee /sys/class/leds/green/brightness
```

实测：写 `100` 后读回 `100`，写 `511` 后回满。**生效，可回退。**

### 2.2 trigger（内核自动控制）

```bash
cat /sys/class/leds/red/trigger
```

实测有 41 个可选 trigger，常用的：

| trigger | 效果 |
|---|---|
| `none` | 手动控制（`brightness` 说了算） |
| `default-on` | 常亮 |
| `heartbeat` | 心跳闪烁 |
| `timer` | 定时闪烁（配 `delay_on`/`delay_off`） |
| `disk-activity` | 磁盘读写闪 |
| `mmc0` / `mmc1` | SD 卡活动 |
| `panic` | 内核 panic 时常亮 |

```bash
# 改成心跳
echo heartbeat | sudo tee /sys/class/leds/blue/trigger
# 改回手动
echo none | sudo tee /sys/class/leds/blue/trigger
echo 0 | sudo tee /sys/class/leds/blue/brightness
```

> **调完记得回 `none`**，否则下次别人想手动控会不生效。
> 注意 `default-on` 在实测的 trigger 列表里被标为 `[default-on]`，说明**默认就是常亮**。

## 3. 按键

```bash
cat /proc/bus/input/devices | grep -A5 -E 'pmic_pwrkey|pmic_resin|gpio-keys'
```

实测设备：

| 设备 | input 节点 | by-path |
|---|---|---|
| `pmic_pwrkey`（电源键） | `input2` / `event2` | `...pon@1300:pwrkey-event` |
| `pmic_resin`（复位键） | `input3` / `event3` | `...pon@1300:resin-event` |
| `gpio-keys` | — | `platform-gpio-keys-event` |

```bash
sudo evtest /dev/input/event2      # 按电源键看 KEY_POWER
sudo evtest /dev/input/event3      # 按复位键看 KEY_RESTART
```

`input2` 的 name 是 `pmic_pwrkey`（`cat /sys/class/input/input2/name` 验证）。

## 4. RTC

```bash
cat /sys/class/rtc/rtc0/name        # rtc-pm8xxx c440000.spmi:pmic@0:rtc@6100
cat /sys/class/rtc/rtc0/date        # 2026-11-13
cat /sys/class/rtc/rtc0/time        # 07:40:34（UTC）
cat /sys/class/rtc/rtc0/since_epoch
hwclock -r                          # 本地时间带时区
```

RTC 早于系统时间时会被 NTP 同步过去：

```bash
timedatectl status
sudo hwclock -w                     # 把系统时间写回 RTC
```

定时唤醒：

```bash
ls /sys/class/rtc/rtc0/             # wakealarm / alarmtimer.*
# 30 分钟后唤醒
sudo sh -c 'echo $(( $(date +%s) + 1800 )) > /sys/class/rtc/rtc0/wakealarm'
cat /sys/class/rtc/rtc0/wakealarm   # 确认
```

## 5. 温度：全表在哪

```bash
for z in /sys/class/thermal/thermal_zone*/; do
  t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null)
  [ -n "$t" ] && echo "$t = $((v/1000)) C"
done | sort
```

实测（2026-11-13，空闲状态）：

| zone type | 温度 |
|---|---|
| `cpu0`~`cpu11` | 45~48 °C |
| `cpuss0` / `cpuss1` | 48 / 48 °C |
| `gpuss0` / `gpuss1` | 44 / 44 °C |
| `nspss0` / `nspss1`（NPU） | 44 / 43 °C |
| `video`（VPU） | 44 °C |
| `ddr` | 46 °C |
| `pm8350c` / `pm7250b` / `pm7325` | PMIC die 温度 |
| `vbat` | 电池电压相关 |
| `pm7250b-ibat-lvl0` | 电池电流阈值 |

`hwmon` 侧有对应名称：

```bash
for h in /sys/class/hwmon/hwmon*; do echo "$(basename $h)=$(cat $h/name 2>/dev/null)"; done
# pm8350c_thermal / pm7250b_thermal / pm7325_thermal / cpu4_thermal ... nspss0_thermal
# video_thermal / ddr_thermal / mdmss0_thermal / pwmfan
```

**`hwmon` 里 `name == "pwmfan"` 的那个就是风扇**（见 `board-fan`）。

## 6. 充电 / USB PD / 电源状态

```bash
ls /sys/class/power_supply/
# 实测: qcom-battmgr-usb  qcom-battmgr-wls  ucsi-source-psy-pmic_glink.ucsi.01
```

```bash
for f in /sys/class/power_supply/qcom-battmgr-usb/*; do
  echo "$(basename $f)=$(head -1 $f 2>/dev/null)"
done
```

实测字段（插着 Type-C 但 `online=0`，说明当时没在取电/或无 PD 协商）：

```
type=USB            online=0
voltage_max=5000000 voltage_now=5102000
current_max=1500000 current_now=0
input_current_limit=100000
usb_type=Unknown [SDP] DCP CDP ACA C PD PD_DRP PD_PPS BrickID
```

`usb_type` 那行是**可选值列表**，方括号是当前值。

### Type-C 角色

```bash
ls /sys/class/typec/
# port0  port0-partner
for t in /sys/class/typec/port*; do
  echo "$(basename $t) data_role=$(cat $t/data_role 2>/dev/null) power_role=$(cat $t/power_role 2>/dev/null)"
done
# 实测: port0 data_role=host [device]  power_role=source [sink]
```

方括号是可选值，未加括号的是当前值。`[]` 里没被选中的是备选。

## 7. BCL（电池电流限制）

BCL 在电流超阈值时降频/降亮度保护。板上有电池管理抽象（`qcom-battmgr-*`），
但当前**没接电池**（只有 USB 供电），所以 BCL 的实际触发主要来自 USB 供电能力。

```bash
ls /sys/class/thermal/ | grep -i bat        # pm7250b-ibat-lvl0
cat /sys/class/thermal/thermal_zone2/type   # pm7250b-ibat-lvl0
cat /sys/class/thermal/thermal_zone2/temp   # 625（milli-单位阈值）

# 电池管理 hwmon
for h in /sys/class/hwmon/hwmon33 /sys/class/hwmon/hwmon34 /sys/class/hwmon/hwmon35; do
  [ -d "$h" ] && echo "$(basename $h)=$(cat $h/name 2>/dev/null)"
done
```

## 8. 已知坑

| 现象 | 原因 | 处置 |
|---|---|---|
| 写 LED `brightness` 没变化 | `trigger` 不是 `none` | 先 `echo none > trigger` |
| LED 开机自己亮 | 默认 trigger 是 `default-on` | §2.2，改完记得回退 |
| `hwclock -r` 时间不对 | RTC 是 UTC，`hwclock` 按本地时区换算 | 看 `timedatectl` 时区 |
| RTC `wakealarm` 写了不生效 | 需要 `rtcwake` 或内核支持 | 用 `sudo rtcwake -m mem -s 60` 验证 |
| `thermal_zone*/temp` 读不到 | 某些 zone 是阈值不是温度 | §5 表格按 type 区分 |
| 温度看起来异常高（如 625） | 那是阈值 zone（`ibat-lvl0`） | 换算成 °C 才有意义 |
| `power_supply` 里 `online=0` 以为没供电 | 可能只是没在做 PD 协商 | 看 `voltage_now`；系统能跑就是有电 |

## 9. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- LED：`red`=511/511（满）、`green`=0、`blue`=255；三者 `max_brightness` 都是 511；
  写 `100` 到 red 后读回 `100`，写 `511` 回满 —— **可写可控**
- trigger 可选 41 项，含 `[default-on]` `heartbeat` `timer` `disk-activity` `mmc0` `mmc1` `panic`
- 按键：`pmic_pwrkey`(input2/event2)、`pmic_resin`(input3/event3)、`gpio-keys`
- RTC：`rtc-pm8xxx c440000.spmi:pmic@0:rtc@6100`，`date=2026-11-13`，`time=07:40:34`(UTC)
- 温度：空闲 cpu 45-48 °C，NPU 43-44 °C，VPU 44 °C，DDR 46 °C
- power_supply：`qcom-battmgr-usb`(type=USB, online=0, voltage_now=5102000)，
  另有 `qcom-battmgr-wls`、`ucsi-source-psy-...`
- Type-C：`port0 data_role=host power_role=source`
- 无 `/sys/class/power_supply/*/capacity`（没接电池）
