# -*- coding: utf-8 -*-
"""v1.0.133 源码自检：四件事逐项核验（剔注释后再匹配，防撞自己写的说明）。"""
import io, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app")
ROOT = os.path.normpath(ROOT)

def read(name):
    with io.open(os.path.join(ROOT, name), encoding="utf-8") as f:
        return f.read()

def code_of(text):
    """剔掉 // 行注释和 /* */ 块注释，只留代码。"""
    out = []
    in_block = False
    for line in text.split("\n"):
        s = line
        if in_block:
            if "*/" in s:
                s = s.split("*/", 1)[1]
                in_block = False
            else:
                continue
        # 去掉 // 之后的部分（粗略：字符串里的 // 极少见，且本判据不依赖那些行）
        if "//" in s:
            s = s.split("//", 1)[0]
        out.append(s)
    return "\n".join(out)

results = []
def check(tag, ok, detail=""):
    results.append((tag, bool(ok), detail))

# ── 1. 续看开关 ────────────────────────────────────────────
wp = read("WatchProgress.swift"); wpc = code_of(wp)
check("1a 总开关键存在", 'static let enabledKey = "resumeEnabled"' in wpc)
check("1b isEnabled 默认假", "static var isEnabled: Bool" in wpc and "bool(forKey: enabledKey)" in wpc)
check("1c position 受开关管", re.search(r"func position\(for key: String\) -> Double \{\s*guard Self\.isEnabled else \{ return 0 \}", wpc))
check("1d fraction 受开关管", re.search(r"func fraction\(.*?\) -> Double\? \{\s*guard Self\.isEnabled else \{ return nil \}", wpc, re.S))
check("1e record 受开关管", re.search(r"func record\(.*?\) \{\s*guard Self\.isEnabled else \{ return \}", wpc, re.S))
check("1f 关掉会清空", "shared.wipe()" in wpc)
check("1g wipe 删文件", "removeItem(at: Self.fileURL)" in wpc)

sv = read("SettingsView.swift"); svc = code_of(sv)
check("1h 设置页有开关", "@AppStorage(WatchProgress.enabledKey) private var resumeEnabled = false" in svc)
check("1i 默认关 = false", "private var resumeEnabled = false" in svc)
check("1j onChange 调 setEnabled", "WatchProgress.setEnabled(on)" in svc)

# ── 2. 自动横屏开关 ───────────────────────────────────────
ps = read("PlayerSheet.swift"); psc = code_of(ps)
check("2a 横屏键存在", 'static let autoLandscapeKey = "autoLandscape"' in psc)
check("2b 读开关", "UserDefaults.standard.bool(forKey: autoLandscapeKey)" in psc)
check("2c 转屏处已挂开关", "if sz.width > sz.height, PlayerBox.autoLandscapeEnabled" in psc)
# 反证：不能再有"无条件转横屏"的调用
bare = re.search(r"if sz\.width > sz\.height \{\s*ScreenOrientation\.landscape\(\)\s*\}", psc)
check("2d 已无无条件转屏", bare is None)
check("2e 设置页有开关", "@AppStorage(PlayerBox.autoLandscapeKey) private var autoLandscape = false" in svc)
check("2f 默认关", "private var autoLandscape = false" in svc)

# ── 3. 边下边播清单改 VOD + 真实时长 ─────────────────────
lp = read("LivePreview.swift"); lpc = code_of(lp)
check("3a 清单改 VOD", "#EXT-X-PLAYLIST-TYPE:VOD" in lpc)
check("3b 有结束标记", "#EXT-X-ENDLIST" in lpc)
check("3c 不再写 EVENT", "#EXT-X-PLAYLIST-TYPE:EVENT" not in lpc)
check("3d 不再写死 10 秒", "#EXTINF:10.0" not in lpc)
check("3e 读时长旁注", "func segmentDurations(taskID: UUID, root: URL) -> [Double]" in lpc)
check("3f 用真实时长", 'String(format: "%.3f", dur(i))' in lpc)
check("3g TARGET 用最长分片", "Int(ceil(maxDur))" in lpc)

dl = read("Downloader.swift"); dlc = code_of(dl)
check("3h 下载器写时长", "writeSegmentDurations(playlist.segmentDurations, dir: options.tempDir)" in dlc)
check("3i 文件名两处一致",
      'static let durationsFileName = "durations.txt"' in dlc and
      'static let durationsFileName = "durations.txt"' in lpc)

# ── 4. 备份补已放行网站 ───────────────────────────────────
db = read("DataBackup.swift"); dbc = code_of(db)
check("4a 导出带域名名单", "if !hosts.isEmpty { defaults[trustedHostsKey] = hosts }" in dbc)
check("4b 恢复读回名单", "ud.set(hosts, forKey: trustedHostsKey)" in dbc)
check("4c 恢复刷缓存", "TrustedHosts.invalidateCache()" in dbc)
check("4d 清掉旧的最近一次", '"vgTrustedCertLastHost"' in dbc)
check("4e 提示手动重信任", "证书信任这件事系统不让程序代劳" in db)
check("4f 两个新开关也进备份", '"resumeEnabled"' in dbc and '"autoLandscape"' in dbc)

th = read("TrustedHosts.swift"); thc = code_of(th)
check("4g 提供了失效入口", "static func invalidateCache() { cache = nil }" in thc)

tb = read("Toolbox.swift")
check("4h 对话框文案已更新", "已放行网站" in tb)

# ── 输出 ──────────────────────────────────────────────────
ok_n = sum(1 for _, ok, _ in results if ok)
for tag, ok, detail in results:
    print(("[PASS] " if ok else "[FAIL] ") + tag + (("  " + detail) if detail else ""))
print("\n%d/%d 通过" % (ok_n, len(results)))
sys.exit(0 if ok_n == len(results) else 1)
