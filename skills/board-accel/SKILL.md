---
name: board-accel
description: "板端算力: Adreno GPU(3d00000.gpu, 315/450/550MHz)、CDSP NPU(HTP v68, QNN 2.x + npu-chat)、Venus VPU(/dev/video32|33 + VA-API)。跑 NPU 推理/硬解视频/查 GPU 频率与负载/判断有没有真走硬件时用。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [gpu, adreno, npu, htp, qnn, vpu, venus, vaapi, v4l2, gstreamer, devfreq]
    related_skills: [board-overview, board-display, board-debug, board-power]
---

# 板端算力（GPU / NPU / VPU）

## 1. 三块硬件

| 硬件 | 内核节点 | 板端入口 |
|---|---|---|
| **Adreno GPU** | `/sys/class/devfreq/3d00000.gpu` | devfreq 频率、`/dev/dri/renderD128` |
| **CDSP / NPU（HTP v68）** | `/dev/fastrpc-cdsp`、`cdsprpcd.service` | QNN 库 + `qnn-net-run` / `npu-chat` |
| **Venus VPU** | `/dev/video32`（dec）+ `/dev/video33`（enc） | `v4l2h264dec`/`v4l2h264enc` + VA-API |

## 2. GPU

```bash
cat /sys/class/devfreq/3d00000.gpu/cur_freq          # 当前频率
cat /sys/class/devfreq/3d00000.gpu/max_freq
cat /sys/class/devfreq/3d00000.gpu/available_frequencies
cat /sys/class/devfreq/3d00000.gpu/governor
cat /sys/class/devfreq/3d00000.gpu/available_governors
```

实测：

```
cur_freq  = 315000000
max_freq  = 550000000
available = 315000000 450000000 550000000
governor  = simple_ondemand
available_governors = userspace simple_ondemand
```

空闲时 `315 MHz` 是**正常**（最低档），不是降频故障。

`/dev/dri/`：

```bash
ls /dev/dri/
# card0  renderD128  by-path
```

`glxinfo` 需要图形会话（root shell 里会报 `unable to open display`）：

```bash
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 glxinfo -B
```

## 3. NPU（CDSP / HTP v68）

### 3.1 前提：确认服务与设备节点

```bash
ls /dev/fastrpc-*
# 实测: /dev/fastrpc-adsp-secure  /dev/fastrpc-cdsp  /dev/fastrpc-cdsp-secure

for u in adsprpcd adsprpcd_audiopd cdsprpcd sscrpcd; do
  printf '%-20s %s\n' "$u" "$(systemctl is-active $u)"
done
# 全部应为 active
```

`/dev/fastrpc-cdsp` 不存在 → NPU 什么都跑不了，先查 `cdsprpcd`。

### 3.2 能力自检（最快确认 NPU 能用）

```bash
qnn-platform-validator --backend all --testBackend --targetPath /tmp/qnnval
```

实测输出（成功）：

```
Backend = GPU
{ Backend Hardware : Supported / Backend Libraries : Found / Unit Test : Passed }
Backend = DSP
{ Backend Hardware : Supported / Backend Libraries : Found / Unit Test : Passed }
```

`Unit Test : Passed` 就是判据。失败先看 `--debug`。

### 3.3 库版本

```bash
ls /usr/lib/libQnnHtp.so
ls /usr/lib/libQnnHtpV68*.so       # 本板是 V68
ls /usr/lib/libQnnGenAiTransformer*.so
strings /usr/lib/libQnnHtp.so | grep -E 'AISW_VERSION|^v2\.' | head -3
```

实测版本（2026-11-13）：

```
AISW_VERSION: 2.47.0
v2.47.0.260601114230
```

后端配置确认（`/usr/share/npu-llm/*/htp_backend_ext_config.json`）：

```json
{ "devices": [ { "soc_id": 35, "dsp_arch": "v68",
                  "cores": [ { "core_id": 0, "perf_profile": "burst",
                               "rpc_control_latency": 100 } ] } ],
  "memory": { "mem_type": "shared_buffer" } }
```

`soc_id 35` + `dsp_arch v68` —— 这就是为什么**只有 V68 的 stub 能用**：
镜像里虽然也带了 V69/V73/V75/V79/V81 的 stub，但那是通用打包。

### 3.4 跑推理

```bash
qnn-net-run --help          # 看参数
# 典型
qnn-net-run --model <model.so> --backend libQnnHtp.so --input_list <list.txt> --output_dir /tmp/out
```

现成的 LLM 应用：

```bash
ls /usr/share/npu-llm/
# llama3.2-1b/  qwen2.5-0.5b/  voice/
#   每个含 htp_backend_ext_config.json / model-config.json / models/ / tokenizer.json

command -v npu-chat
```

> ⚠️ **`npu-chat` 是个 GTK 图形程序，不是命令行工具**。
> 实测 `npu-chat --help` 在无显示环境会 `Gtk-CRITICAL ... GDK_IS_DISPLAY` 然后
> `Traceback ... Gtk.ApplicationWindow` 崩掉。
> 要用它必须从桌面图标启动，或在有会话变量的终端里：
> ```bash
> sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 npu-chat
> ```
> 想在命令行验 NPU，用 `qnn-platform-validator --testBackend`（§3.2）或
> `qnn-net-run`，不要用 `npu-chat`。

### 3.5 推理时看它到底在不在算

```bash
# CDSP 负载（如果镜像暴露）
cat /sys/class/thermal/thermal_zone*/type | grep -n nsp
cat /sys/class/thermal/thermal_zone$(...)  # nspss0/nspss1 温度会上升
watch -n1 'grep nspss /sys/class/thermal/thermal_zone*/type | head -2'

# fastrpc 调用痕迹
sudo dmesg | grep -i fastrpc | tail -5
```

判据：**nspss 温度上升** + `qnn-platform-validator --testBackend` 通过 + 推理有输出。
三者缺一不能断定"走了 NPU"。

## 4. VPU（Venus）硬解硬编

### 4.1 设备节点

```bash
ls /dev/video32 /dev/video33
v4l2-ctl -d /dev/video32 --list-formats-out      # 解码能力（输入码流）
v4l2-ctl -d /dev/video33 --list-formats-out      # 编码
```

实测 `video32`（decoder）支持：

```
[0]: 'H264'  [1]: 'HEVC'  [2]: 'VP90'  [3]: 'HEIC'
```

实测 `video33`（encoder）支持：`Q08C` / `NV12` / `NV21` 等。

### 4.2 firmware 版本

```bash
sudo dmesg | grep -i msm_vidc | head -5
# 实测: QC_IMAGE_VERSION_STRING=video-firmware.2.4.2-...
#       IMAGE_VARIANT_STRING=PROD
#       BUILD_TIME: Nov 12 2024
```

### 4.3 debugfs（看内部状态）

```bash
sudo ls /sys/kernel/debug/msm_vidc/
# core  core_clock_voting  ddr_bw_kbps  llc_bw_kbps  lossless_encoding
# disable_video_syscache  enable_bugon
```

### 4.4 播放：先看清楚这块镜像上什么真能跑

**结论先行：当前镜像上 GStreamer 硬解跑不起来，能用的是软解 `avdec_h264`。**
这一点和旧 SDK 文档写的不一样（旧镜像能硬解），下面是本机实测。

先确认两件事：

```bash
export GST_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/gstreamer-1.0:/usr/lib/gstreamer-1.0

# 1) 解码器的输出格式（这是关键）
v4l2-ctl -d /dev/video32 --list-formats
#   [0]: 'Q08C' (QCOM Compressed 8-bit Format, compressed)   ← QCOM 私有
#   [1]: 'NV12' [2]: 'NV21'

# 2) 现在生效的 v4l2 插件是哪一个
gst-inspect-1.0 v4l2h264dec | grep -E 'Filename|Version'
#   Filename  /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so
#   Version   1.26.2        ← Debian 原版，不是 BSP 那份
```

实测错误：

```
$ gst-launch-1.0 filesrc location=/tmp/v.h264 ! h264parse ! v4l2h264dec ! fakesink
ERROR: from element v4l2h264dec0: Video device uses an unsupported pixel format.
streaming stopped, reason not-negotiated (-4)
```

根因：`/dev/video32` 的 capture 端要 QCOM 私有格式，而实际被加载的 `v4l2h264dec`
是 Debian 1.26.2 原版插件（不认那些私有格式）。镜像里也没装 QCOM 自己的解码元素：

```bash
gst-inspect-1.0 | grep -iE 'c2d|qtivdec|vidcdec'
# → 没有。qti 系列只有 qtivtransform / qtivcomposer / qtivoverlay / qtiqmmfsrc …
```

所以下面这些写法**都会失败**（不要拿去让用户试）：

```
v4l2h264dec ! fakesink                       → not-negotiated
v4l2h264dec ! videoconvert ! autovideosink   → unsupported pixel format
v4l2h264dec device=/dev/video32 ! ...        → 同上
```

### 4.5 能用的播放写法（软解）

```bash
export GST_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/gstreamer-1.0:/usr/lib/gstreamer-1.0

# 文件是真 H.264 Annex-B 时（换 qtdemux 即可播 mp4）
gst-launch-1.0 -e filesrc location=/tmp/v.h264 \
    ! video/x-h264,stream-format=byte-stream,alignment=au ! h264parse \
    ! avdec_h264 ! videoconvert ! autovideosink
```

实测软解基准（300 帧 1280×720，`fakesink`）：

```
soft avdec_h264 : wall=0.48s  user=1.39s  sys=0.13s  cpu=315%
```

> **踩过的坑：`h264parse` 会拒长度前缀（AVCC）文件。**
> `x264enc` 直接 `! filesink` 写出的是 `00 00 00 02 09 10 …`（长度前缀），
> `h264parse` 报 `No valid frames found before end of stream`。
> 两种解法：编码端加 caps `video/x-h264,stream-format=byte-stream,alignment=au`，
> 或解码端显式给同一组 caps。文件头是 `00 00 00 01` 才是 Annex-B。

### 4.6 VA-API

```bash
vainfo
# 实测: VA-API 1.22 (libva 2.22.0)
#       Driver version: Qualcomm Venus stateful V4L2 VA-API backend 0.3.0
#       9 个 profile（H264 CB/Main/High、HEVC Main、VP9 Profile0 等，VLD + EncSlice）
```

root shell 里要先设显示变量，否则 `vainfo` 会走 x11 然后失败：

```bash
LIBVA_DRIVER_NAME=msm XDG_RUNTIME_DIR=/run/user/1001 vainfo
```

### 4.7 怎么证明真走了 VPU（判据）

**前提：V4L2 那条路当前是断的（§4.4），所以现阶段没有可用的硬解链路可证明。**
真要验证 VPU，按下面的判据，不能只看“画面出来了”：

| 判据 | 做法 |
|---|---|
| Venus firmware 启动了流 | `sudo dmesg \| grep -i msm_vidc \| tail`，找 `CmdDec`：`264d` / `265d` |
| 解码器被真打开 | `sudo lsof /dev/video32`（解码时应有进程持着） |
| 格式协商成功 | `GST_DEBUG=v4l2*:4` 看有没有走到 `VIDIOC_S_FMT` |
| CPU 不被打满 | `top -b -n1 \| head -12`；720p30 硬解不应吃掉多核 |

实测一次**失败**尝试留下的日志长这样（可用它反向确认走了哪个节点）：

```
msm_vidc: fw: <VFW_E:CmdDec:264d:...> vDec_SetSubscribeMode(4725):
    Subscribe unsupported port 1 property 300017a
```

只要看到 `CmdDec` 就说明**进了解码器**（即使后面协商失败）；
完全没这条，就是根本没到 VPU。

## 5. 环境变量（这块板上很关键）

`/etc/environment` 里已设：

```
LIBVA_DRIVER_NAME=msm
GST_VA_ALL_DRIVERS=1
GST_PLUGIN_FEATURE_RANK=vah264dec:MAX
GST_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/gstreamer-1.0:/usr/lib/gstreamer-1.0
```

`/etc/profile.d/gst-qti-plugins.sh` 也导出了同一个 `GST_PLUGIN_PATH`。

手动跑时（尤其 root shell）：

```bash
export GST_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/gstreamer-1.0:/usr/lib/gstreamer-1.0
export LIBVA_DRIVER_NAME=msm
export XDG_RUNTIME_DIR=/run/user/1001
export WAYLAND_DISPLAY=wayland-0
```

## 6. 已知坑

| 现象 | 原因 | 处置 |
|---|---|---|
| GPU 315MHz 以为降频 | 空闲最低档 | §2 |
| `glxinfo` / `vainfo` root 下报 display 错 | 无会话变量 | §5 |
| NPU 全都不工作 | `/dev/fastrpc-cdsp` 缺或 `cdsprpcd` 没起 | §3.1 |
| NPU 报后端版本不对 | 误用 V69/V73 等 stub | 本板只有 **V68** 能用 |
| 硬解不出画面 | 用了 `avdec_h264`（不存在） | 用 `v4l2h264dec` |
| 有画面但 CPU 满 | 可能走了其它路径 | §4.6 判据 |
| `v4l2-ctl` 报 `VIDIOC_ENUM_FMT` 空 | 查错了设备类型（out vs cap） | `--list-formats-out` vs `--list-formats` |

## 7. 实测记录

- 2026-11-13，Debian 13 / kernel 6.6.116
- GPU：devfreq `3d00000.gpu`，`cur=315MHz max=550MHz`，
  `available=315/450/550MHz`，governor `simple_ondemand`
- NPU：`/dev/fastrpc-cdsp` 存在；`adsprpcd`/`adsprpcd_audiopd`/`cdsprpcd`/`sscrpcd` 全 active；
  `qnn-platform-validator --backend all --testBackend` → GPU Passed / DSP Passed；
  后端库 `libQnnHtpV68CalculatorStub.so`（确认 v68）
- VPU：`/dev/video32`(dec: H264/HEVC/VP90/HEIC)、`/dev/video33`(enc)；
  firmware `video-firmware.2.4.2`；debugfs 节点齐全
- VA-API：`Qualcomm Venus stateful V4L2 VA-API backend 0.3.0`，9 个 profile
- 现成应用：`/usr/share/npu-llm/{llama3.2-1b,qwen2.5-0.5b,voice}`、`/usr/bin/npu-chat`
- `glxinfo` 在 root shell 下 `unable to open display`（预期）
