import XCTest

/// 离线回归集 —— 把这几天**真踩过的坑**当考题，每次推送由云端自动做一遍。
///
/// ★ 为什么只管"纯逻辑"：这个测试目标**不链 ffmpeg**（那套静态库只有真机切片
///   `ios-arm64`，模拟器上根本链接不上），所以只能测不碰平台的部分 ——
///   而"解析清单 / 洗地址 / 挑锚点"恰好全在这类里，也正是出过事的地方。
final class LogicTests: XCTestCase {

    /// 「广告 + 正片 + 广告」的真实结构：三段来自**不同目录、三把不同钥匙**
    private let threeKeyPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:6
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-KEY:METHOD=AES-128,URI="https://k.example/20260902/AAAABB/2000kb/hls/key.key",IV=0x00000000000000000000000000000000
    #EXTINF:3,
    https://cdn-a.example/20260902/AAAABB/2000kb/hls/a1.ts
    #EXTINF:3,
    https://cdn-a.example/20260902/AAAABB/2000kb/hls/a2.ts
    #EXT-X-KEY:METHOD=AES-128,URI="https://k.example/a3/20260926/REALID/2000kb/hls/key.key",IV=0x00000000000000000000000000000000
    #EXTINF:3,
    https://cdn-b.example/a3/20260926/REALID/2000kb/hls/r1.ts
    #EXTINF:3,
    https://cdn-b.example/a3/20260926/REALID/2000kb/hls/r2.ts
    #EXTINF:3,
    https://cdn-b.example/a3/20260926/REALID/2000kb/hls/r3.ts
    #EXT-X-KEY:METHOD=AES-128,URI="https://k.example/20260924/CCCCDD/2000kb/hls/key.key",IV=0x00000000000000000000000000000000
    #EXTINF:3,
    https://cdn-a.example/20260924/CCCCDD/2000kb/hls/z1.ts
    #EXT-X-ENDLIST
    """

    private var base: URL { URL(string: "https://hsm.example/a3/20260926/REALID/index.m3u8")! }

    // MARK: - ① 清单解析（逐段换钥匙那种）

    func testParseThreeKeyPlaylist() {
        let p = M3U8Playlist.parse(text: threeKeyPlaylist, baseURL: base)
        XCTAssertFalse(p.isMaster)
        XCTAssertEqual(p.segmentURLs.count, 6, "三段一共 6 个分片，一个都不能丢")
        XCTAssertEqual(p.segmentDurations.count, 6, "时长要和分片一一对应")
        XCTAssertNotNil(p.key, "清单里有 AES-128 钥匙")
        XCTAssertEqual(p.baseURL?.absoluteString, base.absoluteString,
                       "清单自己的地址要带出来（钥匙的相对地址要按它解析）")
        XCTAssertEqual(p.rawText, threeKeyPlaylist, "原文要原样留着（生成本地清单靠它）")
        XCTAssertTrue(p.badAddressLines.isEmpty, "这份清单里每行地址都读得懂")
    }

    // MARK: - ② 地址清洗（中文 / 空格 / 坏百分号 / # / ?）

    func testSanitizeKeepsGoodURLUntouched() {
        let u = "https://a.example/b/c.ts"
        XCTAssertEqual(M3U8Playlist.sanitizeURLString(u), u)
    }

    func testSanitizeKeepsQueryMark() {
        let u = "https://a.example/b.ts?token=1"
        XCTAssertEqual(M3U8Playlist.sanitizeURLString(u), u, "`?` 是查询串的开始，必须原样保留")
    }

    func testSanitizeEncodesChineseAndSpace() {
        let s = M3U8Playlist.sanitizeURLString("电影 01.ts")
        XCTAssertTrue(s.contains("%E7%94%B5%E5%BD%B1"), "中文要按 UTF-8 编码：\(s)")
        XCTAssertTrue(s.contains("%20"), "空格要编码：\(s)")
        XCTAssertFalse(s.contains(" "), "结果里不能再有空格")
    }

    func testSanitizeEncodesBrokenPercent() {
        // ★ 写回归测试时才发现的漏网：快路径修了"无效百分号"，慢路径却照样把裸 % 原样输出
        let s = M3U8Playlist.sanitizeURLString("100%.ts")
        XCTAssertTrue(s.contains("%25"), "坏百分号要编成 %25，否则 URL(string:) 还是 nil：\(s)")
    }

    func testSanitizeEncodesHash() {
        let s = M3U8Playlist.sanitizeURLString("a#1.ts")
        XCTAssertTrue(s.contains("%23"), "`#` 会被当片段起始、把文件名切断：\(s)")
    }

    // MARK: - ③ 相对地址解析

    func testResolveRelative() {
        let r = M3U8Playlist.resolve("seg.ts", relativeTo: URL(string: "https://a.example/x/index.m3u8")!)
        XCTAssertEqual(r?.absoluteString, "https://a.example/x/seg.ts")
    }

    func testResolveLeavesAbsoluteAlone() {
        let abs = "https://b.example/s.ts"
        XCTAssertEqual(M3U8Playlist.resolve(abs, relativeTo: base)?.absoluteString, abs)
    }

    // MARK: - ④ 锚点挑选（"广告 + 正片 + 广告"只留正片）

    func testAnchorCandidatesComeFromRequestURLDeepestFirst() {
        let c = PlaylistAnchor.candidates(from: [base])
        XCTAssertEqual(c, ["REALID", "20260926", "hsm.example"],
                       "从深到浅、太短的（a3）和根路径不要：\(c)")
    }

    func testAnchorPicksRealSection() {
        let p = M3U8Playlist.parse(text: threeKeyPlaylist, baseURL: base)
        let segs = p.segmentURLs.map(\.absoluteString)
        let picked = PlaylistAnchor.pick(segmentURLStrings: segs,
                                         candidates: PlaylistAnchor.candidates(from: [base]))
        XCTAssertEqual(picked?.anchor, "REALID", "认出来的应该是正片那一段")
        XCTAssertEqual(picked?.matched, 3)
        XCTAssertEqual(picked?.missed, 3, "另外两段（广告）要落在'不匹配'里")
    }

    func testAnchorGivesUpWhenItCannotTellTwoPilesApart() {
        // ★ v1.0.147 的真机事故：锚点取到了「变体清单所在目录」= hls，
        //   而**每个分片地址里都有 hls** → 全都"匹配" → 过滤静默失效、广告照旧进成品。
        //   规矩：**分不成两堆 = 判据失效**，必须返回 nil 走全下（绝不误删真片）。
        let p = M3U8Playlist.parse(text: threeKeyPlaylist, baseURL: base)
        let segs = p.segmentURLs.map(\.absoluteString)
        XCTAssertTrue(segs.allSatisfy { $0.contains("hls") }, "前提：这些地址里都有 hls")
        XCTAssertNil(PlaylistAnchor.pick(segmentURLStrings: segs, candidates: ["hls"]))
    }

    func testAnchorGivesUpWhenNothingMatches() {
        let p = M3U8Playlist.parse(text: threeKeyPlaylist, baseURL: base)
        let segs = p.segmentURLs.map(\.absoluteString)
        XCTAssertNil(PlaylistAnchor.pick(segmentURLStrings: segs, candidates: ["NOTHERE"]))
    }
}
