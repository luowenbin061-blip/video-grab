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

    /// ★ v1.0.250：观察磁力引擎 —— ①"有任务在跑"时下面那张卡要一直显示
    ///   （哪怕输入框是空的：重开工具箱也能看到它、暂停它、删它）；
    ///   ②换任务前要弹一句确认。
    @ObservedObject private var magnet = MagnetEngine.shared
    /// ★ v1.0.250：换任务确认（当前还有任务在下载时点了「开始」）。
    @State private var showReplaceConfirm = false

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

                // ── B站：清晰度选择（★ v1.0.254：解析完先让用户挑画质）──
                //   条件：有可选档位 + 不在干活 + 没完成。
                //   （下载失败时 busy=false、done=false → 选择区保留，可换个档再点「下载」。）
                if !grabber.qualityOptions.isEmpty && !grabber.busy && !grabber.done {
                    qualityPicker
                }

                // ── 磁力：BT 引擎那一段（找资源 / 列文件 / 勾选 / 进度 / 下完）──
                //   ★ v1.0.250：认出来是磁力、**或者有任务正在跑**都要显示 ——
                //   以前只看输入框：重开工具箱时输入框是空的 → 卡片整个消失，
                //   任务明明还在后台跑却找不到入口（用户实测"任务没了"就是这么来的）。
                if kind == .magnet || magnet.running {
                    MagnetCard(engine: magnet, center: center)
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
        // ★ v1.0.250：换任务确认（还有任务在下载时点「开始」）
        .alert("有任务正在下载", isPresented: $showReplaceConfirm) {
            Button("换新任务", role: .destructive) {
                grabber.handle(link: trimmed, center: center, model: model)
            }
            Button("不换", role: .cancel) {}
        } message: {
            Text("开始新任务会停掉并清除当前这条磁力（下载页里已保存的文件不受影响）。")
        }
    }

    /// ★ v1.0.254：B站 解析完成后的清晰度选择区 —— 档位横排 + 登录提示 + 「下载」。
    ///   档位只列**实际下发的**（下得到的）；"更高但没下发"的档在提示行里说明怎么解锁。
    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择清晰度")
                .font(.system(size: 13, weight: .semibold))
            // 档位横排（最多 5-6 个，自适应换行）
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                ForEach(grabber.qualityOptions, id: \.value) { q in
                    Button {
                        grabber.selectedQuality = q.value
                    } label: {
                        Text(q.name)
                            .font(.system(size: 13,
                                          weight: grabber.selectedQuality == q.value
                                              ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(grabber.selectedQuality == q.value
                                        ? Color.accentColor : Color(.secondarySystemBackground))
                            .foregroundStyle(grabber.selectedQuality == q.value
                                             ? Color.white : Color.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !grabber.qualityHint.isEmpty {
                Text(grabber.qualityHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button {
                grabber.downloadSelected(center: center)
            } label: {
                Text("下载")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func start() {
        guard !trimmed.isEmpty, !grabber.busy else { return }
        // ★ v1.0.250：还有任务在下载 → 换新任务会把旧任务顶掉，先问一句。
        if kind == .magnet, magnet.hasActiveTask {
            showReplaceConfirm = true
            return
        }
        grabber.handle(link: trimmed, center: center, model: model)
    }
}
