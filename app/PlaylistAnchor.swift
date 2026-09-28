import Foundation

/// 播放清单里的"锚点"挑选 —— **纯字符串逻辑，不碰网络也不碰文件**。
///
/// 为什么要单独一个文件：它必须能在**测试目标**里单独编译（那个目标不链 ffmpeg，
/// 所以只能在模拟器上跑纯逻辑）。放在 `PlaylistRelay` 里就带不动了（那个文件依赖
/// 本机服务、JobStore 等）。
///
/// ══ 它是干什么的 ══
/// 有些站会把「广告 + 正片 + 广告」拼成一份清单（三段来自不同视频、不同目录、不同钥匙）。
/// 而广告和正片的**视频参数往往不一样**（实测 1280×720 vs 1280×2276）——
/// 拼进同一个 MP4 后，播放器放到第二段就"只出声音、画面停在广告最后一帧"。
/// 所以我们要先把"哪一段才是用户要的"认出来，只保留那一段。
///
/// ══ 怎么认（以及两条踩过的坑）══
/// 拿**用户请求的那个地址**路径里的一串目录名当候选（从深到浅），
/// 逐个去问"你能把分片分成两堆吗"——**能分成两堆的才算数**：
///   · 谁能分出"有匹配也有不匹配"，就用谁（真片带这个名字、广告不带）；
///   · 谁都分不出来 → 返回 nil，调用方**全下**（绝不误删真片）。
/// ★ v1.0.147 的坑：曾经拿"清单所在目录"当锚点 —— 但清单是 master 挑出来的**变体**，
///   所在目录是 `hls`，而**每个分片地址里都有 hls** → 全都"匹配" → 过滤静默失效。
///   所以必须"试一组候选 + 要求能分成两堆 + 分不出来就报出来"。
enum PlaylistAnchor {

    /// 挑出来的结果
    struct Pick: Equatable {
        let anchor: String
        let matched: Int
        let missed: Int
    }

    /// 从若干候选地址里提取"目录名候选"：从深到浅，去重，太短的（<4 字）不要、
    /// 根路径 `/` 不要。域名也会进候选 —— 它匹配全部，分不成两堆，自然会被筛掉。
    static func candidates(from urls: [URL]) -> [String] {
        var out: [String] = []
        for u in urls {
            for p in u.deletingLastPathComponent().pathComponents.reversed() {
                if p.count >= 4, p != "/", !out.contains(p) { out.append(p) }
            }
        }
        return out
    }

    /// 逐候选试：谁能"分成两堆"（有匹配也有不匹配）就用谁；都不行返回 nil。
    static func pick(segmentURLStrings: [String], candidates: [String]) -> Pick? {
        for cand in candidates {
            var m = 0, x = 0
            for s in segmentURLStrings {
                if s.contains(cand) { m += 1 } else { x += 1 }
            }
            if m > 0, x > 0 { return Pick(anchor: cand, matched: m, missed: x) }
        }
        return nil
    }
}
