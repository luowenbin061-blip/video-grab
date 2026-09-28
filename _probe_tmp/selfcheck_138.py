# -*- coding: utf-8 -*-
"""v1.0.138 源码自检 —— 用户这一轮提的四件事。

  ① 转码时**真卡死**（不是假卡死）→ 能做的：加进度让"看起来卡"消失 + 大文件省一遍 I/O
  ② 要**每任务一份超详细、通俗易懂的下载日志**
  ③ 界面把「重封装」改成「正在转成 MP4…」**并显示进度**
  ④ 内置播放器播放失败（HTTP 400）→ **修**（根因：AVPlayer 解析不了"原生中文相对路径"那份清单）
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

print('=== ④ 播放修复：不再把远端原始清单直接交给 AVPlayer ===')
pr = read('PlaylistRelay.swift'); prc = code_of(pr)
chk('R1 PlaylistRelay 新文件在', 'enum PlaylistRelay {' in prc)
chk('R2 有统一入口 target(remote:title:headers:)',
    'static func target(remote: String' in prc and '-> PlayTarget?' in prc)
chk('R3 有 PlayTarget 类型（Identifiable）',
    'struct PlayTarget: Identifiable' in prc)
chk('R4 只处理 http/https（不碰本地 file:// 与 127.0.0.1）',
    'scheme == "http" || scheme == "https"' in prc)
chk('R5 只处理 VOD（有 ENDLIST 才走）', '"#EXT-X-ENDLIST"' in prc)
chk('R6 逐行清洗走 M3U8Playlist.resolve', 'M3U8Playlist.resolve(line, relativeTo: base)' in prc)
chk('R7 分片写成绝对地址', 'abs.absoluteString' in prc)
chk('R8 #EXT-X-KEY 的 URI 也洗（含非 ASCII 才动）',
    'rewriteKeyURI' in prc and 'rewriteKeyURI(line, base: base)' in prc)
chk('R9 借本机 HTTP 服务提供（HLS 必须 http）',
    'LocalHTTPServer.shared.start(root: root)' in prc and 'LocalHTTPServer.shared.url(name)' in prc)
chk('R10 任何一步不成返回 nil（退回原地址，不比现在差）',
    prc.count('{ return nil }') >= 5)
chk('R11 会用 GB18030 兜底解码', 'HLSDownloader.gb18030' in prc)
chk('R12 旧清单会清理', 'cleanOld' in prc and 'staleAge' in prc)

cv = read('ContentView.swift'); cvc = code_of(cv)
chk('R13 长按播放状态改成 PlayTarget', '@State private var lpPlay: PlaylistRelay.PlayTarget?' in cvc)
chk('R14 长按 onPlay 走 PlaylistRelay.target', 'PlaylistRelay.target(' in cvc)
chk('R15 长按播放器直接用已本地化的地址',
    'PlayerSheet(url: t.url' in cvc and 'key: "lp"' in cvc)
chk('R16 嗅探预览状态改成 PlayTarget',
    '@State private var previewItem: PlaylistRelay.PlayTarget?' in cvc)
chk('R17 嗅探预览按钮走 target', 'previewHeaders(it))' in cvc)
chk('R18 两个 cover 里不再有裸 URL(string:) 播放',
    'if let u = URL(string: it.url)' not in cvc)
chk('R19 拼不出地址时给提示（不静默）',
    '这个地址读不懂，播不了。可以换个源，或者直接下载试试。' in cv)

print()
print('=== ③ 文案：不再出现「重封装 / 转码」，统一「正在转成 MP4…」+ 进度 ===')
ff = read('FFmpegConverter.swift'); ffc = code_of(ff)
chk('W1 开始文案是「正在转成 MP4…」', 'onProgress(0, "正在转成 MP4…")' in ffc)
chk('W2 有进度轮询（500ms 一次）',
    'sizePoller' in ffc and '500_000_000' in ffc)
chk('W3 进度按输出/输入大小算', 'Double(out) / Double(inSize)' in ffc)
chk('W4 进度文案带百分比', '"正在转成 MP4… \\(Int(p * 100))%"' in ffc)
chk('W5 大文件不开 faststart', 'faststartLimit' in ffc and 'useFaststart' in ffc)
chk('W6 体检结果里说明有没有优化开头', '大文件跳过开头优化' in ff)
# ★★ run #138 就挂在这：用 `var args` 拼完参数、再在 Task.detached 里引用它 →
#    `error: reference to captured var 'args' in concurrently-executing code`（白烧一轮）。
#    同一个坑 Downloader.run 里踩过；这条判据把它钉死，以后本地就能拦。
chk('W14 进并发闭包的参数是 let（不能再是 var）',
    'let args = argList' in ffc and 'var args:' not in ffc,
    '仍是 var 声明' if 'var args:' in ffc else '')
ex = read('Exporter.swift')
chk('W7 Exporter 里不再写「FFmpeg 重封装」', 'FFmpeg 重封装' not in ex)
chk('W8 Exporter 用「转成 MP4（FFmpeg）」', '转成 MP4（FFmpeg）' in ex)
chk('W9 备用方式也改名', '转成 MP4（备用方式）' in ex)
chk('W10 TSRemuxer 进度文案也改了', '正在转成 MP4… \\(done / 1_048_576)MB' in read('TSRemuxer.swift'))
dj = read('DownloadJob.swift'); djc = code_of(dj)
chk('W11 阶段名改成「转成 MP4」', 'case .convert:  return "转成 MP4"' in djc)
chk('W12 阶段名下载/拼接也改得更直白',
    '"下载分片"' in djc and '"拼成一整段"' in djc)
chk('W13 不能再出现 stageBegin("转码")', 'stageBegin("转码")' not in djc)

print()
print('=== ② 详细日志（人话版 + 进度 + 结果 + 一键复制）===')
chk('L1 开头说明"要处理的是什么"', '要处理的是：' in dj)
chk('L2 开头说明"从哪个页面来的"', '它是从哪个页面来的：' in dj)
chk('L3 开头说明"接下来会怎么干"', '接下来会：' in dj)
chk('L4 转 MP4 前解释"只是换容器"', '换个容器' in dj)
chk('L5 进度按 10% 一档记进日志',
    'loggedTranscodeStep' in djc and '正在转成 MP4… \\(step * 10)%' in dj)
chk('L6 成功有"结果：成功"一句', '结果：成功' in dj)
chk('L7 半成功（没转出 MP4）也说清楚', '结果：没完全成功' in dj)
chk('L8 失败有"结果：失败"+ 下一步',
    '结果：失败' in dj and '可以试试：' in dj)
chk('L9 过程记录有一键复制按钮', 'UIPasteboard.general.string = logText' in cvc)
chk('L10 复制内容带头部信息（版本/时间/地址/状态）',
    'logText' in cvc and '【VideoGrab 任务记录】' in cv and 'App 版本：' in cv)
chk('L11 记录里带上了主线程失联与内存峰值（诊断真卡死靠它）',
    '主线程最长失联' in dj and '内存峰值' in dj)

print()
print('=== 回归：前几版能力未被回退 ===')
m3 = code_of(read('M3U8.swift'))
chk('G1 中文地址清洗（v1.0.134）', 'static func sanitizeURLString' in m3)
chk('G2 探测不再把 m3u8 当文件（v1.0.136）',
    'String(decoding: data.prefix(4096), as: UTF8.self)' in code_of(read('SourceProbe.swift')))
chk('G3 两份"没分片"报错仍在', 'case noAddress(' in code_of(read('Downloader.swift')))
chk('G4 边下边播 VOD 仍在',
    'EXT-X-PLAYLIST-TYPE:VOD' in code_of(read('LivePreview.swift')))
chk('G5 续看/横屏开关仍在',
    'resumeEnabled' in code_of(read('WatchProgress.swift'))
    and 'autoLandscapeKey' in code_of(read('PlayerSheet.swift')))
chk('G6 备份含已放行网站', 'vgTrustedCertHosts' in code_of(read('DataBackup.swift')))
chk('G7 播放失败仍带 errorLog 定位',
    'item.errorLog()' in code_of(read('PlayerSheet.swift')))

print()
print('RESULT: %d PASS / %d FAIL' % (len(PASS), len(FAIL)))
if FAIL:
    print('FAILED:')
    for f in FAIL: print('  - ' + f)
    sys.exit(1)
