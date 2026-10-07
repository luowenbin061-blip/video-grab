import XCTest

/// 「底部功能类设置」拖动排序的离线回归。
///
/// ★ 为什么值得单开一个文件：`UILayout` 是**纯逻辑**（只碰 Foundation），
///   正好能进这个不链 ffmpeg 的测试目标 —— 每次推送由 CI 在模拟器上真跑一遍。
///   拖动排序最容易出的两种错（**丢项 / 多项**、**落点算错**）都不是看一眼
///   代码能看出来的，必须跑。
final class UILayoutTests: XCTestCase {

    // MARK: - ① 默认顺序本身要合法

    func testDefaultsAreClean() {
        XCTAssertEqual(UILayout.toolDefault.count, 8, "功能卡片是 8 格")
        XCTAssertEqual(UILayout.barDefault.count, 5, "底栏是 5 个")
        XCTAssertEqual(Set(UILayout.toolDefault).count, 8, "功能卡片的 key 不能重复")
        XCTAssertEqual(Set(UILayout.barDefault).count, 5, "底栏的 key 不能重复")
        XCTAssertEqual(UILayout.parse(UILayout.toolDefaultRaw, UILayout.toolDefault),
                       UILayout.toolDefault, "默认串解析回来必须一模一样")
        XCTAssertEqual(UILayout.parse(UILayout.barDefaultRaw, UILayout.barDefault),
                       UILayout.barDefault)
        XCTAssertEqual(UILayout.toolColumns, 4, "8 格是 2×4 —— 换行位置要跟实际卡片一致")
        XCTAssertEqual(UILayout.toolDefault.count, UILayout.toolColumns * 2,
                       "功能卡片正好两行")
    }

    // MARK: - ② parse：脏数据一律收敛成"完整且合法"的顺序

    func testParseRepairsDirtyData() {
        // 空串（新装 App）→ 全默认
        XCTAssertEqual(UILayout.parse("", UILayout.toolDefault), UILayout.toolDefault)

        // 少了几项 → **补在末尾**，不是丢掉
        XCTAssertEqual(UILayout.parse("copy,share,tabs,sniff", UILayout.toolDefault),
                       ["copy", "share", "tabs", "sniff",
                        "bookmarks", "mark", "settings", "toolbox"])

        // 混进不认识的 key 和空白项 → 丢掉不认识的、留下认识的
        // ★ 注意池子要用对：`sniff` / `copy` 是**功能卡片**的 key，
        //   拿 `barDefault` 去解析它们会被当成"不认识的"丢掉（我第一版就写错了这里）。
        XCTAssertEqual(UILayout.parse("sniff, ,bogus,copy", UILayout.toolDefault),
                       ["sniff", "copy", "bookmarks", "mark", "settings", "toolbox",
                        "share", "tabs"])

        // 重复 → 只留第一次
        XCTAssertEqual(UILayout.parse("copy,copy,share", UILayout.toolDefault),
                       ["copy", "share", "bookmarks", "mark", "settings", "toolbox",
                        "tabs", "sniff"])

        // 前后空格要吃干净
        XCTAssertEqual(Array(UILayout.parse(" sniff , copy ", UILayout.toolDefault).prefix(2)),
                       ["sniff", "copy"])
    }

    // MARK: - ③ 重排：拖到谁头上，就落在谁原来的位置

    func testMoveForwardLandsOnTargetPosition() {
        // 默认：bookmarks, mark, settings, toolbox, copy, share, tabs, sniff
        // 把第 1 格拖到第 3 格（settings）头上 → 落在 settings 原来的位置
        let out = UILayout.move(UILayout.toolDefaultRaw, UILayout.toolDefault,
                                from: "bookmarks", to: "settings")
        XCTAssertEqual(out, "mark,settings,bookmarks,toolbox,copy,share,tabs,sniff")
    }

    func testMoveBackwardLandsOnTargetPosition() {
        // 默认：back, forward, menu, downloads, reload
        // 把最后一位（reload）拖到 menu 头上 → 落在 menu 原来的位置
        XCTAssertEqual(UILayout.move(UILayout.barDefaultRaw, UILayout.barDefault,
                                     from: "reload", to: "menu"),
                       "back,forward,reload,menu,downloads")
    }

    func testMoveToFirstAndLast() {
        // 拖到最前 / 最后 —— 最容易越界的两头
        XCTAssertEqual(UILayout.move(UILayout.barDefaultRaw, UILayout.barDefault,
                                     from: "reload", to: "back"),
                       "reload,back,forward,menu,downloads")
        XCTAssertEqual(UILayout.move(UILayout.barDefaultRaw, UILayout.barDefault,
                                     from: "back", to: "reload"),
                       "forward,menu,downloads,reload,back")
    }

    // MARK: - ④ 边界：不动的、拖不认识的

    func testMoveIsNoopForSameKey() {
        XCTAssertEqual(UILayout.move(UILayout.toolDefaultRaw, UILayout.toolDefault,
                                     from: "settings", to: "settings"),
                       UILayout.toolDefaultRaw, "拖到自己头上什么都不该变")
    }

    func testMoveWithUnknownKeyStillReturnsLegalOrder() {
        // 存的是脏数据时，重排也只在"收敛后的合法顺序"上做 ——
        // 绝不能让一次拖动把界面搞成残缺的。
        let out = UILayout.move("bogus,sniff", UILayout.toolDefault,
                                from: "sniff", to: "bookmarks")
        let list = UILayout.parse(out, UILayout.toolDefault)
        XCTAssertEqual(list.count, 8)
        XCTAssertEqual(Set(list), Set(UILayout.toolDefault))
        XCTAssertEqual(list.first, "bookmarks", "sniff 拖到 bookmarks 上 → 它在 bookmarks 之后")
        XCTAssertEqual(list[1], "sniff")
    }

    // MARK: - ⑤ 连续拖：丢项 / 多项的守门员

    func testRepeatedMovesNeverLoseOrDuplicateItems() {
        var raw = UILayout.toolDefaultRaw
        let steps = [("sniff", "bookmarks"), ("bookmarks", "tabs"),
                     ("copy", "mark"), ("tabs", "toolbox"), ("mark", "sniff")]
        for (from, to) in steps {
            raw = UILayout.move(raw, UILayout.toolDefault, from: from, to: to)
        }
        let list = UILayout.parse(raw, UILayout.toolDefault)
        XCTAssertEqual(list.count, 8, "反复拖动不许丢项")
        XCTAssertEqual(Set(list), Set(UILayout.toolDefault), "反复拖动不许换出别的项")
    }

    // MARK: - ⑥ 每一项都要有名字和图标（设置页要显示它们）

    func testEveryKeyHasLabel() {
        for k in UILayout.toolDefault + UILayout.barDefault {
            let (icon, name) = UILayout.label(of: k)
            XCTAssertFalse(icon.isEmpty, "\(k) 缺图标")
            XCTAssertFalse(name.isEmpty, "\(k) 缺名字")
        }
        // 名字不能撞车 —— 两格里显示同一个名字会让人以为能互相拖
        let names = (UILayout.toolDefault + UILayout.barDefault).map { UILayout.label(of: $0).name }
        XCTAssertEqual(Set(names).count, names.count, "选项名字不能重复")
    }
}
