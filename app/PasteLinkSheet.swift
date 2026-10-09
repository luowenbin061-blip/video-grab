import SwiftUI
import UIKit

/// 工具箱「粘贴链接」那张卡。
///
/// 界面刻意只留三样：**一个输入框 + 一个开始按钮 + 一行状态**。
/// （用户明确要求过：大段文字说明要砍掉，靠命名让人自明；真需要解释的只留一句。）
///
/// ★ 这里必须显式写 `@MainActor`（跟 `ToolboxView` 同一个理由）：
///   `LinkGrabber` 是 `@MainActor` 类型，包住它的 View 会被推断成 `@MainActor`；
///   写明之后，本视图里那些私有方法（如 `start()`）才在同一个隔离域里，
///   Button 的回调里调它们不会撞上"跨隔离域同步调用"。
@MainActor
struct PasteLinkSheet: View {
    @ObservedObject var grabber: LinkGrabber
    let center: DownloadCenter
    let model: BrowserModel
    @Binding var isPresented: Bool

    private var trimmed: String {
        grabber.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var kind: LinkGrabber.Kind? { LinkGrabber.kind(of: grabber.text) }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {

                // ── 输入框 + 粘贴 ──
                HStack(spacing: 8) {
                    TextField("链接", text: $grabber.text)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { start() }
                    Button("粘贴") {
                        guard let s = UIPasteboard.general.string else { return }
                        // ★ 抠出链接再填：剪贴板里是**整段分享文案**（前面带标题、后面带标点），
                        //   直接把整段塞进来太乱、也不方便核对。
                        //   抠不到就原样填（让上面那行"认不出"的提示来说话）。
                        grabber.text = LinkText.firstLink(in: s) ?? s
                    }
                    .font(.system(size: 14))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // ── 认出类型就报一声（认不出不报，省得吵）──
                if let k = kind {
                    Label(LinkGrabber.hint(for: k), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                }

                // ── 开始 ──
                Button(action: start) {
                    Text("开始")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(trimmed.isEmpty || grabber.busy
                                    ? Color(.tertiarySystemFill) : Color.accentColor)
                        .foregroundStyle(trimmed.isEmpty || grabber.busy ? Color.secondary : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(trimmed.isEmpty || grabber.busy)

                // ── 磁力：BT 引擎那一段（找资源 / 列文件 / 勾选 / 进度 / 下完）──
                //   只在认出来是磁力时出现。引擎是单例，关掉这张卡下载也在跑。
                if kind == .magnet {
                    MagnetCard(engine: MagnetEngine.shared, center: center)
                    Divider()
                }

                // ── 状态 ──
                if grabber.busy {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: max(0.02, grabber.progress))
                        Text(grabber.stage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else if let e = grabber.error {
                    Text(e)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                } else if grabber.done {
                    Text(grabber.stage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(16)
            .navigationTitle("粘贴链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                }
            }
        }
        // ★ 每次打开都是干净的：上一次的进度/错误不该跟着进来
        .onAppear { grabber.reset() }
    }

    private func start() {
        guard !trimmed.isEmpty, !grabber.busy else { return }
        grabber.handle(link: trimmed, center: center, model: model)
    }
}
