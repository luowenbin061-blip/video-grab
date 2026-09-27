# -*- coding: utf-8 -*-
"""验证 v1.0.134 的 sanitizeURLString 逻辑：用 Python 复刻 Swift 那份实现，
跑用户截图里那份真实清单，确认中文分片地址能解析出来。

★ 这是**逻辑等价性验证**（不是编译验证）：Swift 侧用的是同样的规则
  （非 ASCII / 空格 → 逐 UTF-8 字节 %XX；已是 %XX 的保留；ASCII 保留），
  这里用 Python 复刻一遍，确认"输入 → 输出"符合预期。
"""
import re
from urllib.parse import urljoin

# ── 复刻 Swift 的 sanitizeURLString ─────────────────────────
HEX = set('0123456789abcdefABCDEF')

def sanitize(s: str) -> str:
    if all(ord(c) < 128 and c != ' ' for c in s):
        return s
    out = []
    chars = list(s)
    i = 0
    while i < len(chars):
        c = chars[i]
        if c == '%' and i + 2 < len(chars) and chars[i+1] in HEX and chars[i+2] in HEX:
            out.append(c); out.append(chars[i+1]); out.append(chars[i+2])
            i += 3
            continue
        if ord(c) < 128 and c != ' ':
            out.append(c)
        else:
            for b in c.encode('utf-8'):
                out.append('%%%02X' % b)
        i += 1
    return ''.join(out)

def resolve(line: str, base: str):
    """模拟 Swift 的 resolve：先试原样，不行再洗一遍"""
    # Swift 的 URL(string:) 对非 ASCII 返回 nil —— 这里等价地判定
    ok = all(ord(c) < 128 or c == '%' for c in line)
    if ok:
        return urljoin(base, line)
    return urljoin(base, sanitize(line))

# ── 用户截图里的真实清单 ────────────────────────────────────
BASE = 'https://cdn.example.com/hls/abc/index.m3u8'
PLAYLIST = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:13
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:12.516667, 早披白莉莉莉音号083122-001-CARIB（口交）.0.ts
早披白莉莉莉音号083122-001-CARIB（口交）.0.ts
#EXTINF:8.344444, 早披白莉莉莉音号083122-002-CARIB（口交）.0.ts
早披白莉莉莉音号083122-002-CARIB（口交）.0.ts
#EXT-X-ENDLIST
'''

print('=' * 72)
print('修好之后：这份清单能解析出几条分片？')
print('=' * 72)
n = 0
for raw in PLAYLIST.split('\n'):
    line = raw.strip()
    if not line or line.startswith('#'):
        continue
    u = resolve(line, BASE)
    n += 1
    print('  %d. %s' % (n, u))
print('\n→ 解析出 %d 条分片（修复前 = 0 条）' % n)

print()
print('=' * 72)
print('边界情况（别把不该改的改坏了）')
print('=' * 72)
cases = [
    ('普通 ASCII 地址（不该动）', 'seg_000001.ts', 'seg_000001.ts'),
    ('已经是 %XX（不该重复编码）', '%E6%97%A9.ts', '%E6%97%A9.ts'),
    ('中文（要编码）', '早.ts', '%E6%97%A9.ts'),
    ('全角括号（要编码）', 'a（b）.ts', 'a%EF%BC%88b%EF%BC%89.ts'),
    ('空格（要编码）', 'my video.ts', 'my%20video.ts'),
    ('带查询串（? 和 = 不能动）', 'seg.ts?token=abc&x=1', 'seg.ts?token=abc&x=1'),
    ('中文 + 查询串', '早.ts?token=abc', '%E6%97%A9.ts?token=abc'),
    ('中文目录 + 文件', '视频目录/seg.ts', '%E8%A7%86%E9%A2%91%E7%9B%AE%E5%BD%95/seg.ts'),
    ('混合：一半编码一半中文', '%E6%97%A9-中文.ts', '%E6%97%A9-%E4%B8%AD%E6%96%87.ts'),
]
ok_all = True
for name, inp, want in cases:
    got = sanitize(inp)
    ok = (got == want)
    ok_all = ok_all and ok
    print('  %s %s' % ('OK  ' if ok else 'FAIL', name))
    if not ok:
        print('        输入 %s' % inp)
        print('        期望 %s' % want)
        print('        实得 %s' % got)
print()
print('边界情况全过:', ok_all)
print()
print('★ 关键点：`?` `=` `&` 这些**不能被编码**（它们是 URL 语法的一部分），')
print('  而中文 / 全角 / 空格必须编码 —— 上面两类都验过了。')
