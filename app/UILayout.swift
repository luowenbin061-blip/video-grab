import Foundation

/// 底部界面的**顺序**（v1.0.231「底部功能类设置」）。
///
/// 只存**顺序**，不存"显示 / 隐藏"：用户定的规矩是**只做拖动排序、不增删**
/// —— 池子就是固定的那几个；少一个等于少一个功能，那是 bug 不是配置。
///
/// ★ 存 UserDefaults 的是一串逗号分隔的 key；读的时候一律走 `parse`
///   （**补齐缺失项、丢掉不认识的项**）—— 以后真要增删项，老用户的旧顺序
///   也不会把界面搞坏。
///
/// ★ 本文件只 import Foundation，所以**同时**编进 App 和 CI 回归集
///   （见 project.yml 的 VideoGrabTests sources）—— 排序规则是"光看代码看不出
///   对错"的那类逻辑，得有测试跑。
enum UILayout {

    // MARK: - 两个池子

    /// 功能卡片（底栏「≡」调出来那 8 格）
    static let toolKey = "vgToolOrder"
    static let toolDefault = ["bookmarks", "mark", "settings", "toolbox",
                              "copy", "share", "tabs", "sniff"]

    /// 底栏那 5 个。
    /// ★ 第 5 个是「刷新 / 停止」**两态同一个按钮** —— 它算**一个对象**，
    ///   排序时不能拆成两个（`reload` 这个 key 覆盖两种状态）。
    static let barKey = "vgBarOrder"
    static let barDefault = ["back", "forward", "menu", "downloads", "reload"]

    static var toolDefaultRaw: String { toolDefault.joined(separator: ",") }
    static var barDefaultRaw: String { barDefault.joined(separator: ",") }

    /// 列表首页（功能卡片）一行放几格 —— 8 格正好 2×4，跟实际卡片一致。
    static let toolColumns = 4

    // MARK: - 顺序的读写

    /// 解析存下来的顺序：**丢掉不认识的、去重、补齐缺失的**。
    /// 任何脏数据都收敛成一份"完整且合法"的顺序，绝不返回残缺列表。
    static func parse(_ raw: String, _ fallback: [String]) -> [String] {
        var out: [String] = []
        for piece in raw.split(separator: ",") {
            let k = piece.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, fallback.contains(k), !out.contains(k) { out.append(k) }
        }
        for k in fallback where !out.contains(k) { out.append(k) }
        return out
    }

    /// 把 `from` 挪到 `to` 原来的位置（`to` 让位）。
    ///
    /// 往前拖（from 在后）→ from 落在 to 之前；往后拖（from 在前）→ 落在 to 之后。
    /// 两种都是同一句 `remove(fi)` + `insert(at: ti)`：
    /// remove 之后目标项的索引正好就是它该让开的那个位置。
    static func move(_ raw: String, _ fallback: [String],
                     from: String, to: String) -> String {
        var list = parse(raw, fallback)
        guard let fi = list.firstIndex(of: from),
              let ti = list.firstIndex(of: to), fi != ti else {
            return list.joined(separator: ",")
        }
        let item = list.remove(at: fi)
        list.insert(item, at: ti)
        return list.joined(separator: ",")
    }

    // MARK: - 每一项长什么样（设置页里显示用）

    /// key → (图标名, 中文名)。名字跟界面上那张卡片 / 底栏上的**一模一样**，
    /// 免得用户在设置页里看到的跟实际对不上。
    static func label(of key: String) -> (icon: String, name: String) {
        switch key {
        case "bookmarks": return ("clock.arrow.circlepath", "收藏/历史")
        case "mark":      return ("bookmark", "收藏网址")
        case "settings":  return ("gearshape", "设置")
        case "toolbox":   return ("wrench.and.screwdriver", "工具箱")
        case "copy":      return ("link", "复制URL")
        case "share":     return ("square.and.arrow.up", "分享")
        case "tabs":      return ("square.on.square", "标签页")
        case "sniff":     return ("antenna.radiowaves.left.and.right", "嗅探结果")
        case "back":      return ("chevron.left", "后退")
        case "forward":   return ("chevron.right", "前进")
        case "menu":      return ("line.3.horizontal", "功能键")
        case "downloads": return ("arrow.down.circle", "下载页")
        default:          return ("arrow.clockwise", "刷新")
        }
    }
}
