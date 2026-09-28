# -*- coding: utf-8 -*-
"""第二轮：把审查简报**按模块切成两份更小的**，各派 3 家。
   为什么：第一轮 39KB 题面 → 2 家超时、1 家整段回显、1 家把思考过程当答案。
   实测判断是"题面太大把 180s 预算吃光"，所以这轮压到 ~10KB 一份。
"""
import io, os, json, re, sys
sys.stdout.reconfigure(encoding='utf-8')

APP = r'E:/自用WIN10-最强没有之一/VideoGrab/app'
OUTA = r'E:/自用WIN10-最强没有之一/VideoGrab/_五家审查简报A-内置播放器-20260928.md'
OUTB = r'E:/自用WIN10-最强没有之一/VideoGrab/_五家审查简报B-下载器-20260928.md'
PLAN = r'E:/自用WIN10-最强没有之一/_probe_tmp/plan_review2_20260928.json'

def read(n):
    with io.open(os.path.join(APP, n), encoding='utf-8') as f:
        return f.read()

def cut(name, start, lines=None, to_end=False, end=None, keep_comment=4):
    s = read(name)
    i = s.find(start)
    if i < 0:
        raise SystemExit('!! 标记找不到 %r in %s' % (start[:44], name))
    if to_end:
        body = s[i:]
    elif end:
        j = s.find(end, i)
        if j < 0:
            raise SystemExit('!! 结束标记找不到 %r' % end[:44])
        body = s[i:j]
    else:
        body = '\n'.join(s[i:].split('\n')[:lines])
    # 注释压缩：连续注释只留前 keep_comment 行（只动注释，不碰代码）
    out, run, drop = [], [], 0
    def flush():
        nonlocal drop
        if len(run) > keep_comment:
            out.extend(run[:keep_comment])
            out.append('    // …（此处省略 %d 行历史说明）' % (len(run) - keep_comment))
            drop += len(run) - keep_comment
        else:
            out.extend(run)
        run.clear()
    for line in body.split('\n'):
        if line.strip().startswith('//'):
            run.append(line)
        else:
            flush(); out.append(line)
    flush()
    tag = ('，注释压缩 %d 行' % drop) if drop else ''
    return '```swift\n// ── %s%s ──\n%s\n```\n' % (name, tag, '\n'.join(out).rstrip())


CONSTRAINT = """## 0. 约束（判 bug 时请守住，这些**不是**问题）

- 平台 **iOS 15.0+**，真机 iOS 16.6，**TrollStore 安装（没有 App Store 沙箱）** →
  用未公开 API（`AVURLAssetHTTPHeaderFieldsKey`）和自写 socket 服务是环境允许的，
  **请不要报"不该用私有 API / 不该自己起服务"**。
- 纯 Swift + SwiftUI + AVFoundation + WebKit，无第三方包；FFmpeg 以内嵌静态库**进程内**调用。
- 只服务我自己一台手机的自用工具，不发布、不多用户。
- 你看不到我的工程，**下面贴的代码就是全部依据**；需要别的代码才能下结论时，请写
  "需要看 XXX"，**不要猜**。

## 我们**已经知道并改过**的坑（**请不要再报这些**，重复会浪费我的时间）

1. `URL(string:)` 遇任何非 ASCII 会返回 nil → 已有 `sanitizeURLString` 清洗。
2. 本地裸 `.ts` 喂 AVPlayer 播不了 → 已用"单分片 m3u8"包一层。
3. HLS 用 `file://` 会报 `CoreMediaErrorDomain -12865/12881` → 已全改走本机 http。
4. AVPlayer 解析不了"原生中文相对路径"的分片行（实测请求成 404）→ 见下面的 relay。
5. 直播清单不能快照（会播完即停）→ relay **只对有 `#EXT-X-ENDLIST` 的 VOD 生效**。
6. 清单可能不是 UTF-8（中文站 GBK）→ 已按 utf8 → GB18030 → latin1 兜底。
7. 严格 UTF-8 解码失败会把 m3u8 误判成"普通文件"→ 已改成永不失败的 lossy 解码。
8. `+faststart` 对大文件是**两遍 I/O** → 已对 >400MB 关掉。
9. `AVAssetExportSession` 拿不到 HLS 轨道（`loadTracks` 返回空）→ 所以自写换封装 + 内嵌 FFmpeg 为主。
10. 私聊仓库的构建产物走带 token 的 API 通道（与本题无关）。
"""

REQ = """
────────────────────────────────────────
【回答要求】（务必遵守）

1. 按上面「请重点回答」的编号**逐条**答（A1…X1 / B1…X1），**一条都不许跳**；
   真答不了就写"这条我判断不了，因为……"。
2. **用简体中文**。**直接给结论，不要复述或回显题目/背景/要求清单。**
3. 每条结论**落到具体代码**：指出文件名 + 关键行（例："PlaylistRelay 里
   `guard uri.contains(where: { !$0.isASCII }) else { return line }` 这一行"）。
   只给"建议加错误处理"这种方向话对我没用。
4. **不确定就明说不确定**，不要凑数编造。
5. 回答**第一行**单独写：`[ANSWER {ID}]`
"""

def build(kind):
    if kind == 'A':
        code = ('### A1. PlaylistRelay（把远端清单洗成本地清单再播 —— 本次新写的核心）\n\n'
                + cut('PlaylistRelay.swift',
                      '    /// 临时清单的文件名前缀', to_end=True)
                + '\n### A2. 本机 http 服务的两处关键逻辑（目录穿越防护 / Range）\n\n'
                + cut('LocalHTTPServer.swift', '        // 防目录穿越', lines=12)
                + '\n' + cut('LocalHTTPServer.swift',
                              '        for l in lines where l.lowercased().hasPrefix("range:") {', lines=26)
                + '\n### A3. AVPlayer 那层封装（怎么把本机 http 的清单喂进去、怎么判失败）\n\n'
                + cut('PlayerSheet.swift', '    init(url: URL, resumeKey: String = ""', lines=42, keep_comment=2)
                + '\n' + cut('PlayerSheet.swift', '    private func startPolling() {', lines=40, keep_comment=2)
                + """
## 请重点回答（逐条）

- **A1.** `PlaylistRelay` 里，有没有哪种情况会**把本来能播的反而搞坏**？（逐条列，这是我最怕的）
- **A2.** 把临时 m3u8 写进"下载目录"再靠本机 http 服务提供 —— 并发（两个播放入口同时点）、
  文件清理（`cleanOld`）、服务端口生命周期，分别有什么坑？
- **A3.** 自写 socket 服务这两段（目录穿越防护 / Range 解析）有没有漏洞或 bug？
  （例如 `..`、符号链接、Range 越界、`bytes=-500` 这种 suffix range、多 Range 头、`total==0`）
- **A4.** `PlayerBox` 的兜底（60 秒超时、8 秒卡住、`item.status` 轮询）有没有漏判/误判？
  （`status` 长期 `.unknown`、`item.error` 为空但不出画面、重试后状态不刷新、`onProgress` 回调线程）
- **X1.** 综合来看，你会**先修哪 3 个**？给出具体文件 + 改法。
""")
    else:
        code = ('### B1. 中文/全角地址清洗（不洗 `URL(string:)` 直接返回 nil）\n\n'
                + cut('M3U8.swift', '    static func sanitizeURLString(_ s: String) -> String {',
                      end='    /// baseURL 用「真正取到这份 m3u8 的那个地址」', keep_comment=3)
                + '\n### B2. 下载主流程（并发下分片 → 拼接 → 校验）\n\n'
                + cut('Downloader.swift', '    func run(sourceURL: URL) async throws -> Output {', lines=120, keep_comment=3)
                + '\n### B3. 探测：这个地址到底是什么（决定走清单还是直链）\n\n'
                + cut('SourceProbe.swift', '    static func fetch(url: URL, ua: String, referer: String?,', lines=62, keep_comment=3)
                + '\n### B4. 转成 MP4：先 FFmpeg（进程内 CLI），失败再走自研\n\n'
                + cut('Exporter.swift', '    static func toMP4(ts: URL,', lines=52, keep_comment=2)
                + '\n' + cut('FFmpegConverter.swift', '    static func toMP4(ts: URL, mp4: URL,', to_end=True, keep_comment=2)
                + """
## 请重点回答（逐条）

- **B1.** 哪些地方会**"下到坏文件却报成功"**？（我认为这是最严重的一类，请重点找）
- **B2.** "分片文件已存在就跳过"这个断点续传判据可靠吗？有没有**用旧的/残缺文件冒充新文件**的可能？
  （注意：分片是按序号命名的 `seg_%06d.part`，重试时不会校验已存在分片的完整性）
- **B3.** 有没有**与文件大小成正比的内存分配点**？我遇到"大文件转 MP4 时界面卡死、甚至被杀掉"，
  想确认内存可能堆在哪（包括进程内跑 FFmpeg 这件事本身的后果）。
- **B4.** `sanitizeURLString` 的规则有没有反例会让地址变得**更错**？
  （它只编码非 ASCII 和空格；已存在的 `%XX` 不重复编码；`:/?#[]@!$&'()*+,;=` 保留）
- **X1.** 综合来看，你会**先修哪 3 个**？给出具体文件 + 改法。
""")
    head = ('# 代码审查请求：iOS 网页视频下载器（**自用工具**）—— %s\n\n'
            '我在做一个**只给自己用**的 iOS 网页视频下载器。请以"找 bug"的眼光审下面这段代码。\n'
            '**优先报"会出实事"的问题（下到坏文件、丢数据、崩溃、卡死、播不出来），其次才是优化建议。**\n\n'
            % ('内置播放器' if kind == 'A' else '下载器'))
    return head + CONSTRAINT + '\n## 代码\n\n' + code


a = build('A')
b = build('B')
io.open(OUTA, 'w', encoding='utf-8').write(a)
io.open(OUTB, 'w', encoding='utf-8').write(b)
print('简报A %d 字符 (%.1f KB)  → %s' % (len(a), len(a.encode('utf-8'))/1024, OUTA))
print('简报B %d 字符 (%.1f KB)  → %s' % (len(b), len(b.encode('utf-8'))/1024, OUTB))

PROVIDERS = [('R1', 'qwen', a), ('R2', 'minimax', a), ('R3', 'mimo', a),
             ('R6', 'qwen', b), ('R7', 'minimax', b), ('R8', 'mimo', b)]
subs = []
for i, (rid, prov, body) in enumerate(PROVIDERS, start=1):
    subs.append({'id': rid.lower(), 'primary': prov, 'depends_on': [], 'questions': [rid],
                 'prompt': '【Task %d】[ANSWER %s]\n\n' % (i, rid) + body + REQ.replace('{ID}', rid)})
plan = {'exclude': ['claude', 'gemini', 'chatgpt', 'kimi', 'doubao'], 'subtasks': subs}
io.open(PLAN, 'w', encoding='utf-8').write(json.dumps(plan, ensure_ascii=False, indent=1))
print('计划已写 %s（%d 道，%.0f KB）' % (PLAN, len(subs), len(json.dumps(plan, ensure_ascii=False))/1024))
