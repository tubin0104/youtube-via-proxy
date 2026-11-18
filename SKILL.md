---
name: youtube-via-proxy
description: Use to read a YouTube video (metadata, subtitles, audio, video, or burned-in subtitles) when direct access fails or YouTube answers "Sign in to confirm you're not a bot". Covers local-proxy CONNECT tunnelling, browser cookie export, yt-dlp with a JS runtime plus the remote EJS component, and hard-subtitle frame sampling. 触发场景：要“看一下/理解一下”某个 YouTube 视频、抓字幕、下载音频/视频、或遇到 YouTube 登录验证拦截。
---

# YouTube 内容获取

工具目录：`{{TOOL_DIR}}`（由 install-skill.ps1 按实际位置写入）

## 快速开始

```powershell
$t = "{{TOOL_DIR}}"

# 0. 首次：导出浏览器 cookie（YouTube 反爬必需）
powershell -NoProfile -ExecutionPolicy Bypass -File "$t\yt-fetch.ps1" -Mode cookies

# 1. 元数据
powershell -NoProfile -ExecutionPolicy Bypass -File "$t\yt-fetch.ps1" -Url <URL或ID> -Mode info

# 2. 字幕轨（视频有轨时）
powershell -NoProfile -ExecutionPolicy Bypass -File "$t\yt-fetch.ps1" -Url <URL或ID> -Mode subs

# 3. 音频
powershell -NoProfile -ExecutionPolicy Bypass -File "$t\yt-fetch.ps1" -Url <URL或ID> -Mode audio

# 4. 视频（-Format 134 = 360p，体积小，适合抽帧看内容）
powershell -NoProfile -ExecutionPolicy Bypass -File "$t\yt-fetch.ps1" -Url <URL或ID> -Mode video -Format 134

# 5. 无字幕轨 → 抽硬字幕条（每 12 秒一条）
powershell -NoProfile -ExecutionPolicy Bypass -File "$t\extract-hardsubs.ps1" -Video "$t\out\<ID>.mp4" -Interval 12
```

## 工作方式

`yt-fetch.ps1` 自动探测，无需手改路径：

- **代理**：探测 `127.0.0.1:10808`。在监听 → 走代理；否则直连。
  换端口用 `-ProxyPort 7890`，强制直连用 `-ProxyPort 0`。
- **Python**：依次找 `$env:YTDLP_PYTHON` → 包内 `.venv` → PATH 上的 `python`/`python3`/`py`
  → 常见安装目录。自动跳过 Windows Store 的假 `python.exe` 存根（它只会弹安装广告）。
- **yt-dlp**：找不到时自动建本地 venv 并 `pip install`，不污染系统 Python。
- **Node**：找 `$env:YTDLP_NODE` → PATH → 常见安装位置。找到就启用
  `--js-runtimes node` + `--remote-components ejs:github`。

## 关键参数（缺一不可）

```
--cookies <cookies.txt>              # 反爬必需
--js-runtimes node:<node路径>          # 解 n-challenge
--remote-components ejs:github       # 不加只有 image 格式，报 format not available
--cache-dir <包内目录>                 # 避免写用户目录被拒
```

## 没有字幕轨怎么办（很常见）

中文技术频道常常**不开字幕轨也不开自动字幕**，`--list-subs` 直接回
`has no automatic captions`。但这类视频通常把字幕**烧进画面底部**：

1. `-Mode video -Format 134` 下 360p（约 5MB / 20 秒）；
2. `extract-hardsubs.ps1 -Interval 12` 每 12 秒切一条底部字幕条，放大到 1280 宽；
3. 按文件名顺序逐张读。第 N 张对应 `t=(N-1)*12` 秒；
4. 相邻两条常重复（一句话跨两个采样点），按语义合并。

调整：
- 字幕被切掉一半 → 加大高度，如 `-Crop "iw:ih*0.12:0:ih*0.86"`
- 字幕在画面中部 → 先抽一张全帧确认位置，再用窄条 `"iw:ih*0.08:0:ih*0.6"`
- 跳句太多 → `-Interval 6`

## 排查

| 症状 | 原因与处理 |
|---|---|
| `Sign in to confirm you're not a bot` | cookie 缺失或过期 → `-Mode cookies` 重导 |
| `Requested format is not available` / `n challenge solving failed` | 缺 `--remote-components ejs:github`，或没装 Node |
| `PermissionError` 写不进 cache | `--cache-dir` 指到无权限目录 → 换到包内目录 |
| Cookie 导出失败「database is locked」 | 浏览器还开着 → 完全退出浏览器再试 |
| Chrome 127+ 导出 0 条 | 用了 app-bound 加密 → 改用 `-Browser edge` 或 `-Browser firefox` |
| 代理模式全超时 | 代理对 YouTube 的 TLS 有兼容问题 → 换节点，或 `-ProxyPort 0` 直连 |
| `ffmpeg not found` | 只影响 `-Mode video` 与硬字幕；`winget install Gyan.FFmpeg` |

## 安全

`cookies.txt` 是**等同账号凭据的明文**（含 SID / HSAPISID）。仅本地使用，
不要提交进 git、不要发到聊天或云盘。不用了直接删，下次 `-Mode cookies` 重导。
