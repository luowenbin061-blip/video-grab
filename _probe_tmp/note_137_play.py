# -*- coding: utf-8 -*-
"""把「播放 400」的实测铁证与修复方案记进 notes + 日记（append-only）。"""
import io, os, sys
sys.stdout.reconfigure(encoding='utf-8')

NOTES = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/notes/VideoGrab.md'
LOG = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/2026-09-28.md'

def atomic(p, t):
    tmp = p + '.tmp'
    io.open(tmp, 'w', encoding='utf-8').write(t)
    os.replace(tmp, p)

NOTE = """

### ★★ 「内置播放器播放失败 / HTTP 400」根因（2026-09-28 实测铁证，待修）

用户给的实测地址与截图（`4x1.ekcvn.com`，苍井樱…HEYZO-2008）：

路径结构 = `/changpian/m3u8/yazhouwuma/202609/<同名中文目录>/<同名中文文件>`

**我直接对这个站做了对照实验（只读，分片只取 1 字节）：**

| 请求 | 结果 |
|---|---|
| 清单 `<名称>.m3u8`（编码或原生中文都试了） | **200** · 7745 B · `application/x-mpegURL` |
| 清单里的真实分片 `<名称>0.ts`（编码 / 原生中文 / 带 Range 全试了） | **200 / 206** · `video/vnd.dlna.mpeg-tts` · 354568 B |
| **截图里那条失败请求 `<名称>.ts`（没有序号）** | **404**（1163 B 的 text/html 错误页） |
| 分片带不带 `Referer` | **无差别** —— 这个站对分片**不校验** Referer |

**结论（铁证）：**
1. **站上东西是好的** —— 清单取得到、分片取得到、不需要防盗链头。所以既不是"站上没这文件"，也不是防盗链。
2. **AVPlayer 请求的那个地址在服务端不存在**：它把清单里的 `<名称>0.ts` 变成了 **`<名称>.ts`**，
   **丢掉了序号**；而且它给出的 URL 是 **`https:///4x1.ekcvn.com/…`**（`https://` 后多一个斜杠
   = **主机名为空**）—— 连 URL 都没拼对。
3. **清单里唯一的"异常"就是：分片行是「原生中文 + 全角括号」的相对路径**
   （`苍井樱的打手枪2番号HEYZO-2008（口交）0.ts`）。能正常播放的其它站，分片名都是纯 ASCII。
   → **AVPlayer 的 HLS 分片地址解析管线对这类行处理不良**，这是高度一致的解释。
4. ★ **这跟 v1.0.134/135/136 是同一个病根的第三个表现**：
   下载路径之所以没这个毛病，正因为**我们自己把清单每一行都清洗过**（`sanitizeURLString`）；
   而播放路径**把远端原始清单直接交给了 AVPlayer**，它自己没有清洗这一步。

**修复方案（下次实施）：不要把远端原始清单直接喂给 AVPlayer。**
- 我们自己取清单 → 逐行清洗（百分号编码 + 解析成**绝对**地址）→ **写成本地清单** →
  用**已有的 `LocalHTTPServer`** 以 http 提供它（路径 A）。
- ★ 为什么不能只用本地文件（`file://`）：`Exporter.swift` 里已实测记着
  「本地 .m3u8 → file:// 会报 CoreMediaErrorDomain -12865 / 12881，HLS 必须来自 http/https」。
- 分片地址写成**绝对 http 地址**即可（本测站分片不需要 Referer）；若以后遇到需要的，
  再把分片也走本地转发（同一套机制，代价是本机服务要扛流量）。
"""

LOGLINE = """

## VideoGrab —— 「播放 HTTP 400」根因定案（实测铁证，未修）

用户给了地址 + 截图。我直接对那个站做对照实验：

- 清单 `<名称>.m3u8` → **200 / 7745B / 合法 UTF-8 / 103 个分片**
- 清单里的真实分片 `<名称>0.ts` → **200 / 206 / 354568B**（编码、原生中文、带 Range 都试了，**都行**）
- **截图那条失败请求 `<名称>.ts`（没有序号）→ 404**
- 分片**带不带 Referer 无差别**（这站不校验防盗链）

→ **站上东西好的；是 AVPlayer 把分片名解析错了**：把 `<名称>0.ts` 变成 `<名称>.ts`（丢了序号），
给出的 URL 还是 `https:///4x1.ekcvn.com/…`（主机名为空）。
→ 清单里唯一异常：**分片行是「原生中文 + 全角括号」的相对路径**。能正常播的站分片名都是纯 ASCII。
→ ★ 与 v1.0.134~136 是**同一病根的第三个表现**：下载路径我们自己清洗清单所以没事，
  **播放路径把原始清单直接交给了 AVPlayer**。

**修法**：自己取清单 → 清洗 + 绝对化 → 写成本地清单 → 用已有 `LocalHTTPServer` 以 http 提供
（`file://` 不行，Exporter.swift 里已实测）。

**用户同轮提的其余 3 条**：① 转码是**真卡死**（不是假卡死）② 要**每任务一份超详细、通俗易懂的下载日志**
③ 重封装文案改成「正在转成 MP4…」**并且要显示转码进度**。
"""

n = io.open(NOTES, encoding='utf-8').read()
if 'HTTP 400」根因（2026-09-28 实测铁证' in n:
    print('notes 已写过')
else:
    atomic(NOTES, n + NOTE); print('notes %d -> %d' % (len(n), len(n + NOTE)))
l = io.open(LOG, encoding='utf-8').read()
if '播放 HTTP 400」根因定案' in l:
    print('日记已写过')
else:
    atomic(LOG, l + LOGLINE); print('日记 %d -> %d' % (len(l), len(l + LOGLINE)))

n2 = io.open(NOTES, encoding='utf-8').read(); l2 = io.open(LOG, encoding='utf-8').read()
for name, c in [('notes 有对照实验表', '<名称>0.ts' in n2),
                ('notes 有 404 铁证', '404' in n2 and '没有序号' in n2),
                ('notes 有 AVPlayer 解析错结论', 'AVPlayer 把分片名解析错了' in n2 or '丢掉了序号' in n2),
                ('notes 有修法', 'LocalHTTPServer' in n2),
                ('日记有定案', '播放 HTTP 400」根因定案' in l2),
                ('日记记了同源', '同一病根的第三个表现' in l2)]:
    print(('PASS ' if c else 'FAIL '), name)
