# -*- coding: utf-8 -*-
"""把 v1.0.133 那条索引插到 notes/VideoGrab.md 的开头（归档式，旧条全留）。"""
import io, os

P = r'E:/自用WIN10-最强没有之一/.workbuddy/memory/notes/VideoGrab.md'
s = io.open(P, encoding='utf-8').read()

# 锚点：现有那条 "当前 v1.0.132" 的开头
OLD_HEAD = '  **当前 v1.0.132**'
i = s.find(OLD_HEAD)
assert i > 0, '没找到当前 v1.0.132 那条'

NEW = '''  **当前 v1.0.133**（`9c904e08b6f8fe6d`，10.32 MB）：**四项** ——
  ① 「设置 → 播放」新 Section：**续看开关**（默认**关**，关掉时**一并清空**已存进度）+ **首次播放自动横屏开关**（默认**关**）；
  ② **边下边播清单 EVENT → VOD**（与下载页同一套语义）：新增旁注文件 `durations.txt`（下载器下每个分片时顺手记**真实时长** ——
     TS 分片**字节数推不出时长**），清单里 `#EXTINF` 用真实值、`#EXT-X-TARGETDURATION` 取最长分片向上取整 →
     **总时长准了、没有直播字样了**；代价（用户接受）：清单只算一次，播到"当时已下完的位置"就停，要看新分片退出重进；
  ③ **备份补上「已放行网站」域名名单**（`vgTrustedCertHosts`）+ 两个新开关也进备份；★ **只能带名单、不能带信任**
     —— 系统密钥串的信任记录绑设备且无导出接口，恢复后要**手动重信任一次**，界面明说（不假装能自动恢复）；
  ④ 修交付脚本真坑：`dl_mirror_verify.py` 的 `TAG` **写死在源码里**，传 `--tag` 不生效 → 下的是**上一版的包**
     而「大小 + sha256 全绿」（拿旧版 digest 比旧版文件，自洽）→ 改成命令行参数 + 加**包内 Info.plist 版本号防呆**。
  run #133 一次过。★ **四项疑问的答案**：预览视频 = **直接播线上原始地址（不下载不落盘）**；
  **边下边播与下载页播放器本就是同一个 PlayerSheet**，差异全在清单类型；**备份不含 Cookie / 网页缓存 / 成品视频本身**。
'''

out = s[:i] + NEW + s[i:]
tmp = P + '.tmp'
io.open(tmp, 'w', encoding='utf-8').write(out)
os.replace(tmp, P)

c = io.open(P, encoding='utf-8').read()
checks = {
    '新条在': '**当前 v1.0.133**' in c,
    '旧 132 条还在': '**当前 v1.0.132**' in c,
    '旧 131 条还在': '**v1.0.131**' in c,
    '反引号内容完好（durations）': '`durations.txt`' in c,
    '反引号内容完好（EXTINF）': '`#EXTINF`' in c,
    '反引号内容完好（key）': '`vgTrustedCertHosts`' in c,
    '顺序正确': c.find('**当前 v1.0.133**') < c.find('**当前 v1.0.132**'),
}
for k, v in checks.items():
    print(('  OK  ' if v else '  FAIL') + ' ' + k)
print('\n总长', len(c), '| 全过:', all(checks.values()))
