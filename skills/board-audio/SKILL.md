---
name: board-audio
description: "板端音频: WCD9370 + AW8010 功放 + LT9611 HDMI 音频,走 PAL 插件到 PipeWire。板子上没有 pactl,只有 wpctl/pw-play/pw-record;root 下必须先设 XDG_RUNTIME_DIR 否则 Connection refused。无声/切换输出/录音/HDMI 音频/看 PAL 和 AGM 日志时用。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [audio, pipewire, wpctl, pal, agm, wcd9370, aw8010, hdmi, alsa, tinymix]
    related_skills: [board-overview, board-debug, board-camera]
---

# 板端音频

## 1. 硬件与软件栈

```
应用 (wpctl / pw-play / pw-record / gst / GNOME 音量)
   └── PipeWire 1.4.2  ── module-pal.so（PAL 插件）
          └── PAL (qcom-agm) ── AGM/APM ── ADSP (adsprpcd)
                 └── WCD9370(SoundWire) / LPASS macros / AW8010 PA / LT9611 I2S
```

声卡只有一个：`card0 = qcm6490-idp-snd-card`。

```bash
cat /proc/asound/cards          # 0 [qcm6490idpsndca]: qcm6490 - qcm6490-idp-snd-card
cat /proc/asound/pcm
```

本机实测的 PCM 设备（**别按名字猜用途**）：

| 设备 | 名字 | 用途 |
|---|---|---|
| `hw:0,0` | `CODEC_DMA-LPAIF_RXTX-RX-0 multicodec-0` | **主播放**（扬声器/耳机，走 PAL） |
| `hw:0,1` | `CODEC_DMA-LPAIF_RXTX-TX-3 multicodec-1` | 录音 |
| `hw:0,2` | `CODEC_DMA-LPAIF_VA-TX-0 va_macro_tx1-2` | VA macro（语音唤醒/第二路录音） |
| `hw:0,3` | `DISPLAY_PORT-RX i2s-hifi-3` | **HDMI / DP 音频** |
| `hw:0,4` | `MI2S-LPAIF-RX-PRIMARY i2s-hifi-4` | 第二路 I2S 播放 |

## 2. 第一步永远是：设会话变量 + 用桌面用户

这是这块板上音频问题最常见的假故障来源。

```bash
# root shell 里直接跑 pw-play 会:
#   error: pw_context_connect() failed: Connection refused
# 正确写法:
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
    wpctl status
```

已登录桌面的 `p` 用户自己跑就不用加 `sudo -u p`。

## 3. 看有哪些 sink / source

```bash
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 wpctl status
```

本机实测（截取 Audio 段）：

```
Audio
 ├─ Sinks:
 │      45. pal sink speaker          [vol: 1.00]
 │  *   51. pal sink hdmi audio       [vol: 0.94]     ← * 是默认
 ├─ Sources:
 │  *   48. pal source handset mic    [vol: 1.00]
```

完整节点名（给脚本用）：

```bash
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 \
    pw-cli ls Node 2>/dev/null | grep -E 'node.name|node.description'
```

实测值：`pal_sink_speaker` / `pal_sink_hdmi_out` / `pal_source_speaker_mic`。

> **没有 `pactl`**。所有 `pactl list short sinks`、`pactl set-default-sink` 之类
> 在这块板上都会 `command not found`。等价写法见下表。

| 想做的事 | PulseAudio 写法（**这板没有**） | 板端写法 |
|---|---|---|
| 列出 sink | `pactl list short sinks` | `wpctl status` |
| 设默认输出 | `pactl set-default-sink X` | `wpctl set-default <id>` |
| 音量 | `pactl set-sink-volume X 80%` | `wpctl set-volume <id> 0.8` |
| 静音 | `pactl set-sink-mute X 1` | `wpctl set-mute <id> 1` |
| 切端口 | `pactl set-sink-port` | `wpctl set-route <id> <index>` |
| 切 profile | `pactl set-card-profile` | `wpctl set-profile <id> <index>` |
| 播放文件 | `paplay x.oga` | `pw-play [--target <id>] x.oga` |
| 录音 | `parec x.wav` | `pw-record x.wav` |

`wpctl` 实测支持的全部子命令（`wpctl --help`）：

```
status  get-volume ID  inspect ID  set-default ID
set-volume ID VOL[%][-/+]   set-mute ID 1|0|toggle
set-profile ID INDEX        set-route ID INDEX
clear-default [ID]          settings [KEY] [VAL]
set-log-level [ID] LEVEL
```

## 4. 切输出（扬声器 ↔ HDMI）

```bash
# 看当前默认
wpctl status | grep -A4 '├─ Sinks'

# 切到扬声器（id 每次开机可能变，先 status 查）
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 wpctl set-default 45

# 切到 HDMI
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 wpctl set-default 51

# 临时播放到指定 sink（不改默认）
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 pw-play --target 45 /path/to.oga
```

## 5. 播放 / 录音验证

```bash
# 播放（实测可用的最小命令）
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 \
    pw-play /usr/share/sounds/freedesktop/stereo/window-attention.oga

# 生成测试音并播放（不需要现成音频文件）
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 \
    gst-launch-1.0 -q audiotestsrc num-buffers=100 wave=sine freq=440 \
    ! audio/x-raw,rate=48000,channels=2 ! audioconvert ! pipewiresink

# 录音 3 秒
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 \
    timeout 3 pw-record --rate 48000 --channels 1 /tmp/rec.wav
ls -l /tmp/rec.wav            # 实测 3 秒 ≈ 364 KB（48k/mono/16bit 的 wav）

# 回放刚才录的
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 pw-play /tmp/rec.wav
```

> `aplay -D hw:0,0 file.wav` 可能报 `pcm_write: write error: Invalid argument`：
> PCM 是 PAL 管的，要求 48 kHz / 立体声。**别用 aplay 做验收**，用 `pw-play`。
> 非要 aplay 就转格式：`gst-launch-1.0 filesrc ... ! wavparse ! audioconvert
> ! audioresample ! audio/x-raw,rate=48000,channels=2 ! alsasink device=hw:0,0`

## 6. 音量 / 静音

```bash
export XDG_RUNTIME_DIR=/run/user/1001
wpctl set-volume 45 0.8         # 0.0 ~ 1.0
wpctl set-volume 45 5%+         # 相对加 5%
wpctl set-mute 45 1             # 静音；0 取消
wpctl get-volume 45
```

## 7. HDMI / DP 音频

HDMI 有独立 sink（`pal_sink_hdmi_out`，`hw:0,3`）。总线上的 jack 事件：

```bash
cat /proc/bus/input/devices | grep -A4 'HDMI/DP'
# 实测存在两个: "HDMI/DP0 Jack"(event11)  "HDMI/DP1 Jack"(event12)
# 还有一个 "Headset Jack"(event10) —— 耳机插入检测
```

显示器不播音频的排查顺序：

1. `wpctl status` 里有没有 `pal sink hdmi audio`（没有 → 显示链路没通，先查 `board-display`）
2. `sudo dmesg | grep -iE 'hdmi.*audio|hdmi_codec|snd_soc_hdmi'`
3. `modetest`/显示模式里音频是否使能（HDMI 音频随显示时序走）
4. 默认 sink 是不是还指着 speaker

## 8. 底层控件（tinymix / amixer）

板上 **226 个 ALSA 控件**。它们是 WCD9370 的 codec 控件，**PAL 通常已经配好了**，
改之前先记住原值。

```bash
tinymix contents                 # 226 行全表
tinymix contents | head -20
tinymix get 'RX HPH Mode'
tinymix set 'RX HPH Mode' CLS_H_HIFI
amixer -c 0 scontrols | head      # 简表：CLSH / ADC1 / DEC0 MODE ...
```

> **不要拿 tinymix 当"调音量"用**：音量应该走 `wpctl`。tinymix 改的是 codec 增益，
> PAL 拉流时会重写，改了不一定生效，而且容易影响耳机/扬声器的保护逻辑。

## 9. 排查用日志

dmesg 里几乎没有音频信息，**必须看 journalctl**：

```bash
journalctl -b --no-pager | grep -iE 'pal_stream|agm_session|graph_start|sdw|wcd9370|aw8010|lpass'
```

实测输出样貌（正常停止流时）：

```
pipewire[4083]: pal_stream_stop: 392: Enter. Stream handle :0x...
pipewire[4083]: agm_session_aif_connect: 648 disconnecting aifid:2 with session id=112
pipewire[4083]: close: 504: Exit. deviceCount 0 for device id 28 (PAL_DEVICE_IN_SPEAKER_MIC), exit status 0
```

`exit status 0` = 正常。出现 `PAL_DEVICE_*` 名字能直接告诉你哪条通路。

用户会话服务状态：

```bash
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user is-active pipewire wireplumber
```

## 10. 已知坑

| 现象 | 原因 | 处置 |
|---|---|---|
| `pw_context_connect() failed: Connection refused` | root shell 没会话变量 | §2 |
| `pwctl: command not found` | 用错了名字，是 `wpctl` | §3 |
| `pactl: not found` | 板上就是没有 | 用 §3 的表换写法 |
| `Could not connect to PipeWire`（`wpctl`） | 同上，缺 `XDG_RUNTIME_DIR` | §2 |
| `systemctl is-active pipewire` = inactive | 是 user 作用域 | §9 |
| 扬声器无声但 `aplay -l` 正常 | PCM 被 PAL 独占/格式不对 | 用 `pw-play` 验收 |
| 插入耳机没切换 | jack 事件到了但 PAL 端口没切 | `wpctl inspect <id>` 看 port；或看 journal 里 `PAL_DEVICE_OUT_HEADSET` |
| gst 报 `Couldn't g_module_open libpython` | gst 的 python 插件缺库 | 无害噪音，不影响音频通路 |
| 想跑 `speaker-test` | 板上没这个命令 | 用 §5 的 `audiotestsrc` |

## 11. 实测记录

- 2026-11-13，Debian 13，kernel 6.6.116，PipeWire 1.4.2，用户 p(uid 1001)
- `pactl` / `paplay` / `parec` / `speaker-test` **均不存在**；`wpctl` / `pw-play` /
  `pw-record` / `pw-cli` / `gst-launch-1.0` / `aplay` / `arecord` / `tinymix` 存在
- Sinks: `45 pal_sink_speaker`、`51 pal_sink_hdmi_out`；Source: `48 pal_source_speaker_mic`
- `pw-play --target 45` 与 `gst ... ! pipewiresink` 都能正常播（rc=0）
- `pw-record` 3 秒产出 364588 字节 wav
- `aplay -D hw:0,0` 直接放 wav 会 `pcm_write: Invalid argument`（格式/PAL 独占）
- root 直接 `pw-play` → `Connection refused`；`sudo -u p env XDG_RUNTIME_DIR=...` 正常
