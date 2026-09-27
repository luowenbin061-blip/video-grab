# -*- coding: utf-8 -*-
"""验证猜测：m3u8 里的分片地址带**未百分号编码的中文 + 全角括号**时，
Foundation 的 URL(string:relativeTo:) 会返回 nil → 解析不出分片。

Windows 没有 Swift，用 Python 复现**同一个判据**：
Foundation 的 URL(string:) 要求字符串**只含 RFC 3986 允许的字符**（或已是 %XX），
含非 ASCII / 空格 / 全角字符等一律返回 nil（这是确定行为，不是猜测）。

Python 侧等价判据：urlsplit 能过 ≠ Foundation 能过；
真正的判据是「字符串里有没有非 URI 允许字符」。
"""
import re

# 直接从用户截图里抄下来的两行（分片地址行）
lines = [
    '早披白莉莉莉音号083122-001-CARIB（口交）.0.ts',
    '早披白莉莉莉音号083122-002-CARIB（口交）.0.ts',
]

# RFC 3986 允许的字符集：未保留 + 保留 + %
ALLOWED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
              "-._~:/?#[]@!$&'()*+,;=%")

def foundation_url_ok(s):
    """模拟 Foundation URL(string:) 能否成功（相对 URL 也一样受这个约束）"""
    for ch in s:
        if ch not in ALLOWED:
            return False, ch
    return True, None

print('=' * 70)
print('分片地址行 → Foundation URL(string:relativeTo:) 能不能解析')
print('=' * 70)
for s in lines:
    ok, bad = foundation_url_ok(s)
    n_bad = sum(1 for c in s if c not in ALLOWED)
    print('  地址 : %s' % s)
    print('  结果 : %s' % ('✔ 能解析' if ok else '✘ 返回 nil（第一个非法字符 = %r）' % bad))
    print('  非法字符个数: %d / 总长 %d' % (n_bad, len(s)))
    print()

print('=' * 70)
print('结论')
print('=' * 70)
print('这两条地址里有：')
for s in lines[:1]:
    kinds = {}
    for c in s:
        if ord(c) > 127:
            if '\u4e00' <= c <= '\u9fff':
                kinds.setdefault('汉字', []).append(c)
            elif c in '（）':
                kinds.setdefault('全角括号', []).append(c)
            else:
                kinds.setdefault('其他非ASCII(%04X)' % ord(c), []).append(c)
    for k, v in kinds.items():
        print('  · %s × %d  %s' % (k, len(v), ''.join(v)))
print()
print('→ 只要有**一个**非 ASCII 字符，Foundation 的 URL(string:) 就返回 nil。')
print('→ 解析器 `guard let abs = URL(string: line, relativeTo: baseURL) else { continue }`')
print('  会把这两行**静默跳过** → segmentURLs 空 → 报「m3u8 里没有解析出任何分片」。')
print()
print('★ 为什么亚瑟浏览器能下：它不走 Foundation 的 URL(string:)，')
print('  要么先做了百分号编码，要么直接用 URLComponents / 自己拼 → 没有这个限制。')
