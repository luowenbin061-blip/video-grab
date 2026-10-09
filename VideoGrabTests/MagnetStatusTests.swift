import XCTest

/// 磁力引擎状态解析的离线回归集。
///
/// ★ 这里钉的都是"光看代码看不出对错、跑起来才知道"的判据：
///   · 元数据没到 / 到了但一个文件都没有 → 界面**不许**出现空列表；
///   · 默认勾选：有视频就勾全部视频（一季多集是常态），种子里那些广告图/说明文件别默认下；
///   · 大小和速度的显示不能跟着系统语言变（单测要能钉死）。
final class MagnetStatusTests: XCTestCase {

    private let fullJSON = """
    {"state":"downloading","name":"某部剧 第一季","meta":true,
     "totalBytes":5000000000,"doneBytes":1200000000,"rateBytes":2400000,
     "peers":7,"progress":0.24,
     "files":[
       {"index":0,"path":"某部剧/01.mp4","size":1000000000,"done":1000000000},
       {"index":1,"path":"某部剧/02.mkv","size":1200000000,"done":200000000},
       {"index":2,"path":"某部剧/说明.txt","size":1024,"done":0},
       {"index":3,"path":"某部剧/样片.mp4","size":20000000,"done":0},
       {"index":4,"path":"某部剧/cover.jpg","size":300000,"done":0}]}
    """

    // MARK: - 解析

    func testParseFullSnapshot() {
        let s = MagnetStatus.parse(fullJSON)
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.state, .downloading)
        XCTAssertEqual(s?.name, "某部剧 第一季")
        XCTAssertEqual(s?.metaReady, true)
        XCTAssertEqual(s?.totalBytes, 5_000_000_000)
        XCTAssertEqual(s?.doneBytes, 1_200_000_000)
        XCTAssertEqual(s?.rateBytes, 2_400_000)
        XCTAssertEqual(s?.peers, 7)
        XCTAssertEqual(s?.files.count, 5)
        XCTAssertEqual(s?.files.first?.index, 0)
        XCTAssertEqual(s?.files[1].name, "02.mkv")
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(MagnetStatus.parse("not json"))
        XCTAssertNil(MagnetStatus.parse(""))
        XCTAssertNil(MagnetStatus.parse("{\"state\":"))
    }

    /// 元数据还没到：状态是 metadata、没有 files 段 —— 不许崩，也不许把 metaReady 当 true
    func testParseBeforeMetadata() {
        let s = MagnetStatus.parse("{\"state\":\"metadata\",\"name\":\"x\",\"meta\":false}")
        XCTAssertEqual(s?.state, .metadata)
        XCTAssertEqual(s?.metaReady, false)
        XCTAssertEqual(s?.files.isEmpty, true)
    }

    /// ★ 「引擎说元数据到了、但一个文件都没有」→ 必须回退成"还没到"，
    ///   否则界面会出现一个空列表，用户以为坏了。
    func testEmptyFileListIsTreatedAsNoMetadata() {
        let s = MagnetStatus.parse("{\"state\":\"downloading\",\"meta\":true,\"files\":[]}")
        XCTAssertEqual(s?.metaReady, false)
    }

    func testUnknownStateFallsBack() {
        XCTAssertEqual(MagnetStatus.parse("{\"state\":\"weird\"}")?.state, .unknown)
        XCTAssertEqual(MagnetStatus.parse("{}")?.state, .unknown)
    }

    // MARK: - 文件类型与名字

    func testFileKindByExtension() {
        XCTAssertEqual(MagnetStatus.FileKind(path: "a/b/01.MP4"), .video)   // 大小写不敏感
        XCTAssertEqual(MagnetStatus.FileKind(path: "a.mkv"), .video)
        XCTAssertEqual(MagnetStatus.FileKind(path: "a.webm"), .video)
        XCTAssertEqual(MagnetStatus.FileKind(path: "a.flac"), .audio)
        XCTAssertEqual(MagnetStatus.FileKind(path: "a.jpg"), .image)
        XCTAssertEqual(MagnetStatus.FileKind(path: "readme.txt"), .doc)
        XCTAssertEqual(MagnetStatus.FileKind(path: "noext"), .doc)
    }

    func testFileNameIsBasename() {
        let f = MagnetStatus.File(index: 0, path: "剧名/第一集/01.mp4", size: 1, done: 0)
        XCTAssertEqual(f.name, "01.mp4")
    }

    func testFileProgress() {
        let half = MagnetStatus.File(index: 0, path: "a.mp4", size: 100, done: 50)
        XCTAssertEqual(half.progress, 0.5, accuracy: 0.0001)
        // 大小未知时不许除零
        XCTAssertEqual(MagnetStatus.File(index: 0, path: "a.mp4", size: 0, done: 10).progress, 0)
    }

    // MARK: - 默认勾哪些（★ 这块最要紧）

    /// 有视频 → 全部视频都勾上（一季多集，少勾一集更让人烦）
    func testDefaultSelectionPicksAllVideos() {
        let s = MagnetStatus.parse(fullJSON)!
        XCTAssertEqual(MagnetStatus.defaultSelection(in: s.files), [0, 1, 3])
    }

    /// 一个视频都没有 → 勾体积最大的那个（至少不是空的）
    func testDefaultSelectionFallsBackToBiggest() {
        let files = [
            MagnetStatus.File(index: 0, path: "a.txt", size: 100, done: 0),
            MagnetStatus.File(index: 1, path: "b.bin", size: 900, done: 0),
            MagnetStatus.File(index: 2, path: "c.nfo", size: 5, done: 0),
        ]
        XCTAssertEqual(MagnetStatus.defaultSelection(in: files), [1])
    }

    /// 一个文件都没有 → 空集（调用方按"全都下"处理）
    func testDefaultSelectionEmpty() {
        XCTAssertTrue(MagnetStatus.defaultSelection(in: []).isEmpty)
    }

    func testTotalSize() {
        let s = MagnetStatus.parse(fullJSON)!
        XCTAssertEqual(MagnetStatus.totalSize(of: [0, 1], in: s.files), 2_200_000_000)
        XCTAssertEqual(MagnetStatus.totalSize(of: [], in: s.files), 0)
    }

    // MARK: - 显示

    func testHumanSize() {
        XCTAssertEqual(MagnetStatus.humanSize(1024), "1.0 KB")
        XCTAssertEqual(MagnetStatus.humanSize(1024 * 1024), "1.0 MB")
        XCTAssertEqual(MagnetStatus.humanSize(1_500_000_000), "1.4 GB")
        XCTAssertEqual(MagnetStatus.humanSize(512), "512 B")
        XCTAssertEqual(MagnetStatus.humanSize(0), "未知")
        XCTAssertEqual(MagnetStatus.humanSize(-5), "未知")
    }

    func testHumanRate() {
        XCTAssertEqual(MagnetStatus.humanRate(0), "0 B/s")
        XCTAssertEqual(MagnetStatus.humanRate(1024), "1.0 KB/s")
        XCTAssertEqual(MagnetStatus.humanRate(2_400_000), "2.3 MB/s")
    }
}
