# -*- coding: utf-8 -*-
"""v1.0.133 结构检查：括号配平（状态机）+ 非法转义（普通字符串里只许 \\n \\t \\r \\" \\\\ \\0 \\u \\()）"""
import io, os, re, sys

ROOT = r'E:/自用WIN10-最强没有之一/VideoGrab/app'
FILES = ['WatchProgress.swift', 'SettingsView.swift', 'PlayerSheet.swift',
         'LivePreview.swift', 'Downloader.swift', 'DataBackup.swift',
         'TrustedHosts.swift', 'Toolbox.swift', 'ContentView.swift', 'M3U8.swift',
         'SourceProbe.swift']

CLOSE = {'}': '{', ')': '(', ']': '['}

def scan(src):
    """括号配对状态机（认字符串插值）"""
    i, n = 0, len(src)
    depth = {'{': 0, '(': 0, '[': 0}
    interp = []
    state = 'code'
    line = 1
    bad = []
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if state == 'code':
            if c == '\n':
                line += 1; i += 1; continue
            if c == '/' and nxt == '/':
                state = 'line'; i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block'; i += 2; continue
            if src.startswith('"""', i):
                state = 'ml'; i += 3; continue
            if c == '"':
                state = 'str'; i += 1; continue
            if c in depth:
                depth[c] += 1; i += 1; continue
            if c in CLOSE:
                if c == ')' and interp and depth['('] == interp[-1]:
                    interp.pop(); state = 'str'; i += 1; continue
                depth[CLOSE[c]] -= 1
                if depth[CLOSE[c]] < 0:
                    bad.append('第 %d 行多了个 %s' % (line, c))
                i += 1; continue
            i += 1; continue
        if state == 'line':
            if c == '\n':
                state = 'code'; line += 1
            i += 1; continue
        if state == 'block':
            if c == '\n': line += 1
            if c == '*' and nxt == '/':
                state = 'code'; i += 2; continue
            i += 1; continue
        if state == 'str':
            if c == '\\':
                if nxt == '(':
                    interp.append(depth['(']); state = 'code'; i += 2; continue
                i += 2; continue
            if c == '"':
                state = 'code'; i += 1; continue
            if c == '\n': line += 1
            i += 1; continue
        if state == 'ml':
            if c == '\n': line += 1
            if src.startswith('"""', i):
                state = 'code'; i += 3; continue
            i += 1; continue
    return depth, bad, interp, state

def bare_string_escapes(src):
    """扫普通字符串（先摘掉 #"..."# 原始字符串）里出现的非法转义。
    返回 [(行号, 转义字符)]。"""
    # 先保护原始字符串：把 #"..."# 整体替换成等长占位（保留换行以维持行号）
    def blank(m):
        s = m.group(0)
        return re.sub(r'[^\n]', ' ', s)
    src2 = re.sub(r'#"(?:\\.|[^"\\])*"#', blank, src, flags=re.S)

    allowed = set('ntr"\\0u()')
    out = []
    line = 1
    i = 0
    n = len(src2)
    while i < n:
        c = src2[i]
        if c == '\n':
            line += 1; i += 1; continue
        if c == '/' and i + 1 < n and src2[i+1] == '/':
            j = src2.find('\n', i)
            i = n if j < 0 else j
            continue
        if c == '/' and i + 1 < n and src2[i+1] == '*':
            j = src2.find('*/', i + 2)
            if j < 0:
                break
            line += src2.count('\n', i, j)
            i = j + 2
            continue
        if src2.startswith('"""', i):
            j = src2.find('"""', i + 3)
            if j < 0: break
            line += src2.count('\n', i, j)
            i = j + 3
            continue
        if c == '"':
            i += 1
            while i < n:
                ch = src2[i]
                if ch == '\n':
                    line += 1; break
                if ch == '\\':
                    nx = src2[i+1] if i+1 < n else ''
                    if nx not in allowed:
                        out.append((line, '\\' + nx))
                    i += 2; continue
                if ch == '"':
                    i += 1; break
                i += 1
            continue
        i += 1
    return out

ok = True
for f in FILES:
    src = io.open(os.path.join(ROOT, f), encoding='utf-8').read()
    d, bad, interp, state = scan(src)
    good = all(v == 0 for v in d.values()) and not bad and not interp and state == 'code'
    esc = bare_string_escapes(src)
    if esc: good = False
    print(('PASS ' if good else 'FAIL ') + '%-22s %s 插值=%d 末态=%s %s%s'
          % (f, d, len(interp), state,
             ('; '.join(bad) if bad else ''),
             (' 非法转义:' + str(esc) if esc else '')))
    if not good: ok = False
print('RESULT:', 'ALL PASS' if ok else 'HAS FAILURE')
sys.exit(0 if ok else 1)
