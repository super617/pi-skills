---
name: board-gpio
description: "板端 40Pin 扩展: GPIO/I2C9/SPI10/UART12/PWM/ADC 怎么用。这板上没有 i2cdetect 和 gpioset,GPIO 用官方的 rgs(lgpio) 或 /sys/kernel/debug/gpio,PWM 走 sysfs,ADC 读 iio。需要点灯、读传感器、接风扇、量电压时用。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [gpio, 40pin, i2c, spi, uart, pwm, adc, rgs, lgpio, iio]
    related_skills: [board-overview, board-fan, board-power, board-debug]
---

# 40Pin 扩展口

## 1. 引脚表（只列了常用信号，完整表看硬件手册）

| Pin | 信号 | 板端节点 | 备注 |
|---|---|---|---|
| 3 | I2C9_SDA | `/dev/i2c-9` | 和 pin5 一组 |
| 5 | I2C9_SCL | `/dev/i2c-9` | |
| 8 | UART12_TX | `/dev/ttyHS2` | 115200 |
| 10 | UART12_RX | `/dev/ttyHS2` | |
| 19/21/23/24 | SPI10 | `/dev/spidev10.0` | 10 MHz |
| 26 | SPI10_CS1 | `/dev/spidev10.1` | |
| 32 | FAN_TACH | GPIO_76 | 风扇转速输入 |
| 33 | FAN_PWM | GPIO_78 | 风扇调速输出 |
| 2 / 4 | 5V | — | 注意总电流 |
| 6/9/14/20/25/30/34/39 | GND | — | |

> **ADC 不在 40Pin 插针的常规位置**，见 §6。

## 2. GPIO：三个 gpiochip，别搞混

```bash
ls /dev/gpiochip*
sudo head -20 /sys/kernel/debug/gpio     # ★ 唯一能看到「chip → 物理 pin → 当前电平」的地方
```

本机实测的 chip 划分（**注意全局编号不是从 0 开始**）：

| chip | GPIO 全局编号 | 所属控制器 | 用途 |
|---|---|---|---|
| `gpiochip0` | 512-523 | `pmic@8:pinctrl` | PMIC GPIO |
| `gpiochip1` | 524-533 | `pmic@1:gpio` | PMIC GPIO |
| `gpiochip2` | 534-542 | `pmic@2:gpio` | PMIC GPIO |
| `gpiochip3` | 543-546 | `pmic@0:gpio` | PMIC GPIO |
| **`gpiochip4`** | **547-722** | **`f100000.pinctrl`** | ★ **TLMM，40Pin 的 GPIO 都在这** |
| `gpiochip5` | 723-737 | `33c0000.pinctrl` | 另一组（可 sleep） |

**40Pin 上的引脚用 `gpiochip4`**，编号是 TLMM 的 offset（如 GPIO_36 = chip4 的 line 36）。

### 2.1 用 rgs（推荐，官方带的 lgpio 命令行）

板上 `dpkg -l lgpio` 是 `1.0-r0`，装的是 `rgs` + `rgpiod`。
`rgs` 是一个**交互式命令行**，不是一条命令干一件事。

```bash
rgs            # 进入交互，或者用 -h
rgs -h         # 看帮助（有输出，别用 rgs help，会报 unknown command）
```

实测帮助里可用的命令（`h` 是句柄，`g` 是 gpio 号）：

| 命令 | 作用 |
|---|---|
| `help` | 打印帮助 |
| `GC h` | 关闭 gpiochip |
| `GIC h` | gpiochip 信息（行数、label） |
| `GIL h g` | 该 line 的信息 |
| `GGR h g` | 读组 |
| `GGW h g gbits` | 写组 |
| `GDEB h g us` | 设置去抖 |

> ⚠️ 实际动手前先 `rgs -h` 看当前固件支持哪些子命令，不同 lgpio 版本命令集不同。
> 更稳的路线是 §2.2 的 Python 或 C。

### 2.2 Python（python-periphery，最省事）

```bash
# 需要先装（板上没有预装）
apt list --installed 2>/dev/null | grep -i periphery
sudo apt install -y python3-periphery      # 或 pip3 install python-periphery --break-system-packages
```

```python
from periphery import GPIO
out = GPIO("/dev/gpiochip4", 36, "out")    # pin3 → GPIO36
out.write(True)                            # 3.3V
out.close()
inp = GPIO("/dev/gpiochip4", 37, "in")     # pin5 → GPIO37
print(inp.read())
```

### 2.3 C（lgpio）

```bash
# 库在，但**没有开发软链**：只剩 liblgpio.so.1，没有 liblgpio.so
ls /usr/lib/liblgpio.so*
# 编译时要显式指全名，或用 -l:liblgpio.so.1
gcc x.c -o x -l:liblgpio.so.1
```

`lgGpiochipOpen(4)` 对应 TLMM。头文件不在默认 include 路径，需要自己带
`lgpio.h`（源码包里）。

### 2.4 只读：直接看 debugfs（不用装任何工具）

```bash
sudo cat /sys/kernel/debug/gpio | grep -A40 'gpiochip4'
# 每行: gpio36: out high normal vin-0 pull-down 10uA push-pull high
#                              ↑方向 ↑电平             ↑上下拉      ↑驱动
```

**这是排查"我配的 GPIO 到底生效没"最快的方法**，比任何工具都直接。

### 2.5 这块板上没有的东西

```
i2cdetect / i2cget / i2cset   ✗ 未安装（apt install i2c-tools）
gpiodetect / gpioset / gpioget ✗ 未安装（apt install gpiod）
python3-gpiod                  ✗ 未安装
```

## 3. I2C9

```bash
ls /dev/i2c-9                       # 存在即已使能
# 没装 i2cdetect 时怎么知道挂了什么：
ls /sys/bus/i2c/devices/ | grep '^9-'
for d in /sys/bus/i2c/devices/9-*/name; do echo "$(dirname $d | xargs basename)=$(cat $d)"; done
```

要让某个器件挂上来（比如 BME280 @0x76）：

```bash
# 方式 A：设备树 overlay（需要在 DTS 里加节点，板端改不了，需重新编译）
# 方式 B：运行时实例化（重启失效）
echo bme280 0x76 | sudo tee /sys/bus/i2c/devices/i2c-9/new_device
# 删掉
echo 0x76 | sudo tee /sys/bus/i2c/devices/i2c-9/delete_device
```

装 i2c-tools 后：

```bash
sudo apt install -y i2c-tools
sudo i2cdetect -y -r 9
```

> 板上默认没有外网限制问题：`apt-get -s install i2c-tools` 实测能解析包，
> 且 `curl http://deb.debian.org/debian/` 返回 200。装工具前先问用户。

## 4. SPI10

```bash
ls -l /dev/spidev10.0 /dev/spidev10.1
# 权限: crw------- root root → 需要 sudo 或加 udev 规则
```

回环测试（把 MOSI 和 MISO 短接）：

```bash
# 板上没有 spidev_test，用 python 最省事
apt install -y python3-spidev 2>/dev/null || pip3 install spidev --break-system-packages
python3 - <<'PY'
import spidev
s = spidev.SpiDev(); s.open(10, 0); s.max_speed_hz = 10_000_000; s.mode = 0
sent = [0xAA, 0x55, 0x01]
print("sent", sent, "recv", s.xfer2(sent))   # 短接时 recv 应等于 sent
s.close()
PY
```

## 5. UART12（`/dev/ttyHS2`）

```bash
ls -l /dev/ttyHS2                 # crw-rw---- root dialout
groups | grep dialout             # 桌面用户 p 在 dialout 组里，可直接读写
```

回环测试（pin8 与 pin10 短接）：

```bash
python3 - <<'PY'
import serial, time
p = serial.Serial("/dev/ttyHS2", 115200, timeout=1)
p.write(b"hello40pin\r\n"); time.sleep(0.2)
print(repr(p.read(64))); p.close()
PY
```

没装 pyserial：

```bash
stty -F /dev/ttyHS2 115200 raw -echo
( cat /dev/ttyHS2 & ) ; printf 'hi\r\n' > /dev/ttyHS2 ; sleep 1 ; kill %1
```

## 6. PWM 与 ADC

### PWM（pin33 = GPIO_78）

40Pin 的风扇 PWM **不是** `/sys/class/pwm/`（那个是 PMIC 的 4 路，见 `board-fan`）。
插针上的 PWM 要走 GPIO_78 的 lgpio PWM：

```bash
# 板载风扇走 pwmfan hwmon（见 board-fan）
ls /sys/class/pwm/pwmchip0/          # npwm=4，属 PMIC（c440000.spmi:pmic@2:pwm）
```

插针 PWM 用 C/python 的 lgpio `lgTxPwm(chip, gpio=78, freq=1000, duty=50, 0, 0)`。

### ADC（PM7325 VADC，**最大 1.8 V**）

```bash
ls /sys/bus/iio/devices/iio:device1/in_voltage*
cat /sys/bus/iio/devices/iio:device1/in_voltage_pm7325_adc0_input
```

实测（2026-11-13）：

```
in_voltage_pm7325_adc0_input=25886     # 悬空时读数
in_voltage_pm7325_adc1_input=21020
in_voltage_pm7325_adc2_input=129       # 接地附近
```

换算：`V = raw / 65535 × 1.8`（12-bit 有效位，但 iio 报 16-bit 满量程）。

```bash
python3 - <<'PY'
for i in range(3):
    f=f"/sys/bus/iio/devices/iio:device1/in_voltage_pm7325_adc{i}_input"
    raw=int(open(f).read())
    print(f"ADC{i}: raw={raw:6d}  {raw/65535*1.8:.3f} V")
PY
```

> **超过 1.8 V 会打坏 PMIC**。测 5 V/3.3 V 必须分压。

另有一组温度通道在 `iio:device0`：`in_temp_bat_id_input` / `in_temp_chg_temp_input` /
`in_temp_die_temp_input`。

## 7. 已知坑

| 现象 | 原因 | 处置 |
|---|---|---|
| `i2cdetect: command not found` | 未装 i2c-tools | 用 §3 的 sysfs 查法，或问用户能否装 |
| `gpioset: command not found` | 未装 gpiod | §2.1 / §2.2 |
| `gcc x.c -llgpio` 链接失败 | 只有 `liblgpio.so.1`，没有 `.so` | `-l:liblgpio.so.1` |
| `rgs` 卡住不返回 | 它是交互式命令行 | `rgs -h` 看用法，或用 python |
| `/dev/spidev10.0` 打不开 | 权限 600 root | sudo，或加 udev 规则 |
| GPIO 写了没反应 | 该 pin 被别的驱动占用（pinctrl 里已 mux） | `sudo cat /sys/kernel/debug/gpio` 看是否 `requested` |
| ADC 读数一直满量程 | 输入超 1.8 V 或悬空 | 分压；悬空读数无意义 |

## 8. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- gpiochip：0(512-523) 1(524-533) 2(534-542) 3(543-546) **4(547-722, TLMM)** 5(723-737)
- `/dev/i2c-9`、`/dev/spidev10.0`/`.1`、`/dev/ttyHS2` 均存在
- PWM：`/sys/class/pwm/pwmchip0` npwm=4（PMIC PWM，非插针）
- ADC：`iio:device1` 上 `pm7325_adc0/1/2`，实测 raw 值见上
- `rgs` 存在（lgpio 1.0-r0），`rgs help` 报 unknown command，`rgs -h` 有输出
- `i2cdetect`/`gpioset`/`python3-gpiod` 均未安装；`liblgpio.so.1` 存在但无 `.so` 软链
