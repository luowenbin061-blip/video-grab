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

    /// 「还要多久」：算不出来就返回 nil（宁可不说，也不编一个时间给他）
    func testEtaText() {
        XCTAssertNil(CompressPlan.etaText(doneSec: 0, totalSec: 600, speed: 0))
        XCTAssertNil(CompressPlan.etaText(doneSec: 0, totalSec: 0, speed: 1))
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 50, speed: 1), "不到 1 分钟")
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 600, speed: 1), "约 10 分钟")
        // 干了 60 秒、总 600 秒、2 倍速 → 还剩 270 秒 ≈ 5 分钟
        XCTAssertEqual(CompressPlan.etaText(doneSec: 60, totalSec: 600, speed: 2), "约 5 分钟")
        XCTAssertEqual(CompressPlan.etaText(doneSec: 0, totalSec: 7200, speed: 1), "约 2 小时")
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
}
