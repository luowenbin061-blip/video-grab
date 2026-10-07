import Foundation
import Combine

/// 用户脚本的清单与代码（单例）。
///
/// ★ 目录：`Library/Application Support/UserScripts/`
///   —— **故意不放进 `JobStore.dir`**：那个目录是「共享给电脑」的根，
///     放进去等于同一 Wi-Fi 下拿到口令的人也能下载这里的脚本。
///
/// ★ 内置脚本**不落盘**：代码每次从 App 包里读（`resources/userscript-*.js`），
///   所以换一版包，内置脚本自动就是新的 —— 不会出现"用户目录里还留着旧版内置脚本"。
///   只有它的**开关状态**落在 UserDefaults 里（极小，就一个布尔）。
///
/// ★ 导入的脚本：代码落 `UserScripts/<id>.js`，清单元数据落 `manifest.json`。
///   清单很小，启动时读它；代码按需读。
final class UserScriptStore: ObservableObject {

    static let shared = UserScriptStore()

    /// 内置脚本：`resources` 里的文件名（不带扩展名）→ 出厂默认是否开着。
    /// ★ 自动播放这个**默认开** —— 他要的就是这个功能，装上就该能用。
    static let builtins: [(file: String, on: Bool)] = [
        ("userscript-autoplay", true),
    ]

    /// 导入脚本的代码大小上限（超过就是异常脚本，挡在门外）
    static let maxBytes = 200 * 1024

    @Published private(set) var scripts: [UserScript] = []

    /// 内置脚本的开关状态（键 = 脚本 id）
    private static let onKey = "userScriptBuiltinOn"

    private let dir: URL
    private var manifestURL: URL { dir.appendingPathComponent("manifest.json") }

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("UserScripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 读清单

    private func load() {
        var out: [UserScript] = []
        let on = UserDefaults.standard.dictionary(forKey: Self.onKey) as? [String: Bool] ?? [:]

        // ① 内置：代码和头部都从包里读（名字 / 说明 / @match 只有一处定义 —— 就在 js 里）
        for b in Self.builtins {
            let src = Self.bundleSource(b.file)
            let head = UserScriptHeader.parse(src)
            let id = "builtin." + b.file
            out.append(UserScript(id: id,
                                  name: head.name.isEmpty ? b.file : head.name,
                                  matches: head.matches,
                                  enabled: on[id] ?? b.on,
                                  builtin: true,
                                  desc: head.desc))
        }

        // ② 导入的：读 manifest.json
        if let d = try? Data(contentsOf: manifestURL),
           let list = try? JSONDecoder().decode([UserScript].self, from: d) {
            for var s in list where !s.builtin {
                // 代码文件不在了（被系统清过 / 手动删过）→ 这条就是坏的，丢掉
                guard FileManager.default.fileExists(atPath: fileURL(s).path) else { continue }
                s.builtin = false
                out.append(s)
            }
        }
        scripts = out
    }

    private func saveManifest() {
        let list = scripts.filter { !$0.builtin }
        if let d = try? JSONEncoder().encode(list) {
            try? d.write(to: manifestURL, options: .atomic)
        }
    }

    // MARK: - 代码

    private func fileURL(_ s: UserScript) -> URL {
        dir.appendingPathComponent(s.id + ".js")
    }

    private static func bundleSource(_ name: String) -> String {
        guard let u = Bundle.main.url(forResource: name, withExtension: "js"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s
    }

    /// 取某条脚本的源码（内置从包里读，导入的从文件读）
    func sourceCode(of s: UserScript) -> String {
        if s.builtin {
            return Self.bundleSource(String(s.id.dropFirst("builtin.".count)))
        }
        return (try? String(contentsOf: fileURL(s), encoding: .utf8)) ?? ""
    }

    /// 给注入用的：当前启用、且代码非空的脚本 + 源码
    var enabledSources: [(script: UserScript, code: String)] {
        scripts.filter { $0.enabled }.compactMap { s in
            let c = sourceCode(of: s)
            return c.isEmpty ? nil : (s, c)
        }
    }

    // MARK: - 改

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].enabled = on
        if scripts[i].builtin {
            var d = UserDefaults.standard.dictionary(forKey: Self.onKey) as? [String: Bool] ?? [:]
            d[id] = on
            UserDefaults.standard.set(d, forKey: Self.onKey)
        } else {
            saveManifest()
        }
    }

    func remove(_ id: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }), !scripts[i].builtin else { return }
        let s = scripts[i]
        try? FileManager.default.removeItem(at: fileURL(s))
        scripts.remove(at: i)
        saveManifest()
    }

    /// 改一条导入脚本的代码（内置的不给改）
    func updateCode(_ id: String, _ code: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }), !scripts[i].builtin else { return }
        let head = UserScriptHeader.parse(code)
        if !head.name.isEmpty { scripts[i].name = head.name }
        if !head.matches.isEmpty { scripts[i].matches = head.matches }
        scripts[i].desc = head.desc
        try? code.data(using: .utf8)?.write(to: fileURL(scripts[i]), options: .atomic)
        saveManifest()
    }

    // MARK: - 导入

    enum ImportError: LocalizedError {
        case empty
        case tooBig
        case duplicate

        var errorDescription: String? {
            switch self {
            case .empty:     return "这个文件是空的。"
            case .tooBig:    return "脚本太大了（超过 200KB），不像是正常的用户脚本。"
            case .duplicate: return "同样的脚本已经在了。"
            }
        }
    }

    /// 导入一段脚本代码（粘贴或从文件读进来的都走这里）。
    /// ★ 头部解析宽容：没有 `@name` 就叫「未命名脚本」，没有 `@match` 就对所有网站生效。
    @discardableResult
    func importCode(_ code: String) throws -> UserScript {
        let src = code.replacingOccurrences(of: "\r\n", with: "\n")
        guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.empty
        }
        guard src.utf8.count <= Self.maxBytes else { throw ImportError.tooBig }

        // 完全一样的代码重复导入 → 挡住（免得列表里出现一堆同名项）
        for s in scripts where !s.builtin && sourceCode(of: s) == src {
            throw ImportError.duplicate
        }

        let head = UserScriptHeader.parse(src)
        let s = UserScript(id: UUID().uuidString,
                           name: head.name.isEmpty ? "未命名脚本" : head.name,
                           matches: head.matches,
                           enabled: true,
                           builtin: false,
                           desc: head.desc)
        try? Data(src.utf8).write(to: fileURL(s), options: .atomic)
        scripts.append(s)
        saveManifest()
        return s
    }
}
