# -*- coding: utf-8 -*-
"""① MEMORY.md 瘦身：VideoGrab 那条巨型索引进 notes/VideoGrab.md，主文件留精简索引
   ② 今天的日记追加 v1.0.137 这段

★ 规矩：**只搬不删**（「替换 ≠ 删除」）。搬走的那段原文一字不改地附录进 notes，
  并在 MEMORY.md 里写明"版本史在 notes"。
"""
import io, os, re, sys
sys.stdout.reconfigure(encoding='utf-8')

MEM = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/MEMORY.md'
NOTES = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/notes/VideoGrab.md'
LOG = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/2026-09-28.md'

def atomic(path, text):
    tmp = path + '.tmp'
    io.open(tmp, 'w', encoding='utf-8').write(text)
    os.replace(tmp, path)

# ── ① MEMORY.md 瘦身 ────────────────────────────────────────────────
mem = io.open(MEM, encoding='utf-8').read()
m = re.search(r'^- \*\*VideoGrab\*\*.*$', mem, re.M)
if not m:
    print('!! 找不到 VideoGrab 索引行'); sys.exit(1)
old_line = m.group(0)
print('原索引行 %d 字符' % len(old_line))

NEW_LINE = (
    '- **VideoGrab**（iOS 网页视频嗅探下载器，真机 iOS 16.6）→ `notes/VideoGrab.md`'
    '（**版本史与全部技术细节都在那里**，2026-09-28 从本文件搬入，只搬不删）。\n'
    '  当前 **v1.0.137**（sha256 `68a7d37d202e1496`，10.33 MB，**待真机验收**）= '
    '① 修「小部分视频下载失败」的**另一半**：探测阶段**严格 UTF-8 解码失败 → 把 m3u8 当直链文件下**'
    '（只取前 2KB 会切在汉字中间；中文站还可能是 GBK 编码）→ 解码改成**永不失败** '
    '+ 认 `mpegurl` 内容类型与 `.m3u8` 后缀；② 中文站 **GBK 清单按 GB18030 正确解码**'
    '（以前 isoLatin1 兜底会把字节翻倍 → 分片地址全错 → 必然 404 还报得像"站上没这文件"）；'
    '③ 播失败时多显示 **失败请求 + 出错地址**（给「播不了」定案用）。\n'
    '  上一版 **v1.0.135** = 修**中文分片地址**（`URL(string:)` 遇非 ASCII 直接返回 nil → 分片行被静默跳过）'
    '+ **长按那张预览大白卡可点 = 用内置播放器播**（不加按钮文字，只叠小三角；视频/直播同一套 PlayerSheet）。\n'
    '  上一版 **v1.0.133** = 两个播放开关（续看/自动横屏，默认关）+ 边下边播清单改 VOD 用真实分片时长 + '
    '备份补「已放行网站」名单（**只能带名单不能带信任**）。\n'
    '  ★ **交付固定 5 步**：推送 → 下载校验 → `install_ipa.py` 落地固定入口 → 验固定入口 → 文档；'
    '流程走技能 `ios-app-cloud-build`。\n'
    '  ★★ **下载校验必须走「带 token 的 API 资产通道」**（`GET /repos/{r}/releases/assets/{id}` + '
    '`Authorization` + `Accept: application/octet-stream`）：**仓库是私有的**，国内镜像匿名拉一律 404，'
    '而且有的镜像把 9 字节的 `Not Found` 缓存住 → 脚本每轮只落 9 字节、看起来像"镜像抽风"。实测 3 MB/s。\n'
    '  ★ 交付入口 `VideoGrab\\VideoGrab-unsigned.ipa`。★ 2026-09-27 用户「当前程序已比较满意」进稳定期；'
    '**去水印已搁置，别再主动推**。'
)

mem2 = mem.replace(old_line, NEW_LINE, 1)
atomic(MEM, mem2)
print('MEMORY.md %d -> %d 字符' % (len(mem), len(mem2)))

# ── 把搬走的那段原文附进 notes（一字不改） ──────────────────────────
notes = io.open(NOTES, encoding='utf-8').read()
if 'MEMORY.md 索引行原文（2026-09-28 搬入' in notes:
    print('notes 里已附过，跳过')
else:
    block = ('\n\n---\n\n## MEMORY.md 索引行原文（2026-09-28 搬入，只搬不删）\n\n'
             '> 原先 MEMORY.md 里 VideoGrab 那一条越滚越长（含 v1.0.84~v1.0.135 的逐版记要），\n'
             '> 已把整段原文挪到这里存档，MEMORY.md 只留精简索引。以下为一字未改的原文。\n\n'
             + old_line.replace('\\', '\\\\').replace('`', '`') + '\n')
    atomic(NOTES, notes + block)
    print('notes/VideoGrab.md %d -> %d 字符' % (len(notes), len(notes + block)))

# ── ② 今天的日记追加 ────────────────────────────────────────────────
log = io.open(LOG, encoding='utf-8').read() if os.path.exists(LOG) else '# 2026-09-28\n'
if 'v1.0.137' in log:
    print('日记里已写过 v1.0.137，跳过')
else:
    ADD = """

## VideoGrab v1.0.137 —— 修「还是有小部分视频下载失败」的另一半（11:3x 交付）

用户（附两张截图）：「1.还是有小部分视频下载失败 2.也有部分视频内置播放器播放失败 拉不起来播放器」。

### 问题 1 的根因（★ 和 v1.0.135 是**同一件事的另一半**）

v1.0.135 修的是「分片地址带中文」；这次是「**整份清单读不出来**」。

★ 根因在 `SourceProbe`（下载前先探一下地址是什么）：
```
let text = String(data: data.prefix(2048), encoding: .utf8) ?? ""   // ← 严格 UTF-8
```
严格 UTF-8 解码有**两个特别常见**的失败场景，一失败就把取回内容当**空串**：
1. 清单**根本不是 UTF-8**（中文站常见 GBK）；
2. 只取了**前 2048 字节**，正好切在一个汉字**中间**（汉字 3 字节，很容易切中）。

→ `trimmed` 空 → `hasPrefix("#EXTM3U")` 为假 → 掉进「单个文件」分支 → `kind = .file`
→ **下载器把清单本身当一个文档下载了**。

**用户截图里那条过程记录就是铁证**，和推断完全吻合：
```
· 探测: HTTP 206 · application/x-mpegURL · 32KB · 支持分段 · 单个文件 · 文件
✓ 直链下载完成 0.0MB（.m3u8）· 文件
✓ 已保存（文件，不需要转码）
```
—— 而且**没有「开头：」那一段**（因为 headText 是空的），这一条最能定性。

**修法**：
- 解码换成 **永不失败** 的 `String(decoding:as:)`（坏字节变 U+FFFD，ASCII 原样保留）——
  `#EXTM3U` 是纯 ASCII，只要解码别整个失败就一定认得出；顺手去 UTF-8 BOM。
- 补两道保险：**服务器自己说 mpegurl** / **地址后缀就是 .m3u8** → 也按清单处理
  （顺序上「网页」判定仍在前面，免得 `.m3u8` 返回的 404 页被当清单）。
- 顺手 `loadPlaylist`：以前 `utf8 ?? isoLatin1`，isoLatin1 对 GBK 不是"失败"而是**把字节搞错**
  （`牛` 的 `C5 A3` → "Å£" → 再 percent-encode 每字符变 2 字节 → 地址整体错位 → 必然 404）
  → 中间插一层 **GB18030**（用 `CFStringConversions` 那套，`BookmarkImporter.decode` 已有先例）。

### 问题 2：只能加定位信息，真因待定

「播放器起不来」截图是 `CoreMediaErrorDomain -16845 / HTTP 400` —— 但这句**分不清**是
「清单被拒」还是「某个分片被拒」，两者修法完全不同。所以这版加了：
- `item.errorLog()` 的**失败请求 uri + HTTP 状态码**（HLS 每一跳都记着，是唯一能定案的东西）；
- `describe()` 补 `NSURLErrorFailingURLStringErrorKey`（**出错**的地址 ≠ 我们传进去的地址）。

→ 已请用户下次把这两行截图发来（或在错误页点「复制地址」把地址发我）。

### 交付过程踩的坑（★ 值得记进技能）

1. **下载通道全挂**：`gh-proxy.com`、`ghproxy.net` 对 **v1.0.135 和 v1.0.137 都回 404**，
   而 v1.0.135 十分钟前刚从镜像下成功过。
   → 真因：**仓库是私有的**（匿名 `GET /repos/...` = 404），镜像匿名拉当然 404，
     有的还把 9 字节的 `Not Found` **缓存住** → 脚本每轮只落 9 字节，看起来像"镜像抽风"。
   → 改用 **`GET /repos/{r}/releases/assets/{id}` + `Authorization: token` + `Accept: application/octet-stream`**
     → **HTTP 200，3 MB/s**（比镜像快 10 倍）。`dl_mirror_verify.py` 已按此重写。
   → 用户「不走节点了 我开clash了」：Clash 端口 **7897** 可用（7890/10809/1080 无监听）。
2. **curl `-C 0` 也要求服务端支持 Range** → 不支持时报 `(33) does not seem to support byte ranges`
   → 脚本每轮都带 `-C` 就**空转**（我自己还先写了个会无限重下的版本，被日志里 400 多行刷屏发现）。
   → 规矩：首轮**不带** `-C`；撞上 (33) 才切整段下载，且"有进展"的判据不能用"多了几个字节"。

run #137 成功（#136 是纯文档推送烧掉的号），sha256 `68a7d37d202e1496`，10.33 MB。
自检：源码 28/28、结构 11/11、类型前缀 0 可疑、包内验收 34/34。
"""
    atomic(LOG, log + ADD)
    print('日记 %d -> %d 字符' % (len(log), len(log + ADD)))

# ── 核验 ────────────────────────────────────────────────────────────
mem3 = io.open(MEM, encoding='utf-8').read()
n3 = io.open(NOTES, encoding='utf-8').read()
l3 = io.open(LOG, encoding='utf-8').read()
print('\n=== 核验 ===')
for name, cond in [
    ('MEMORY.md 有 v1.0.137', 'v1.0.137' in mem3),
    ('MEMORY.md 不再含 v1.0.84 那类老版本串', 'v1.0.84' not in mem3),
    ('MEMORY.md 指向 notes', '版本史与全部技术细节都在那里' in mem3),
    ('MEMORY.md 记了私有仓库/API 通道', 'API 资产通道' in mem3),
    ('notes 里有搬入标记', 'MEMORY.md 索引行原文（2026-09-28 搬入' in n3),
    ('notes 保住了老版本史（v1.0.84）', 'v1.0.84' in n3),
    ('notes 保住了 v1.0.135 细节', 'sanitizeURLString' in n3),
    ('日记有 v1.0.137', 'v1.0.137' in l3),
    ('日记记了私有仓库根因', '仓库是私有的' in l3),
]:
    print(('PASS ' if cond else 'FAIL '), name)
print('\nMEMORY.md 现在 %d 字符（原 %d）' % (len(mem3), len(mem)))
