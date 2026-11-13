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

debugfs 里 gpiochip4 的行带 func 和驱动能力（TLMM 特有，PMIC 的 chip 没有）：

```
 gpio0   : in  high func1 2mA no pull
 gpio2   : out high func0 16mA no pull
                 ↑方向 ↑电平 ↑功能号 ↑驱动电流 ↑上下拉
```

### 2.0 先看权限：这些设备**全只有 root 能开**

```bash
ls -l /dev/i2c-* /dev/gpiochip* /dev/spidev*
```

实测全都是 `crw------- 1 root root`。桌面用户 `p` 的组只有
`sudo audio video users input`（**不在 `dialout`，也不在 `gpio`/`i2c`**），所以：

```
sudo -u p python3 -c 'open("/dev/i2c-9","rb")'
  → PermissionError: [Errno 13] Permission denied
sudo -u p python3 -c 'open("/dev/spidev10.0","rb")'
  → PermissionError: [Errno 13] Permission denied
sudo -u p python3 -c 'open("/dev/gpiochip4","rb")'
  → PermissionError: [Errno 13] Permission denied
```

| 设备 | 权限 | `p` 能用吗 | 备注 |
|---|---|---|---|
| `/dev/i2c-N` | `root:root 600` | ✗ | **全部总线**，不只 i2c9 |
| `/dev/gpiochipN` | `root:root 600` | ✗ | 全部 6 个 |
| `/dev/spidev10.x` | `root:root 600` | ✗ | |
| `/dev/ttyHS2`（UART12） | `root:dialout 660` | ✗ | `p` **不在 dialout**，实测 `cat: Permission denied` |
| `/sys/kernel/debug/gpio` | 需 root | ✗ | 只读也要 sudo |

→ **本节下面所有命令都默认带 `sudo`**。不想每条都 sudo，就加一条 udev 规则
（属改系统配置，先问用户）：

```bash
# /etc/udev/rules.d/60-gpio-i2c.rules
SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-*", GROUP="i2c", MODE="0660"
```

### 2.1 先把结论说清楚：`rgs` 在这块板上用不了

板上确实装了 `lgpio 1.0-r0`（含 `/usr/bin/rgs`、`/usr/bin/rgpiod`），
`rgpiod.service` 也是 active（只监听 `127.0.0.1:8889`）。**但实测所有实际操作都失败**：

```bash
rgs -h                          # 帮助能打（rc=0）
rgs u t1 share 1 go 4           # 打开 gpiochip4 → 返回句柄，OK
rgs u t1 gic <handle>           # Error: no permission to perform action  (-93)
rgs u t1 gil <handle> 36        # 同  -93
rgs u t1 gr  <handle> 36        # 同  -93
rgs u t1 gso <handle> 36        # 同  -93
```

| 验证项 | 结果 |
|---|---|
| root 跑 | -93 EPERM |
| 桌面用户 `p` 跑 | -93 EPERM |
| `gpiochip0`(PMIC) / `gpiochip4`(TLMM) | 都是 -93 |
| 往 `/permits` 放 `*: *` 等放宽规则后 `rgs lcfg` | 仍 -93 |

→ **`rgs` 的 daemon 路径（rgpiod）在这份镜像上不可用**，不是权限配错几行就能救的。
不要把它当推荐方案，也不要因为 `/permits` 不存在就去改系统配置。

另外帮助文本里有两个坑：示例写的 `s 1` 会报 `bad parameter`，要写 **`share 1`**；
`rgs help` 会报 `unknown command`，要看帮助用 `rgs -h`。

### 2.2 能用的路：lgpio 本地直连（不经 daemon）

`rgs` 走 daemon，而 lgpio 的库函数是**直接打开 `/dev/gpiochipN`**，这条路是好的。
板上没有 `lgpio.h`，也没有 `liblgpio.so` 软链，所以编译要两条都绕过：

```c
/* gpio_read.c -- 自声明原型，板内无 lgpio.h */
#include <stdio.h>
#include <string.h>
int lgGpiochipOpen(int chip);
int lgGpiochipClose(int h);
int lgGpioRead(int h, int gpio);
int lgGpioGetMode(int h, int gpio);
int lgGpioClaimOutput(int h, int flags, int gpio, int level);
int lgGpioWrite(int h, int gpio, int level);
int lgGpioFree(int h, int gpio);

int main(void) {
    int h = lgGpiochipOpen(4);            /* TLMM */
    if (h < 0) { printf("open: %s\n", strerror(-h)); return 1; }
    printf("gpio36 mode=%d level=%d\n", lgGpioGetMode(h, 36), lgGpioRead(h, 36));

    /* 输出：先 claim 再 write（会真的拉电平，动手前想好看什么） */
    if (lgGpioClaimOutput(h, 0, 78, 0) == 0) {   /* 78 = 40Pin pin33 */
        lgGpioWrite(h, 78, 1);
        lgGpioWrite(h, 78, 0);
        lgGpioFree(h, 78);
    }
    lgGpiochipClose(h);
    return 0;
}
```

```bash
gcc gpio_read.c -o gpio_read -l:liblgpio.so.1   # 注意是全名，-llgpio 会找不到
./gpio_read
```

实测输出（2026-11-13，只读，没有拉电平）：

```
lgGpiochipOpen(4) -> 0
gpio36  GetMode -> 65536  read -> 1      ← 65536 = LG_SET_INPUT (0x10000)
gpio37  GetMode -> 65536  read -> 1
gpio38  GetMode -> 65536  read -> 0
close -> 0
```

→ **读写都可用**。`GetMode` 返的是位掩码，`0x10000` = 输入模式。

> 板上 `liblgpio.so.1` 存在但**没有** `liblgpio.so` 开发软链，也没有头文件。
> 想要头文件和 `-llgpio`：`sudo apt install liblgpio-dev`（装前问用户）。

### 2.3 Python：periphery / lgpio 模块都得先装

板上 `python3-periphery`、`lgpio`(python)、`python3-gpiod` **都没装**：

```bash
sudo apt install -y python3-periphery       # 或有网时 pip3 install python-periphery --break-system-packages
```

```python
from periphery import GPIO
with GPIO("/dev/gpiochip4", 36, "in") as pin:    # pin3 → GPIO36
    print(pin.read())
```

不装任何包时的只读方案见 §2.4。
inp = GPIO("/dev/gpiochip4", 37, "in")     # pin5 → GPIO37
print(inp.read())
```

### 2.4 只读：直接看 debugfs（不用装任何工具）

```bash
sudo cat /sys/kernel/debug/gpio | grep -A40 'gpiochip4'
# 每行: gpio36: out high normal vin-0 pull-down 10uA push-pull high
#                              ↑方向 ↑电平             ↑上下拉      ↑驱动
```

**这是排查"我配的 GPIO 到底生效没"最快的方法**，比任何工具都直接。

### 2.5 这块板上没有的东西

```
i2cdetect / i2cget / i2cset    ✗ 未安装（apt install i2c-tools）
gpiodetect / gpioset / gpioget ✗ 未安装（apt install gpiod / libgpiod-tools）
python3-gpiod                  ✗ 未安装
python3-periphery              ✗ 未安装
lgpio (python 模块)             ✗ 未安装；liblgpio.so.1 有，但无 -dev 无头文件
rgs / rgpiod                   ✓ 装了、服务在跑，但**所有操作返回 -93**（见 §2.1）
```

## 3. I2C（含 40Pin 的 I2C9）

板上 **没有 i2cdetect/i2cget/i2cset**（没装 i2c-tools），**也没有 python smbus/smbus2**。
但 `gcc` 和 `/usr/include/linux/i2c*.h` 都在，所以「零安装」也能扫和读。

```bash
ls /dev/i2c-*          # 实测: i2c-0 1 3 9 13 16 17
# 不看工具，先看内核已经认了什么器件：
for d in /sys/bus/i2c/devices/*/name; do echo "$(dirname $d | xargs basename)=$(cat $d)"; done
```

本机实测的已绑定器件：

| 节点 | 器件 | 说明 |
|---|---|---|
| `0-002b` | `lt9611uxc` | HDMI 桥变体（未贴） |
| `0-0041` | `lt9611uxd` | ★ HDMI 桥，实际在用的 |
| `1-002c` | `emc2303` | 风扇控制器 |
| `1-0047` | `sgm7220` | Type-C CC 控制器 |
| `3-0014` | `gt911` | DSI 屏触摸（屏未接） |
| `3-0045` | `8.0inch-panel` | DSI 屏（未接） |
| `i2c-16/17` | `dpu_dp_aux` | DP AUX 通道，**不是普通 I2C 总线**，别拿去扫器件 |

### 3.1 零安装扫总线（替代 `i2cdetect`）

用**1 字节读**做探针，不用零长写。这点实测有差别：零长写探针对
gpio 实测在 `bus0 0x41`（LT9611UXD）**探不到**，而读探针能探到。读操作也不会改器件寄存器。

```c
/* i2cscan.c -- gcc i2cscan.c -o i2cscan && sudo ./i2cscan 0 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

static int probe(int fd, int addr) {
    unsigned char b = 0;
    struct i2c_msg m = { .addr = (unsigned short)addr, .flags = I2C_M_RD,
                         .len = 1, .buf = &b };
    struct i2c_rdwr_ioctl_data x = { .msgs = &m, .nmsgs = 1 };
    return ioctl(fd, I2C_RDWR, &x) >= 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <bus>\n", argv[0]); return 2; }
    char path[32];
    snprintf(path, sizeof path, "/dev/i2c-%d", (int)strtol(argv[1], NULL, 0));
    int fd = open(path, O_RDWR);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }
    printf("bus%s read-probe: ", argv[1]);
    int n = 0;
    for (int a = 0x03; a <= 0x77; a++) if (probe(fd, a)) { printf("%02x ", a); n++; }
    if (!n) printf("(nothing responded)");
    printf("\n");
    close(fd);
    return n ? 0 : 1;
}
```

实测输出（2026-11-13，当前硬件）：

```
bus0 read-probe: 41              ← LT9611UXD（HDMI 桥）
bus1 read-probe: 47              ← SGM7220（Type-C CC）
bus3 read-probe: (nothing responded)   ← DSI 屏/触摸未接，正常
bus9 read-probe: (nothing responded)   ← 40Pin 没插器件
bus13 read-probe: (nothing responded)
bus16 read-probe: (nothing responded)
```

> 一个已知的不对称：`1-002c`(emc2303) 在 sysfs 里有驱动绑定，但通用读探针**不应答**。
> 所以「探不到」不等于「没这个器件」，还要看 `/sys/bus/i2c/devices/`。

### 3.2 零安装读寄存器（替代 `i2cget`）

```c
/* i2c_get.c -- gcc i2c_get.c -o i2c_get && sudo ./i2c_get 1 0x47 0x00 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <bus> <addr> <reg>\n", argv[0]);
        return 2;
    }
    int bus = (int)strtol(argv[1], NULL, 0);
    int addr = (int)strtol(argv[2], NULL, 0);
    int reg = (int)strtol(argv[3], NULL, 0);

    char path[32];
    snprintf(path, sizeof path, "/dev/i2c-%d", bus);
    int fd = open(path, O_RDWR);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }

    unsigned char r = (unsigned char)reg, v = 0;
    struct i2c_msg m[2] = {
        { .addr = (unsigned short)addr, .flags = 0,       .len = 1, .buf = &r },
        { .addr = (unsigned short)addr, .flags = I2C_M_RD, .len = 1, .buf = &v },
    };
    struct i2c_rdwr_ioctl_data x = { .msgs = m, .nmsgs = 2 };
    if (ioctl(fd, I2C_RDWR, &x) < 0) {
        fprintf(stderr, "read 0x%02x reg 0x%02x on bus%d: %s\n",
                addr, reg, bus, strerror(errno));
        close(fd);
        return 1;
    }
    printf("bus%d 0x%02x reg 0x%02x = 0x%02x (%d)\n", bus, addr, reg, v, v);
    close(fd);
    return 0;
}
```

实测：

```
$ sudo ./i2c_get 0 0x41 0x00     → bus0 0x41 reg 0x00 = 0x00 (0)      LT9611UXD 应答
$ sudo ./i2c_get 1 0x47 0x00     → bus1 0x47 reg 0x00 = 0x30 (48)     SGM7220 应答
$ sudo ./i2c_get 0 0x2b 0x00     → No such device or address          UXC 未贴（预期）
$ sudo ./i2c_get 3 0x14 0x00     → No such device or address          屏未接（预期）
```

`ENXIO`/`No such device or address` = 该地址没人应答，不是代码错。

> 不要用 `i2c_smbus_read_byte_data()`：它在 `libi2c`（`i2c/smbus.h`）里，
> 属于没装的 i2c-tools，编译会报 `implicit declaration`。用上面的 `I2C_RDWR` 纯内核接口。

### 3.3 让一个器件挂上来（运行时实例化，重启失效）

```bash
# 以 BME280 @0x76 为例；要对应内核里有驱动才行
echo bme280 0x76 | sudo tee /sys/bus/i2c/devices/i2c-9/new_device
dmesg | tail -5                       # 看 probe 结果
ls /sys/bus/i2c/devices/9-0076/
# 删掉
echo 0x76 | sudo tee /sys/bus/i2c/devices/i2c-9/delete_device
```

永久生效要改设备树（板端改不了，得重编内核）。

### 3.4 想装标准工具

```bash
sudo apt install -y i2c-tools && sudo i2cdetect -y -r 9
```

实测能装：`apt-get -s install i2c-tools` 能解析到 `i2c-tools 4.4-2`，
`curl http://deb.debian.org/debian/` 返回 200。**装包前先问用户。**

## 4. SPI10

```bash
ls -l /dev/spidev10.0 /dev/spidev10.1
# 权限: crw------- root root → 需要 sudo 或加 udev 规则
```

回环测试（把 MOSI 和 MISO 短接）：

```bash
# 板上没有 spidev_test，也没装 python3-spidev
sudo apt install -y python3-spidev    # 装前问用户；装完用下面的脚本
sudo python3 - <<'PY'
import spidev
s = spidev.SpiDev(); s.open(10, 0); s.max_speed_hz = 10_000_000; s.mode = 0
sent = [0xAA, 0x55, 0x01]
print("sent", sent, "recv", s.xfer2(sent))   # 短接时 recv 应等于 sent
s.close()
PY
```

不装任何包时的只读检查：确认控制器和片选在内核里就位。

```bash
ls -l /dev/spidev10.*
ls /sys/bus/spi/devices/          # 期望有 spi10.0 / spi10.1
for d in /sys/bus/spi/devices/*; do echo "$(basename $d) -> $(cat $d/uevent 2>/dev/null | tr '\n' ' ')"; done
```

## 5. UART12（`/dev/ttyHS2`）

```bash
ls -l /dev/ttyHS2                 # crw-rw---- root dialout
id                                # p 的组: sudo audio video users input —— 这里没有 dialout
# → UART12 也要 sudo，除非自己 usermod -aG dialout p 后重新登录
```

回环测试（pin8 与 pin10 短接）：

```bash
# 板上没装 python3-serial
sudo apt install -y python3-serial     # 装前问用户
sudo python3 - <<'PY'
import serial, time
p = serial.Serial("/dev/ttyHS2", 115200, timeout=1)
p.write(b"hello40pin\r\n"); time.sleep(0.2)
print(repr(p.read(64))); p.close()
PY
```

不装包时的写法（`stty` + `cat`，全是系统自带工具）：

```bash
sudo stty -F /dev/ttyHS2 115200 raw -echo
sudo sh -c 'timeout 2 cat /dev/ttyHS2 & sleep 0.3; printf "hi\r\n" > /dev/ttyHS2; wait'
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

- 2026-11-13，Debian 13 / kernel 6.6.116，桌面用户 `p` 的组：`sudo audio video users input`
- gpiochip：0(512-523) 1(524-533) 2(534-542) 3(543-546) **4(547-722, TLMM)** 5(723-737)
- **权限：`/dev/i2c-*` `/dev/gpiochip*` `/dev/spidev*` 全是 `root:root 600`**，
  `p` 实测三个都 `PermissionError`；`/dev/ttyHS2` 是 `root:dialout 660` 但 `p` 不在 dialout
  → **本节命令全部需要 sudo**
- **`rgs`/`rgpiod`：服务 active、`go`/`i2co`/`share` 能返回句柄，
  但 `gic`/`gil`/`gr`/`gso` 全部 `-93 EPERM`**（root 和 p 都一样，chip0/chip4 都一样，
  放 `/permits` 后 `lcfg` 也不行）→ daemon 路径不可用
- **lgpio 本地直连可用**（不经 daemon）：`lgGpiochipOpen(4)` → 0，
  `gpio36 GetMode=65536(LG_SET_INPUT) read=1`，`gpio37 read=1`，`gpio38 read=0`；
  编译：`gcc x.c -o x -l:liblgpio.so.1`（板内无 `lgpio.h`，需自声明原型）
- **I2C 零安装可用**：用 `I2C_RDWR` 1-字节读探针扫到 `bus0:41`、`bus1:47`；
  `bus3/9/13/16` 无应答（屏未接 / 40Pin 空 / DP AUX）
- 零长写探针**会漏** LT9611UXD(0x41)，读探针不会 —— 扫描用读探针
- `1-002c`(emc2303) 有驱动绑定但通用读探针不应答
- PWM：`/sys/class/pwm/pwmchip0` npwm=4（PMIC PWM，非插针）
- ADC：`iio:device1` 的 `pm7325_adc0/1/2`，实测 `0.604V / 0.563V / 0.000V`（悬空）
- `i2cdetect`/`gpioset`/`python3-gpiod`/`python3-periphery`/`python3-serial`/`spidev`
  均未安装；`liblgpio.so.1` 存在但无 `.so` 软链、无头文件；`gcc` 有
- SPI：`/sys/bus/spi/devices/` 有 `spi10.0` `spi10.1`
