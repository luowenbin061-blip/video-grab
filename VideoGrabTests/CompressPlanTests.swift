import XCTest

/// 「压画质省空间」的档位账 —— 离线回归集。
///
/// ★ 为什么这几条值得当考题：v1.0.157 真机上出现过
///   **「49.6MB 的片子，界面显示能压到 122MB」** —— 根子是档位写死了绝对码率，
///   遇到低码率片源等于"往上加码"。这一版改成按源码率的比例取值。
///   这类错**看不出来、编译也过**，只能靠数字断言挡在门外。
///
/// ★ 又一个真洞：`if srcBytes > 0 { …体积比检查… }` —— 读不到原片大小就**静默跳过体检**，
///   于是"变大的成品"照样算成功。现在读不到就**返回 0 码率**（调用方据此直接判失败）。
final class CompressPlanTests: XCTestCase {

    private func mb(_ b: Int64) -> Double { Double(b) / 1_048_576 }

    /// 真机上那几条片子的（体积, 时长）—— 从交接单里抄的实测值，别再改
    private let realSources: [(name: String, bytes: Int64, sec: Double)] = [
        ("15.7MB/60s（2195kbps）", 16_462_643, 60),
        ("99.6MB/893s（936kbps）", 104_438_170, 893),
        ("36.2MB/349s（870kbps）", 37_958_451, 349),
        ("49.6MB/670s（621kbps）", 52_009_370, 670),
        ("812.7MB/3552s（1919kbps）", 852_177_715, 3552),
    ]

    /// ★★ 主考题：**任何档位、任何一条片子，预估体积都不能比原片大**
    func testNoTierEverGrowsTheFile() {
        for s in realSources {
            let bps = CompressPlan.sourceBps(bytes: s.bytes, duration: s.sec)
            XCTAssertGreaterThan(bps, 0, "\(s.name) 的源码率算不出来")
            for t in CompressPlan.Tier.allCases {
                let target = CompressPlan.targetVideoBps(tier: t, sourceBps: bps)
                let est = CompressPlan.estimateBytes(videoBps: target, duration: s.sec)
                XCTAssertLessThan(est, s.bytes,
                                  "\(s.name) 的「\(t.title)」预估 \(mb(est))MB ≥ 原片 \(mb(s.bytes))MB —— 加码了")
            }
        }
    }

    /// 把交接单里那张表钉住：49.6MB / 670s 那条片子，五档分别约 44.9 / 35.0 / 32.5 / 25.1 / 20.1 MB
    func testRealCase496MBMatchesTheHandoffTable() {
        let bytes: Int64 = 52_009_370, sec = 670.0
        let bps = CompressPlan.sourceBps(bytes: bytes, duration: sec)
        XCTAssertEqual(bps, 621_007, accuracy: 500, "源码率应约 621kbps")

        let expected: [(CompressPlan.Tier, Double)] = [
            (.light, 44.9), (.clear, 35.0), (.balance, 32.5), (.save, 25.1), (.tiny, 20.1),
        ]
        for (t, want) in expected {
            let target = CompressPlan.targetVideoBps(tier: t, sourceBps: bps)
            let got = mb(CompressPlan.estimateBytes(videoBps: target, duration: sec))
            XCTAssertEqual(got, want, accuracy: 0.25,
                           "「\(t.title)」预估 \(got)MB，应该是约 \(want)MB")
        }
    }

    /// 码率天花板：目标视频码率恒 ≤ 源码率 × 0.9（"绝不越压越大"的硬保险）
    func testTargetBitrateNeverExceedsCeiling() {
        for bps in [220_000.0, 621_007.0, 936_000.0, 2_195_000.0, 12_000_000.0] {
            for t in CompressPlan.Tier.allCases {
                let target = Double(CompressPlan.targetVideoBps(tier: t, sourceBps: bps))
                XCTAssertLessThanOrEqual(target, bps * CompressPlan.bitrateCeiling + 1)
            }
        }
    }

    /// 所有档位的比例都必须 < 1（防止以后有人加档位时把"加码"加回来）
    func testEveryRatioIsBelowOne() {
        for t in CompressPlan.Tier.allCases {
            XCTAssertLessThan(t.ratio, 1.0, "「\(t.title)」的比例不该 ≥ 1")
            XCTAssertGreaterThan(t.ratio, 0.0)
        }
    }

    /// ★ 洞的考题：读不到原片信息（大小 0 / 时长 0）→ 目标码率必须是 **0**，
    ///   调用方据此直接判失败（以前是静默跳过体积体检 → 放行"变大的成品"）
    func testUnknownSourceInfoYieldsZeroNotASilentSkip() {
        XCTAssertEqual(CompressPlan.targetVideoBps(tier: .balance, sourceBps: 0), 0)
        XCTAssertEqual(CompressPlan.sourceBps(bytes: 0, duration: 100), 0)
        XCTAssertEqual(CompressPlan.sourceBps(bytes: 1_000_000, duration: 0), 0)
        XCTAssertEqual(CompressPlan.estimateBytes(videoBps: 0, duration: 100), 0)
    }

    /// 只缩不放 + 偶数尺寸 + 竖屏横屏都按"短边"算
    func testFitShrinksOnlyAndKeepsEvenNumbers() {
        // 竖屏 1280×2276 → 短边 854
        let p = CompressPlan.fit(width: 1280, height: 2276, shortSide: 854)
        XCTAssertEqual(p?.w, 854)
        XCTAssertEqual(p?.h, 1518)
        // 横屏 1920×1080 → 短边也是 854（这里短边是**高**）
        let l = CompressPlan.fit(width: 1920, height: 1080, shortSide: 854)
        XCTAssertEqual(l?.w, 1518)
        XCTAssertEqual(l?.h, 854)
        // 比目标还小 → 不放大
        XCTAssertNil(CompressPlan.fit(width: 640, height: 480, shortSide: 854))
        // 不缩的档位
        XCTAssertNil(CompressPlan.fit(width: 1280, height: 2276, shortSide: nil))
        // 尺寸必须是偶数（编码器要求）
        for t in CompressPlan.Tier.allCases {
            if let f = CompressPlan.fit(width: 1177, height: 2093, shortSide: t.shortSide) {
                XCTAssertEqual(f.w % 2, 0)
                XCTAssertEqual(f.h % 2, 0)
            }
        }
    }

    /// 「还要多久」的单位规则（v1.0.162 用户点名改的）：
    /// **不满 1 分钟精确到秒**、1 小时以内用分钟、超过 1 小时用"小时 + 分"；
    /// 算不出来就返回 nil（宁可不说，也不编一个时间给他）。
    func testEtaText() {
        XCTAssertNil(CompressPlan.etaText(doneSec: 0, totalSec: 600, speed: 0))
        XCTAssertNil(CompressPlan.etaText(doneSec: 0, totalSec: 0, speed: 1))
        // ★ 不满一分钟 → 精确到秒（以前一律"不到 1 分钟"）
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 50, speed: 1), "50 秒")
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 59, speed: 1), "59 秒")
        XCTAssertEqual(CompressPlan.etaText(doneSec: 570, totalSec: 600, speed: 1), "30 秒")
        // 刚起步（剩 0 秒也不会写成"0 秒"）
        XCTAssertEqual(CompressPlan.etaText(doneSec: 10, totalSec: 10, speed: 1), "1 秒")
        // ≥ 1 分钟 → 分钟
        XCTAssertEqual(CompressPlan.etaText(doneSec: 61, totalSec: 121, speed: 1), "1 分钟")
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 600, speed: 1), "10 分钟")
        // 干了 60 秒、总 600 秒、2 倍速 → 还剩 270 秒 ≈ 5 分钟（4.5 进位）
        XCTAssertEqual(CompressPlan.etaText(doneSec: 60, totalSec: 600, speed: 2), "5 分钟")
        // ≥ 1 小时 → 小时 + 分
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 7200, speed: 1), "2 小时")
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 7500, speed: 1), "2 小时 5 分")
        // 返回值里**不带**"还要 / 约" —— 由调用方拼，避免"还要 约 3 分钟"
        XCTAssertFalse(CompressPlan.etaText(doneSec: 0, totalSec: 600, speed: 1)!.contains("约"))
    }

    /// 图片：每档预估都得比原图小，而且档位越激进估得越小
    func testPhotoEstimatesAlwaysShrink() {
        let bytes: Int64 = 3_145_728        // 3MB 的一张图
        var last: Int64 = bytes
        for t in CompressPlan.PhotoTier.allCases {
            let est = CompressPlan.estimatePhotoBytes(tier: t, bytes: bytes)
            XCTAssertLessThan(est, bytes, "「\(t.title)」的预估不该 ≥ 原图")
            XCTAssertLessThan(est, last, "档位越激进应该估得越小")
            last = est
        }
        XCTAssertEqual(CompressPlan.estimatePhotoBytes(tier: .normal, bytes: 0), 0)
        // 质量必须是 0~1 之间的合法值
        for t in CompressPlan.PhotoTier.allCases {
            XCTAssertTrue(t.quality > 0 && t.quality < 1, "「\(t.title)」的质量值越界")
        }
    }

    // MARK: - 队列的规矩（v1.0.160）

    /// ★★ 主规矩：**串行** —— 已经有一条在跑就绝不再取；
    /// 没有在跑的就取**最靠前的等待中**那条（先来先压）。
    /// 为什么值得当考题：这条要是坏了（比如同时跑两条），真机上只表现为"更烫、更慢"，
    /// 肉眼根本看不出来 —— 只能靠离线断言挡。
    func testQueueRunsOneAtATimeAndInOrder() {
        XCTAssertNil(CompressPlan.nextRunIndex(slots: []))
        XCTAssertEqual(CompressPlan.nextRunIndex(slots: [.other, .waiting, .waiting]), 1,
                       "跳过已结束的行，取最靠前的等待中")
        XCTAssertNil(CompressPlan.nextRunIndex(slots: [.running, .waiting]),
                     "已经有一条在跑 → 不许再取")
        XCTAssertNil(CompressPlan.nextRunIndex(slots: [.other, .running, .waiting]))
        XCTAssertNil(CompressPlan.nextRunIndex(slots: [.other, .other]), "没等待中的就该歇着")
    }

    /// 队列上限就是用户拍的那个数
    func testQueueCapIsTwenty() {
        XCTAssertEqual(CompressPlan.maxQueue, 20)
    }

    /// ★ v1.0.163：「压缩前的状态」文案组装。
    /// 只记参数（大小/分辨率/码率）——**不还原画面**（有损不可逆，物理上做不到）。
    func testSourceInfoLine() {
        // 真机那条：49.6MB / 670 秒 → 621kbps
        XCTAssertEqual(CompressPlan.sourceInfoLine(bytes: 52_009_370,
                                                   resolution: "1280×2276", duration: 670),
                       "原片 49.6MB · 1280×2276 · 621kbps")
        // 没分辨率 → 跳过那一段
        XCTAssertEqual(CompressPlan.sourceInfoLine(bytes: 52_009_370, resolution: nil, duration: 670),
                       "原片 49.6MB · 621kbps")
        // 空串也算没有
        XCTAssertEqual(CompressPlan.sourceInfoLine(bytes: 52_009_370, resolution: "", duration: 670),
                       "原片 49.6MB · 621kbps")
        // 读不到时长（相册选来的，或图片）→ 不算码率，**绝不除零**
        XCTAssertEqual(CompressPlan.sourceInfoLine(bytes: 3_145_728,
                                                   resolution: "4032×3024", duration: 0),
                       "原片 3.0MB · 4032×3024")
        // 读不到大小 → 不报码率
        XCTAssertFalse(CompressPlan.sourceInfoLine(bytes: 0, resolution: nil, duration: 670)
                        .contains("kbps"))
    }

    /// 开压前要腾的空间：必须**大于**成品本身的预估 ——
    /// 因为成品和原片会同时在（我们绝不自动删原片），还要给临时文件和系统留余量。
    func testSpaceNeededLeavesAMargin() {
        XCTAssertGreaterThan(CompressPlan.spaceNeeded(outputBytes: 1_000_000_000), 1_000_000_000)
        XCTAssertGreaterThan(CompressPlan.spaceNeeded(outputBytes: 0), 0)
        XCTAssertGreaterThanOrEqual(CompressPlan.spaceNeeded(outputBytes: 0), 200 * 1_048_576)
        // 负数（读不到大小时传 0 或负数）不能让需求变成负的
        XCTAssertGreaterThan(CompressPlan.spaceNeeded(outputBytes: -5), 0)
    }
}
