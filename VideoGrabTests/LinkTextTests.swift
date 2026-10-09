import XCTest

/// 「粘贴链接」文本识别的离线回归集。
///
/// ★★ 这一版就是被这里坑的（用户实测：粘 B站 分享一律"认不出"）：
///   ① **分享出去的链接永远带标题文案** —— 用户点"粘贴"拿到的是整段文字，不是干净网址；
///   ② **b23.tv 短链里没有 BV 号** —— 老判据要求"必须认出 BV 号"，短链一律过不了。
///   这两条都是"看代码觉得没问题、跑起来才知道错"的那种，所以必须钉住。
final class LinkTextTests: XCTestCase {

    // MARK: - ① 从文案里抠链接（用户粘的就是这个形态）

    /// 真实形态：B站 App 复制出来的分享文案
    func testExtractsBiliShareText() {
        let share = "【第一眼就惊艳的汉服摄影! -哔哩哔哩】 https://b23.tv/AbCdEfG"
        XCTAssertEqual(LinkText.firstLink(in: share), "https://b23.tv/AbCdEfG")
        XCTAssertEqual(LinkText.kind(of: share), .bili)
    }

    /// 链接后面还跟着中文／全角括号（分享文案很常见）→ 要在中文处干净截断
    func testStopsAtChineseAfterLink() {
        XCTAssertEqual(LinkText.firstLink(in: "看看这个 https://b23.tv/AbCdEfG（来自哔哩哔哩）"),
                       "https://b23.tv/AbCdEfG")
        XCTAssertEqual(LinkText.firstLink(in: "【标题】https://www.bilibili.com/video/BV1xx411c7mD 复制打开"),
                       "https://www.bilibili.com/video/BV1xx411c7mD")
    }

    /// 链接前面有标题、后面紧跟标点
    func testTrimsTrailingPunctuation() {
        XCTAssertEqual(LinkText.firstLink(in: "https://b23.tv/AbCdEfG，"), "https://b23.tv/AbCdEfG")
        XCTAssertEqual(LinkText.firstLink(in: "https://b23.tv/AbCdEfG。"), "https://b23.tv/AbCdEfG")
        XCTAssertEqual(LinkText.trimTrailingPunctuation("a.com/x），"), "a.com/x")
    }

    /// ★★ 短链：**没有 BV 号也必须认出来**（老判据就是栽在这）
    func testShortLinkIsRecognizedEvenWithoutBVID() {
        XCTAssertEqual(LinkText.kind(of: "https://b23.tv/AbCdEfG"), .bili)
        XCTAssertEqual(LinkText.kind(of: "https://b23.tv/AbCdEfG"), .bili)
        XCTAssertNil(BiliParse.bvid(inLink: "https://b23.tv/AbCdEfG"))   // 确认它确实没有 BV 号
    }

    /// 磁力
    func testMagnet() {
        let m = "magnet:?xt=urn:btih:4482A51EEAB7645F1234567890ABCDEF12345678"
        XCTAssertEqual(LinkText.firstLink(in: m), m)
        XCTAssertEqual(LinkText.kind(of: m), .magnet)
        // 前面带说明文字也要能抠出来
        XCTAssertEqual(LinkText.kind(of: "这个资源不错 " + m), .magnet)
    }

    // MARK: - ② 认类型

    func testBiliKinds() {
        XCTAssertEqual(LinkText.kind(of: "https://www.bilibili.com/video/BV1xx411c7mD"), .bili)
        XCTAssertEqual(LinkText.kind(of: "https://www.bilibili.com/video/av170001"), .bili)
        XCTAssertEqual(LinkText.kind(of: "https://www.bilibili.com/video/BV1xx411c7mD?p=3"), .bili)
        // 不是视频页（首页/搜索）→ 不认，免得点开一个不是视频的页
        XCTAssertNil(LinkText.kind(of: "https://www.bilibili.com/"))
    }

    func testOtherPlatforms() {
        XCTAssertEqual(LinkText.kind(of: "https://v.douyin.com/abcdEFG/"), .web(.douyin))
        XCTAssertEqual(LinkText.kind(of: "https://www.douyin.com/video/7123456789"), .web(.douyin))
        XCTAssertEqual(LinkText.kind(of: "https://www.xiaohongshu.com/explore/abcdef"), .web(.xiaohongshu))
        XCTAssertEqual(LinkText.kind(of: "https://xhslink.com/a/abcdef"), .web(.xiaohongshu))
        XCTAssertEqual(LinkText.kind(of: "https://v.kuaishou.com/abcdef"), .web(.kuaishou))
    }

    func testRejectsLookalikeDomains() {
        // 长得像的域名不许被骗过去
        XCTAssertNil(LinkText.kind(of: "https://notbilibili.com/video/BV1xx411c7mD"))
        XCTAssertNil(LinkText.kind(of: "https://bilibili.com.evil.cn/video/BV1xx411c7mD"))
        XCTAssertNil(LinkText.kind(of: "https://douyin.com.evil.cn/video/1"))
    }

    func testRejectsPlainText() {
        XCTAssertNil(LinkText.kind(of: "第一眼就惊艳的汉服摄影"))
        XCTAssertNil(LinkText.kind(of: ""))
        XCTAssertNil(LinkText.kind(of: "   "))
        XCTAssertNil(LinkText.kind(of: "https://example.com/hello"))
        XCTAssertNil(LinkText.firstLink(in: "这段话里没有任何链接"))
    }

    // MARK: - ③ 没有协议头的链接

    func testBareDomain() {
        XCTAssertEqual(LinkText.kind(of: "b23.tv/AbCdEfG"), .bili)
        XCTAssertEqual(LinkText.kind(of: "www.bilibili.com/video/BV1xx411c7mD"), .bili)
        XCTAssertEqual(LinkText.normalized("b23.tv/AbCdEfG"), "https://b23.tv/AbCdEfG")
    }

    func testBareDomainDoesNotSwallowSentences() {
        // 含中文的片段不许被当成域名（否则一句中文会被拼成 https://一句中文）
        XCTAssertNil(LinkText.kind(of: "汉服摄影.好看"))
        XCTAssertFalse(LinkText.looksLikeBareDomain("1.5"))
        XCTAssertFalse(LinkText.looksLikeBareDomain("..."))
        XCTAssertTrue(LinkText.looksLikeBareDomain("b23.tv/AbCdEfG"))
    }

    /// 拿到的必须是**抠出来的那条链接**，不是原文案 —— 后面要靠它去开网页/解析
    func testNormalizedReturnsCleanLink() {
        let share = "【标题】 https://b23.tv/AbCdEfG， 复制打开"
        XCTAssertEqual(LinkText.normalized(share), "https://b23.tv/AbCdEfG")
    }

    func testHintIsNonEmpty() {
        XCTAssertFalse(LinkText.hint(for: .magnet).isEmpty)
        XCTAssertFalse(LinkText.hint(for: .bili).isEmpty)
        XCTAssertFalse(LinkText.hint(for: .web(.douyin)).isEmpty)
    }
}
