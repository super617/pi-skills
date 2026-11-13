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
```

实测存在 `libQnnHtpV68Stub.so` / `libQnnHtpV68CalculatorStub.so`，
另外 V69/V73/V75/V79/V81 的 stub 也在（镜像通用打包，**只有 V68 能用**）。

`qnn-platform-validator` 实测加载的是
`libQnnHtpV68CalculatorStub.so` → 确认后端是 **v68**。

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
npu-chat --help             # 或直接跑，默认用 qwen
```

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

### 4.4 硬解播放

```bash
export GST_PLUGIN_PATH=/usr/lib/aarch64-linux-gnu/gstreamer-1.0:/usr/lib/gstreamer-1.0
gst-launch-1.0 -e filesrc location=/path/test.mp4 ! qtdemux ! h264parse \
    ! v4l2h264dec capture-io-mode=5 output-io-mode=5 ! videoconvert ! autovideosink
```

**没有软件解码器**（`avdec_h264` 缺失）。所以能看到画面，基本就说明走了硬解。

### 4.5 VA-API

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

### 4.6 怎么证明真走了 VPU（关键判据）

| 判据 | 做法 |
|---|---|
| Venus firmware 在日志里有流启动 | `sudo dmesg \| grep -i msm_vidc \| tail` |
| CPU 占用没打满 | `top -b -n1 \| head -12`，解码 1080p30 时单核不该 100% |
| 硬解插件被实际使用 | `GST_DEBUG=3 gst-launch-1.0 ...` 看选的是 `v4l2h264dec` |
| `/dev/video32` 被打开 | `sudo lsof /dev/video32` |

只看到"画面出来了"**不能**证明是硬解。

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
