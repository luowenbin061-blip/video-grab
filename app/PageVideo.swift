import SwiftUI

/// 页面上的一个 `<video>` 元素 —— 由 `sniffer.js` 上报（独立于「自动嗅探」开关）。
///
/// ★ 它不是「一个可播地址」，只是「页面上有这么个视频盒子」。
///   能不能播要另看两件事：① 它自己的 `src`（是 `blob:` 就拿不到）；
///   ② 嗅探结果里有没有对得上的 `hls` / `file` 候选。
struct PageVideo: Identifiable, Equatable {
    var id: Int { i }
    let i: Int
    let src: String          // 能直接播的地址；blob 时为空
    let blob: Bool
    let playing: Bool
    let muted: Bool
    let autoplay: Bool
    let controls: Bool
    let dur: Int             // 秒
    let w: Int
    let h: Int
    let area: Int            // 占屏百分比
    let center: Bool

    /// 「更像正片还是更像广告」的粗打分。
    ///
    /// ★ 不用单一条件判断 —— "正在播"和"面积最大"都**不够**：
    ///   自动播放的静音广告同样符合这两条。所以让几个信号凑分，
    ///   分低时**不自动播**，改成弹列表让用户自己选。
    var confidence: Int {
        var s = 0
        if !muted { s += 3 }                 // 有声音 → 通常是正片
        if dur >= 120 { s += 3 }
        else if dur >= 60 { s += 2 }
        else if dur >= 20 { s += 1 }
        if area >= 25 { s += 2 }             // 占屏够大
        else if area >= 10 { s += 1 }
        if center { s += 1 }                 // 位于视口中心
        if controls { s += 1 }               // 带控制条
        if playing { s += 1 }
        if autoplay && muted { s -= 4 }      // 自动播 + 静音 = 典型广告特征
        return s
    }

    /// 够不够格「只有一个就直接播」。
    var isConfident: Bool { confidence >= 6 }

    /// 一行说明（列表里显示用）。
    var summary: String {
        var parts: [String] = []
        if playing { parts.append("正在播放") }
        if dur > 0 {
            let m = dur / 60, s = dur % 60
            parts.append(m > 0 ? String(format: "%d 分 %d 秒", m, s) : String(format: "%d 秒", s))
        }
        parts.append(String(format: "%d×%d", w, h))
        if area > 0 { parts.append("占屏 \(area)%") }
        if muted { parts.append("静音") }
        return parts.joined(separator: " · ")
    }

    /// 解析 JS 上报（字段缺了就用安全默认值，绝不因为一条脏数据整份丢掉）。
    static func parse(_ body: [String: Any]) -> [PageVideo] {
        guard let raw = body["videos"] as? [[String: Any]] else { return [] }
        var out: [PageVideo] = []
        for (idx, d) in raw.enumerated() {
            func int(_ k: String, _ def: Int = 0) -> Int {
                if let n = d[k] as? Int { return n }
                if let n = d[k] as? Double { return Int(n) }
                if let n = d[k] as? NSNumber { return n.intValue }
                return def
            }
            func bool(_ k: String) -> Bool {
                if let b = d[k] as? Bool { return b }
                if let n = d[k] as? NSNumber { return n.boolValue }
                return false
            }
            out.append(PageVideo(
                i: int("i", idx),
                src: (d["src"] as? String) ?? "",
                blob: bool("blob"),
                playing: bool("playing"),
                muted: bool("muted"),
                autoplay: bool("autoplay"),
                controls: bool("controls"),
                dur: int("dur"),
                w: int("w"),
                h: int("h"),
                area: int("area"),
                center: bool("center")))
        }
        return out
    }
}

/// 「这页有多个视频」时弹的选择卡片。
///
/// ★ 只列**本页的 video**（不是嗅探到的全部媒体）—— 这是它跟「嗅探结果」面板的分工：
///   那边是「全量网络媒体 + 下载」，这里是「本页视频 + 一键盘」。
struct PageVideoPicker: View {
    let videos: [PageVideo]
    let hasCandidates: Bool                 // 嗅探结果里有没有能播的候选
    let onPlay: (PageVideo) -> Void
    let onOpenSniff: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(videos.sorted { $0.confidence > $1.confidence }) { v in
                        Button {
                            onPlay(v)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: v.playing ? "play.circle.fill" : "play.rectangle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(v.src.isEmpty ? Color.secondary : Color.blue)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text("视频 \(v.i + 1)")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.primary)
                                        if v.playing {
                                            Text("正在播")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.green, in: Capsule())
                                        }
                                        if v.src.isEmpty {
                                            Text("地址待抓")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color(.tertiarySystemFill), in: Capsule())
                                        }
                                    }
                                    Text(v.summary)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(hasCandidates
                         ? "点一条就用内置播放器播 —— 网页上那些盖在视频上的浮层（倒计时广告、遮罩）都不会出现。"
                         : "这页的视频地址还没抓到。**先去网页里点一下播放**，再回来点这里。")
                }
                Section {
                    Button("在嗅探结果里看（可下载）") {
                        dismiss()
                        onOpenSniff()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("本页视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
