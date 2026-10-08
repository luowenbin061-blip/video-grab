import XCTest

/// ★ v1.0.238：`SiteRules` 的口径测试。
///
/// 这几条都是"错了会很难查"的类型：
///   · 子域判歪 → 名单失效：该清的站不清、或者无关的站被清（把页面弄坏）；
///   · 归一化漏了 `www.` / `m.` → `www.a.com` 和 `m.a.com` 被当成两个站；
///   · 命中写成裸 `hasSuffix` → 加 `a.com` 把 `nota.com` 也一起清了（完全无关的站）。
final class SiteRulesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SiteRules.forgetAll(.adCleanOn)
    }

    override func tearDown() {
        SiteRules.forgetAll(.adCleanOn)
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
        SiteRules.add("example.com", to: .adCleanOn)
        XCTAssertEqual(SiteRules.hit("example.com", in: .adCleanOn), "example.com")
        XCTAssertEqual(SiteRules.hit("cdn.example.com", in: .adCleanOn), "example.com")
        // ★ 关键两条：长得像的**不能**误命中
        XCTAssertNil(SiteRules.hit("notexample.com", in: .adCleanOn))
        XCTAssertNil(SiteRules.hit("example.com.evil.net", in: .adCleanOn))
    }

    func testAddRejectsJunkAndDuplicates() {
        XCTAssertFalse(SiteRules.add("", to: .adCleanOn))
        XCTAssertFalse(SiteRules.add("com", to: .adCleanOn))          // 不含点 → 不算域名
        XCTAssertTrue(SiteRules.add("a.com", to: .adCleanOn))
        XCTAssertFalse(SiteRules.add("www.a.com", to: .adCleanOn))    // 归一化之后重复
        XCTAssertEqual(SiteRules.count(.adCleanOn), 1)
    }

    // MARK: - 增删

    func testRemoveAndForgetAll() {
        SiteRules.add("a.com", to: .adCleanOn)
        SiteRules.add("b.com", to: .adCleanOn)
        XCTAssertEqual(SiteRules.count(.adCleanOn), 2)
        SiteRules.remove("a.com", from: .adCleanOn)
        XCTAssertEqual(SiteRules.all(.adCleanOn), ["b.com"])
        SiteRules.forgetAll(.adCleanOn)
        XCTAssertEqual(SiteRules.count(.adCleanOn), 0)
    }

    // MARK: - ★ v1.0.238 反转的核心：没在名单里 = 一个都不清

    /// 名单为空 = **谁都不清**（老版是"默认全清 + 按站豁免"）。
    /// ★ 这条是这次反转的命门，必须有断言守着 —— 搞反了就是"全站被清"。
    func testEmptyListCleansNothing() {
        XCTAssertEqual(SiteRules.count(.adCleanOn), 0)
        XCTAssertNil(SiteRules.hit("any-site.com", in: .adCleanOn))
        XCTAssertFalse(SiteRules.has("www.whatever.cn", .adCleanOn))
    }

    // MARK: - 注入源（cleaner.js 的 ONLY 名单）

    /// 名单要**真的填进脚本**，而且填的是 `ONLY`（不是老版的 `SKIP`）。
    /// ★ `cleanerSource` 是 `@MainActor` 类上的 static 方法 → 测试方法也得标 `@MainActor`。
    /// ★ 判据写成"代码那一行的形式"，别带前导缩进（换容器会让缩进变一格、断言集体失效）。
    @MainActor
    func testCleanerSourceCarriesOnlyList() {
        let src = BrowserModel.cleanerSource(hosts: ["a.com", "b.com"])
        XCTAssertTrue(src.contains("var ONLY = [\"a.com\",\"b.com\"];"))
        XCTAssertFalse(src.contains("var SKIP"))
        XCTAssertFalse(src.contains("var MODE"))
        // 脚本自己判 host 的那段还在（不在名单里 → 一个字都不干）
        XCTAssertTrue(src.contains("if (!vgHostListed()) return;"))
    }
}
