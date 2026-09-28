# -*- coding: utf-8 -*-
"""v1.0.136 源码自检 —— 逐条核对本轮三处改动是否真的落地。

本轮针对用户 2026-09-28 报的两条：
  ① 还是有小部分视频下载失败（截图：`application/x-mpegURL · 单个文件 · 文件`）
  ② 部分视频内置播放器播不了（截图：CoreMedia -16845 / HTTP 400）

① 的根因已在 SourceProbe：**严格 UTF-8 解码失败 → 把 m3u8 当成直链文件下**。
② 本轮只能加**定位用的诊断**（错误日志 + 出错地址），真因要拿到地址才能定案。
"""
import io, os, re, sys
sys.stdout.reconfigure(encoding='utf-8')

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')

def read(n):
    with io.open(os.path.join(APP, n), encoding='utf-8') as f:
        return f.read()

def code_of(src):
    """剔注释，只留真代码（判据撞注释这个坑踩过四次了）。"""
    out, i, n, blk = [], 0, len(src), False
    while i < n:
        if blk:
            if src.startswith('*/', i): blk = False; i += 2
            else: i += 1
            continue
        if src.startswith('/*', i): blk = True; i += 2; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        out.append(src[i]); i += 1
    return ''.join(out)

PASS, FAIL = [], []
def chk(label, ok, detail=''):
    (PASS if ok else FAIL).append(label)
    print(('PASS ' if ok else 'FAIL ') + label + (('  ' + detail) if detail else ''))

sp = read('SourceProbe.swift'); spc = code_of(sp)
print('=== ① SourceProbe：别再因为"解不出来"就把清单判成文件 ===')
chk('S1 用永不失败的 String(decoding:as:)', 'String(decoding: data.prefix(4096), as: UTF8.self)' in spc)
chk('S2 不再用会返回 nil 的严格 UTF-8 解码',
    'String(data: Data(data.prefix(2048)), encoding: .utf8) ?? ""' not in spc)
chk('S3 去掉 UTF-8 BOM', 'hasPrefix("\\u{FEFF}")' in spc)
chk('S4 认 mpegurl 这个 Content-Type', 'ct.contains("mpegurl")' in spc)
chk('S5 认 .m3u8 后缀', 'pathExtension.lowercased() == "m3u8"' in spc)
chk('S6 新增 looksLikePlaylist 分支', 'else if looksLikePlaylist {' in spc)
chk('S7 网页判断仍排在"后缀像清单"之前',
    spc.index('ct.hasPrefix("text/html")') < spc.index('else if looksLikePlaylist'))
chk('S8 取回内容仍写进过程记录（headText）', 'p.headText = Self.oneLine(' in spc)

dl = read('Downloader.swift'); dlc = code_of(dl)
print('=== ② Downloader：中文站 GBK 清单要能正确解码 ===')
chk('D1 有 gb18030 编码常量', 'static let gb18030' in dlc)
chk('D2 用 CoreFoundation 拿编码号',
    'CFStringConvertEncodingToNSStringEncoding' in dlc and 'GB_18030_2000' in dlc)
chk('D3 解码顺序 utf8 → gb18030 → isoLatin1',
    dlc.index('encoding: .utf8') < dlc.index('encoding: Self.gb18030') < dlc.index('encoding: .isoLatin1'))
chk('D4 记下"是不是 UTF-8"', 'wasUTF8' in dlc)
chk('D5 非 UTF-8 时在开头那句里明说',
    '[这份清单不是 UTF-8，已按 GB18030 读]' in dl)

ps = read('PlayerSheet.swift'); psc = code_of(ps)
print('=== ③ PlayerSheet：播失败时能定位到"哪条请求被拒" ===')
chk('P1 用了 errorLog()', 'item.errorLog()' in psc)
chk('P2 打印失败请求的 uri', '失败请求：' in ps)
chk('P3 打印 HTTP 状态码', 'ev.errorStatusCode' in psc)
chk('P4 describe 里加了出错地址', 'NSURLErrorFailingURLStringErrorKey' in psc)
chk('P5 原来的"播放器起不来"界面还在', '播放器起不来' in ps)
chk('P6 60 秒兜底还在', '600' in psc and '60 秒还是加载不出来' in ps)
chk('P7 8 秒卡住兜底还在', '加载卡住了' in ps)

print()
print('=== 回归：前几版能力未被回退 ===')
m3 = code_of(read('M3U8.swift'))
chk('R1 中文地址清洗还在', 'static func sanitizeURLString' in m3)
chk('R2 resolve 还在', 'static func resolve(' in m3)
chk('R3 noAddress 分家还在', 'case noAddress(' in code_of(read('Downloader.swift')))
chk('R4 长按内置播放接线还在', 'onPlay: {' in code_of(read('ContentView.swift')))
chk('R5 续看开关还在', 'resumeEnabled' in code_of(read('WatchProgress.swift')))
chk('R6 自动横屏开关还在', 'autoLandscapeKey' in code_of(read('PlayerSheet.swift')))
chk('R7 边下边播 VOD 还在', 'EXT-X-PLAYLIST-TYPE:VOD' in code_of(read('LivePreview.swift')))
chk('R8 备份含已放行网站', 'vgTrustedCertHosts' in code_of(read('DataBackup.swift')))

print()
print('RESULT: %d PASS / %d FAIL' % (len(PASS), len(FAIL)))
if FAIL:
    print('FAILED:')
    for f in FAIL: print('  - ' + f)
    sys.exit(1)
