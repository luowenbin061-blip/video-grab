# -*- coding: utf-8 -*-
"""v1.0.141 源码自检 —— 「把解密/拼接/换封装交给 ffmpeg」这次架构改动。

依据全是**本机跑真 ffmpeg 实测**出来的（不是推想）：
  · 3 把钥匙齐全 → 输出 38.9 秒完整；只用一把 → 只剩 12 秒
  · 钥匙走 http / 后缀 .part → 都被 ffmpeg 白名单拒；分片与钥匙都叫 .ts + 本地相对名 → 通过
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

dl = read('Downloader.swift'); dlc = code_of(dl)
print('=== A. 命名统一（实测结论：分片与钥匙都必须是媒体后缀）===')
chk('A1 新增 DLName 统一定义命名', 'enum DLName {' in dlc)
chk('A2 分片后缀 .ts', 'seg_%06d.ts' in dlc)
chk('A3 保留老名 .part 用于兼容', 'seg_%06d.part' in dlc)
chk('A4 钥匙也用 .ts', 'key_%d.ts' in dlc)
chk('A5 本地清单名固定', 'local.m3u8' in dlc)
chk('A6 partURL 走 DLName', 'options.tempDir.appendingPathComponent(DLName.segment(i))' in dlc)
chk('A7 老分片会就地改名（不让已下的白费）',
    'try? fm.moveItem(at: old, to: dest)' in dlc)
# ★★ v1.0.142 真机踩的坑：`skipJoin` 曾是 Options 的字段 —— 而 Options 是 struct，
#   调用方 `var dl = HLSDownloader(options: opt)` 之后再改 `opt.skipJoin` **静默不生效**，
#   于是拼接照旧跑、只用最后一把钥匙、成品 1%。现在它是 run() 的参数，没有"哪份副本"问题。
chk('A8 skipJoin 是 run() 的**参数**（不能是 Options 字段）',
    'func run(sourceURL: URL, skipJoin: Bool = false)' in dlc
    and 'var skipJoin' not in dlc and 'options.skipJoin' not in dlc)
chk('A9 skipJoin 时只下分片、直接返回（不解密不拼接）',
    'if skipJoin {' in dlc and 'writtenSegments: 0' in dlc)
chk('A9b 调用点是用参数传的（不能写成 opt.skipJoin = true）',
    'run(sourceURL: src, skipJoin: true)' in code_of(read('DownloadJob.swift'))
    and 'opt.skipJoin' not in code_of(read('DownloadJob.swift')))
chk('A10 Output 带出清单（生成清单要用原文）', 'let playlist: M3U8Playlist?' in dlc)

lp = code_of(read('LivePreview.swift'))
print()
print('=== B. 边下边播仍认老分片 ===')
chk('B1 新名优先、老名兜底', 'DLName.segment(i)' in lp and 'DLName.oldSegment(i)' in lp)

pr = code_of(read('PlaylistRelay.swift'))
print()
print('=== C. 生成本地清单（喂给 ffmpeg 的那份）===')
chk('C1 新增 localPlaylistURL', 'static func localPlaylistURL(playlist: M3U8Playlist, partsDir: URL' in pr)
chk('C2 逐行重写（复用 rawText，不动解析器）', 'playlist.rawText.components(separatedBy: .newlines)' in pr)
chk('C3 钥匙现场取一次、存成本地文件', 'DLName.key(keyIndex)' in pr)
chk('C4 钥匙地址按**清单的**基准地址解析（外部审查点过的）',
    'M3U8Playlist.resolve(info.uri, relativeTo: b)' in pr)
chk('C5 分片写成相对名（不出现绝对地址）', 'out.append(name)' in pr)
chk('C6 缺分片就带着**具体原因**回落老路（不是一句笼统的话）', 'why: String?' in pr and '个分片文件不在' in pr)
chk('C7 不假装会处理 fMP4 的 EXT-X-MAP（先不做，让它报错）',
    '#EXT-X-MAP' in read('PlaylistRelay.swift') and '故意不处理' in read('PlaylistRelay.swift'))

m3 = code_of(read('M3U8.swift'))
print()
print('=== D. 清单带上自己的地址（钥匙相对地址要靠它）===')
chk('D1 M3U8Playlist 新增 baseURL', 'var baseURL: URL?' in m3)
chk('D2 parse 里赋值', 'p.baseURL = baseURL' in m3)

ff = code_of(read('FFmpegConverter.swift'))
print()
print('=== E. ffmpeg 入口 + 成品体检 ===')
chk('E1 输入改成"任意可读输入 + 输入体积"',
    'static func toMP4(input: URL, inputBytes: Int64, mp4: URL' in ff)
chk('E2 用的是 input.path', '"-i", input.path' in ff)
chk('E3 体积比体检（50%~150%）', 'ratio >= 0.5, ratio <= 1.5' in ff)
chk('E4 输出没有视频轨仍算失败', '输出里没有视频轨' in ff)

ex = code_of(read('Exporter.swift'))
print()
print('=== F. 老路（自研换封装）也必须过体检 ===')
chk('F1 新增 checkSize', 'private static func checkSize(out: URL, input: URL) throws' in ex)
chk('F2 手段 1 成功前调用它', 'try checkSize(out: mp4, input: ts)' in ex)
chk('F3 调用点已适配新签名', 'input: ts, inputBytes: 0' in ex)

dj = read('DownloadJob.swift'); djc = code_of(dj)
print()
print('=== G. 编排：主路 ffmpeg → 不成才回落到老路 ===')
chk('G1 主路先只下分片（用 run 的参数，不是改 Options）',
    'run(sourceURL: src, skipJoin: true)' in djc and 'opt.skipJoin' not in djc)
chk('G2 调用 remuxViaFFmpeg', 'await remuxViaFFmpeg(' in djc)
chk('G3 老路被 if !ffmpegDone 包住', 'if !ffmpegDone {' in djc)
chk('G4 转 MP4 那段也受同一条件控制', djc.count('if !ffmpegDone {') >= 2)
chk('G5 有 remuxViaFFmpeg 实现', 'private func remuxViaFFmpeg(partsDir: URL' in djc)
chk('G6 它用 FFmpegConverter 的新签名', 'FFmpegConverter.toMP4(' in djc and 'inputBytes: partsBytes' in djc)
chk('G7 有体积统计 dirSize', 'private static func dirSize(' in djc)
chk('G8 有上下文头助手', 'private static func ctxHeaders(' in djc)
chk('G9 缩略图在新路成功时也抽（thumbSource = ffmpegMP4）',
    'var thumbSource: URL? = ffmpegMP4' in djc)
# ★★ run #141 编译失败就挂在这：这两个变量声明在"下载分支"里、却在分支外用 →
#    `cannot find 'ffmpegMP4' in scope`。文本自检查不出"作用域"，所以这里单列一条位置判据钉死。
chk('G10 声明必须在分支外（在 joinedBytes 声明之前）—— run #141 的坑',
    djc.index('var ffmpegMP4: URL? = nil') < djc.index('var joinedBytes: Int64 = 0'))
chk('G11 分支里是赋值、不是重新声明',
    'let ffmpegMP4 = await remuxViaFFmpeg(' not in djc
    and 'ffmpegMP4 = await remuxViaFFmpeg(' in djc)

print()
print('=== H. 回归：前几版不能被碰掉 ===')
chk('H1 分片完成标记（v1.0.140）', 'doneMarkerURL' in dlc and 'badContent' in dlc)
chk('H2 缺分片抛错 + 独立计数（v1.0.140）',
    'missingSegment' in dlc and 'writtenSegments: writtenCount' in dlc)
chk('H3 探测不整份进内存（v1.0.140）',
    'HeadOnlyReader' in code_of(read('SourceProbe.swift')))
chk('H4 Range 严格 416（v1.0.140）',
    'sendRangeNotSatisfiable' in code_of(read('LocalHTTPServer.swift')))
chk('H5 地址清洗两个死角（v1.0.140）',
    'percentEscapesLookOK' in code_of(read('M3U8.swift')))
chk('H6 URI 一律绝对化（v1.0.139）', 'rewriteURIAttrs' in pr)
chk('H7 播放清单本地化仍在（v1.0.139）', 'static func target(remote:' in pr)
chk('H8 转 MP4 有进度（v1.0.138）', 'sizePoller' in ff)
chk('H9 详细日志 + 复制记录（v1.0.138）',
    '【VideoGrab 任务记录】' in read('ContentView.swift'))

print()
print('RESULT: %d PASS / %d FAIL' % (len(PASS), len(FAIL)))
if FAIL:
    print('FAILED:')
    for f in FAIL: print('  - ' + f)
    sys.exit(1)
