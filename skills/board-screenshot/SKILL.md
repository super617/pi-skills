---
name: board-screenshot
description: "板端截图: Debian/Ubuntu 上都没有 gnome-screenshot 和 grim 时,怎么用 GNOME Screenshot portal(gdbus)截屏,如何指定输出路径、非交互截取、以及 weston 会话下的做法。用户要'截个图看看'时用。"
version: 1.0.0
license: MIT
platforms: [linux]
metadata:
  pi:
    tags: [screenshot, gnome, portal, gdbus, weston, wayland, display]
    related_skills: [board-overview, board-display, board-debug]
---

# 板端截图

## 0. 先看清楚：这板上没有截图命令

实测（Debian 13 和 Ubuntu 26.04 都一样）：

```
gnome-screenshot   ✗ 未安装
grim               ✗ 未安装
weston-screenshooter ✓ 有（但只在 weston 会话下能用）
gdbus              ✓ 有  ← 用这个
```

所以**不要**建议 `gnome-screenshot -f x.png`，那条命令会直接 `command not found`。

## 1. GNOME 会话（Debian / Ubuntu 桌面默认）：用 Screenshot portal

原理：GNOME 从 41 起禁止直接调 `org.gnome.Shell.Screenshot`（会返回
`AccessDenied: Screenshot is not allowed`），正确入口是 xdg-desktop-portal。

### 1.1 一句话版（root 下也能跑）

```bash
export XDG_RUNTIME_DIR=/run/user/1001
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus

gdbus call --session \
  --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Screenshot.Screenshot \
  "" '{"interactive": <false>, "handle_token": <"shot1">}'
```

返回一个 request 对象路径，**调用成功 ≠ 已经出图**。文件不是直接给到
你指定的路径，而是落在默认图库里：

```
~/Pictures/Screenshot-N.png
```

（首次是 `Screenshot-1.png`，之后递增。）

### 1.2 要指定输出路径：给 `uri` 参数（可选，按版本支持）

```bash
gdbus call --session --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Screenshot.Screenshot \
  "" '{"interactive": <false>, "handle_token": <"shot2">, "modal": <false>}'
```

> `uri` 在部分 portal 版本被忽略。**最稳的写法**：截到 `~/Pictures/`，然后自己 mv：
> ```bash
> latest=$(ls -t ~p/Pictures/Screenshot-*.png | head -1)
> cp "$latest" /tmp/shot.png
> ```

### 1.3 等它真的落盘（脚本里必须等）

portal 是异步的，`gdbus call` 立刻返回，图晚 1~3 秒才出现。轮询：

```bash
before=$(ls -t ~p/Pictures/Screenshot-*.png 2>/dev/null | head -1)
gdbus call --session --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Screenshot.Screenshot \
  "" '{"interactive": <false>, "handle_token": <"shot3">}' >/dev/null

for i in $(seq 1 20); do
    sleep 0.5
    now=$(ls -t ~p/Pictures/Screenshot-*.png 2>/dev/null | head -1)
    [ "$now" != "$before" ] && [ -n "$now" ] && { echo "$now"; break; }
done
```

现成的封装：`scripts/board-shot.sh`（见 §4）。

### 1.4 以桌面用户身份跑（更稳）

root 有时连不上 p 的 session bus，直接切身份最省事：

```bash
sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
    gdbus call --session --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop \
      --method org.freedesktop.portal.Screenshot.Screenshot \
      "" '{"interactive": <false>, "handle_token": <"shot4">}'
```

## 2. 确认 portal 在不在

```bash
ls /usr/share/xdg-desktop-portal/portals/
# 期望: gnome.portal  gtk.portal  gnome-keyring.portal

sudo -u p env XDG_RUNTIME_DIR=/run/user/1001 gdbus call --session \
    --dest org.freedesktop.portal.Desktop --object-path / \
    --method org.freedesktop.DBus.Peer.Ping
```

没有 `gnome.portal` 就说明桌面不是 GNOME（可能是 weston），走 §3。

## 3. weston 会话

```bash
# 需要 WESTON 的 socket，通常 /run/user/1001/wayland-0 或 /tmp/wayland-0
ls /run/user/1001/wayland-* /tmp/wayland-* 2>/dev/null
weston-screenshooter           # 交互式，按提示
```

或用 weston 自带按键（`Super+S`，取决于 `weston.ini` 的 `[shell]` 配置）。

## 4. 直接可用的脚本

```bash
bash ~/.pi/agent/pi-skills/scripts/board-shot.sh            # → ~/Pictures/ 下最新一张
bash ~/.pi/agent/pi-skills/scripts/board-shot.sh /tmp/a.png  # → 拷到指定路径并打印
```

脚本自己处理：设环境变量、调 portal、轮询落盘、拷到目标路径、打印结果路径。

## 5. 已知坑

| 现象 | 原因 | 解 |
|---|---|---|
| `AccessDenied: Screenshot is not allowed` | 直接调了 `org.gnome.Shell.Screenshot` | 改走 portal（§1） |
| `XDG_RUNTIME_DIR is invalid or not set` | root shell 没继承桌面会话变量 | 按 §1.1 设 |
| `Could not connect: No such file or directory` | bus 地址不对，或没人登录桌面 | `who` 确认有 `seat0` 会话；`loginctl list-sessions` |
| `gdbus call` 返回成功但没文件 | portal 异步；或会话被锁屏 | 按 §1.3 轮询；锁屏状态下截不到 |
| 截出来全黑 | Wayland 下硬件合成器 + 受保护内容 | 换 weston 会话试；或确认不是 DRM 独占 |

## 6. 实测记录

- 2026-11-13，Debian 13 / GNOME Shell 48.7 / Wayland / 用户 p(uid 1001)：
  - `org.gnome.Shell.Screenshot` → `AccessDenied: Screenshot is not allowed`
  - `org.freedesktop.portal.Screenshot.Screenshot`（`interactive=false`）→ 成功，
    文件落 `/home/p/Pictures/Screenshot-N.png`
  - `gnome-screenshot` / `grim` 均未安装
  - 附加现象：`x11` 分支会报 `can't connect to X server`（正常，是 Wayland 会话）
