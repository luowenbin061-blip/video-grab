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
