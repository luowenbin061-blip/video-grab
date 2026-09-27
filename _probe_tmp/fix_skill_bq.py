# -*- coding: utf-8 -*-
"""修掉分册02 末尾那节里被 bash 吃掉的反引号内容（v1.0.133 那节）。

★ 教训：绝不要把带反引号的长文本塞在 python -c "..." 里 —— bash 先处理整条命令行，
  反引号会被当命令替换，把内容整段吞掉（本次实测：表格里所有代码标记都变成了空白）。
  一律用 Write 工具落成 .py 再执行。
"""
import io, os

P = r'C:/Users/87479/.workbuddy/skills/ios-app-cloud-build/references/02-iOS平台与注入.md'
s = io.open(P, encoding='utf-8').read()

# 找到坏掉的那节开头（从标题开始到文件末尾整段替换）
MARK = '## ★★ HLS 清单的 VOD / EVENT 决定播放器怎么显示（v1.0.133 实做）'
i = s.find(MARK)
assert i > 0, '没找到 v1.0.133 那节标题'

GOOD = '''## ★★ HLS 清单的 VOD / EVENT 决定播放器怎么显示（v1.0.133 实做）

同一个 `AVPlayerViewController`，喂**不同清单类型**，界面表现完全不同 —— 这条以前没记，
导致「边下边播时没有总时长、还显示直播字样」查了一轮。**差异全在清单，不在播放器代码。**

| | VOD 型 | EVENT 型 |
|---|---|---|
| 标签 | `#EXT-X-PLAYLIST-TYPE:VOD` + **有** `#EXT-X-ENDLIST` | `#EXT-X-PLAYLIST-TYPE:EVENT`，**故意不写** ENDLIST |
| 播放器认知 | 有头有尾的普通片子 | 还没完的直播流 |
| 时长显示 | 按 `#EXTINF` 累加，**正常显示** | **不显示总时长** |
| 其他 | —— | 打出直播 / LIVE 元素 |
| 会不会回来取新清单 | **不会**（播完清单里的就停） | **会**（所以能"边下边播"接上新分片） |

★ **本质取舍**：想「总时长准 + 不是直播」就得 VOD，但 VOD 播完**现有**分片就停
（想看新下完的要重开播放器）；想保留"追着下"的能力就只能 EVENT，那总时长天然不准。
**这类取舍必须让用户选**，别自己替他决定（用户 2026-09-28 选了 VOD + 可接受重开）。

★ **`#EXT-X-TARGETDURATION` 必须是「最长那个分片」向上取整** —— 写小了播放器会认为清单非法。

### `#EXTINF` 的时长从哪来（TS 分片的字节数推不出时长）

单个 TS 分片文件里**没有时长字段**，字节数跟时长也不成正比 ——
所以「现场生成清单」时拿不到分片时长，以前只能写死（`#EXTINF:10.0`），总时长必然是错的。
**正解：在下每个分片的时候顺手把真实时长记一份到旁注文件**（`durations.txt`，一行一个，
下标 = 行号 = 分片序号），现场生成清单时读它，缺行才退回兜底值。
★ 这类「旁注文件」要留意两处**文件名常量必须一致**（下载器写 / 清单生成读），
最好两边都留一句注释指向对方。
'''

out = s[:i] + GOOD
tmp = P + '.tmp'
io.open(tmp, 'w', encoding='utf-8').write(out)
os.replace(tmp, P)

c = io.open(P, encoding='utf-8').read()
checks = {
    '标题在': MARK in c,
    'AVPlayerViewController': '`AVPlayerViewController`' in c,
    'PLAYLIST-TYPE:VOD': '`#EXT-X-PLAYLIST-TYPE:VOD`' in c,
    'PLAYLIST-TYPE:EVENT': '`#EXT-X-PLAYLIST-TYPE:EVENT`' in c,
    'EXTINF 标记': '`#EXTINF`' in c,
    'TARGETDURATION': '`#EXT-X-TARGETDURATION`' in c,
    'durations.txt': '`durations.txt`' in c,
    '写死10.0': '`#EXTINF:10.0`' in c,
    '旧的 ENDLIST 节还在': 'HLS 清单里的分片地址是「相对清单自己的位置」解析的' in c,
    'sheet 那节还在': '在 sheet 里「先关自己、再弹另一个 sheet」是行不通的' in c,
}
for k, v in checks.items():
    print(('  OK  ' if v else '  FAIL') + ' ' + k)
print('\n总长', len(c), '| 全过:', all(checks.values()))
