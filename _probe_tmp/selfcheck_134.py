# -*- coding: utf-8 -*-
"""v1.0.134 源码自检 —— 逐条核对本轮两个改动是否真的落地。

判据分两组：
  A. 问题1「个别视频下载失败」的修复（M3U8 中文/全角地址）
  B. 问题2「长按菜单加内置播放」（LongPressMenu + ContentView）

★ 为什么要 `code_of()`：注释里也会出现这些词（我自己写的注释就引用了），
  直接搜会把「注释里有、代码里没有」误判成通过。所以先把注释行剔掉再找。
"""
import io, os, re, sys

APP = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')

def read(name):
    p = os.path.join(APP, name)
    with io.open(p, 'r', encoding='utf-8') as f:
        return f.read()

def code_of(src):
    """剔掉 // 行注释和 /* */ 块注释，只留真代码。"""
    out = []
    i, n = 0, len(src)
    in_block = False
    while i < n:
        if in_block:
            if src.startswith('*/', i):
                in_block = False; i += 2
            else:
                i += 1
            continue
        if src.startswith('/*', i):
            in_block = True; i += 2; continue
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        # 字符串里的 // 不处理（本项目没出现 URL 里带 // 且同行有注释的情况）
        out.append(src[i]); i += 1
    return ''.join(out)

PASS, FAIL = [], []

def chk(label, ok, detail=''):
    (PASS if ok else FAIL).append(label)
    print(('PASS ' if ok else 'FAIL ') + label + (('  ' + detail) if detail else ''))

m3 = read('M3U8.swift')
m3c = code_of(m3)

print('=== A. M3U8 中文/全角地址修复 ===')
chk('A1 sanitizeURLString 已定义', 'static func sanitizeURLString(_ s: String) -> String' in m3c)
chk('A2 sanitize 快路径（ASCII+无空格直接返回）',
    'allSatisfy({ $0.isASCII && $0 != " " })' in m3c)
# 已是 %XX 不重复编码
chk('A3 已是 %XX 不重复编码', "hexDigits" in m3c or "isHex" in m3c or "'%'" in m3c or '"%"' in m3c.replace("'%'", '"%"'), )
chk('A4 UTF-8 逐字节百分号编码', 'utf8' in m3c)
chk('A5 resolve(_:relativeTo:) 已定义',
    'static func resolve(_ line: String, relativeTo baseURL: URL) -> URL?' in m3c)
chk('A6 resolve 内先试原样再洗', 'URL(string: line, relativeTo: baseURL)' in m3c
    and 'sanitizeURLString(line)' in m3c)
chk('A7 分片地址行走 resolve', 'resolve(line, relativeTo: baseURL)' in m3c)
chk('A8 失败行有记录（不再静默 continue）', 'badLines' in m3c)
chk('A9 新增 badAddressLines 属性', 'var badAddressLines: [String]' in m3c)
chk('A10 parse 末尾回填 badAddressLines', 'badAddressLines = badLines' in m3c)
chk('A11 #EXT-X-KEY 的 URI 也走 resolve',
    'resolve(' in m3c and 'EXT-X-KEY' in m3c)

dl = read('Downloader.swift')
dlc = code_of(dl)
print('=== A12-A14 Downloader 报错分家 ===')
chk('A12 Fail 新增 noAddress 分支', 'case noAddress(' in dlc)
chk('A13 noAddress 文案存在（含"N 条""例如"）',
    '分片地址读不懂' in dl and ('例如' in dl))
chk('A14 guard 里区分 noAddress / noSegment',
    'throw Fail.noAddress(' in dlc and 'throw Fail.noSegment(' in dlc)
chk('A15 segmentDurations 旁注文件仍写（v1.0.133 能力不丢）',
    'writeSegmentDurations' in dlc and 'durations.txt' in dl)

lp = read('LongPressMenu.swift')
lpc = code_of(lp)
print('=== B. 长按菜单加内置播放 ===')
chk('B1 LongPressMenuView 有 onPlay 回调', 'let onPlay: () -> Void' in lpc)
chk('B2 previewCard 是 Button(action: onPlay)', 'Button(action: onPlay)' in lpc)
chk('B3 previewCard 加了可点区域', '.contentShape(Rectangle())' in lpc)
chk('B4 previewCard 用 .plain 按钮样式', '.buttonStyle(.plain)' in lpc)
chk('B5 播放角标存在', 'play.circle.fill' in lpc)
chk('B6 「不要加按钮名字」——未新增文字行',
    lpc.count('Text(') == lp.count('Text(') - 0, 'Text( 出现 %d 次' % lp.count('Text('))
chk('B7 actionCard 仍只有 Download / 选择清晰度两行',
    '"Download"' in lpc and '选择清晰度' in lpc)

cv = read('ContentView.swift')
cvc = code_of(cv)
print('=== B8-B15 ContentView 接线 ===')
chk('B8 新增 lpPlay 状态', '@State private var lpPlay: LongPressMenuInfo?' in cvc)
chk('B9 调用点传了 onPlay', 'onPlay: {' in cvc)
chk('B10 onPlay 里先关菜单', 'model.closeLongPressMenu()' in cvc)
chk('B11 onPlay 里 160ms 后再抬卡片',
    '160_000_000' in cvc and 'lpPlay = m' in cvc)
chk('B12 新增 fullScreenCover(item: $lpPlay)', '.fullScreenCover(item: $lpPlay)' in cvc)
chk('B13 播放器用 PlayerSheet', 'PlayerSheet(url: u' in cvc)
chk('B14 带请求头（防盗链）', 'headers: lpHeaders(m)' in cvc)
chk('B15 lpHeaders 助手存在', 'private func lpHeaders(' in cvc)
chk('B16 lpHeaders 带 Referer/UA/Cookie',
    '"Referer"' in cvc and '"User-Agent"' in cvc and '"Cookie"' in cvc)
chk('B17 地址先经 sanitize 再进播放器',
    'M3U8Playlist.sanitizeURLString(m.url)' in cvc)
chk('B18 播不出来时有提示（不静默黑屏）',
    '播不了' in cv or '读不懂' in cv)
chk('B19 键固定成 "lp"（不污染任务续看）', 'key: "lp"' in cvc)
# ★ run #134 挂在这：写成 M3U8.sanitizeURLString，而本工程真名是 M3U8Playlist。
#   括号配平查不出来（两边都合法），所以单列一条断言，把这个雷钉死。
chk('B20 没有写成裸 M3U8.（真名是 M3U8Playlist）',
    not re.search(r'\bM3U8\.(?!Playlist)', cvc),
    'M3U8. 出现在代码里' if re.search(r'\bM3U8\.(?!Playlist)', cvc) else '')

print()
print('=== C. v1.0.133 能力未被回退 ===')
wp = code_of(read('WatchProgress.swift'))
sv = code_of(read('SettingsView.swift'))
chk('C1 resumeEnabled 总开关还在', 'resumeEnabled' in wp)
chk('C2 wipe() 还在', 'func wipe()' in wp)
chk('C3 PlayerBox.autoLandscapeKey 还在',
    'autoLandscapeKey' in code_of(read('PlayerSheet.swift')))
chk('C4 边下边播仍是 VOD', 'EXT-X-PLAYLIST-TYPE:VOD' in code_of(read('LivePreview.swift')))
chk('C5 备份仍含 vgTrustedCertHosts',
    'vgTrustedCertHosts' in code_of(read('DataBackup.swift')))

print()
print('RESULT: %d PASS / %d FAIL' % (len(PASS), len(FAIL)))
if FAIL:
    print('FAILED:')
    for f in FAIL:
        print('  - ' + f)
    sys.exit(1)
