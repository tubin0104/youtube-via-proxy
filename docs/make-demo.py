#!/usr/bin/env python
"""Render docs/demo.png — a Chinese terminal-style screenshot of the workflow.

Drawn with Pillow so the output is deterministic and independent of any browser
or headless-rendering dependency. Uses Windows fonts when present, and falls back
to Pillow's bitmap font otherwise.

Run:
    python docs/make-demo.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "demo.png")

# Layout
PAD = 28
WIN_W = 1120
TITLEBAR_H = 36
TERM_PAD_X = 20
TERM_PAD_Y = 16
FONT_SIZE = 14
LINE_H = 23
SCALE = 2  # render at 2x then downscale for crisp text

# Palette (dark terminal)
BG = (12, 12, 12)
WIN_BORDER = (43, 43, 43)
TITLEBAR_BG = (31, 31, 31)
DOT_RED = (255, 95, 87)
DOT_YELLOW = (254, 188, 46)
DOT_GREEN = (40, 200, 64)
C_TEXT = (204, 204, 204)
C_PROMPT = (78, 201, 176)
C_PATH = (86, 156, 214)
C_CMD = (220, 220, 220)
C_OUT = (154, 154, 154)
C_OK = (106, 153, 85)
C_HL = (206, 145, 120)
C_VAL = (181, 206, 168)
C_WARN = (215, 186, 125)
C_DIM = (110, 110, 110)
C_BADGE_BG = (38, 79, 120)
C_BADGE_FG = (207, 232, 255)


def pick_font(size):
    """Prefer a font that covers both CJK and monospace ASCII."""
    candidates = [
        (r"C:\Windows\Fonts\msyh.ttc", 0),      # Microsoft YaHei
        (r"C:\Windows\Fonts\simhei.ttf", 0),    # SimHei
        (r"C:\Windows\Fonts\consola.ttf", 0),   # Consolas (no CJK)
    ]
    for path, index in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size, index=index)
            except OSError:
                continue
    return ImageFont.load_default()


def S():
    """Spacer line."""
    return [("", None, True)]


SCRIPT = [
    # 1. clone
    [("PS ", C_PROMPT), ("D:\\tools\\youtube-via-proxy> ", C_PATH),
     ("git clone https://github.com/tubin0104/youtube-via-proxy.git", C_CMD)],
    [("Cloning into 'youtube-via-proxy'...", C_OUT)],
    [("remote: Enumerating objects: 12, done.", C_OUT)],
    [("Receiving objects: 100% (12/12), 18.41 KiB | 2.30 MiB/s, done.", C_OK)],
    S(),
    # 2. install
    [("PS ", C_PROMPT), ("D:\\tools\\youtube-via-proxy> ", C_PATH),
     (".\\install-skill.ps1", C_CMD), ("[1] 检查环境", C_BADGE_FG)],
    [("installed skill -> C:\\Users\\you\\.agents\\skills\\youtube-via-proxy\\SKILL.md", C_OUT)],
    [("tool dir       -> D:\\tools\\youtube-via-proxy", C_OUT)],
    [("checking prerequisites...", C_OUT)],
    [("  python: C:\\Python312\\python.exe (3.12)", C_OK)],
    [("  node  : C:\\Program Files\\nodejs\\node.exe", C_OK)],
    [("  ffmpeg: C:\\ProgramData\\chocolatey\\bin\\ffmpeg.exe", C_OK)],
    [("  proxy : 127.0.0.1:10808 UP", C_OK)],
    S(),
    # 3. cookies
    [("PS ", C_PROMPT), ("D:\\tools\\youtube-via-proxy> ", C_PATH),
     (".\\yt-fetch.ps1 -Mode cookies", C_CMD), ("[2] 导出 cookie", C_BADGE_FG)],
    [("Exporting cookies from chrome ...", C_OUT)],
    [("master key: 32 bytes", C_OUT)],
    [("decrypt backend: node", C_OUT)],
    [("wrote 23 cookies -> D:\\tools\\youtube-via-proxy\\cookies.txt", C_OK)],
    S(),
    # 4. info
    [("PS ", C_PROMPT), ("D:\\tools\\youtube-via-proxy> ", C_PATH),
     (".\\yt-fetch.ps1 -Url TI66H3VDE3Y -Mode info", C_CMD), ("[3] 抓元数据", C_BADGE_FG)],
    [("mode: proxy http://127.0.0.1:10808", C_DIM)],
    [("解决 Cloudflare 免费科学上网的一切问题。CFPilot丨自动部署丨高速节点丨优选 IP", C_HL)],
    [("author: ", C_OUT), ("世敬天", C_VAL)],
    [("duration_sec: ", C_OUT), ("961", C_VAL)],
    [("upload_date: ", C_OUT), ("20261106", C_VAL)],
    [("view_count: ", C_OUT), ("45364", C_VAL)],
    [("subtitles: ", C_OUT), ("NA", C_WARN), ("   <- 该视频没有字幕轨", C_DIM)],
    S(),
    # 5. video
    [("PS ", C_PROMPT), ("D:\\tools\\youtube-via-proxy> ", C_PATH),
     (".\\yt-fetch.ps1 -Url TI66H3VDE3Y -Mode video -Format 134", C_CMD),
     ("[4] 下视频", C_BADGE_FG)],
    [("[download] 100% of    5.01MiB in 00:04 at 1.09MiB/s", C_OUT)],
    [('[Merger] Merging formats into "out\\TI66H3VDE3Y.mp4"', C_OK)],
    S(),
    # 6. hardsubs
    [("PS ", C_PROMPT), ("D:\\tools\\youtube-via-proxy> ", C_PATH),
     (".\\extract-hardsubs.ps1 -Video .\\out\\TI66H3VDE3Y.mp4 -Interval 12", C_CMD),
     ("[5] 抽硬字幕", C_BADGE_FG)],
    [("sampling every 12s", C_OUT)],
    [("crop: iw:ih*0.20:0:ih*0.80", C_OUT)],
    [("produced 80 strips", C_OK)],
    [("index N corresponds to t = (N-1) * 12 seconds", C_DIM)],
]

BADGE_GAP = 22 * SCALE   # space between the command text and its chip


def main():
    font = pick_font(FONT_SIZE * SCALE)
    dummy = Image.new("RGB", (10, 10))
    ddraw = ImageDraw.Draw(dummy)

    spacer_h = int(LINE_H * SCALE * 0.55)
    content_h = 0
    for segs in SCRIPT:
        if len(segs) == 1 and len(segs[0]) == 3:
            content_h += spacer_h
        else:
            content_h += LINE_H * SCALE

    term_h = TERM_PAD_Y * SCALE * 2 + content_h
    win_h = TITLEBAR_H * SCALE + term_h
    img_w = WIN_W * SCALE
    img_h = PAD * SCALE * 2 + win_h

    img = Image.new("RGB", (img_w, img_h), BG)
    draw = ImageDraw.Draw(img)

    x0, y0 = PAD * SCALE, PAD * SCALE
    x1, y1 = x0 + WIN_W * SCALE, y0 + win_h
    draw.rounded_rectangle([x0, y0, x1, y1], radius=10 * SCALE,
                           fill=BG, outline=WIN_BORDER, width=max(1, SCALE // 2))

    draw.rounded_rectangle([x0, y0, x1, y0 + TITLEBAR_H * SCALE], radius=10 * SCALE,
                           fill=TITLEBAR_BG, outline=WIN_BORDER, width=max(1, SCALE // 2))
    draw.rectangle([x0 + SCALE, y0 + TITLEBAR_H * SCALE - 2 * SCALE,
                    x1 - SCALE, y0 + TITLEBAR_H * SCALE], fill=TITLEBAR_BG)

    dot_y = y0 + TITLEBAR_H * SCALE // 2
    dot_r = 6 * SCALE
    for i, color in enumerate((DOT_RED, DOT_YELLOW, DOT_GREEN)):
        cx = x0 + (16 + i * 20) * SCALE
        draw.ellipse([cx - dot_r, dot_y - dot_r, cx + dot_r, dot_y + dot_r], fill=color)

    title_font = pick_font(11 * SCALE)
    draw.text((x0 + 96 * SCALE, dot_y), "Windows PowerShell — youtube-via-proxy",
              font=title_font, fill=(184, 184, 184), anchor="lm")

    ty = y0 + TITLEBAR_H * SCALE + TERM_PAD_Y * SCALE
    tx = x0 + TERM_PAD_X * SCALE

    for segs in SCRIPT:
        if len(segs) == 1 and len(segs[0]) == 3:
            ty += spacer_h
            continue

        cx = tx
        for item in segs:
            text, color = item[0], item[1]
            if not text:
                continue
            if color == C_BADGE_FG:
                # Chips sit after the command; reserve real horizontal space.
                cx += BADGE_GAP
                w = ddraw.textlength(text, font=font)
                draw.rounded_rectangle(
                    [cx, ty + 4 * SCALE, cx + w + 16 * SCALE, ty + LINE_H * SCALE - 4 * SCALE],
                    radius=4 * SCALE, fill=C_BADGE_BG)
                draw.text((cx + 8 * SCALE, ty), text, font=font, fill=C_BADGE_FG)
                cx += w + 16 * SCALE
                continue
            draw.text((cx, ty), text, font=font, fill=color)
            cx += ddraw.textlength(text, font=font)
        ty += LINE_H * SCALE

    final = img.resize((img_w // SCALE, img_h // SCALE), Image.LANCZOS)
    final.save(OUT, "PNG", optimize=True)
    print("wrote %s (%dx%d)" % (OUT, final.width, final.height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
