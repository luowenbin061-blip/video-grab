# -*- coding: utf-8 -*-
"""把「转码环节卡死/崩溃」的代码层诊断记进 notes/VideoGrab.md + 今天的日记（append-only）。"""
import io, os, sys
sys.stdout.reconfigure(encoding='utf-8')

NOTES = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/notes/VideoGrab.md'
LOG = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/2026-09-28.md'

def atomic(p, t):
    tmp = p + '.tmp'
    io.open(tmp, 'w', encoding='utf-8').write(t)
    os.replace(tmp, p)

NOTE_ADD = """

---

## 「转码（重封装）阶段卡死 / 大文件崩溃」的代码层诊断（2026-09-28，只查未改）

用户描述：**下载分片、拼接都不卡；只有转 MP4 时基本都会卡，小的卡得短、大的卡得久，
极端情况（大文件、内存高）直接崩溃**。问「是手机性能还是代码问题」。

### 一、转码这一步其实有两条路，界面表现完全不同（★ 最快的判别法）

`Exporter.toMP4` 的顺序是：**① FFmpeg 重封装 → ② 自研 TSRemuxer → ③ 系统导出会话**。

| 路径 | 界面显示什么 | 有没有进度 |
|---|---|---|
| ① FFmpeg（首选） | 「**FFmpeg 转码中…**」 | **没有**。`FFmpegConverter` 只在开始调 `onProgress(0, …)`、结束调 `onProgress(1, …)` |
| ② 自研重封装（兜底） | 「正在重封装… **1234MB / 5678MB**」 | **有**，逐块上报 |

→ **看一眼界面停在哪个句子，就能判断走的是哪条路。**
走 FFmpeg 时界面**从开始到结束一动不动**（`convertProgress` 只有 0 和 1 两个值），
所以「卡死」里**有很大一部分是「没有进度」而不是真卡**。

### 二、代码侧确定的问题（非推测）

1. ★★ **FFmpeg 是"进程内"跑的**（`Hook.m` 用 `setjmp/longjmp` 拦 ffmpeg 内部的 `exit()`）。
   三个后果：
   - **内存算在 App 头上、和 App 共用同一个上限** → 大文件时 ffmpeg 的内存 + App 自己的内存
     一起撞 iOS 的内存上限 → **被系统杀**。这是「内存高就崩溃」的直接机制。
   - **`longjmp` 会跳过 ffmpeg 自己的清理** —— 线程 / 锁 / 内存都不回收；
     `resetFFmpeg()` 只清了 3 个计数器。源码注释自己也写了"这条路上本来就容易越跑越胖"。
     → **连着转多个任务会累积**。
   - `static jmp_buf j` 是**全局变量** → 同时跑两个 ffmpeg 调用会互相踩栈上下文
     （目前串行所以没炸，是埋着的雷）。
2. **`+faststart` 对大文件是两遍 I/O** —— 写完整个文件后再读一遍重写，把 moov 挪到文件头。
   时间天然 ∝ 文件大小，正好对上"大的卡得久"。
3. **`Task.detached(priority: .userInitiated)`** 是高优先级后台线程，会跟界面抢 CPU；
   老机器 / 发热降频时更明显（放大器，不是根因）。
4. **自研兜底那条路更慢**：纯 Swift 逐字节解 MPEG-TS，比 ffmpeg 慢一个数量级；
   而且 `pump()` 里 writer 不就绪时会**最多等 30 秒**（等不到就"保留已写入部分"产出一个
   只有部分内容的 MP4）→ 这段等待在界面上就是纯粹的不动。

### 三、结论的边界（诚实说）

- **手机性能是放大器，不是根因**。"内存 ∝ 文件大小"在任何机器上都成立，
  所以根因在代码的工作方式（**进程内 + 全量 I/O 两遍**），不在"你的手机不行"。
- **ffmpeg 是黑盒**（进程内，看不到它内部在吃什么内存）→ **具体是哪一块内存在涨，只靠读代码定不了案**，
  必须靠实测。要看的两样：① 那条任务的**过程记录**（会写 FFmpeg 退出码、
  以及有没有走到「备用：自研重封装」那行）；② 卡死时**界面还能不能滑动**。

### 四、以后要修的话，性价比排序（尚未实施）

1. **给转码加"看得见的进度"**（最便宜、收益最大）：`-c copy` 的输出大小 ≈ 输入大小，
   所以**定时看一眼输出文件多大**就能算出百分比，不需要动 ffmpeg 一行 —— 跟下载页算速度一个套路。
   这一条能直接把"假卡死"消掉。
2. **`+faststart` 改成条件性**：小文件才加，大文件省掉一整遍 I/O。
3. **加护栏**：超过某个体积先提示、或转码前先看空间/内存。
4. **长期正解**：把 ffmpeg 移出进程（TrollStore 无 App Store 沙箱，理论上可 `posix_spawn`
   一个随包附带的 ffmpeg 可执行文件）→ **可行性需先查证，不能拍脑袋**。
"""

LOG_ADD = """

## VideoGrab —— 「转码阶段卡死/大文件崩溃」诊断（只查未改，12:0x）

用户问：下载分片、拼接都不卡，**只有转 MP4 基本都会卡**，大的卡得久、极端情况崩溃；是手机性能还是代码？

**查到的（代码事实）：**
- `Exporter` 转码有两条路：**① FFmpeg（首选）→ ② 自研 TSRemuxer（兜底）**。
  ★ **① 完全没有进度上报** —— `FFmpegConverter` 只在开始/结束各调一次 `onProgress`，
  所以走 FFmpeg 时界面**从开始到结束一动不动**；② 有进度（「正在重封装… XMB/YMB」）。
  → **"卡死"里很大一部分是"没进度"而不是真卡**，而且看一眼界面显示哪句就知道走的哪条路。
- ★★ **FFmpeg 是进程内跑的**（`Hook.m` setjmp/longjmp 拦 `exit()`）→
  内存**算在 App 头上、共用同一个上限**（大文件撞 jetsam = 用户说的"崩溃"）；
  `longjmp` 跳过 ffmpeg 自己的清理、`resetFFmpeg` 只清 3 个计数 → **越跑越胖**；
  `static jmp_buf j` 是全局 → 并发调用会踩栈（现在串行没炸，是雷）。
- `+faststart` 对大文件是**两遍 I/O**（重写整个文件把 moov 挪前面）→ 时间 ∝ 体积，对上"大的卡得久"。
- 自研兜底本身慢一个数量级，且 writer 不就绪时**最多等 30 秒**（等不到就产出"部分内容"）。
- **结论**：手机性能是**放大器**不是根因；"内存 ∝ 体积"在任何机器上都成立。
  ffmpeg 是黑盒 → **具体哪块内存在涨，读代码定不了案，必须实测**。

**下次要的东西**：那条任务的**过程记录**（看 FFmpeg 退出码 / 有没有走自研）+ 卡死时界面能不能滑动。

**将来修的顺序**（未实施）：① 给转码加"输出文件大小→百分比"的进度（最便宜、直接消掉假卡死）；
② `+faststart` 只给小文件；③ 加体积护栏；④ 长期把 ffmpeg 移出进程（TrollStore 无沙箱，
`posix_spawn` 理论上可行，**需先查证**）。
"""

n = io.open(NOTES, encoding='utf-8').read()
if '转码（重封装）阶段卡死' in n:
    print('notes 已写过，跳过')
else:
    atomic(NOTES, n + NOTE_ADD)
    print('notes %d -> %d' % (len(n), len(n + NOTE_ADD)))

l = io.open(LOG, encoding='utf-8').read()
if '转码阶段卡死' in l:
    print('日记已写过，跳过')
else:
    atomic(LOG, l + LOG_ADD)
    print('日记 %d -> %d' % (len(l), len(l + LOG_ADD)))

n2 = io.open(NOTES, encoding='utf-8').read()
l2 = io.open(LOG, encoding='utf-8').read()
for name, c in [('notes 有诊断节', '转码（重封装）阶段卡死' in n2),
                ('notes 有判别法', '看一眼界面停在哪个句子' in n2),
                ('notes 有进程内结论', '内存算在 App 头上' in n2),
                ('notes 有修的顺序', '给转码加"看得见的进度"' in n2),
                ('日记有诊断', '转码阶段卡死' in l2)]:
    print(('PASS ' if c else 'FAIL '), name)
