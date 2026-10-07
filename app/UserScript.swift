import Foundation

/// 一条用户脚本（油猴那套的简化版）。
///
/// ★ 为什么要有这个体系（用户 2026-10-07 拍板）：他要在设置里**能自己导入脚本**，
///   并且先把最想要的那件事（自动播放网页视频）做成**第一个内置脚本**。
///   用户脚本 = 一段在网页里跑的 JS，靠 `@match` 决定对哪些网站生效。
///
/// ★ 存储分两处（**代码绝不塞 UserDefaults** —— 几 KB 起，会让 App 启动时全量加载）：
///   · **内置脚本**：代码在 App 包里（`resources/userscript-*.js`），只读、不能删；
///   · **导入的脚本**：代码在 `Application Support/UserScripts/<id>.js`，
///     清单是同目录下的 `manifest.json`（很小，启动时只读它）。
///
/// ★ 本文件只 import Foundation → **同时编进 App 和 CI 回归集**
///   （`@match` 的匹配规则是"光看代码看不出对错"的那类，必须跑）。
struct UserScript: Identifiable, Codable, Equatable {
    /// 稳定标识：内置的写死（`builtin.*`），导入的是 UUID 串
    var id: String
    /// 显示名（油猴 `@name`；没有就"未命名脚本"）
    var name: String
    /// 油猴 `@match` 规则；**空数组 = 全部网站**
    var matches: [String]
    /// 只影响"下次加载页面时注不注入"（已经打开的页面要重载）
    var enabled: Bool
    /// 内置脚本：代码在 App 包里，**不能改也不能删**
    var builtin: Bool
    /// 一行说明（`@description`）
    var desc: String

    /// 是不是对所有网站生效（设置页里显示"全部网站"用）
    var isEverywhere: Bool {
        matches.isEmpty || matches.contains("*://*/*")
    }

    /// 设置页那一行右边的小字：全部网站 / 几个网站
    var scopeText: String {
        isEverywhere ? "全部网站"
                     : (matches.count == 1 ? matches[0] : "\(matches.count) 个网站")
    }
}

// MARK: - 油猴头部解析

/// 解析脚本头上那段 `// ==UserScript== … // ==/UserScript==`。
///
/// ★ 要**宽容**：用户粘进来的脚本头部经常不规范 —— 可能没有 `@name`、
///   可能用 CRLF、可能有 BOM、可能字段名大小写混着写。解析器一律不报错，
///   缺什么就用默认值补（缺 `@name` → "未命名脚本"；缺 `@match` → 全部网站）。
enum UserScriptHeader {

    struct Info {
        var name = ""
        var matches: [String] = []
        var desc = ""
    }

    static func parse(_ code: String) -> Info {
        var info = Info()
        var s = code.replacingOccurrences(of: "\r\n", with: "\n")
                     .replacingOccurrences(of: "\r", with: "\n")
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }

        var inside = false
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if !inside {
                // 宽松：只要那一行里出现这个标记就算开头
                if line.contains("==UserScript==") { inside = true }
                continue
            }
            if line.contains("==/UserScript==") { break }

            // 头部里每一行都是注释；遇到真正的一行代码说明头部到头了
            var body = line
            if body.hasPrefix("//") {
                body = String(body.dropFirst(2))
            } else if body.hasPrefix("/*") {
                body = body.replacingOccurrences(of: "/*", with: "")
                           .replacingOccurrences(of: "*/", with: "")
            } else if body.isEmpty {
                continue
            } else {
                break
            }

            let t = body.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("@") else { continue }
            let parts = t.dropFirst().split(maxSplits: 1, omittingEmptySubsequences: true,
                                            whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = parts.first.map(String.init) else { continue }
            let val = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            switch key.lowercased() {
            case "name":
                if info.name.isEmpty { info.name = val }
            case "match", "include":
                if !val.isEmpty { info.matches.append(val) }
            case "description":
                if info.desc.isEmpty { info.desc = val }
            default:
                break
            }
        }
        return info
    }
}

// MARK: - @match 匹配

/// 油猴 `@match` 的匹配（`<scheme>://<host><path>` 三段，通配符只支持 `*`）。
///
/// ★ 规则（跟浏览器扩展那套对齐，也就是用户在别处见惯的行为）：
///   · scheme：`*` 或精确相等（忽略大小写）
///   · host：`*` 全匹配；`*.example.com` 匹配 **example.com 本身和它的子域**
///     （★ 这条是有意放宽的：用户写 `*.example.com` 的意思就是"这个站自己也算"，
///       按"只算子域"实现会让 `example.com` 反而不生效 —— 那是更常见的踩坑）
///   · path：`*` 任意；**query 和 hash 不参与匹配**
///
/// ★ JS 侧（注入进网页的那份）有同一套算法的精简版；两边靠同一批用例守住
///   （Swift 这边跑 CI，JS 那边跑 `_probe_tmp` 的行为回归）。
enum UserScriptMatch {

    /// 任意一条规则命中就算命中；**规则为空 = 全部网站**
    static func hitAny(_ patterns: [String], _ url: URL) -> Bool {
        let list = patterns.isEmpty ? ["*://*/*"] : patterns
        for p in list where hit(p, url) { return true }
        return false
    }

    static func hit(_ pattern: String, _ url: URL) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let sep = p.range(of: "://") else { return false }

        let pScheme = String(p[p.startIndex..<sep.lowerBound]).lowercased()
        if pScheme != "*" && pScheme != scheme { return false }

        let rest = String(p[sep.upperBound...])
        let pHost: String
        let pPath: String
        if let slash = rest.firstIndex(of: "/") {
            pHost = String(rest[rest.startIndex..<slash]).lowercased()
            pPath = String(rest[slash...])
        } else {
            pHost = rest.lowercased()
            pPath = "/*"
        }
        if !hostHit(pHost, host) { return false }

        let path = url.path.isEmpty ? "/" : url.path
        return glob(pPath, path)
    }

    /// host 那一节的匹配（见上面 `*.` 的口径）
    static func hostHit(_ pattern: String, _ host: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let base = String(pattern.dropFirst(2))
            return host == base || host.hasSuffix("." + base)
        }
        return pattern == host
    }

    /// 只认 `*` 的通配匹配（经典回溯写法；`?` 在这里是**普通字符**）
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count && p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// 导入时用来提醒：这条规则看着就不对（比如忘了写 `://`）
    static func looksValid(_ pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard p.contains("://") else { return false }
        guard let sep = p.range(of: "://") else { return false }
        let host = String(p[sep.upperBound...]).split(separator: "/").first.map(String.init) ?? ""
        return !host.isEmpty
    }
}
