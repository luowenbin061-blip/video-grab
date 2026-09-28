# -*- coding: utf-8 -*-
"""v1.0.140 源码自检 —— 外部审查里「成立」的 7 条（9 号用户明确不修）。

对应关系：
  3 → SourceProbe 探测不再把整个文件读进内存
  4 → 缺分片必须抛错 + 完成判据换成"两处独立计数"
  5 → 分片内容校验（Content-Length + 首字节），**且只对明文 TS 生效**
  6 → 分片完成标记（防"短响应被永久当完整"）
  7 → 本机服务 Range 严格化（不合法一律 416）
  8 → 地址清洗：快路径验 %XX、`#` 一律编码
"""
import io, os, re, sys
sys.stdout.reconfigure(encoding='utf-8')

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')

def read(n):
    with io.open(os.path.join(APP, n), encoding='utf-8') as f:
        return f.read()

def code_of(src):
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
print('=== 3 探测不再把整个文件读进内存 ===')
chk('S1 新增 HeadOnlyReader（自己当 delegate）',
    'private final class HeadOnlyReader' in spc and 'URLSessionDataDelegate' in spc)
chk('S2 不再用 data(for:) 取探测内容',
    'URLSession.shared.data(for: r)' not in spc)
chk('S3 收满 limit 立刻 cancel', 'buf.count >= limit { dataTask.cancel() }' in spc)
chk('S4 自己 cancel 引发的 -999 不算失败', 'NSURLErrorCancelled' in spc)
chk('S5 用完解开 session/delegate 互持', 'invalidateAndCancel()' in spc)
chk('S6 仍然带 Range 头（服务器愿意遵守就省流量）', '"bytes=0-4095"' in spc)

dl = read('Downloader.swift'); dlc = code_of(dl)
print()
print('=== 4 缺分片抛错 + 完成判据换成独立计数 ===')
chk('D1 Fail 新增 missingSegment', 'case missingSegment([Int])' in dlc)
chk('D2 拼接循环不再静默跳过（改成记录）', 'missing.append(i)' in dlc)
chk('D3 旧写法 else { continue } 已消失',
    'Data(contentsOf: part) else { continue }' not in dlc)
chk('D4 缺分片时抛错并删掉残缺 .ts',
    'if !missing.isEmpty {' in dlc and 'throw Fail.missingSegment(missing)' in dlc)
chk('D5 Output 新增 writtenSegments', 'let writtenSegments: Int' in dlc)
chk('D6 拼接时统计真正写进去的个数', 'writtenCount += 1' in dlc)
chk('D7 返回值带上 writtenSegments', 'writtenSegments: writtenCount' in dlc)

print()
print('=== 5 分片内容校验（且只对明文 TS 生效 —— 这条最关键）===')
chk('D8 Fail 新增 badContent', 'case badContent(Int, String)' in dlc)
chk('D9 校验声明的长度', 'h.expectedContentLength > 0' in dlc and 'Int64(data.count) != h.expectedContentLength' in dlc)
chk('D10 校验首字节 0x47', 'first != 0x47' in dlc)
chk('D11 ★ 只对明文 TS 校验（不误伤加密流 / fMP4）',
    'let isPlainTS = (playlist.key == nil)' in dlc and 'ext != "m4s" && ext != "mp4"' in dlc)
chk('D12 校验放在落盘之前', dlc.index('first != 0x47') < dlc.index('try data.write(to: dest'))

print()
print('=== 6 分片完成标记（防短响应被永久当完整）===')
chk('D13 有 doneMarkerURL', 'private func doneMarkerURL(_ index: Int) -> URL' in dlc)
chk('D14 续传要求标记对得上',
    'try? String(contentsOf: doneMarkerURL(index), encoding: .utf8)' in dlc)
chk('D15 落盘成功后写标记', 'write(to: doneMarkerURL(index)' in dlc)
chk('D16 兼容升级前的老文件（认一次并补标记）',
    '老文件：只认这一次' in dl)

sv = read('LocalHTTPServer.swift'); svc = code_of(sv)
print()
print('=== 7 本机服务 Range 严格化 ===')
chk('H1 新增 416 发送函数（带 Content-Range）',
    'private func sendRangeNotSatisfiable' in svc and '"Content-Range: bytes */\\(total)' in svc)
chk('H2 多个 Range 头 → 416', 'if rangeLines.count > 1 {' in svc)
chk('H3 逗号多范围 → 416', 'spec.contains(",")' in svc)
chk('H4 起止写反 → 416（e >= s 才接受）', 'guard let e = Int(eStr), e >= s else {' in svc)
chk('H5 bytes=-0 → 416（要求 n > 0）', 'guard let n = Int(eStr), n > 0 else {' in svc)
chk('H6 旧的宽松解析已消失', 'comps.count > 1, let e = Int(comps[1]), e > 0' not in svc)

m3 = read('M3U8.swift'); m3c = code_of(m3)
print()
print('=== 8 地址清洗：快路径验 %XX、# 一律编码 ===')
chk('M1 快路径新增两个条件',
    '$0 != "#" }), percentEscapesLookOK(s)' in m3c)
chk('M2 新增 percentEscapesLookOK', 'private static func percentEscapesLookOK' in m3c)
chk('M3 # 也走"要编码"那一支', 'c.isASCII, c != " ", c != "#"' in m3c)
chk('M4 ★ ? 仍然保留（它是查询串的开始，编码掉就取不到东西）',
    'c != "?"' not in m3c)

print()
print('=== 回归：前面几版的修复不能被碰掉 ===')
pr = code_of(read('PlaylistRelay.swift'))
chk('R1 URI 一律绝对化（v1.0.139 修的回归）',
    'rewriteURIAttrs' in pr and 'rewriteKeyURI' not in pr)
chk('R2 临时清单稳定文件名 + 7 天保留',
    'stableKey(remote.absoluteString)' in pr and '7 * 24 * 3600' in pr)
chk('R3 只处理 VOD / 只处理 http(s)',
    '"#EXT-X-ENDLIST"' in pr and 'scheme == "http" || scheme == "https"' in pr)
chk('R4 探测的 m3u8 判定仍在（v1.0.136）',
    'String(decoding: data.prefix(4096), as: UTF8.self)' in spc)
chk('R5 两类"没分片"报错仍在', 'case noAddress(' in dlc)
chk('R6 转 MP4 有进度 + 大文件不 faststart',
    'sizePoller' in code_of(read('FFmpegConverter.swift')))
chk('R7 长按内置播放接线仍在', 'PlaylistRelay.target(' in code_of(read('ContentView.swift')))

print()
print('RESULT: %d PASS / %d FAIL' % (len(PASS), len(FAIL)))
if FAIL:
    print('FAILED:')
    for f in FAIL: print('  - ' + f)
    sys.exit(1)
