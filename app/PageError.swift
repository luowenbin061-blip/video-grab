import SwiftUI

/// 「打不开这个网页」时给用户看的东西（整页覆盖，对齐 Safari）。
///
/// ★ 为什么要有这一层：原来加载失败只在屏幕上闪一行小字，1.8 秒就没了 ——
///   用户根本来不及看清是"没网"还是"地址错了"还是"证书有问题"，
///   感觉就是"点了没反应"。Safari 的做法是**整页告诉你原因**，我们照做。
struct PageError: Equatable {

    /// 大标题：一句人话（绝不出现 -1003 这种错误码）
    let title: String
    /// 具体原因 + 能做什么
    let reason: String
    /// 技术细节（错误域 + 码）。平时不用看，出问题时报出来能直接定位
    let detail: String
    /// 出错的地址（「重试」要用）
    let url: String
    /// 是不是证书问题 —— 是的话多给一个「仍然访问」
    let isCertificate: Bool

    /// 把系统报的错翻成人话。
    ///
    /// ★ 千万别把 NSURLErrorDomain -1003 直接甩给用户 —— 他看不懂，也帮不上忙。
    ///   这张表就是「系统错误 → 用户能理解的话 + 能采取的动作」。
    static func make(fallbackURL: String, error: Error) -> PageError {
        let ns = error as NSError
        // 系统会在 userInfo 里放"真正失败的那个地址"，比我们记的地址准
        let failing = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? fallbackURL

        var title = "打不开这个网页"
        var reason = "出错原因：\(error.localizedDescription)"
        var cert = false

        // ★ URLError.Code(rawValue:) 不是可失败的初始化器（它不做校验），
        //   所以只能先构造、再比较，不能写进 if 的条件绑定里。
        if ns.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: ns.code)
            switch code {
            case .notConnectedToInternet:
                (title, reason) = ("没有网络",
                                   "手机现在连不上网。看一眼 Wi-Fi 或流量是不是断了，然后再点重试。")
            case .timedOut:
                (title, reason) = ("网站没反应",
                                   "等了很久它也没回话。可能是网络太慢，也可能是这个网站本身有问题。")
            case .cannotFindHost:
                (title, reason) = ("找不到这个网站",
                                   "地址可能拼错了，也可能这个网站已经不存在了。")
            case .cannotConnectToHost:
                (title, reason) = ("连不上这个网站",
                                   "服务器拒绝连接 —— 它可能挂了，也可能被当前网络屏蔽了。")
            case .dnsLookupFailed:
                (title, reason) = ("找不到这个网站",
                                   "域名解析失败。换个网络再试试。")
            case .networkConnectionLost:
                (title, reason) = ("网络断了",
                                   "连接中途断开。等一会儿再点重试。")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .secureConnectionFailed:
                cert = true
                title = "这个网站的证书有问题"
                reason = "为了安全，我们没有继续连接。如果你确定这个网站可以信任，可以点下面的「仍然访问」。"
            case .appTransportSecurityRequiresSecureConnection:
                (title, reason) = ("这个网站不让安全连接",
                                   "它要求用不加密的方式连接，被系统拦住了。")
            default:
                break
            }
        } else if ns.domain == "WebKitErrorDomain" && ns.code == 101 {
            (title, reason) = ("这个链接打不开",
                               "系统不认这种链接（它可能不是网页地址）。")
        }

        return PageError(title: title, reason: reason,
                         detail: "\(ns.domain) \(ns.code)",
                         url: failing,
                         isCertificate: cert)
    }

    /// 「这个页面反复把浏览器内核搞崩」—— 不是网络问题，是页面自己的问题。
    /// ★ 为什么要单独一条：崩溃自动重载本来就有，但**没上限** —— 崩→重载→崩会转不停。
    ///   崩够次数就停止自动恢复，把这一页摆成错误页，让用户自己决定要不要再试
    ///   （点「重试」会给一次全新的机会）。
    static func crashGaveUp(url: String, attempts: Int) -> PageError {
        PageError(title: "这个网页一直崩",
                  reason: "它连续 \(attempts) 次把浏览器内核搞崩了，我们就不再自动恢复了 —— "
                        + "再转下去也是白转（还费电）。过一会儿点「重试」，或者换个网页看。",
                  detail: "WebContentProcessDidTerminate ×\(attempts)",
                  url: url,
                  isCertificate: false)
    }
}

/// 错误页本体：整页盖住网页内容（不透明），给原因 + 「重试」。
struct PageErrorView: View {

    let info: PageError
    /// 点「重试」
    let onRetry: () -> Void
    /// 只有证书问题才有的「仍然访问」（其他错误传 nil）
    var onTrust: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // 不透明底 —— 必须盖死下面的网页，否则半透的错位画面更难看
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 13) {
                Image(systemName: info.isCertificate ? "lock.fill" : "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)

                Text(info.title)
                    .font(.system(size: 19, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text(info.reason)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: onRetry) {
                        Text("重试")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 9)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if let onTrust {
                        Button(action: onTrust) {
                            Text("仍然访问")
                                .font(.system(size: 15, weight: .medium))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 9)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 5)

                VStack(spacing: 3) {
                    if !info.url.isEmpty {
                        Text(info.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(info.detail)
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
