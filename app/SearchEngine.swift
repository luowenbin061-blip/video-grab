import Foundation

/// 地址栏「输的不是网址就去搜」—— 搜哪儿由这里定（v1.0.205）。
///
/// ★ 为什么单独一个小文件：设置页要它（给选项）、地址栏要它（拼搜索地址），
///   两边都不该依赖对方，塞在一个中立的小类型里最干净。
enum SearchEngine: String, CaseIterable, Identifiable {
    case baidu, bing, sogou, google, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baidu:  return "百度"
        case .bing:   return "必应"
        case .sogou:  return "搜狗"
        case .google: return "谷歌"
        case .custom: return "自定义"
        }
    }

    /// 链接模板，`%@` 是查询词占位
    var template: String {
        switch self {
        case .baidu:  return "https://www.baidu.com/s?wd=%@"
        case .bing:   return "https://cn.bing.com/search?q=%@"
        case .sogou:  return "https://www.sogou.com/web?query=%@"
        case .google: return "https://www.google.com/search?q=%@"
        case .custom: return Self.customTemplate
        }
    }

    // MARK: - 存取

    static let key = "searchEngine"
    static let customKey = "searchEngineCustom"
    static let defaultTemplate = "https://www.baidu.com/s?wd=%@"

    /// 自定义模板。**必须含 `%@`**，否则当没填（不然点搜索会跳到一个残缺地址）。
    static var customTemplate: String {
        let t = UserDefaults.standard.string(forKey: customKey) ?? ""
        return t.contains("%@") ? t : defaultTemplate
    }

    static var current: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .baidu
    }

    // MARK: - 拼地址

    /// 查询词 → 搜索地址。
    ///
    /// ★★ 编码只用 **unreserved 字符集**（字母数字和 `-._~`）：
    ///   系统那个 `.urlQueryAllowed` **保留 `&` `=` `?`** —— 查询词里带个 `&`
    ///   就会把搜索链接的参数拆坏（搜"A&B"变成搜"A"再传个 B 参数）。
    func url(for query: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let q = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let t = template.contains("%@") ? template : Self.defaultTemplate
        return t.replacingOccurrences(of: "%@", with: q)
    }
}
