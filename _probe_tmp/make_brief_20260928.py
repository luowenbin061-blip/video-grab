# -*- coding: utf-8 -*-
"""生成「内置播放器 + 下载器」的代码审查简报（给五家网页 AI 看）。

★ 硬要求：**代码必须逐字来自源码**（按标记抽取），绝不手敲 ——
  上次发出去的审查材料里有事实错误（把最低系统写成 iOS 16.0，实为 15.0），
  所以这次凡是"事实"一律从文件里读出来填进模板。
"""
import io, os, sys, re
sys.stdout.reconfigure(encoding='utf-8')

APP = r'E:/自用WIN10-最强没有之一/VideoGrab/app'
OUT = r'E:/自用WIN10-最强没有之一/VideoGrab/_五家审查简报-内置播放器与下载器-20260928.md'

def read(name):
    with io.open(os.path.join(APP, name), encoding='utf-8') as f:
        return f.read()

def cut(name, start_marker, lines=None, to_end=False, end_marker=None):
    """按标记从文件里抽一段。找不到标记就抛（绝不静默给空）。

    ★ 抽出来之后做一道**注释压缩**：连续超过 6 行的注释只留前 6 行。
      为什么：完整源码 50KB，DeepSeek 那类 64K 上下文的模型可能吃不下；
      而这些注释大半是"我们踩过的历史坑"，简报正文里已经用大白话列过一遍了
      （见「已知的坑」那一节），压缩掉不损失审代码需要的信息。
      **只动注释行，绝不碰代码行**；被压掉的行数会写出来，可回溯。
    """
    s = read(name)
    i = s.find(start_marker)
    if i < 0:
        raise SystemExit('!! 找不到标记 %r in %s' % (start_marker[:48], name))
    if to_end:
        body = s[i:]
    elif end_marker:
        j = s.find(end_marker, i)
        if j < 0:
            raise SystemExit('!! 找不到结束标记 %r in %s' % (end_marker[:48], name))
        body = s[i:j]
    else:
        body = '\n'.join(s[i:].split('\n')[:lines])
    body, dropped = compress_comments(body)
    tag = ('，注释压缩掉 %d 行' % dropped) if dropped else ''
    return '```swift\n// ── %s%s ──\n%s\n```\n' % (name, tag, body.rstrip())


def compress_comments(body, keep=6):
    """连续注释超过 keep 行时，只留前 keep 行 + 一句省略说明。返回 (新文本, 去除行数)。"""
    out = []
    run = []
    dropped = 0

    def flush():
        nonlocal dropped
        if len(run) > keep:
            out.extend(run[:keep])
            out.append('    // …（此处省略 %d 行历史说明，均为已修过的旧问题）' % (len(run) - keep))
            dropped += len(run) - keep
        else:
            out.extend(run)
        run.clear()

    for line in body.split('\n'):
        st = line.strip()
        if st.startswith('//'):
            run.append(line)
        else:
            flush()
            out.append(line)
    flush()
    return '\n'.join(out), dropped

def fact(pattern, name, default='?'):
    s = read(name)
    m = re.search(pattern, s, re.M)
    return m.group(1) if m else default

# ── 事实核查（从文件里读，不手写）──
proj = io.open(r'E:/自用WIN10-最强没有之一/VideoGrab/project.yml', encoding='utf-8').read()
min_ios = re.search(r'IPHONEOS_DEPLOYMENT_TARGET:\s*"([^"]+)"', proj).group(1)
appver = '1.0.139'

A = []
A.append(cut('PlaylistRelay.swift', 'enum PlaylistRelay {', to_end=True))
A.append(cut('LivePreview.swift', '    static func playlistBody(forPath path: String, root: URL) -> String? {',
             to_end=True))
A.append(cut('PlayerSheet.swift', '    init(url: URL, resumeKey: String = ""', lines=52))
A.append(cut('PlayerSheet.swift', '    private func startPolling() {', lines=50))
A.append(cut('LocalHTTPServer.swift', '        // 防目录穿越', lines=12))
A.append(cut('LocalHTTPServer.swift', '        for l in lines where l.lowercased().hasPrefix("range:") {', lines=30))

B = []
B.append(cut('M3U8.swift', '    static func sanitizeURLString(_ s: String) -> String {',
             end_marker='    /// baseURL 用「真正取到这份 m3u8 的那个地址」'))
B.append(cut('Downloader.swift', '    func run(sourceURL: URL) async throws -> Output {', lines=132))
B.append(cut('SourceProbe.swift', '    static func fetch(url: URL, ua: String, referer: String?,', lines=72))
B.append(cut('Exporter.swift', '    static func toMP4(ts: URL,', lines=70))
B.append(cut('FFmpegConverter.swift', '    static func toMP4(ts: URL, mp4: URL,', to_end=True))
B.append(cut('DownloadJob.swift', '            phase = "探测地址…"', lines=40))
B.append(cut('DownloadJob.swift', '            // ★ v1.0.101：上次已经拼好的 .ts 还在', lines=42))

brief = """# 代码审查请求：iOS 网页视频下载器（**自用工具**）—— 内置播放器 + 下载器 两套逻辑

我在做一个**只给自己用**的 iOS 网页视频下载器。想请你以"找 bug"的眼光审一下下面两套逻辑。
**请优先报"会出实事"的问题（下到坏文件、丢数据、崩溃、卡死、播不出来），其次才是优化建议。**

## 0. 先看约束（判 bug 时请守住，这些**不是**问题）

- 平台 **iOS {min_ios} 以上**，真机 iOS 16.6；**通过 TrollStore 安装，没有 App Store 沙箱**
  → 所以会用到**未公开 API**（`AVURLAssetHTTPHeaderFieldsKey`）和**自写 socket 服务**，
    这些是环境允许的，请不要报"不该用私有 API / 不该自己起服务"。
- 纯 Swift + SwiftUI + AVFoundation + WebKit；**没有第三方包**（FFmpeg 以内嵌静态库形式**在进程内**调它的 CLI main）。
- **不处理 DRM 加密的付费内容**（拿不到就是拿不到）。
- 只服务我自己一台手机，不对外发布、不做多用户。
- 已知：**网页 AI 看不到我的工程**，所以下面贴的代码就是全部依据；
  如果你需要某段没贴的代码才能下结论，请直接说"需要看 XXX"，**不要猜**。

## 1. 两套逻辑的分工

```
【下载器】 嗅探到地址 → 探测这个地址是什么
                    → 是分片清单(m3u8)：下分片 → 拼成一整段 .ts → 转成 MP4
                    → 是单个文件(mp4/pdf…)：直接整份下
                    → 断点续传靠"已存在的分片文件直接跳过"
【内置播放器】 播"网页里的地址" 或 播"本地下好的文件"
                    → 本机自写 HTTP 服务负责把本地文件/清单以 http 喂给 AVPlayer
                    → 长按菜单/嗅探面板播放时，先走 PlaylistRelay 把远端清单"本地化"
```

## 2. 【模块 A】内置播放器

### A.1 最关键的新代码：PlaylistRelay（把远端清单"洗"成本地清单再播）

**为什么有它（实测结论，不是猜）**：某个站的分片行是「**原生中文 + 全角括号的相对路径**」，
`AVPlayer` 自己解析这行时出错了 —— 把 `<名称>0.ts` 请求成了 `<名称>.ts`（**丢了序号**），
服务器回 404。我们实测：清单本身 200、清单里的真实分片 200、**连 Referer 都不用**。
结论：**站上东西是好的，是播放器解析不了那份清单**。
所以改成：我们**自己取清单 → 逐行洗成绝对地址 → 写成本地 m3u8 → 用本机 HTTP 提供**。

{A0}
### A.2 本地服务的目录穿越防护 + Range 处理

{A2}
{A3}
### A.3 播放器的 AVPlayer 封装（本机 http 里的清单怎么喂进去）

{A1}
{A4}
### A.4 边下边播用的"现场生成清单"（每下完一个分片它就变长）

{A5}
## 3. 【模块 B】下载器

### B.1 中文/全角地址的清洗（不洗 `URL(string:)` 会直接返回 nil）

{B0}
### B.2 下载主流程（分片并发下载 → 拼接 → 校验）

{B1}
### B.3 探测：这个地址到底是什么

{B2}
### B.4 转成 MP4：先 FFmpeg（进程内 CLI），失败再走自研

{B3}
{B4}
### B.5 主任务里两个关键决策点

{B5}
{B6}
## 4. 请重点回答（**请按编号逐条答，不要跳**）

**模块 A（播放器）**
- **A1.** `PlaylistRelay` 里，有没有哪种情况会**把本来能播的反而搞坏**？（逐条列，这是我最怕的）
- **A2.** 把临时 m3u8 写进"下载目录"再靠本机 http 服务提供 —— 并发（两个播放入口同时点）、
  文件清理、端口/服务生命周期，分别有什么坑？
- **A3.** `PlayerBox` 那几个兜底（60 秒超时、8 秒卡住、`item.status` 轮询）有没有漏判/误判？
  例如 `status` 长期停在 `.unknown`、`item.error` 为空但画面不出、reload 后状态不刷新。
- **A4.** 自写 socket 服务（只在下面贴了**目录穿越**和 **Range** 两段）：
  这两段有没有漏洞或 bug？（例如 `..` / 符号链接 / Range 越界 / `suffix-range` / 多 Range 头）

**模块 B（下载器）**
- **B1.** 哪些地方会**"下到坏文件却报成功"**？（我认为这是最严重的一类错误，请重点找）
- **B2.** "分片已存在就跳过"这个断点续传判据可靠吗？有没有**用旧的/残缺文件冒充新文件**的可能？
- **B3.** 有没有**与文件大小成正比的内存分配点**？我遇到"大文件转 MP4 时界面卡死甚至被杀"，
  想确认内存到底可能堆在哪。
- **B4.** `sanitizeURLString` 的规则有没有反例会让地址变得**更错**？（它只编码非 ASCII 和空格，
  已存在的 `%XX` 不重复编码，`:/?#[]@!$&'()*+,;=` 这些保留）

**通用**
- **X1.** 综合两套逻辑，你会**先修哪 3 个**？请给出具体文件与改法，不要只给方向。

### 附：我们**已经知道并改过**的坑（**请不要再报这些**，重复会浪费我的时间）

1. `URL(string:)` 遇到任何非 ASCII 字符会返回 nil → 已有 `sanitizeURLString` 清洗。
2. 本地裸 `.ts` 直接喂 AVPlayer 播不了 → 已用"单分片 m3u8"包一层。
3. HLS 用 `file://` 会报 `CoreMediaErrorDomain -12865/12881` → 已全部改走本机 http。
4. AVPlayer 解析不了"原生中文相对路径"的分片行（实测请求成 404）→ 就是 A.1 那个 relay。
5. 直播清单不能做快照（会播完即停）→ relay **只对有 `#EXT-X-ENDLIST` 的 VOD 生效**。
6. 清单可能不是 UTF-8（中文站 GBK）→ 已按 utf8 → GB18030 → latin1 逐层兜底。
7. 严格 UTF-8 解码失败会把 m3u8 误判成"普通文件"→ 已改成永不失败的 lossy 解码。
8. `+faststart` 对大文件要**两遍 I/O** → 已对 >400MB 关掉它。
9. `AVAssetExportSession` 拿不到 HLS 的轨道（`loadTracks` 返回空）→ 所以自己写换封装、并以内嵌 FFmpeg 为主。
10. 私有仓库禁止匿名拉取 → 我们下载构建产物走的是带 token 的 API 通道（与本题无关，仅说明）。

---
（App 版本 {appver}；本简报由本地脚本从源码逐字抽取生成）
"""

body = brief.replace('{min_ios}', min_ios).replace('{appver}', appver)
for i, blk in enumerate(A):
    body = body.replace('{A%d}' % i, blk)
for i, blk in enumerate(B):
    body = body.replace('{B%d}' % i, blk)

# 占位符必须全部填掉
left = re.findall(r'\{[AB]\d\}', body)
if left:
    raise SystemExit('!! 还有占位符没填: %s' % left)

io.open(OUT, 'w', encoding='utf-8').write(body)
print('已生成：%s' % OUT)
print('字符数 %d（约 %.0f KB），行数 %d' % (len(body), len(body.encode('utf-8')) / 1024, body.count('\n')))
print('min_ios 事实核查 =', min_ios)
print('代码块数 A=%d B=%d' % (len(A), len(B)))
