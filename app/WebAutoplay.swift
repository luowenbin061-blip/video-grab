import Foundation
import WebKit

/// 「网页媒体自动播放」的四档策略（★ v1.0.230，用户 2026-10-07 提的需求）。
///
/// 他要的是：**限制某些会自动播的网页，同时也能让网页视频自动播**；
/// 而且**要区分音频和视频**（有的人只想拦视频、留着背景音乐）。
///
/// ★ 系统 API 正好就是四档，一一对应（`WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback`）：
///   | 选项 | 取值 |
///   |---|---|
///   | 允许视频和音频自动播放 | `[]` |
///   | 禁止音频自动播放 | `.audio` |
///   | 禁止视频自动播放 | `.video` |
///   | 禁止视频和音频自动播放 | `[.audio, .video]` |
enum WebAutoplay: String, CaseIterable, Identifiable {

    case all = "all"
    case noAudio = "noAudio"
    case noVideo = "noVideo"
    case none = "none"

    /// 设置页的 @AppStorage 绑这个键
    static let key = "webAutoplayPolicy"

    var id: String { rawValue }

    /// 当前策略。★ **默认「允许全部」** —— 跟以前完全一致（原来是写死的 `[]`），
    ///   用户 2026-10-07 拍板"默认不要收紧"（他当初就是为让页面自己跑视频才那么设的）。
    static var current: WebAutoplay {
        WebAutoplay(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .all
    }

    /// 把这一档落到系统那个属性上（唯一的使用处：`BrowserModel.makeRawWebView`）。
    ///
    /// ★★ 故意**不把这个 OptionSet 的类型名写进签名** —— 直接赋值让编译器按属性类型推断。
    ///   理由：那个类型名（`WKAudiovisualMediaTypes`）只要有一个字母偏差就编不过，
    ///   而本地没有 Xcode、只能靠云编译，一次白跑就是几分钟。
    ///   **少写一个类型名 = 少一个"名字写错"的风险点**（这个坑项目里踩过）。
    func apply(to cfg: WKWebViewConfiguration) {
        switch self {
        case .all: cfg.mediaTypesRequiringUserActionForPlayback = []
        case .noAudio: cfg.mediaTypesRequiringUserActionForPlayback = .audio
        case .noVideo: cfg.mediaTypesRequiringUserActionForPlayback = .video
        case .none: cfg.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        }
    }

    /// ★★ 给注入脚本用（`sniffer.js` 里那两个占位行）。
    ///
    /// 为什么必须再有这一层：系统那层**只拦得住"带声音"的自动播** ——
    /// 而"网页自己就播起来"最常见的形态恰好是**静音自动播**（`<video muted autoplay>`，
    /// 或页面自己设 muted 再 play），WebKit 对静音视频通常是单独放行的。
    /// 用户明确要求「静音自动播也要管住」，所以这一层不能省。
    var blockAudio: Bool { self == .noAudio || self == .none }
    var blockVideo: Bool { self == .noVideo || self == .none }

    /// 设置页里那个选项的名字（**名字就把事说清**，不另外写说明 —— 用户定的规矩）
    var title: String {
        switch self {
        case .all: return "允许视频和音频自动播放"
        case .noAudio: return "禁止音频自动播放"
        case .noVideo: return "禁止视频自动播放"
        case .none: return "禁止视频和音频自动播放"
        }
    }

    /// 上一级那一行右侧的摘要（让人不进二级页也知道现在是什么状态）
    var short: String {
        switch self {
        case .all: return "都允许"
        case .noAudio: return "只拦音频"
        case .noVideo: return "只拦视频"
        case .none: return "都禁止"
        }
    }
}
