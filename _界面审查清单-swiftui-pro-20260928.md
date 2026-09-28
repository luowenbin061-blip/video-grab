# VideoGrab 界面代码审查清单（swiftui-pro 手册 · 2026-09-28）

**审查范围**：`app/*.swift` 共 46 个文件
**前提约束（本次审查全程按这个过滤）**：iOS 15.0 部署目标 · Xcode 15.4 / Swift 5.10 · TrollStore 免签 · 大文件多年积累不拆
**方法**：按手册 9 个分册的规则逐条落到代码上；规则不适用我们环境的**明确标注"不适用"**，不凑数。

---

## 一、真问题（建议改）

### ① `ContentView.swift:68` —— 每次界面刷新都在**扫整个下载目录**（唯一一条值得动的）

```swift
var usedSpace: Int64 { JobStore.totalSize() }
```

- **问题**：`JobStore.totalSize()` 会遍历整个下载目录（可能要统计几百 MB 的成品 + 上千个分片文件）。
  而这是 `DownloadCenter`（`@MainActor`）上的**计算属性**：只要界面读到它、或者任务列表有任何变化触发重渲染，
  **就在主线程上跑一次磁盘遍历**。
- **手册依据**：performance.md —— "假设 `body` 会被频繁调用；能在里面做的排序/过滤等逻辑应尽量移出"、
  "view 初始化要尽量轻，非平凡的工作挪到 `task()` 里"。
- **为什么算真问题**：这和今天修掉的「删除/清理时页面卡死」是**同一类**（主线程干磁盘活），
  只是入口不同 —— 那条是"点删除"，这条是"渲染列表/看已用空间"。
- **修法（两选一）**：
  1. **缓存 + 显式失效**：删完/下完/清完时更新一个 `@Published var usedSpaceCache`，界面只读缓存；
     （手册也提醒：缓存必须配失效逻辑，否则会显示旧值）
  2. 或不缓存，但**挪出主线程**：`task { usedSpace = await Task.detached { JobStore.totalSize() }.value }`。
- **代价**：小（改 1 处 + 3~4 个更新点）。

### ② P2 · 列表渲染里的过滤/映射（数据量小，先记账）

| 位置 | 干什么 | 何时值得改 |
|---|---|---|
| `ContentView.swift:1539` | 每次渲染 `center.jobs.filter {}` | 任务上百条时 |
| `ContentView.swift:821 / 937 / 941` | 同上（activeJobs / videoGroups / otherGroups） | 同上 |
| `BookmarksView.swift:206` | 每个分组查一次 `store.marksIn()` | 书签上百条时 |
| `ContentView.swift:67` | `jobs.filter { $0.isActive }.count` | 同上 |

**判断**：我们实际数据量是**几十条量级**，这几条现在**不值得动**（手册的原则对，但收益 < 改动风险）。

---

## 二、手册提到、但**对我们不适用**（不凑数，逐条说明）

| 手册规则 | 我们的情况 | 判定 |
|---|---|---|
| 优先 `@Observable` + `@State`，避免 `ObservableObject`/`@Published`/`@StateObject` | `@Observable` 要 **iOS 17+**；我们部署目标是 15.0 | **不适用**（换不过去） |
| `foregroundColor` → `foregroundStyle`、`cornerRadius` → `clipShape` | 全工程只有 1 处 `cornerRadius`，在 iOS 15 上**它才是对的 API**（新写法要 17） | **不适用** |
| `onAppear` 里的异步工作改用 `task()`（能被自动取消） | 查过的 3 处 `onAppear` 里都是**同步准备**（`preparePiP` / `scanQuietly` / `AppAudio.acquire`），不是异步 | **不适用** |
| 避免 `Binding(get:set:)`，改用 `@State` + `onChange` | 4 处都是"用可选值驱动 alert/sheet"（`deleteTarget != nil`、`renaming != nil`）——这是 iOS 15 上的标准写法，改反而绕 | **低优先**（不值得改） |
| 每个类型拆一个文件 | 与既成事实冲突（ContentView 132KB）；手册也承认这是"项目约定"层面的建议 | **不适用**（我们的约定是集中） |
| 用 SwiftData / `ModelContext.fetchCount()` | 我们不用 SwiftData | **不适用** |
| 无障碍（VoiceOver / Dynamic Type / Reduce Motion）分册 | 自用单机 App，暂不作为本轮目标（**要的话下次单独做一轮**） | **本轮未审** |

---

## 三、干净项（扫了，确实没有）

| 检查 | 结果 |
|---|---|
| `AnyView` | **0 处** ✔ |
| 强解包 / `try!` / `as!` | **0 处** ✔ |
| `@State` 漏写 `private` | **0 处** ✔ |
| `id: \.self`（应优先 `Identifiable`） | **0 处** ✔ |
| `print()` 调试残留 | **0 处** ✔ |
| **仓库里有没有密钥 / token** | **0 处** ✔（推送脚本在工作区里，不在仓库内） |
| 核心逻辑的单元测试 | 已有 12 条（v1.0.152 落地）✔ |

---

## 四、一句话总结

按这份手册，我们的界面代码**没有系统性毛病** —— 唯一值得动的是 **`usedSpace` 那条主线程扫目录**（①），
它和今天修掉的「删除卡界面」是同一类问题。其余是"原则对、但我们数据量小、不值得为它冒改动风险"。

**审查过程中的一个自我纠正**：我最初的粗扫得出"非 Lazy 列表 15 处"，复查后发现**判据本身无效**
（正则只是匹配了所有 `VStack/HStack`，没区分是不是长列表）—— **这条不作为发现**，已剔除。


---

# 第二轮：设计规范 + 无障碍（design / accessibility 两个分册）

**范围**：`app/*.swift` 46 个文件 · 扫描脚本 `_probe_tmp/scan_design_a11y.py`
★ 说明：这轮先出现了**两次我自己的误报**，逐条核实后已剔除（见文末"自我纠正"）。

## 一、成立、建议改（2 条）

### ① `TabGrid.swift:107-117` —— 关闭标签页的 ✕，可点区域只有 **40×40**，不到 44

```swift
Button { model.closeTab(id: t.id) } label: {
    Image(systemName: "xmark")
        .frame(width: 26, height: 26)     // ← 26
        .background(.thinMaterial, in: Circle())
}
.padding(7)                                // ← 26 + 7×2 = 40，仍 < 44
```
- **手册依据**：design.md —— "Apple 对 iOS 交互的最小可点区域是 **44×44**，必须严格保证"。
- **实际感受**：真机上点标签页右上角那个小 ✕ 要瞄准，容易点空（尤其单手/走动时）。
- **修法**：把 `.frame(width: 26, height: 26)` 改成 44×44（图标本身大小不变，只是可点范围变大）；
  或保留视觉 26，外面加 `.frame(width: 44, height: 44).contentShape(Rectangle())`。**改一行。**
- 它已经有 `.accessibilityLabel("关闭这个标签")` ✔ 无障碍标签这块是合格的。

### ② `Toolbox.swift:194 / 200` —— 工具箱的状态标记**只靠颜色**（← **这是我三小时前刚引入的**）

```swift
.background(Capsule().fill(Color.red))                  // 嗅探数量徽标：只有红色
Circle().fill(Color.green).frame(width: 8, height: 8)    // 开关"已开"：只有绿点
```
- **手册依据**：accessibility.md —— "如果颜色是界面上重要的区分方式，要尊重系统的
  `accessibilityDifferentiateWithoutColor` 设置，**给出颜色之外的差异**（图标、纹理、描边）"。
- **谁会受影响**：色觉障碍用户（红绿难分）——**包括红绿色盲，比例不低**；另外在强光下看屏幕时，
  纯色小圆点也比"形状差异"更难辨认。
- **修法（1~2 行）**：开着时不要只换颜色，**换个形状**——例如把绿点改成小勾
  `Image(systemName: "checkmark")`，或"空心圈 = 关、实心点 = 开"。
- 顺带：这两处**都没有** `accessibilityLabel`，加一句更稳（"开着" / "3 条地址"）。

## 二、成立、但**建议不改**（记录边界，不折腾）

| 项 | 数量 | 为什么不动 |
|---|---|---|
| **硬写字号 `.font(.system(size: N))`** | **185 处**（11~13 占大头） | 这些文字**不跟随系统的"文字大小"设置**。手册的补救是 `@ScaledMetric`（我们 0 处使用）。要动就是**全工程改字号体系**的大工程，而这是自用 App、你自己不会去调系统字号 —— **收益极低**。★ 但记住：**哪天要给别人用/给长辈用，这是第一件要做的事** |
| 硬编码 `.padding(数值)` | 116 处 | 纯风格统一问题，改动收益 ≈ 0，还得大范围回归 |
| `RoundedRectangle(..., style: .continuous)` 多写 | 13 处 | 手册说"默认就是它，不用写"——删了**没有任何视觉变化**，纯噪音 |
| `onTapGesture` 无无障碍标记 | 8 处（0 处带标记） | 其中多数是"点空白关闭弹层"这类修饰性手势（手册也允许）。真正该改成 `Button` 的只有 **1 处**：`ContentView:1642 .onTapGesture { togglePick(job) }`（点任务行勾选）→ 归入 P2 |

## 三、**不适用**（手册提到，但我们这样是对的）

| 手册规则 | 我们的实际情况 |
|---|---|
| 别用 `Color(UIColor.xxx)`，改用 SwiftUI 语义色 | 2 处（`LongPressMenu`、`PagePDF`）。`Color(UIColor.systemBackground)` 在 **iOS 15 上就是取系统背景色的常规写法**（`PagePDF` 那处是 CoreGraphics 画 PDF，本来就得用 UIColor） |
| 别用 `UIScreen.main` 读可用空间 | 2 处都在 `ThumbLoader`，读的是**屏幕缩放比**用来算缩略图像素，不是拿 bounds 当布局基准 —— 手册针对的是后者 |
| 用 `ContentUnavailableView` 做空状态 | 需要 **iOS 17+**，我们目标 15 → 用不了 |
| 用 `Label` 代替 `HStack`、`bold()` 代替 `fontWeight(.bold)` | `fontWeight(.medium/.semibold)` 全工程 **0 处** ✔ 这条我们本来就干净 |

## 四、自我纠正（这轮我误报了两次）

1. **"5 处图标按钮缺 VoiceOver 标签"→ 实际 4 处都有** `.accessibilityLabel`（`BookmarksView` 57-84 行）。
   原因：我的正则块在第一个 `}` 处截断，没读到紧跟其后的那一行。
2. **"非 Lazy 长列表 15 处"（上一轮）→ 判据本身无效**：正则只是匹配了所有 `VStack/HStack`，没区分是不是长列表。

★ 这两次都印证了那条老规矩：**AI 审查的结论必须逐条回源码核实** —— 我自己的粗扫误报率，比它抓到的真问题还高。
