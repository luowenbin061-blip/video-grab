import XCTest

/// 「短链直解」的离线回归集（★ v1.0.257）。
///
/// ★ 喂的全是**浏览器里真实抓到过的页面形态**的缩微样本（字段名 / 转义形态 /
///   双 CDN 都照抄实测数据），机制来源见 `ShortVideoParse` 文件头 +
///   `_probe_tmp/sv_probe*.py`（2026-10-09 PC 实测）。
///   "转义怎么还原、playwm 怎么换、三家页面怎么抠"这类，光看代码看不出对错，必须跑。
final class ShortVideoParseTests: XCTestCase {

    // MARK: - 抖音

    /// JSON 路线：_ROUTER_DATA → item_list[0] → play_addr.url_list（转义照抄真实页面）
    func testDouyinFromRouterData() {
        let html = #"<html><script>window._ROUTER_DATA = {"loaderData":{"video_(id)\u002Fpage":{"videoInfoRes":{"item_list":[{"aweme_id":"7521","desc":"山丘｜测试\n第二行","video":{"play_addr":{"uri":"x","url_list":["https:\u002F\u002Faweme.snssdk.com\u002Faweme\u002Fv1\u002Fplaywm\u002F?video_id=abc","https:\u002F\u002Fmirror.example\u002Fplaywm\u002F?video_id=abc"]}}}]}}}}</script></html>"#
        let r = ShortVideoParse.douyinVideo(in: html)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.title, "山丘｜测试 第二行")
        // 第一个候选 = 去水印版（playwm → play）
        XCTAssertEqual(r?.urls.first?.absoluteString,
                       "https://aweme.snssdk.com/aweme/v1/play/?video_id=abc")
        // 双 CDN 的去水印版 + playwm 原串兜底都在（去重后 4 条）
        XCTAssertEqual(r?.urls.count, 4)
    }

    /// 正则兜底路线：JSON 切片不可用（页面里没有 _ROUTER_DATA）也能抠出来
    func testDouyinRegexFallback() {
        let html = #""play_addr":{"uri":"x","url_list":["https:\u002F\u002Faweme.snssdk.com\u002Faweme\u002Fv1\u002Fplaywm\u002F?video_id=xyz"]},"desc":"正则兜底标题""#
        let r = ShortVideoParse.douyinVideo(in: html)
        XCTAssertEqual(r?.urls.first?.absoluteString,
                       "https://aweme.snssdk.com/aweme/v1/play/?video_id=xyz")
        XCTAssertEqual(r?.title, "正则兜底标题")
    }

    func testDouyinNoVideo() {
        // 图文 / 已删除 / 风控验证页 → 必须判空（继续走回落，别拿垃圾链去下）
        XCTAssertNil(ShortVideoParse.douyinVideo(in: "<html>视频不存在</html>"))
    }

    /// 长编号：各种链接形态（路径里的 id 要赢过 query 里的 mid）
    func testLongID() {
        XCTAssertEqual(ShortVideoParse.longID(in: "https://www.douyin.com/video/7521023890996514083"),
                       "7521023890996514083")
        XCTAssertEqual(ShortVideoParse.longID(
            in: "https://www.iesdouyin.com/share/video/7521023890996514083/?region=CN&mid=7521023758266633023"),
            "7521023890996514083")
        XCTAssertNil(ShortVideoParse.longID(in: "https://v.douyin.com/abcdEFG/"))
        XCTAssertNil(ShortVideoParse.longID(in: "https://xhslink.cn/o/AxnRePgIokn"))
    }

    // MARK: - 小红书

    func testXhs() {
        let html = #"<script>window.__INITIAL_STATE__={"noteData":{"data":{"noteData":{"title":"DeepSeek 测试","desc":"x","video":{"consumer":{"originVideoKey":"spectrum\u002F1040g3583249p85ng0s0g5pen7tfhe54actnap28"}}}}}}</script>"#
        let r = ShortVideoParse.xhsVideo(in: html)
        XCTAssertEqual(r?.title, "DeepSeek 测试")
        XCTAssertEqual(r?.urls.first?.absoluteString,
                       "https://sns-video-bd.xhscdn.com/spectrum/1040g3583249p85ng0s0g5pen7tfhe54actnap28")
    }

    func testXhsNoVideo() {
        XCTAssertNil(ShortVideoParse.xhsVideo(in: "<html>图文笔记，没有视频</html>"))
    }

    // MARK: - 快手

    func testKwai() {
        let html = #"<script>{"photo":{"mainMvUrls":[{"cdn":"tymov2.a.kwimgs.com","url":"https:\u002F\u002Ftymov2.a.kwimgs.com\u002Fupic\u002Fx.mp4?clientCacheKey=3xabc_b.mp4"},{"cdn":"txmov2.a.kwimgs.com","url":"https:\u002F\u002Ftxmov2.a.kwimgs.com\u002Fupic\u002Fx.mp4?clientCacheKey=3xabc_b.mp4"}],"caption":"立定跳远测试 #tag"}}</script>"#
        let r = ShortVideoParse.kwaiVideo(in: html)
        XCTAssertEqual(r?.title, "立定跳远测试 #tag")
        XCTAssertEqual(r?.urls.count, 2)   // 双 CDN 镜像都给
        XCTAssertEqual(r?.urls.first?.absoluteString,
                       "https://tymov2.a.kwimgs.com/upic/x.mp4?clientCacheKey=3xabc_b.mp4")
    }

    func testKwaiNoVideo() {
        XCTAssertNil(ShortVideoParse.kwaiVideo(in: "<html>没有 mainMvUrls</html>"))
    }

    // MARK: - 小工具

    /// 转义还原 / 去水印替换 / 标题清洗（三家共用的三件小事）
    func testUnescapeAndWatermark() {
        XCTAssertEqual(ShortVideoParse.unescape(#"https:\u002F\u002Fx.com\u002Fa?b=1&amp;c=2"#),
                       "https://x.com/a?b=1&c=2")
        XCTAssertEqual(ShortVideoParse.noWatermark("https://a/playwm/?v=1"),
                       "https://a/play/?v=1")
        XCTAssertEqual(ShortVideoParse.noWatermark("https://a/play/?v=1"),
                       "https://a/play/?v=1")   // 没有 playwm 就原样
        XCTAssertEqual(ShortVideoParse.cleanTitle("标题\\n第二行"), "标题 第二行")
    }
}
