#!/usr/bin/env python3
"""board-skills-prompt -- ask the person on the board whether to update the skills.

Started by `board-skills autostart` when a newer pi-skills snapshot exists and
there is a desktop session. Exit status is the answer, so the caller does not
have to parse anything:

    0   update now
    1   later (ask again next login)
    2   do not ask again for this version
    3   no display / GTK unavailable -- the caller falls back to a tty question

The dialog is deliberately plain GTK4, no libadwaita: this has to render on the
Debian 13 image (GTK 4.18) and on Ubuntu 26.04 (GTK 4.22) and must not fail if
libadwaita is missing.

    board-skills-prompt.py <installed-version> <remote-version>
"""

import sys

try:
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, GLib
except (ImportError, ValueError):
    sys.exit(3)

RESULT_UPDATE = 0
RESULT_LATER = 1
RESULT_NEVER = 2

APP_ID = "org.quectel.PiSkillsUpdate"


def build(local_version, remote_version):
    """Return (window, state). state["result"] is what main() reports."""
    state = {"result": RESULT_LATER}

    window = Gtk.Window()
    window.set_title("Pi 技能包更新")
    window.set_default_size(520, -1)
    window.set_resizable(False)

    header = Gtk.HeaderBar()
    window.set_titlebar(header)

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
    box.set_margin_top(22)
    box.set_margin_bottom(18)
    box.set_margin_start(22)
    box.set_margin_end(22)
    window.set_child(box)

    icon = Gtk.Image.new_from_icon_name("software-update-available-symbolic")
    icon.set_pixel_size(56)
    box.append(icon)

    title = Gtk.Label()
    title.set_markup("<b>板端技能包有新版</b>")
    box.append(title)

    detail = Gtk.Label()
    detail.set_wrap(True)
    detail.set_xalign(0.5)
    detail.set_justify(Gtk.Justification.CENTER)
    detail.add_css_class("dim-label")
    detail.set_text(
        "已安装 %s\n远端 %s\n\n"
        "更新会把板端技能说明换成仓库里的最新版本。"
        "不影响 pi 本身、你的会话记录或 API 配置；"
        "更新失败时会继续用当前这份。" % (local_version, remote_version))
    box.append(detail)

    # Where it will be written, spelled out: this touches the home directory and
    # people deserve to see the path before saying yes.
    path = Gtk.Label()
    path.set_xalign(0.5)
    path.set_selectable(True)
    path.add_css_class("dim-label")
    path.set_text("~/.pi/agent/pi-skills")
    box.append(path)

    buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
    buttons.set_halign(Gtk.Align.CENTER)
    buttons.set_margin_top(6)

    def finish(result):
        state["result"] = result
        window.close()

    never = Gtk.Button(label="这一版不再提醒")
    never.set_tooltip_text("下次有新提交时仍会提示")
    never.connect("clicked", lambda *_: finish(RESULT_NEVER))
    buttons.append(never)

    later = Gtk.Button(label="稍后")
    later.connect("clicked", lambda *_: finish(RESULT_LATER))
    buttons.append(later)

    update = Gtk.Button(label="现在更新")
    update.add_css_class("suggested-action")
    update.set_size_request(140, 40)
    update.connect("clicked", lambda *_: finish(RESULT_UPDATE))
    buttons.append(update)

    box.append(buttons)

    # Closing the window means "later": the default in state["result"] is
    # already RESULT_LATER, so no close-request handler is needed (returning
    # True there would block the close instead of recording the answer).

    return window, state


def main(argv):
    if len(argv) != 2:
        print("usage: board-skills-prompt.py <installed> <remote>", file=sys.stderr)
        return 3

    local_version, remote_version = argv

    app = Gtk.Application(application_id=APP_ID)

    def on_activate(_app):
        window, state = build(local_version, remote_version)
        window.set_application(_app)
        window.present()
        # Keep the answer reachable after the main loop exits.
        app.answer = state

    app.connect("activate", on_activate)

    # GTK4 has no gtk_main_quit equivalent to Gtk.main_quit; the application
    # ends when the last window closes, which is exactly what finish() does.
    app.run([])
    return getattr(app, "answer", {"result": RESULT_LATER})["result"]


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(RESULT_LATER)
