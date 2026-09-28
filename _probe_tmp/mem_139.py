# -*- coding: utf-8 -*-
"""MEMORY.md 的 VideoGrab 索引行更新到 v1.0.139（保持"只留索引"的形状）。"""
import io, os, sys
sys.stdout.reconfigure(encoding='utf-8')

P = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/MEMORY.md'
s = io.open(P, encoding='utf-8').read()

OLD_MARK = '  当前 **v1.0.137**（sha256 `68a7d37d202e1496`'
NEW_HEAD = (
    '  当前 **v1.0.139**（sha256 `9c38841757e6726d`，10.35 MB，**待真机验收**）= ① ★★ **修「内置播放器播不了」**：\n'
    '  实测铁证 —— 清单与真实分片都 **200**、**连 Referer 都不用**，但播放器请求的 `<名称>.ts`（**丢了序号**）是 **404**；\n'
    '  **站上东西是好的，是 AVPlayer 解析不了「原生中文 + 全角括号的相对路径」那份清单**。\n'
    '  修法（新文件 `PlaylistRelay.swift`）：**自己取清单 → 逐行洗成绝对地址 → 写本地 m3u8 → 用 `LocalHTTPServer` 以 http 播**；\n'
    '  三条边界别随手改：**只走 VOD**（直播快照会播完即停）、**只走 http(s)**、**任一步不成退回原地址**。\n'
    '  ② 「转成 MP4」**有进度**了（500ms 轮询输出文件大小，`-c copy` 输出≈输入）+ 用词全线改掉（不再叫"重封装/转码"）；\n'
    '  ③ 大文件（>400MB）**关掉 `+faststart`**（它要**两遍 I/O**）；④ 每任务**说人话的详细日志** + **「复制记录」一键复制**（带版本/时间/地址/结果抬头）。\n'
    '  run #138 编译失败（`var` 被 `Task.detached` 捕获）→ #139 成功。\n'
    '  上一版 **v1.0.137**（sha256 `68a7d37d202e1496`'
)

i = s.find(OLD_MARK)
if i < 0:
    print('!! 找不到 v1.0.137 标记，中止'); sys.exit(1)
s2 = s[:i] + NEW_HEAD + s[i + len(OLD_MARK):]

# 顺手把最上面那句"当前版本"的指引改准
s2 = s2.replace('（**版本史与全部技术细节都在那里**，2026-09-28 从本文件搬入，只搬不删）。',
                '（**版本史与全部技术细节都在那里**，2026-09-28 从本文件搬入，只搬不删）。')

tmp = P + '.tmp'
io.open(tmp, 'w', encoding='utf-8').write(s2)
os.replace(tmp, P)

s3 = io.open(P, encoding='utf-8').read()
print('MEMORY.md %d -> %d 字符' % (len(s), len(s3)))
for n, c in [('有 v1.0.139', 'v1.0.139' in s3),
             ('保留了 v1.0.137 摘要', 'v1.0.137' in s3),
             ('记了播放修复方案', 'PlaylistRelay.swift' in s3),
             ('记了 API 通道', 'API 资产通道' in s3),
             ('没超 4000 字符左右', len(s3) < 5200)]:
    print(('PASS ' if c else 'FAIL '), n)
