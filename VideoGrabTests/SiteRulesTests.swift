import XCTest

/// ★ v1.0.236：`SiteRules` 的口径测试。
///
/// 这几条都是"错了会很难查"的类型：
///   · 子域判歪 → "跨站"判据失效：不该弹的狂弹（站内翻页也问）、该弹的不弹；
///   · 归一化漏了 `www.` / `m.` → `www.a.com` 和 `m.a.com` 被当成两个站；
///   · 命中写成裸 `hasSuffix` → 加 `a.com` 把 `nota.com` 也免掉了（完全无关的站）。
final class SiteRulesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SiteRules.forgetAll(.openInNewTab)
        SiteRules.forgetAll(.adCleanSkip)
    }

    override func tearDown() {
        SiteRules.forgetAll(.openInNewTab)
        SiteRules.forgetAll(.adCleanSkip)
        super.tearDown()
    }

    // MARK: - 归一化

    func testNormalizeStripsSchemePathPortAndMobilePrefix() {
        XCTAssertEqual(SiteRules.normalize("https://www.Example.com/a/b?x=1"), "example.com")
        XCTAssertEqual(SiteRules.normalize("http://m.a.com"), "a.com")
        XCTAssertEqual(SiteRules.normalize("wap.a.com/x"), "a.com")
        XCTAssertEqual(SiteRules.normalize("a.com:8080/p"), "a.com")
        XCTAssertEqual(SiteRules.normalize("  WWW.A.CN  "), "a.cn")
        XCTAssertEqual(SiteRules.normalize("a.com."), "a.com")
    }

    // MARK: - 命中（本域 / 子域）

    func testHitCoversSubdomainsButNotLookalikes() {
        SiteRules.add("example.com", to: .adCleanSkip)
        XCTAssertEqual(SiteRules.hit("example.com", in: .adCleanSkip), "example.com")
        XCTAssertEqual(SiteRules.hit("cdn.example.com", in: .adCleanSkip), "example.com")
        // ★ 关键两条：长得像的**不能**误命中
        XCTAssertNil(SiteRules.hit("notexample.com", in: .adCleanSkip))
        XCTAssertNil(SiteRules.hit("example.com.evil.net", in: .adCleanSkip))
    }

    func testAddRejectsJunkAndDuplicates() {
        XCTAssertFalse(SiteRules.add("", to: .adCleanSkip))
        XCTAssertFalse(SiteRules.add("com", to: .adCleanSkip))          // 不含点 → 不算域名
        XCTAssertTrue(SiteRules.add("a.com", to: .adCleanSkip))
        XCTAssertFalse(SiteRules.add("www.a.com", to: .adCleanSkip))    // 归一化之后重复
        XCTAssertEqual(SiteRules.count(.adCleanSkip), 1)
    }

    // MARK: - 跨站判据（点链接弹窗用它决定弹不弹）

    func testSameSiteTreatsWwwAndMobileAsOneSite() {
        XCTAssertTrue(SiteRules.sameSite("https://www.a.com/x", "https://m.a.com/y"))
        XCTAssertTrue(SiteRules.sameSite("https://a.com/x", "https://sub.a.com/y"))
        XCTAssertFalse(SiteRules.sameSite("https://a.com/x", "https://b.com/y"))
        XCTAssertFalse(SiteRules.sameSite("https://a.com", "https://nota.com"))
        // 读不出来时不打扰他（宁可少问一次）
        XCTAssertTrue(SiteRules.sameSite("", "https://a.com"))
    }

    // MARK: - 增删

    func testRemoveAndForgetAll() {
        SiteRules.add("a.com", to: .openInNewTab)
        SiteRules.add("b.com", to: .openInNewTab)
        XCTAssertEqual(SiteRules.count(.openInNewTab), 2)
        SiteRules.remove("a.com", from: .openInNewTab)
        XCTAssertEqual(SiteRules.all(.openInNewTab), ["b.com"])
        SiteRules.forgetAll(.openInNewTab)
        XCTAssertEqual(SiteRules.count(.openInNewTab), 0)
    }

    /// 两组名单互不串门（一条命中的规则不该影响另一组）
    func testTwoListsAreIndependent() {
        SiteRules.add("a.com", to: .openInNewTab)
        XCTAssertTrue(SiteRules.has("a.com", .openInNewTab))
        XCTAssertFalse(SiteRules.has("a.com", .adCleanSkip))
    }
}
