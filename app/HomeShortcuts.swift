import Foundation
import UIKit

/// 首页（新标签页）快捷入口的一格。
///
/// 两类的区别：
///   · `url`     = 一个网站（点它 = 用当前标签打开这个地址）
///   · `feature` = 我们自己的一个功能（点它 = 执行，跟底栏 ≡ 卡片里那些一样）
///
/// ★ 格子的顺序就是数组顺序（"移到最前"= 挪到 index 0）。
struct HomeItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case url, feature }

    var id: UUID = UUID()
    var kind: Kind
    /// 网址格子 = 网址；功能格子 = `HomeFeature.rawValue`
    var value: String
    /// 显示名（网址格子可自定义；功能格子跟着功能走）
    var title: String = ""
    /// 抓下来的图标文件名（存在 home/icons/ 下）。空 = 没抓到 → 界面用首字母色块兜底
    var iconFile: String = ""
}

/// 首页能放的功能格子。
/// ★ rawValue 会被写进存档，**改名字等于让老存档认不出来** —— 只加不改。
enum HomeFeature: String, CaseIterable, Identifiable {
    case sniff, downloads, bookmarks, toolbox, settings, tabs, copyURL
    case desktopMode, noImage, pagePDF, share

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sniff:       return "嗅探结果"
        case .downloads:   return "下载管理"
        case .bookmarks:   return "收藏/历史"
        case .toolbox:     return "工具箱"
        case .settings:    return "设置"
        case .tabs:        return "标签页"
        case .copyURL:     return "复制 URL"
        case .desktopMode: return "桌面模式"
        case .noImage:     return "无图模式"
        case .pagePDF:     return "导出 PDF"
        case .share:       return "分享"
        }
    }

    /// 只用 iOS 14/15 一定存在的 SF Symbol（不存在的名字会显示成空白，不崩但难看）
    var icon: String {
        switch self {
        case .sniff:       return "antenna.radiowaves.left.and.right"
        case .downloads:   return "arrow.down.circle"
        case .bookmarks:   return "clock.arrow.circlepath"
        case .toolbox:     return "wrench.and.screwdriver"
        case .settings:    return "gearshape"
        case .tabs:        return "square.on.square"
        case .copyURL:     return "link"
        case .desktopMode: return "desktopcomputer"
        case .noImage:     return "eye.slash"
        case .pagePDF:     return "doc.richtext"
        case .share:       return "square.and.arrow.up"
        }
    }

    /// 开关型功能（界面上显示"开/关"，点了是切换）
    var isToggle: Bool {
        self == .desktopMode || self == .noImage
    }
}

/// 首页快捷入口的存档 + 图标缓存。
///
/// 为什么单独存一份、不复用书签：
///   · 书签是"我保存过的所有网站"（可能几百条，还带分组/回收站）；
///     首页只要**十来个**每天真会点的入口 —— 混在一起会互相拖累。
///   · 首页格子还能放"功能"，书签那边没有这个概念。
///   代价：两边都得自己维护（可以接受）。
///
/// 图标：**只抓站点自己的 /favicon.ico**，不接任何第三方图标服务
///   （那些域名（Google 之类）国内打不开，接了就是给自己埋雷）。
///   抓不到 → 界面用「首字母 + 按域名生成的颜色」兜底，永远有东西显示。
@MainActor
final class HomeStore: ObservableObject {

    static let shared = HomeStore()

    /// 按显示顺序排的格子
    @Published private(set) var items: [HomeItem] = []
    /// 已读进内存的图标（键 = `iconFile`）
    @Published private(set) var icons: [String: UIImage] = [:]

    private static var dir: URL {
        JobStore.dir.appendingPathComponent("home", isDirectory: true)
    }
    private static var iconsDir: URL {
        dir.appendingPathComponent("icons", isDirectory: true)
    }
    private static var fileURL: URL {
        dir.appendingPathComponent("shortcuts.json")
    }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.iconsDir, withIntermediateDirectories: true)
        items = Self.readFromDisk()
        // ★ v1.0.124：清掉"这个版本已经不认识"的功能格子。
        //   删掉某个功能（这回是截长图）后，老存档里可能还留着它 ——
        //   不清的话首页上会多出一个点不动、显示问号的小方块。
        let before = items.count
        items.removeAll { $0.kind == .feature && HomeFeature(rawValue: $0.value) == nil }
        if items.count != before { save() }
        loadIconsFromDisk()
    }

    // MARK: - 增删改

    /// 加一个网址格子（地址会自动补 https:// 并按 host 去重）
    @discardableResult
    func addURL(_ raw: String, title: String = "") -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return false }
        if items.contains(where: { $0.kind == .url && $0.value == s }) { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var it = HomeItem(kind: .url, value: s,
                          title: name.isEmpty ? Self.defaultTitle(for: u) : name)
        it.iconFile = "\(it.id.uuidString).png"
        items.append(it)
        save()
        Task { await fetchIcon(for: it) }      // 抓到就刷新图标，抓不到用首字母
        return true
    }

    func addFeature(_ f: HomeFeature) {
        guard !items.contains(where: { $0.kind == .feature && $0.value == f.rawValue }) else { return }
        items.append(HomeItem(kind: .feature, value: f.rawValue, title: f.title))
        save()
    }

    func remove(_ item: HomeItem) {
        items.removeAll { $0.id == item.id }
        if !item.iconFile.isEmpty {
            try? FileManager.default.removeItem(at: Self.iconsDir.appendingPathComponent(item.iconFile))
            icons[item.iconFile] = nil
        }
        save()
    }

    /// 长按 →「移到最前」
    func moveToTop(_ item: HomeItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), i > 0 else { return }
        let it = items.remove(at: i)
        items.insert(it, at: 0)
        save()
    }

    func rename(_ item: HomeItem, to newName: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        items[i].title = n
        save()
    }

    // MARK: - 图标

    func icon(for item: HomeItem) -> UIImage? {
        guard !item.iconFile.isEmpty else { return nil }
        return icons[item.iconFile]
    }

    /// 把还没有图标的网址格子补齐（打开首页时调一次）
    func refreshMissingIcons() {
        let missing = items.filter { $0.kind == .url && icon(for: $0) == nil }
        guard !missing.isEmpty else { return }
        for it in missing { Task { await fetchIcon(for: it) } }
    }

    /// 抓站点自己的 favicon。**只试 /favicon.ico**：绝大多数站都在那儿，
    /// 再往下挖 <link rel="icon"> 需要先下整页 HTML，为首页这点事不值得。
    private func fetchIcon(for item: HomeItem) async {
        guard item.kind == .url, let u = URL(string: item.value),
              let scheme = u.scheme, let host = u.host, !host.isEmpty else { return }
        if icons[item.iconFile] != nil { return }
        let candidates = ["\(scheme)://\(host)/favicon.ico"]
        for s in candidates {
            if let img = await Self.downloadIcon(s) {
                if let data = img.pngData() {
                    try? data.write(to: Self.iconsDir.appendingPathComponent(item.iconFile),
                                    options: .atomic)
                    icons[item.iconFile] = img     // @Published → 界面立刻换上
                }
                return
            }
        }
    }

    private static func downloadIcon(_ s: String) async -> UIImage? {
        guard let u = URL(string: s) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.setValue(Self.safariUA, forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        do {
            let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, !data.isEmpty, data.count <= 512 * 1024 else { return nil }
            guard let img = UIImage(data: data), img.size.width >= 8 else { return nil }
            return img
        } catch { return nil }
    }

    private static let safariUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    private func loadIconsFromDisk() {
        for it in items where !it.iconFile.isEmpty {
            let f = Self.iconsDir.appendingPathComponent(it.iconFile)
            if let d = try? Data(contentsOf: f), let img = UIImage(data: d) {
                icons[it.iconFile] = img
            }
        }
    }

    // MARK: - 落盘

    private static func readFromDisk() -> [HomeItem] {
        guard let d = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([HomeItem].self, from: d) else { return [] }
        return list
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - 显示辅助

    /// 没抓到图标时显示的「首字母」：中文取第一个字，英文/数字取大写首字母
    static func initial(for item: HomeItem) -> String {
        let n = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let src = n.isEmpty ? (URL(string: item.value)?.host ?? "?") : n
        guard let c = src.first else { return "?" }
        return String(c).uppercased()
    }

    /// 没抓到图标时的兜底名（host 去掉 www.）
    private static func defaultTitle(for u: URL) -> String {
        var h = u.host ?? u.absoluteString
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }
}
