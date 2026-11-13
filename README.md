# pi-skills — 板端技能包（Quectel PI / QCS6490）

这一套 skill 是给 **跑在板子上的 pi** 用的，不是给 SDK 主机用的。

- 运行环境：Quectel PI H1（QCS6490 / QSM565DP-WF），**板内** Debian 13 或 Ubuntu 26.04
- 全部命令都在板子上直接执行（`bash` / `python3` / sysfs / dbus），**不依赖 adb**
- 不带 SDK 那套东西：没有 `bitbake` / `buildconfig` / `quectel_build/` / 交叉编译 / 代码提交 / 烧录

> SDK 主机侧的那套（编译、烧录、git 提交、driver-arch 源码索引）在 SDK 仓库的
> `quectel_build/skills/` 里，和本仓库是**两套独立的东西**，互不覆盖。

## 装到哪

pi 启动时会扫描这些位置（见 pi 文档 `docs/skills.md`）：

| 位置 | 用途 |
|---|---|
| `~/.pi/agent/skills/` | 用户技能（本仓库推荐装到这里） |
| `~/.agents/skills/` | Agent Skills 规范目录，pi 也认 |
| `<project>/.pi/skills/` | 项目技能，从 cwd 向上找 |

本仓库的 `install.sh` 默认装到 `~/.pi/agent/skills/`，每个 skill 一个目录，
更新时整目录替换（见 `scripts/install.sh`）。

## 开机自动检查更新

`pi-agent-setup` 在登录时会跑一次 `--only-if-needed`。板端 skill 的更新检查挂在同一个
入口上（`scripts/skill-update-check.sh`）：**有新版才提示，没新版静默退出**。

```bash
# 手动检查（交互）
~/.pi/agent/pi-skills/scripts/skill-update-check.sh

# 只看有没有更新，不提示（给 GUI/自动化用）
~/.pi/agent/pi-skills/scripts/skill-update-check.sh --check
```

## 目录

```
skills/
  board-overview/          这块板是什么、怎么自检、两套 OS 的差异
  board-debug/             板端调试入口：日志、dmesg、systemd、trace、截图
  board-display/           显示（HDMI/LT9611、DSI 屏、DP over Type-C、背光、触摸）
  board-camera/            摄像头（IMX219、qtiqmmfsrc / camss 两套栈）
  board-audio/             音频（WCD9370 + AW8010、PAL/PipeWire、HDMI 音频）
  board-gpio/              40Pin（GPIO/I2C9/SPI10/UART12/PWM/ADC，含 rgs 用法）
  board-ethernet/          以太网（YT6801 PCIe 网卡、RJ45 LED、吞吐）
  board-wireless/          Wi-Fi（QCA1023 SDIO）+ 蓝牙（HCI UART）
  board-storage/           UFS / SD / NVMe、挂载、性能
  board-pcie/              PCIe / M.2（设备识别、链路速率、供电复位）
  board-5g/                5G 模块（RG520N、QRTR、控制面）
  board-power/             PMIC / 电源域 / 按键 / LED / RTC / 温度 / BCL
  board-fan/               风扇与温控（pwmfan hwmon + fan_ctrl.service）
  board-accel/             GPU / NPU / VPU（Adreno、HTP v68、Venus + VA-API）
  board-usb/               USB（Type-C / DP Alt、A 口、qusb 复合模式）
  board-factory/           工厂模式（fct_done_flag、AT 口、写号）
  board-screenshot/        板端截图（GNOME 门户 / weston）
scripts/
  install.sh               把 skills/ 装到 ~/.pi/agent/skills/
  skill-update-check.sh    对比 GitHub 上的版本，有新东西才提示
  board-check.sh           一次性打印这块板的自检快照
```

安装布局（`install.sh` 做的事，等价于手动）：

```
~/.pi/agent/skills/<name>/SKILL.md     软链到 pi-skills/skills/<name>/SKILL.md
~/.pi/agent/pi-skills/                 本仓库的检出（git clone）
```

用软链而不是拷贝：`git pull` 之后 skill 立刻是新内容，不用重装。

## 设计原则

1. **只写板子上验证过的命令**。每个 skill 末尾都有「实测记录」日期和当时输出，
   和实机不符就先当作未验证。
2. **不假设工具存在**。Debian 13 上没有 `pactl` / `gnome-screenshot` / `i2cdetect` /
   `gpioset`，每个 skill 都给出 sysfs 或 dbus 的等价写法，并标明哪条是「需要 apt install」。
3. **只读优先**。会改硬件状态的操作（改 LED、拉 GPIO、切 USB 模式）先说明影响和回退。
4. **两套 OS 分开写**。Debian 13 / Ubuntu 26.04 的差异集中在
   `board-overview` 的「OS 差异」一节，其它 skill 只提会变化的地方。
