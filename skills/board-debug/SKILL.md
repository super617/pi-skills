---
name: board-debug
description: "板端调试入口: dmesg 受限时怎么读、journalctl 看子系统日志、systemd 单元排查、sysfs/debugfs 定位、perf/ftrace/strace、一次性抓齐证据的脚本。板子上任何'没反应/报错/卡住'的问题先用它取证。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [debug, dmesg, journalctl, systemd, ftrace, strace, sysfs, debugfs]
    related_skills: [board-overview, board-screenshot, board-camera, board-audio]
---

# 板端调试

## 1. 日志在哪

| 来源 | 命令 | 说明 |
|---|---|---|
| 内核 | `sudo dmesg -T` | ★ `dmesg_restrict=1`，**普通用户读不到**，必须 sudo |
| 内核（持续） | `sudo dmesg -wT` | 边操作边看，Ctrl-C 停 |
| systemd + 所有服务 | `journalctl -b --no-pager` | 本次启动全部；`-b -1` 上一次启动 |
| 单个服务 | `journalctl -u pipewire -b --no-pager` | 音频看这个，不是 dmesg |
| 用户会话服务 | `journalctl --user -b --no-pager` | 需要 `XDG_RUNTIME_DIR` 且以 `p` 身份 |
| 桌面/GUI | `journalctl -b _COMM=gnome-shell --no-pager` | 或 `-u gdm` |
| 内核 oops/panic | `sudo journalctl -k -b -p err` | 只看 err 以上 |

`dmesg` 时间戳默认是开机秒数，`-T` 换成人类时间；和 `journalctl` 对时间用得上。

## 2. 先看系统状态的三条命令

```bash
systemctl --failed --no-pager                 # 哪些单元挂了
systemctl list-units --state=running --no-pager | head -30
journalctl -b -p warning --no-pager | tail -50
```

### 2.1 ★ 这几个 failed 是常态，不要去修

本机实机 `systemctl --failed` 固定输出这 5 个：

```
● var-usbfw.mount                       failed   mount usb_fw unit
● bt-autoconnect.service                failed   Reconnect paired Bluetooth audio devices
● camx-v4l2-bridge@0.service           failed   Camx V4L2 Bridge for camera 0
● gstd.service                         failed   GSTreamer Daemon
● iptables-restore.service             failed   Restore iptables rules
```

| 单元 | 为什么失败 | 什么时候才真需要管 |
|---|---|---|
| `var-usbfw.mount` | USB 固件分区不存在 | 只有需要 USB 固件升级时 |
| `bt-autoconnect` | 没配对过蓝牙音频设备 | 配过音频设备却不重连时 |
| `camx-v4l2-bridge@0` | **没接摄像头模组** | 接了模组仍失败时（相机问题）|
| `gstd` | GStreamer daemon 没配置 | 用到 gstd 的管道时 |
| `iptables-restore` | 没有规则文件 | 真有自己的防火墙规则时 |

→ 向用户报「系统有 5 个服务失败」之前先对这张表。把这几个当新故障追，
等于把预期状态当 bug。

### 2.2 崩机取证：pstore 不可用

```bash
ls /sys/fs/pstore/          # 实测: 不存在 → 没有 pstore 后端
cat /proc/sys/kernel/panic  # 10（panic 后 10 秒重启）
cat /proc/sys/kernel/sysrq  # 438
```

所以**上一次崩溃的 dmesg 拿不回来**（没 pstore/ramoops）。要抓 panic 只能：
串口 console 常开、或事先 `journalctl -f` / `dmesg -w` 录到外部。
下结论前先确认「能不能拿到上次的日志」，拿不到就直说。

板上有几个关键单元，出问题先看它们的 `is-active`：

```bash
for u in cam-server bluetooth pipewire wireplumber fan_ctrl atci gdm; do
    printf '%-16s %s\n' "$u" "$(systemctl is-active $u 2>&1)"
done
```

> 用户会话服务（`pipewire` / `wireplumber`）在 **user 作用域**，
> 系统作用域查会显示 `inactive`，别误判：
> ```bash
> sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user is-active pipewire
> ```

## 3. 子系统日志关键词（实测有效）

```bash
# 显示
sudo dmesg | grep -iE 'lt9611|dsi|panel|drm|edid|ws_touchscreen'

# 音频（dmesg 几乎没有，必须 journalctl）
journalctl -b --no-pager | grep -iE 'agm|pal_|graph_start|sdw|wcd9370|aw8010|lpass'

# 摄像头
sudo dmesg | grep -iE 'CAM_|cam_sensor|cam_req|camisp|csiphy|cci|imx219'

# 无线
sudo dmesg | grep -iE 'ath11k|wlan|hci|btqca|qca'

# VPU / Venus
sudo dmesg | grep -iE 'msm_vidc|venus'

# NPU / fastrpc
sudo dmesg | grep -iE 'fastrpc|cdsp|adsprpcd|qnn'

# 电源 / 温度
sudo dmesg | grep -iE 'pmic|regulator|thermal|bcl'
```

## 4. sysfs / debugfs 定位

```bash
# 设备树最终生效的节点（比看源码准）
ls /proc/device-tree/
cat /proc/device-tree/model
tr -d '\0' < /proc/device-tree/soc@0/*/compatible 2>/dev/null

# 驱动绑定情况
ls /sys/bus/platform/drivers/            # 每个驱动下挂着哪些设备
ls -l /sys/bus/i2c/devices/              # I2C 上实际有什么器件（含驱动名）
for d in /sys/bus/i2c/devices/*/name; do echo "$(dirname $d | xargs basename)=$(cat $d)"; done

# GPIO 当前真实状态（含方向、电平、上拉）
sudo cat /sys/kernel/debug/gpio

# 中断
grep -E 'lt9611|ath11k|cam|venus|i2c' /proc/interrupts

# debugfs（需要 root）
sudo ls /sys/kernel/debug/
sudo ls /sys/kernel/debug/msm_vidc/        # Venus 内部状态
```

## 5. 动态追踪

板上都有：`strace` `ltrace` `perf` `trace-cmd`（**没有** `bpftrace`）。

```bash
# 某个进程在等什么
sudo strace -f -tt -e trace=openat,ioctl -p <pid>
sudo strace -f -e trace=ioctl v4l2-ctl -d /dev/video32 --list-formats-out 2>&1 | tail -20

# 内核函数调用（需要 root）
sudo trace-cmd record -p function_graph -l 'lt9611*' -g 20
sudo trace-cmd report | head -50

# ftrace 手工
sudo sh -c 'echo function_graph > /sys/kernel/tracing/current_tracer'
sudo sh -c 'echo "lt9611uxd*" > /sys/kernel/tracing/set_ftrace_filter'
sudo sh -c 'echo 1 > /sys/kernel/tracing/tracing_on'
# ... 复现 ...
sudo sh -c 'echo 0 > /sys/kernel/tracing/tracing_on'
sudo cat /sys/kernel/tracing/trace | head -60
```

## 6. 一次性抓齐证据（推荐）

出问题时不要一条条问用户。跑这个，把整块证据带回来：

```bash
bash ~/.pi/agent/pi-skills/scripts/board-check.sh > /tmp/board.txt 2>&1
sudo dmesg -T > /tmp/dmesg.txt 2>&1
journalctl -b --no-pager > /tmp/journal.txt 2>&1
```

然后按子系统筛。产物在 `/tmp`，重启就没了，需要留档就拷到 `~/`。

## 7. 已知坑

1. **`dmesg` 报 `Operation not permitted`** —— 不是权限坏，是 `dmesg_restrict=1`，加 sudo。
2. **`journalctl --user` 报 `Failed to connect to bus`** —— 缺 `XDG_RUNTIME_DIR`，
   或当前是 root（root 没有 p 的 user bus）。用 `sudo -u p env XDG_RUNTIME_DIR=...`。
3. **`systemctl is-active pipewire` 显示 inactive** —— 用户作用域，见 §2。
4. **`printk` 级别**：`kernel.printk = 4 4 1 6`，`pr_debug`/`dev_dbg` 默认**不打印**。
   要看动态调试信息：
   ```bash
   sudo sh -c 'echo -n "file <驱动文件.c> +p" > /sys/kernel/debug/dynamic_debug/control'
   sudo dmesg -wT
   ```
5. **相机的 `CAM_ERR: Invalid ioctl cmd`** 在没有应用拉流时会刷屏，属于正常噪音。

## 8. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116：`dmesg_restrict=1` 确认；
  `strace`/`ltrace`/`perf`/`trace-cmd` 均在；`bpftrace` 不在；
  `/sys/kernel/tracing/` 可写（root）。
