import XCTest

/// 网页黑名单的离线回归 —— **每一条都对应一个"最容易悄悄坏掉"的口径**。
///
/// ★ 为什么值得单开一个文件：`BlockList` 是**纯逻辑**（只碰 Foundation + UserDefaults），
///   正好能进这个不链 ffmpeg 的测试目标 —— 每次推送由 CI 在模拟器上真跑一遍。
///   这比"在源码里 grep 关键字"硬得多：grep 只能证明"代码在那儿"，
///   跑起来才能证明"判据是对的"。
final class BlockListTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BlockList.forgetAll()
    }

    override func tearDown() {
        BlockList.forgetAll()
        super.tearDown()
    }

    // MARK: - ① 规范化：网址 / 域名 / 带 www / 带端口 / 带路径 → 同一个规则

    func testNormalizeStripsSchemePathPortAndWWW() {
        let want = "example.com"
        XCTAssertEqual(BlockList.normalize("example.com"), want)
        XCTAssertEqual(BlockList.normalize("www.example.com"), want, "开头的 www. 必须去掉")
        XCTAssertEqual(BlockList.normalize("https://www.example.com/a/b?c=1"), want)
        XCTAssertEqual(BlockList.normalize("http://example.com:8080/x"), want, "端口要去掉")
        XCTAssertEqual(BlockList.normalize("  WWW.Example.COM  "), want, "大小写和前后空格都要吃")
    }

    func testNormalizeRejectsGarbage() {
        XCTAssertEqual(BlockList.normalize(""), "")
        XCTAssertEqual(BlockList.normalize("   "), "")
        XCTAssertEqual(BlockList.normalize("这不是网址"), "", "没有点的认不出来，必须拒收")
        XCTAssertEqual(BlockList.normalize("www"), "", "只有 www 本身也不能收（会被削成空串）")
    }

    // MARK: - ② 命中：本域 + 子域命中；**长得像的域名绝不能命中**

    func testHitMatchesSelfAndSubdomains() {
        BlockList.add("example.com")
        XCTAssertEqual(BlockList.hit("example.com"), "example.com")
        XCTAssertEqual(BlockList.hit("m.example.com"), "example.com", "子域要命中")
        XCTAssertEqual(BlockList.hit("a.b.example.com"), "example.com", "多级子域也要命中")
        XCTAssertEqual(BlockList.hit("EXAMPLE.com"), "example.com", "大小写不敏感")
    }

    func testHitDoesNotMatchLookalikeDomain() {
        // ★★ 这条是整个名单里**最容易写错**的一条：
        //   如果用裸 `hasSuffix("example.com")`，那 notexample.com / myexample.com
        //   都会被误拦 —— 但它们是完全不同的站。
        //   正解是连那个点一起比：`hasSuffix("." + "example.com")`。
        BlockList.add("example.com")
        XCTAssertNil(BlockList.hit("notexample.com"), "notexample.com 不是子域")
        XCTAssertNil(BlockList.hit("myexample.com"), "myexample.com 不是子域")
        XCTAssertNil(BlockList.hit("example.com.cn"), "example.com.cn 是另一个域名")
        XCTAssertNil(BlockList.hit(""), "空 host 不能命中")
    }

    func testAddingWWWHostCoversTheBareOne() {
        // 口径②的由来：用户从 `www.x.com` 那一页点"加入黑名单"，
        // 结果 `x.com` 照样能进 —— 那种半吊子拦截最像"功能坏了"。
        BlockList.add("www.example.com")
        XCTAssertEqual(BlockList.count, 1)
        XCTAssertTrue(BlockList.blocks("https://example.com/"), "去掉 www 之后，裸域名也要被拦")
        XCTAssertTrue(BlockList.blocks("https://www.example.com/"))
    }

    // MARK: - ③ 加 / 删 / 去重 / 拒收垃圾

    func testAddIsIdempotentAndRemovable() {
        XCTAssertTrue(BlockList.add("https://www.example.com/x"), "第一次加应当返回 true")
        XCTAssertFalse(BlockList.add("example.com"), "同一个站换个写法再加，不算新增")
        XCTAssertEqual(BlockList.count, 1)

        BlockList.remove("www.example.com")
        XCTAssertEqual(BlockList.count, 0, "删的时候也要认得出是同一个站")
        XCTAssertNil(BlockList.hit("example.com"))
    }

    func testAddRejectsGarbage() {
        XCTAssertFalse(BlockList.add("不是网址"))
        XCTAssertFalse(BlockList.add(""))
        XCTAssertEqual(BlockList.count, 0, "认不出来的一律不能进名单")
    }

    // MARK: - ④ 网址级判据（真正被导航拦下来时走的就是这个）

    func testBlocksByURLString() {
        BlockList.add("example.com")
        XCTAssertTrue(BlockList.blocks("https://m.example.com/video/1"))
        XCTAssertFalse(BlockList.blocks("https://other.com/x"))
        XCTAssertFalse(BlockList.blocks("这不是网址"), "读不出 host 的不能算命中")
    }
}
