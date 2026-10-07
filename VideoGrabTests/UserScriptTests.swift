import XCTest

/// 「用户脚本」的离线回归 —— 重点是 `@match` 的匹配口径。
///
/// ★ 为什么必须跑：`@match` 是**最容易悄悄错**的一段 ——
///   `*.a.com` 该不该匹配 `a.com` 本身？`a.com` 该不该匹配 `b.a.com`？
///   光看代码看不出对错，而在真机上发现"脚本该跑没跑"要花一整个来回。
///
/// ★ JS 侧（注入进网页的那份包装）有同一套算法的精简版，两边靠同一批口径守住。
final class UserScriptTests: XCTestCase {

    private func u(_ s: String) -> URL { URL(string: s)! }

    // MARK: - ① 油猴头部：要宽容，别被不规范的头搞崩

    func testParseStandardHeader() {
        let code = """
        // ==UserScript==
        // @name         自动播放网页视频
        // @match        *://*/*
        // @description  整页只有一个可见视频时，帮你把它播起来
        // ==/UserScript==

        (function () {})();
        """
        let h = UserScriptHeader.parse(code)
        XCTAssertEqual(h.name, "自动播放网页视频")
        XCTAssertEqual(h.matches, ["*://*/*"])
        XCTAssertEqual(h.desc, "整页只有一个可见视频时，帮你把它播起来")
    }

    func testParseToleratesCrlfBomAndCase() {
        let code = "\u{FEFF}// ==UserScript==\r\n// @NAME 张三的脚本\r\n// @Match https://a.com/*\r\n// ==/UserScript==\r\n"
        let h = UserScriptHeader.parse(code)
        XCTAssertEqual(h.name, "张三的脚本", "BOM / CRLF / 大写字段名都要能吃")
        XCTAssertEqual(h.matches, ["https://a.com/*"])
    }

    func testParseAllowsMultipleMatchesAndMissingName() {
        let code = """
        // ==UserScript==
        // @match https://a.com/*
        // @match https://b.com/*
        // ==/UserScript==
        """
        let h = UserScriptHeader.parse(code)
        XCTAssertEqual(h.matches, ["https://a.com/*", "https://b.com/*"])
        XCTAssertEqual(h.name, "", "没写 @name → 交给上层补「未命名脚本」")
    }

    func testParseStopsAtRealCode() {
        // 头部之后是真正的代码 —— 里面的注释不该被当头部读
        let code = """
        // ==UserScript==
        // @name 甲
        // ==/UserScript==
        // @name 乙
        """
        XCTAssertEqual(UserScriptHeader.parse(code).name, "甲")
    }

    // MARK: - ② @match：三段（scheme / host / path）的口径

    func testMatchEverywhere() {
        XCTAssertTrue(UserScriptMatch.hit("*://*/*", u("https://a.com/x")))
        XCTAssertTrue(UserScriptMatch.hit("*://*/*", u("http://b.cn/")))
        XCTAssertTrue(UserScriptMatch.hitAny([], u("https://any.com/")), "规则为空 = 全部网站")
    }

    func testMatchSchemeMustAgree() {
        XCTAssertTrue(UserScriptMatch.hit("https://a.com/*", u("https://a.com/x")))
        XCTAssertFalse(UserScriptMatch.hit("http://a.com/*", u("https://a.com/x")),
                       "写了 http 就不该匹配 https")
    }

    func testMatchHostExactDoesNotCoverSubdomain() {
        XCTAssertTrue(UserScriptMatch.hit("https://a.com/*", u("https://a.com/x")))
        XCTAssertFalse(UserScriptMatch.hit("https://a.com/*", u("https://b.a.com/x")),
                       "精确写 a.com → 不覆盖子域")
    }

    func testMatchWildcardHostCoversSelfAndSubdomain() {
        // ★ 这条是**有意放宽**的口径：用户写 *.a.com 的意思就是"这个站自己也算"。
        //   按"只算子域"实现的话，a.com 反而不生效 —— 那是更常见的踩坑。
        XCTAssertTrue(UserScriptMatch.hit("https://*.a.com/*", u("https://a.com/x")),
                      "*.a.com 要覆盖 a.com 本身")
        XCTAssertTrue(UserScriptMatch.hit("https://*.a.com/*", u("https://b.a.com/x")),
                      "也要覆盖子域")
        XCTAssertFalse(UserScriptMatch.hit("https://*.a.com/*", u("https://b.a.com.evil.cn/x")),
                       "★ 后缀必须是完整的一节，不能被 b.a.com.evil.cn 骗过去")
    }

    func testMatchPathAndQuery() {
        XCTAssertTrue(UserScriptMatch.hit("https://a.com/v/*", u("https://a.com/v/1")))
        XCTAssertFalse(UserScriptMatch.hit("https://a.com/v/*", u("https://a.com/x/1")))
        // query / hash 不参与匹配
        XCTAssertTrue(UserScriptMatch.hit("https://a.com/v/*", u("https://a.com/v/1?t=9#f")))
        // 规则里没写路径 → 默认 /*（任意路径）
        XCTAssertTrue(UserScriptMatch.hit("https://a.com", u("https://a.com/any/path")))
    }

    func testMatchIsCaseInsensitiveOnHostAndScheme() {
        XCTAssertTrue(UserScriptMatch.hit("HTTPS://A.com/*", u("https://a.com/x")))
        XCTAssertTrue(UserScriptMatch.hit("https://a.com/*", u("https://A.CoM/x")))
    }

    // MARK: - ③ 通配匹配本身

    func testGlob() {
        XCTAssertTrue(UserScriptMatch.glob("/*", "/a/b/c"))
        XCTAssertTrue(UserScriptMatch.glob("/a*", "/abc"))
        XCTAssertTrue(UserScriptMatch.glob("/a*/c", "/ab/c"))
        XCTAssertTrue(UserScriptMatch.glob("*", "任意"))
        XCTAssertTrue(UserScriptMatch.glob("abc", "abc"))
        XCTAssertFalse(UserScriptMatch.glob("abc", "abd"))
        XCTAssertFalse(UserScriptMatch.glob("/a*", "/b"))
    }

    // MARK: - ④ 导入时的粗检 + 显示用的摘要

    func testLooksValid() {
        XCTAssertTrue(UserScriptMatch.looksValid("*://*/*"))
        XCTAssertTrue(UserScriptMatch.looksValid("https://a.com/*"))
        XCTAssertFalse(UserScriptMatch.looksValid("a.com/*"), "少了 :// 就不像规则")
        XCTAssertFalse(UserScriptMatch.looksValid("https://"), "没有主机名")
    }

    func testScopeText() {
        let everywhere = UserScript(id: "x", name: "n", matches: [], enabled: true,
                                    builtin: false, desc: "")
        XCTAssertTrue(everywhere.isEverywhere)
        XCTAssertEqual(everywhere.scopeText, "全部网站")

        let one = UserScript(id: "y", name: "n", matches: ["https://a.com/*"], enabled: true,
                             builtin: false, desc: "")
        XCTAssertFalse(one.isEverywhere)
        XCTAssertEqual(one.scopeText, "https://a.com/*")

        let two = UserScript(id: "z", name: "n",
                             matches: ["https://a.com/*", "https://b.com/*"],
                             enabled: true, builtin: false, desc: "")
        XCTAssertEqual(two.scopeText, "2 个网站")
    }
}
