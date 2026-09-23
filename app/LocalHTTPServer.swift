import Foundation
import Network

/// 一个只服务本机的极简 HTTP 文件服务器。
///
/// 为什么需要它：
///   iOS 的 AVFoundation **读不了本地 MPEG-TS 文件**——Apple 官方论坛明确说
///   "TS files are not and will not be supported on iOS. You must use fMP4."
///   报错就是 `无法打开 / 不支持此媒体格式`，而且是在 AVURLAsset 建轨道时就失败。
///   但它**支持通过 HTTP 以 HLS 的形式播 TS**（AVPlayer 播 m3u8 就是这个机制）。
///
///   所以：把下载好的分片留在磁盘上，用这个服务器在本机 HTTP 暴露出去，
///   再让 AVPlayer 去播 `http://127.0.0.1:port/media/index.m3u8` —— 就能播了。
///   而且这条 HTTP 通道也能让 AVAssetReader 读到轨道，从而导出 mp4。
///
/// 只监听 127.0.0.1，不对外。支持 Range，因为播放器偶尔会要。
final class LocalHTTPServer {

    static let shared = LocalHTTPServer()

    private let queue = DispatchQueue(label: "vg.localhttp")
    private var listener: NWListener?
    private var running = false

    /// 服务器根目录（分片和 m3u8 放在这里）
    private var root: URL?
    private(set) var port: UInt16 = 0

    private init() {}

    // MARK: - 生命周期

    /// 启动（幂等）。root 是要对外暴露的目录。
    @discardableResult
    func start(root: URL) -> UInt16? {
        self.root = root
        if running, port > 0 { return port }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 只绑本机回环，别让局域网能访问
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state {
                    NSLog("LocalHTTPServer 失败: \(e)")
                }
            }
            l.start(queue: queue)
            listener = l
            running = true

            // 等端口分配好（最多 2 秒）
            let deadline = Date().addingTimeInterval(2)
            while l.port == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if let p = l.port {
                port = p.rawValue
                return port
            }
            return nil
        } catch {
            NSLog("LocalHTTPServer 起不来: \(error)")
            return nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        port = 0
    }

    /// 拿到某个相对路径的播放地址
    func url(_ relativePath: String) -> URL? {
        guard port > 0 else { return nil }
        let clean = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        return URL(string: "http://127.0.0.1:\(port)/\(clean)")
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            if error != nil {
                conn.cancel()
                return
            }

            // 请求头以 \r\n\r\n 结束
            if let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
                self.respond(conn, requestHead: head)
                return
            }
            if isComplete || buf.count > 32 * 1024 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let lines = requestHead.components(separatedBy: "\r\n")
        guard let first = lines.first else { conn.cancel(); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendSimple(conn, status: 405, reason: "Method Not Allowed", body: Data())
            return
        }

        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("/") { path = String(path.dropFirst()) }
        if path.isEmpty { path = "index.m3u8" }

        guard let root else { sendSimple(conn, status: 404, reason: "Not Found", body: Data()); return }

        // 防目录穿越
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path) else {
            sendSimple(conn, status: 403, reason: "Forbidden", body: Data())
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
              !isDir.boolValue,
              let fh = try? FileHandle(forReadingFrom: target) else {
            sendSimple(conn, status: 404, reason: "Not Found", body: Data())
            return
        }
        defer { try? fh.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
        let total = (attrs?[.size] as? Int) ?? 0
        let mime = Self.mimeType(for: target.pathExtension)

        // Range？
        var rangeStart = 0
        var rangeEnd = total - 1
        var partial = false
        for l in lines where l.lowercased().hasPrefix("range:") {
            let v = l.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            if let r = v.range(of: "bytes=") {
                let spec = v[r.upperBound...]
                let comps = spec.split(separator: "-", omittingEmptySubsequences: false)
                if let s = Int(comps.first ?? ""), s >= 0 {
                    rangeStart = s
                    if comps.count > 1, let e = Int(comps[1]), e >= s { rangeEnd = min(e, total - 1) }
                    partial = true
                } else if comps.count > 1, let e = Int(comps[1]) {
                    // bytes=-N 形式
                    rangeStart = max(0, total - e)
                    rangeEnd = total - 1
                    partial = true
                }
            }
        }

        if rangeStart > rangeEnd || rangeStart >= total {
            sendSimple(conn, status: 416, reason: "Range Not Satisfiable", body: Data())
            return
        }

        let length = rangeEnd - rangeStart + 1
        var header = ""
        header += partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if partial {
            header += "Content-Range: bytes \(rangeStart)-\(rangeEnd)/\(total)\r\n"
        }
        header += "Connection: close\r\n\r\n"

        try? fh.seek(toOffset: UInt64(rangeStart))
        let body = (try? fh.read(upToCount: length)) ?? Data()

        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func sendSimple(_ conn: NWConnection, status: Int, reason: String, body: Data) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "m4s": return "video/iso.segment"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
