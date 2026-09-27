# -*- coding: utf-8 -*-
"""MEMORY.md 的 VideoGrab 索引行更新：
  ① 当前版本改成 v1.0.135（新两行写清本轮）
  ② v1.0.133 的详细四项描述**压缩成一句**（细节已进 notes/VideoGrab.md 与日记）——
     MEMORY.md 只留索引，别让它无限膨胀。
★ 原子写；改完回读核验。
"""
import io, os, sys
sys.stdout.reconfigure(encoding='utf-8')

P = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/MEMORY.md'
s = io.open(P, encoding='utf-8').read()

OLD_VER = '当前 **v1.0.133**（**四项改动**：'
NEW_VER = ('当前 **v1.0.135**（**两项**：① ★★ 修「个别视频下载失败」—— '
           '**根因不在"个别"，在"分片地址带中文"**：`URL(string:)` 遇到**任何非 ASCII 字符**'
           '（中文/全角括号/空格）**直接返回 nil**，而解析代码写的是"解析不出来就 continue" → '
           '**所有分片行被静默跳过** → 报「没有解析出任何分片」，真因被埋（亚瑟浏览器不走这条路所以能下）。'
           '修法：新增 `M3U8Playlist.sanitizeURLString`（非 ASCII + 空格转百分号编码；'
           '**已是 `%XX` 的不重复编码**；`?` `#` `=` `&` **有含义的符号原样保留**）+ `resolve(_:relativeTo:)`；'
           '分片行与 `#EXT-X-KEY` 的 URI 全走它。★ **报错分两类**（`noSegment` 清单本就空 / '
           '`noAddress` **有分片但地址读不懂、会指名道姓说是哪一行**）—— 静默 `continue` 最害人，'
           '失败原因必须留痕。② **长按那张预览大白卡能点了** = 用**我们的播放器**播（不走网页播放器）：'
           '用户要「不要加按钮名字」→ 界面**一个字没加**，只在图标右下角叠颗小播放三角；'
           '**视频和直播不用做两套**（复用的 `PlayerSheet` 自己看清单类型分）；'
           '播不出来给明话（`PlayerSheet` 自身 `.failed` + 60s 超时兜底；地址脏到洗不出来就显示'
           '「这个地址读不懂，播不了」）；进度键固定 `"lp"` 不污染任务续看。'
           '★ 交付踩坑：run #134 **编译失败** —— 我把类型名写成 `M3U8`，真名 `M3U8Playlist` '
           '（**括号配平查不出**）→ 已补检查器 `_probe_tmp/typechk_swift.py`（扫 `Ident.method(` '
           '× 本工程类型名）。run #135 成功，sha256 `33e1734713f23d2c`，10.33 MB。'
           '**待真机验收**。上一版 **v1.0.133**（**四项改动**：')

if OLD_VER not in s:
    print('!! 找不到锚点，中止'); sys.exit(1)
s2 = s.replace(OLD_VER, NEW_VER, 1)

# 把 v1.0.133 的长描述里的"四项改动详细列表"压缩：只保留结果与关键坑，细节已在日记/notes
OLD_LONG = """① 新起「设置 → 播放」Section，加**续看开关**与**首次播放自动横屏开关**，都**默认关**（用户 2026-09-28 选的；续看关掉时**一并清空**已存进度）；② **边下边播清单从 EVENT 改成 VOD** —— 与下载页同一套语义，`#EXTINF` 用**真实分片时长**（新增旁注文件 `durations.txt`：下载器下每个分片时顺手记时长，因为 **TS 分片的字节数推不出时长**），于是**总时长准了、没有直播字样了**；代价（用户接受）：清单只在打开播放器那一刻算一次，播到"当时已下完的位置"就停，要看新分片退出重进；③ **备份补上「已放行网站」域名名单**（`vgTrustedCertHosts`）+ 两个新开关也进备份；★ **只能带名单、不能带信任** —— 系统密钥串的信任记录绑设备且无导出接口，恢复后要**手动重信任一次**，界面明说（不假装能自动恢复）；④ 修交付脚本真坑：`dl_mirror_verify.py` 的 `TAG` **写死在源码里**，传 `--tag` 不生效 → 下的是**上一版的包**而「大小+sha256 全绿」（拿旧版 digest 比旧版文件，自洽）→ 已改成命令行参数 + 加**包内 Info.plist 版本号防呆**。）run #133 一次过，sha256 `9c904e08b6f8fe6d`，10.32 MB。★ 四项疑问的答案也已定：**预览视频 = 直接播线上原始地址（不下载不落盘）**；**边下边播与下载页播放器本就是同一个 PlayerSheet**，差异全在清单类型；**备份不含 Cookie / 网页缓存 / 成品视频**。"""

NEW_SHORT = """① 「设置 → 播放」两个开关（续看 / 首次播放自动横屏，都**默认关**；续看关掉**一并清空**进度）；② **边下边播清单 EVENT → VOD** + `#EXTINF` 用**真实分片时长**（新增 `durations.txt` 旁注，因为 **TS 字节数推不出时长**）→ **总时长准了、没有直播字样了**；代价（用户接受）：清单只算一次，播到"已下完的位置"就停，看新分片要重进；③ **备份补「已放行网站」名单**（`vgTrustedCertHosts`）★ **只能带名单不能带信任**（系统密钥串绑设备、无导出接口 → 恢复后**手动重信任一次**，界面明说）；④ 修 `dl_mirror_verify.py` 的 `TAG` **写死在源码**（传 `--tag` 不生效 → 下到**上一版包**而「大小+sha256 全绿」）→ 改命令行参数 + **包内 Info.plist 版本号防呆**。run #133 一次过，sha256 `9c904e08b6f8fe6d`，10.32 MB。★ 已定：**预览 = 直接播线上地址（不落盘）**；**边下边播与下载页本就是同一个 PlayerSheet**；**备份不含 Cookie / 网页缓存 / 成品视频**。"""

if OLD_LONG in s2:
    s2 = s2.replace(OLD_LONG, NEW_SHORT, 1)
    print('已压缩 v1.0.133 长描述')
else:
    print('（v1.0.133 长描述锚点没找到 —— 只更新了版本号，不报错）')

tmp = P + '.tmp'
io.open(tmp, 'w', encoding='utf-8').write(s2)
os.replace(tmp, P)

s3 = io.open(P, encoding='utf-8').read()
print('OK  %d -> %d 字符' % (len(s), len(s3)))
for k in ['v1.0.135', 'v1.0.133', 'typechk_swift.py', 'sanitizeURLString', 'M3U8Playlist']:
    print(('  FOUND   ' if k in s3 else '  MISSING '), k)
