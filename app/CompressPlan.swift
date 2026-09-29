import Foundation

/// 压缩的「账」—— 档位怎么定、目标码率算多少、体积估多少、要缩到多大、还要多久。
///
/// ★★ 为什么单独一个文件、而且**一行都不碰 AVFoundation / ffmpeg**：
///   离线回归集（`VideoGrabTests`）不链 ffmpeg（那套静态库只有真机切片 `ios-arm64`，
///   模拟器上链接不上），所以凡是"能被机器自动验"的东西，都得先抽成纯函数放进来。
///   档位算错会让界面上的预估体积骗人 —— v1.0.157 真机就出过
///   「49.6MB 的片子显示能压到 122MB」。这种错最该被回归集挡在门外。
enum CompressPlan {

    // MARK: - 视频档位

    /// 五档。★★ **按源码率的比例取值，不再写死绝对码率** —— 这是 v2 的核心修正：
    ///   旧版写死 1.4 / 0.8 / 0.45 Mbps，遇到源码率只有 621kbps 的片子就等于
    ///   "往上加码"，预估体积反而比原片还大（真机上显示 49.6MB → 122MB）。
    ///   改成比例之后：**任何档位都不会比原片大**（比例全 < 1，还有 0.9 的硬顶）。
    enum Tier: String, CaseIterable, Identifiable {
        case light, clear, balance, save, tiny

        var id: String { rawValue }

        /// 目标视频码率 = 源码率（含音频）× ratio
        var ratio: Double {
            switch self {
            case .light:   return 0.70
            case .clear:   return 0.50
            case .balance: return 0.45
            case .save:    return 0.30
            case .tiny:    return 0.20
            }
        }

        /// 目标**短边**上限（nil = 不缩，只降码率）。
        /// 为什么按"短边"说：这些站全是 1280×2276 的竖屏片，
        /// 说"720p"会被理解成宽 720 —— 竖屏片的短边才是宽。
        var shortSide: Int? {
            switch self {
            case .light, .clear: return nil
            case .balance:       return 854
            case .save:          return 720
            case .tiny:          return 640
            }
        }

        /// 胶囊上那一两个字（一行要塞 5 个，长文案放不下）
        var title: String {
            switch self {
            case .light:   return "轻压"
            case .clear:   return "清晰"
            case .balance: return "均衡"
            case .save:    return "省空间"
            case .tiny:    return "最小"
            }
        }

        /// 选中后下面那行解释（说清"省多少"和"画面会怎样"）
        var blurb: String {
            switch self {
            case .light:   return "还是原分辨率，画面几乎看不出差别"
            case .clear:   return "还是原分辨率，手机上够清楚"
            case .balance: return "短边缩到 854，日常刷着看够用"
            case .save:    return "短边缩到 720，明显变小但能接受"
            case .tiny:    return "最省空间，画面会明显糊一些"
            }
        }
    }

    // MARK: - 图片档位

    /// 图片按 **JPEG 质量**重压（不缩分辨率 —— 缩放会改变观感，
    /// 而"省空间"对照片来说靠质量档就够了）。
    enum PhotoTier: String, CaseIterable, Identifiable {
        case hq, normal, compact, small

        var id: String { rawValue }

        /// 直接进 `kCGImageDestinationLossyCompressionQuality`
        var quality: Double {
            switch self {
            case .hq:      return 0.90
            case .normal:  return 0.75
            case .compact: return 0.60
            case .small:   return 0.40
            }
        }

        var title: String {
            switch self {
            case .hq:      return "高清"
            case .normal:  return "标准"
            case .compact: return "省空间"
            case .small:   return "最小"
            }
        }

        var blurb: String {
            switch self {
            case .hq:      return "几乎看不出是重压过的（发朋友圈够用）"
            case .normal:  return "画质和体积的折中，日常看图没差别"
            case .compact: return "细看能看出一点，放手机里看没问题"
            case .small:   return "最省空间，放大看会有明显的块"
            }
        }

        /// 预估体积比例 —— ★ **这是经验值，不是算出来的**，界面上必须带"约"字。
        /// 照片和截图是两个完全不同的分布，实测偏差能到 ±30%，只当参考。
        var estimateRatio: Double {
            switch self {
            case .hq:      return 0.85
            case .normal:  return 0.55
            case .compact: return 0.38
            case .small:   return 0.22
            }
        }
    }

    // MARK: - 算账

    /// 音频按 128kbps 估（`-c copy` 后音频码率不变，源大多是 AAC 128k）
    static let audioBps: Double = 128_000
    /// 目标视频码率的硬顶：源码率的 0.9 倍（**保证绝不"越压越大"**）。
    /// 比例档位本身已经 < 1，这层是给"以后有人加档位"兜底的。
    static let bitrateCeiling: Double = 0.9

    /// 源码率（bps，**含音频**）= 文件字节 × 8 ÷ 时长
    static func sourceBps(bytes: Int64, duration: Double) -> Double {
        guard bytes > 0, duration > 0 else { return 0 }
        return Double(bytes) * 8.0 / duration
    }

    /// 目标视频码率。读不出源码率时返回 0 —— 调用方据此**直接判失败**，
    /// 绝不"跳过体检硬压"（那正是 v1.0.157 的洞）。
    static func targetVideoBps(tier: Tier, sourceBps: Double) -> Int {
        guard sourceBps > 0 else { return 0 }
        let raw = sourceBps * tier.ratio
        let cap = sourceBps * bitrateCeiling
        let v = min(raw, cap)
        guard v.isFinite, v > 0 else { return 0 }
        return Int(v.rounded())
    }

    /// 预估成品体积（字节）
    static func estimateBytes(videoBps: Int, duration: Double) -> Int64 {
        guard videoBps > 0, duration > 0 else { return 0 }
        return Int64((Double(videoBps) + audioBps) * duration / 8.0)
    }

    /// 图片的预估体积（粗糙，界面上带"约"）
    static func estimatePhotoBytes(tier: PhotoTier, bytes: Int64) -> Int64 {
        guard bytes > 0 else { return 0 }
        return Int64(Double(bytes) * tier.estimateRatio)
    }

    /// 只缩不放：**短边**超过 cap 才缩，返回**偶数**尺寸（编码器要求宽高为偶数）。
    /// 返回 nil = 不用缩（保持原样）。
    /// 竖屏 1280×2276 → cap 854 得 (854, 1518)；横屏 1920×1080 → cap 854 得 (1518, 854)。
    static func fit(width: Int, height: Int, shortSide cap: Int?) -> (w: Int, h: Int)? {
        guard let cap, cap > 0, width > 0, height > 0 else { return nil }
        let short = min(width, height)
        guard short > cap else { return nil }          // 只缩不放
        let k = Double(cap) / Double(short)
        let w = even(Double(width) * k)
        let h = even(Double(height) * k)
        guard w >= 2, h >= 2 else { return nil }
        return (w, h)
    }

    private static func even(_ v: Double) -> Int {
        let n = Int(v.rounded())
        return n % 2 == 0 ? n : n - 1
    }

    /// 「还要多久」—— 用 ffmpeg 报的 `speed`（倍速）算。
    /// ★★ v1.0.162 改的单位规则（用户点名）：
    ///   · **不满 1 分钟：精确到秒** ——「42 秒」（以前一律写"不到 1 分钟"，太糊）
    ///   · 1~60 分钟：以分钟为主 ——「3 分钟」
    ///   · 1 小时以上：小时 + 分 ——「1 小时 5 分」（整点就写「2 小时」）
    /// ★ 只返回**时长本身**（"3 分钟"），"还要"由调用方拼 ——
    ///   以前这里自带"约"，跟调用方的"还要"拼一起变成「还要 约 3 分钟」，很别扭。
    /// speed ≤ 0 或算不出来时返回 **nil**（宁可不说，也不给一个瞎编的时间）。
    static func etaText(doneSec: Double, totalSec: Double, speed: Double) -> String? {
        guard totalSec > 0, doneSec >= 0, speed > 0.01 else { return nil }
        let left = max(0, totalSec - doneSec) / speed
        guard left.isFinite else { return nil }
        if left < 60 { return "\(max(1, Int(left.rounded()))) 秒" }
        let m = Int((left / 60).rounded())
        if m < 60 { return "\(m) 分钟" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h) 小时" : "\(h) 小时 \(mm) 分"
    }

    // MARK: - 记住上次选的档位

    /// ★ v1.0.162（用户要求）：档位要**记住上次的选择** ——
    /// 主要是给"下载页批量加入"用的（那页没有档位控件，弹窗要带出上次那个）。
    /// 键放这儿：压缩卡和弹窗两边天然同步。
    static let videoTierKey = "compressVideoTier"
    static let photoTierKey = "compressPhotoTier"

    // MARK: - 队列的规矩（纯逻辑，考在离线回归集里）

    /// 队列上限 —— **用户拍的：最多 20 个**（`notes/VideoGrab.md` 的压缩队列交接单）
    static let maxQueue = 20

    /// 一条任务在"调度"眼里的样子（只留调度需要的信息）
    enum Slot { case waiting, running, other }

    /// 下一步该跑哪一条。
    /// · **串行**：已经有一条在跑 → 返回 nil（一次只压一个 —— 硬件编码器只有一个，
    ///   同时跑两个只会更烫更慢，用户也认了这条）
    /// · 否则取**最靠前的 waiting**（先来先压）
    /// · 返回 nil = 没活可干
    ///
    /// ★ 为什么值得抽成纯函数：这条规矩要是坏了（比如同时跑两条），
    ///   在真机上只表现为"更烫、更慢"——**肉眼根本看不出来**，只能靠离线断言挡。
    static func nextRunIndex(slots: [Slot]) -> Int? {
        if slots.contains(where: { $0 == .running }) { return nil }
        return slots.firstIndex(of: .waiting)
    }

    /// 开压之前要腾出多少空间才敢开工。
    /// 成品会和原片**同时在**（我们绝不自动删原片），所以至少要留出成品的量；
    /// 再加 10% 余量 + 200MB 机动 —— 编码器还要写临时文件，系统也在用同一块空间。
    static func spaceNeeded(outputBytes: Int64) -> Int64 {
        let base = max(0, outputBytes)
        return Int64(Double(base) * 1.1) + 200 * 1_048_576
    }

    /// ★ v1.0.163：「压缩前的状态」记一笔 —— 用户要求"能不能记录压缩前的状态"。
    /// 只记**参数**（大小 · 分辨率 · 码率），**不还原画面**：
    /// 压缩有损不可逆，原画质的信息只存在于原文件里，删了就没了
    /// （这条得跟用户说清，别让他以为以后能"修回来"）。
    /// 抽成纯函数是为了能被离线考题验（码率换算、除零、缺分辨率都藏在这里）。
    static func sourceInfoLine(bytes: Int64, resolution: String?, duration: Double) -> String {
        var parts = ["原片 \(mb(bytes))MB"]
        if let r = resolution, !r.isEmpty { parts.append(r) }
        if bytes > 0, duration > 0 {
            let kbps = Int((Double(bytes) * 8 / duration / 1000).rounded())
            if kbps > 0 { parts.append("\(kbps)kbps") }
        }
        return parts.joined(separator: " · ")
    }

    /// 界面上的体积（MB，一位小数）
    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}
