import XCTest

/// B站解析的离线回归集。
///
/// ★★ 这些判据里，wbi 签名那几条的数字**不是我写的**，是拿 JS 参考实现
///   （照 B站 官方示例逐字照搬）跟本工程算法的等价写法**对拍出来的**。
///   所以它们能当"标准答案"用 —— 算法改歪了会立刻红。
///
/// ★ 这个测试目标只编译 `project.yml` 里那份纯逻辑白名单，所以 `BiliParse`
///   必须保持自包含（只 Foundation + CryptoKit）。哪天它 import 了 UIKit，
///   这里会直接编译不过 —— 那是提醒，不是故障。
final class BiliParseTests: XCTestCase {

    // MARK: - ① wbi 签名：跟 JS 参考实现对拍出来的标准答案

    /// 典型 playurl 参数（最常见的那条路）
    func testWbiQueryMatchesReferenceCase1() {
        let params = ["bvid": "BV1xx411c7mD", "cid": "123456", "qn": "127",
                      "fnval": "4048", "fnver": "0", "fourk": "1"]
        let img = "7cd084941338484aae1ad9425b84077c"
        let sub = "4932caff0ff746eab6f01bf08b70ac45"
        XCTAssertEqual(BiliParse.mixinKey(imgKey: img, subKey: sub),
                       "ea1db124af3c7062474693fa704f4ff8")
        XCTAssertEqual(
            BiliParse.wbiQuery(params: params, imgKey: img, subKey: sub, wts: 1_700_000_000),
            "bvid=BV1xx411c7mD&cid=123456&fnval=4048&fnver=0&fourk=1&qn=127&wts=1700000000"
            + "&w_rid=1e2ba2ea3e153cece642b49537a5dc47")
    }

    /// `!'()*` 这五个字符必须**先被滤掉**再编码（不是丢掉整个参数）
    func testWbiQueryFiltersForbiddenChars() {
        let params = ["keyword": "a!b'c(d)e*f", "page": "1"]
        XCTAssertEqual(
            BiliParse.wbiQuery(params: params,
                               imgKey: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                               subKey: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                               wts: 1_700_000_000),
            "keyword=abcdef&page=1&wts=1700000000"
            + "&w_rid=13bf295eeac491ad3c48225f961512ba")
    }

    /// 中文和空格要按 UTF-8 逐字节转义（这条最容易写错成"原样拼进去"）
    func testWbiQueryEncodesChineseAndSpace() {
        let params = ["search": "Hello World 你好", "order": "totalrank"]
        XCTAssertEqual(
            BiliParse.wbiQuery(params: params,
                               imgKey: "0123456789abcdef0123456789abcdef",
                               subKey: "fedcba9876543210fedcba9876543210",
                               wts: 1_700_000_000),
            "order=totalrank&search=Hello%20World%20%E4%BD%A0%E5%A5%BD&wts=1700000000"
            + "&w_rid=ed6a19cb9af645f4f77c39dcb0b0b075")
    }

    /// 只有 wts 一个参数时也要能算（边界）
    func testWbiQuerySingleParam() {
        XCTAssertEqual(
            BiliParse.wbiQuery(params: [:],
                               imgKey: "deadbeefdeadbeefdeadbeefdeadbeef",
                               subKey: "cafebabecafebabecafebabecafebabe",
                               wts: 1_700_000_000),
            "wts=1700000000&w_rid=fa1404a8134a4c06be9da858a08f8d24")
    }

    /// key 不足 64 位时返回空串（调用方据此判"没拿到 key"，而不是拿半个 key 去算签名）
    func testMixinKeyRejectsShortKeys() {
        XCTAssertEqual(BiliParse.mixinKey(imgKey: "abc", subKey: "def"), "")
    }

    // MARK: - ② 认链接

    func testBVIDRecognition() {
        XCTAssertEqual(BiliParse.bvid(inLink: "https://www.bilibili.com/video/BV1xx411c7mD"),
                       "BV1xx411c7mD")
        XCTAssertEqual(BiliParse.bvid(inLink: "https://www.bilibili.com/video/BV1xx411c7mD/?p=3"),
                       "BV1xx411c7mD")
        XCTAssertEqual(BiliParse.bvid(inLink: "BV1xx411c7mD"), "BV1xx411c7mD")
        // 尾巴不够 10 位 → 认不出来，不许瞎认
        XCTAssertNil(BiliParse.bvid(inLink: "https://x.com/BV1xx41"))
        // 含中文的“字母”不能被当成 BV 号的一部分
        XCTAssertNil(BiliParse.bvid(inLink: "https://x.com/BV你好你好你好你好你好"))
    }

    func testAIDRecognition() {
        XCTAssertEqual(BiliParse.aid(inLink: "https://www.bilibili.com/video/av170001"), 170001)
        XCTAssertEqual(BiliParse.aid(inLink: "https://api.bilibili.com/x?aid=170001"), 170001)
        // 普通单词里的 av 不许认
        XCTAssertNil(BiliParse.aid(inLink: "https://x.com/have/1"))
    }

    func testRefPrefersBVID() {
        XCTAssertEqual(BiliParse.ref(inLink: "https://www.bilibili.com/video/BV1xx411c7mD"),
                       .bvid("BV1xx411c7mD"))
        XCTAssertEqual(BiliParse.ref(inLink: "https://www.bilibili.com/video/av170001"),
                       .aid(170001))
    }

    func testPageParsing() {
        XCTAssertEqual(BiliParse.page(inLink: "https://www.bilibili.com/video/BV1xx411c7mD"), 1)
        XCTAssertEqual(BiliParse.page(inLink: "https://www.bilibili.com/video/BV1xx411c7mD?p=3"), 3)
        XCTAssertEqual(BiliParse.page(inLink: "https://x.com/a?p=0"), 1)   // 0 不合法 → 退回 1
    }

    func testPlatformRecognition() {
        XCTAssertTrue(BiliParse.isBiliLink("https://www.bilibili.com/video/BV1xx411c7mD"))
        XCTAssertTrue(BiliParse.isBiliLink("https://b23.tv/abcdefg"))
        XCTAssertFalse(BiliParse.isBiliLink("https://notbilibili.com.evil.cn/x"))
        XCTAssertTrue(BiliParse.isShortLink("https://b23.tv/abcdefg"))
        XCTAssertFalse(BiliParse.isShortLink("https://www.bilibili.com/video/BV1xx411c7mD"))
    }

    // MARK: - ③ 解析平台返回的 JSON

    /// ★★ 这条钉的是"**没登录也要能解析**"：nav 返回 code:-101（未登录），
    ///   但里头的 wbi_img 照样有 —— 所以判据里**不许看 code**。
    func testImgSubKeysFromNotLoggedInNav() {
        let json = """
        {"code":-101,"message":"账号未登录","ttl":1,"data":{"isLogin":false,
         "wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
                    "sub_url":"https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png"}}}
        """
        let k = BiliParse.imgSubKeys(navJSON: Data(json.utf8))
        XCTAssertEqual(k?.imgKey, "7cd084941338484aae1ad9425b84077c")
        XCTAssertEqual(k?.subKey, "4932caff0ff746eab6f01bf08b70ac45")
    }

    func testImgSubKeysRejectsGarbage() {
        XCTAssertNil(BiliParse.imgSubKeys(navJSON: Data("not json".utf8)))
        XCTAssertNil(BiliParse.imgSubKeys(navJSON: Data("{\"code\":0}".utf8)))
    }

    func testFileNameStem() {
        XCTAssertEqual(BiliParse.fileNameStem("https://a.com/bfs/wbi/abc.png"), "abc")
        XCTAssertEqual(BiliParse.fileNameStem("abc"), "abc")
    }

    /// 分 P：拿的必须是 `pages[p-1].cid`，不是 `data.cid`
    func testVideoInfoPicksPageCID() {
        let json = """
        {"code":0,"data":{"aid":111,"cid":999,"title":"总标题","duration":600,
          "pages":[{"cid":1001,"duration":100},{"cid":1002,"duration":200},
                   {"cid":1003,"duration":300}]}}
        """
        let d = Data(json.utf8)
        XCTAssertEqual(BiliParse.videoInfo(viewJSON: d, page: 1)?.cid, 1001)
        XCTAssertEqual(BiliParse.videoInfo(viewJSON: d, page: 2)?.cid, 1002)
        XCTAssertEqual(BiliParse.videoInfo(viewJSON: d, page: 2)?.duration, 200)
        XCTAssertEqual(BiliParse.videoInfo(viewJSON: d, page: 1)?.aid, 111)
        XCTAssertEqual(BiliParse.videoInfo(viewJSON: d, page: 1)?.title, "总标题")
        // 页码越界 → 退回 data.cid，不许崩
        XCTAssertEqual(BiliParse.videoInfo(viewJSON: d, page: 99)?.cid, 999)
    }

    func testVideoInfoRejectsNoCID() {
        XCTAssertNil(BiliParse.videoInfo(viewJSON: Data("{\"code\":0,\"data\":{\"title\":\"x\"}}".utf8)))
        XCTAssertNil(BiliParse.videoInfo(viewJSON: Data("garbage".utf8)))
    }

    // MARK: - ④ 挑流

    /// 同清晰度优先 H.264（哪怕另一个编码带宽更大）
    func testPickVideoPrefersAVCWithinTopQuality() {
        let list = [
            BiliParse.Stream(url: "u1", quality: 80, codecs: "hev1.1.6", width: 1920,
                             height: 1080, bandwidth: 5000),
            BiliParse.Stream(url: "u2", quality: 80, codecs: "avc1.640032", width: 1920,
                             height: 1080, bandwidth: 3000),
            BiliParse.Stream(url: "u3", quality: 64, codecs: "avc1", width: 1280,
                             height: 720, bandwidth: 9999),
        ]
        XCTAssertEqual(BiliParse.pickVideo(list)?.url, "u2")
    }

    func testPickVideoTakesHighestQuality() {
        let list = [
            BiliParse.Stream(url: "lo", quality: 32, codecs: "avc1", width: 0, height: 0,
                             bandwidth: 1),
            BiliParse.Stream(url: "hi", quality: 80, codecs: "avc1", width: 0, height: 0,
                             bandwidth: 1),
        ]
        XCTAssertEqual(BiliParse.pickVideo(list)?.url, "hi")
        XCTAssertNil(BiliParse.pickVideo([]))
    }

    func testPickAudioPrefersMp4a() {
        let list = [
            BiliParse.Stream(url: "ec3", quality: 30250, codecs: "ec-3", width: 0, height: 0,
                             bandwidth: 9000),
            BiliParse.Stream(url: "aac", quality: 30280, codecs: "mp4a.40.2", width: 0, height: 0,
                             bandwidth: 128),
        ]
        XCTAssertEqual(BiliParse.pickAudio(list)?.url, "aac")
        // 没有 mp4a 时退回"带宽最大"
        let only = [BiliParse.Stream(url: "x", quality: 1, codecs: "ec-3", width: 0, height: 0,
                                     bandwidth: 5)]
        XCTAssertEqual(BiliParse.pickAudio(only)?.url, "x")
        XCTAssertNil(BiliParse.pickAudio([]))
    }

    func testStreamsFromDASH() {
        let json = """
        {"code":0,"data":{"accept_quality":[80,64,32],"quality":80,"dash":{
          "duration":600,
          "video":[
            {"id":80,"baseUrl":"https://v/1080hev.m4s","codecs":"hev1","width":1920,"height":1080,"bandwidth":5000},
            {"id":80,"baseUrl":"https://v/1080avc.m4s","codecs":"avc1","width":1920,"height":1080,"bandwidth":3000},
            {"id":32,"baseUrl":"https://v/480.m4s","codecs":"avc1","width":854,"height":480,"bandwidth":700}],
          "audio":[{"id":30280,"baseUrl":"https://a/192k.m4s","codecs":"mp4a.40.2","bandwidth":320000}]}}}
        """
        let r = BiliParse.streams(playURLJSON: Data(json.utf8))
        XCTAssertEqual(r?.video.url, "https://v/1080avc.m4s")
        XCTAssertEqual(r?.video.quality, 80)
        XCTAssertEqual(r?.audio?.url, "https://a/192k.m4s")
        XCTAssertEqual(BiliParse.acceptQuality(playURLJSON: Data(json.utf8)), [80, 64, 32])
    }

    /// 没有 DASH 时退回 durl（整段 mp4，音视频在一起 → 音频为 nil）
    func testStreamsFallbackToDurl() {
        let json = """
        {"code":0,"data":{"quality":32,"durl":[{"url":"https://x/all.mp4","size":123}]}}
        """
        let r = BiliParse.streams(playURLJSON: Data(json.utf8))
        XCTAssertEqual(r?.video.url, "https://x/all.mp4")
        XCTAssertNil(r?.audio)
    }

    func testStreamsRejectsEmpty() {
        XCTAssertNil(BiliParse.streams(playURLJSON: Data("{\"code\":0,\"data\":{}}".utf8)))
        XCTAssertNil(BiliParse.streams(playURLJSON: Data("nope".utf8)))
    }

    func testQualityName() {
        XCTAssertEqual(BiliParse.qualityName(80), "1080P")
        XCTAssertEqual(BiliParse.qualityName(32), "480P")
        XCTAssertEqual(BiliParse.qualityName(116), "1080P60")
        XCTAssertEqual(BiliParse.qualityName(1), "清晰度 1")
    }
}
