# UI 与交互优化方案

本文只提方案，不含实现。行号对应 `perf/stability-8gb` 分支完成后的代码。

评估依据是对 `Sources/App/` 的完整走读。按「性价比」排序，而非按严重程度 —— 有些问题很严重但改动很大，有些很小但立刻能感知。

---

## 一、高性价比（每项半天以内）

### 1. 队列行右键菜单 —— 全项目性价比最高的一处

`ContentView.swift:87` 的 `.contextMenu` 目前只有一项「Remove from Queue」。

问题在于：**从 app 内到达产出文件的唯一途径，是把行拖到 Finder**（`VideoItemView.swift:40-49` 的 `.draggable`）。这个交互没有任何视觉提示，绝大多数用户不会发现。烧录完成后，界面上没有任何地方告诉用户文件在哪。

建议补齐 macOS 用户会本能去找的几项：

- **在 Finder 中显示** —— `NSWorkspace.shared.activateFileViewerSelecting([url])`
- **打开** —— `NSWorkspace.shared.open(url)`
- **拷贝路径**
- **显示 SRT 附属文件**
- **重试** —— 失败项目前只能移除后重新拖入

另外补一个**双击行 = 在 Finder 中显示**。

### 2. 三处静默失败需要暴露

| 位置 | 现状 | 用户看到的 |
|---|---|---|
| `ASRModelService.swift` `download()` | 已改为记录 `lastError` + 日志（本分支） | **UI 仍未显示** —— 需要在 `ModelDownloadSheet` 里渲染 `lastError` |
| `LiveCaptionsViewModel.swift` `runSavePanel` | 只 `logger.error` | 保存面板关闭，什么都没发生，用户以为存好了 |
| `ConfigService.swift` `update()` | `try? newConfig.save()` | API key 写入失败时下次启动静默消失 |

第一项本分支已经把错误**记录下来**了（`lastError`），把它显示出来只需要在 sheet 里加一个 `if let error`。

### 3. 错误 toast 不应自动消失

`ToastCenter.swift` 对所有 toast 一律 3 秒后自动关闭，包括「N 个失败」这种汇总错误。

建议：按 `kind` 区分 —— `.success` 保持自动消失，`.error` 需要手动关闭。同时 `VideoItemView.swift:124` 的失败状态行是 `.lineLimit(1)` 且不可选中，200 字符的 ffmpeg stderr 被截断且无法复制，至少要加 `.help(item.status)` 和「拷贝详情」。

### 4. 处理过程中的取消按钮

`ProcessingViewModel.startProcessing()` 丢弃了 Task 句柄，`processQueue()` 里没有 `Task.isCancelled` 检查，`FFmpegVideoComposer.runComposition` 是同步阻塞读循环 —— 三处都要改才能真正支持取消：

1. 保存 Task 句柄
2. 每个 item 之间检查 `Task.isCancelled`
3. `FFmpegVideoComposer` 持有 `Process` 引用，取消时 `terminate()`

用户目前唯一的「取消」方式是退出 app，而 `main.swift` 的 ⌘Q 是无条件 `NSApp.terminate(nil)`，会留下一个半截的输出文件和一个孤儿 ffmpeg 进程 —— 见第 8 项。

### 5. Live Captions 窗口置顶 + 尺寸持久化

- 全项目没有任何 `NSWindow.level` 设置。字幕窗口盖在视频或会议上是最主要的使用场景，缺少置顶开关很违和。
- 全项目没有 `frameAutosaveName` / `@SceneStorage`，两个窗口每次启动都回到默认位置和尺寸。

（本分支已把 `WindowGroup` 改成 `Window`，所以不会再开出多个字幕窗口。）

### 6. 无障碍标签

**全项目 `accessibilityLabel` / `accessibilityHint` / `accessibilityValue` / `@ScaledMetric` 零命中。**

最低限度：

- 约 12 个 `.labelStyle(.iconOnly)` 的工具栏按钮只有 `.help(...)`。`.help` 是 tooltip，**不是**无障碍标签，VoiceOver 会去念 SF Symbol 的名字。
- `VideoItemView` 一行会被读成四个互不相关的元素，需要 `.accessibilityElement(children: .combine)`。
- `Toast` 是纯视觉覆盖层，没有 `AccessibilityNotification.Announcement`。由于 toast 是本 app 的**主要**错误通道，VoiceOver 用户目前收不到任何错误提示。
- 字幕 `NSTextView` 缺少 `.updatesFrequently` 特性，实时字幕不会被播报 —— 对一个字幕功能来说这点尤其讽刺。

### 7. 引擎选择器标注「已下载」

两个 picker 都只显示 `displayName` + `downloadSizeLabel`，无论模型是否已在磁盘上，文案都是「首次下载 ~1.2 GB」。

判定函数**全都已经存在**：`FluidAudioRecognizer.isModelCached(version:)`、两个 sherpa recognizer 里的文件存在性检查。把它们收进一个 `ModelCatalog`，每行渲染成 `已下载 ✓` / `将下载 ~999 MB` 即可。

（本分支已加上内存维度的提示：低内存机器上重量级引擎会标注「needs more memory」。）

### 8. 处理中退出的确认

`main.swift` 用 `CommandGroup(replacing: .appTermination)` 替换了 ⌘Q，且没有 `applicationShouldTerminate` 守卫。烧录途中退出会留下孤儿 ffmpeg 子进程和一个截断的输出文件，就放在用户源文件旁边。

### 9. 空状态加一个按钮

`DropAreaView` 的空队列状态设计得不错，但没有按钮。添加视频只有两条路：拖拽，或从 `CommandGroup(replacing: .newItem)` 里的菜单项按 ⌘O。加一个「选择视频…」按钮 + 「或按 ⌘O」提示，约 10 行。

### 10. 拖入不支持的文件要给反馈

`ContentView.swift` 对文件夹或 `.webm` 直接返回 `false`，没有任何提示。`ProcessingViewModel.addVideos` 只在重复时给 toast，被扩展名过滤掉的从不提示。

顺带：视频扩展名列表在 `ContentView.swift`、`DropAreaView.swift`、`ProcessingViewModel.swift` **各写了一份**，迟早会漂移。

### 11. Live Captions 字号控制

`SelectableTranscriptView.swift` 把字体硬编码为 `NSFont.preferredFont(forTextStyle: .body)`。一个字幕窗口的受众与需要放大文字的人群高度重叠 —— 建议 ⌘+ / ⌘− 并持久化。

（本分支已修正对比度：已确认的历史行原本用 `secondaryLabelColor`、临时的实时行用 `labelColor`，也就是**用户真正在读的内容反而更暗**，现已对调。）

---

## 二、中等投入、回报明显

### 12. sherpa 模型下载的真实进度与取消

`SherpaTarballDownloader` 用 `session.download(from:)`，**没有任何进度回调**。两个 sherpa 引擎分别是 570 MB 和 999 MB，下载完还要 `tar -xjf` 解压近 1 GB，全程只有一个静态字符串加一个转圈。

更糟的是 `.loadingModel` 状态下工具栏的主按钮被替换成 `ProgressView()`，**屏幕上根本没有 Stop 按钮**，⌘R 也只在 `.idle`/`.capturing` 分支绑定。用户无法从 UI 取消一个 1 GB 的下载。

建议：

1. `URLSessionDownloadDelegate`（或 `session.bytes(for:)`）暴露 `AsyncStream<Double>`
2. `LifecycleState.loadingModel` 带上 `progress: Double?` 和 `phase: String`（下载 / 解压两个阶段要分开）
3. 渲染确定式进度条 + 取消按钮
4. 保存 start Task 句柄，让 Stop 真的能取消 —— 目前 `start()` 的 Task 没有句柄，`stopInternal` 的 `finish()` 会排在 `start()` 后面，`start` 返回后又会把状态设回 `.capturing`

### 13. 字幕样式实时预览

`SettingsInspector` 提供字体、字号、边框、下边距四项，而**唯一的预览方式是烧录一整个视频**。

建议加一条静态预览：一个 16:9 的模拟画面，用相同的 ARGB 值和等比边距渲染示例文字。`SubtitleStyle.assForceStyle()` 已经集中了语义，预览和烧录不会走样。

另注：`SubtitleStyle` 有 8 个字段，Settings 只暴露 4 个。`alignment` 和 `marginHorizontal` 完全不可达，而 `alignment` 一旦不是 `.bottomCenter`，「下边距」这个标签就是错的。

### 14. 填上冻结的进度条

`FluidAudioRecognizer.transcribe` 只 `reportStatus` 一次，不报百分比，`VideoPipeline` 在它返回后直接从 10% 跳到 70%。**默认引擎下最长的那个阶段，进度条是完全静止的** —— 一小时的视频就是几分钟不动。Qwen3 路径反而有增量百分比，两个引擎体验不一致。

好消息：**FluidAudio 0.15 提供了 `transcriptionProgressStream`**（`AsyncThrowingStream<Double, Error>`），本分支升级后已经可用，接上即可。这是升级顺带解锁的能力。

### 15. Live Captions 错误分类 + 重试按钮

`captureErrorMessage`（`LiveCaptionsViewModel.swift`）是全项目最好的一段错误文案 —— 它说明了原因、解释了 macOS TCC 需要重启的怪癖、并给出确切操作。但它**只用在 SCStream 失败那一条路径**上。覆盖下载 / 解压 / 模型加载全部失败的那条 `recognizer.start()` 路径完全绕过了它。

而失败面板对所有错误都只给两个按钮：「打开系统设置」和「退出 Scribe」—— 即使错误是 tarball 404。**没有重试按钮。**

建议：给 `LifecycleState.failed` 带一个 error-kind 枚举，按类型切换恢复操作：

- 网络不可达 → 「你处于离线状态。[重试]」
- 磁盘空间不足（`NSFileWriteOutOfSpaceError` / tar 失败）→ 「空间不足，\(engine) 需要约 \(2×size) 可用空间」（目前显示的是原始 bzip2 stderr）
- HTTP 4xx/5xx → 「模型服务器返回 \(status)，发布地址可能已变更 —— 试试其他引擎」
- 权限 → 保持现有文案

### 16. 首次启动的 ffmpeg 预检

没有任何地方在启动时检查 ffmpeg。`ProcessingViewModel.createPipeline` 捕获 `FFmpegLocator` 失败后**静默替换成 `FailingAudioExtractor`/`FailingVideoComposer`**，于是用户拖入 10 个视频、点开始、得到 10 行「Failed: FFmpeg not found」。

应该在启动时检查一次并显示常驻横幅，附带可执行的安装指引。相关地：`ScribeError` 只实现了 `errorDescription`，没有 `recoverySuggestion` —— `ffmpegNotFound` 只说「请安装 FFmpeg」，没有命令、没有链接、没有按钮。

---

## 三、较大改动

### 17. 统一的模型管理面板

用户试完五个 Live Captions 引擎加两个离线 Qwen3，会在 `~/Library/Application Support/Scribe/models/` 攒下约 **3.5–4 GB**，而 app 内**无处查看、无处删除**。

同时现有的唯一模型 UI（`ModelDownloadSheet`）硬编码在 Parakeet v2 上，`ContentView` 的工具栏按钮也只反映 Parakeet 状态 —— 如果用户在 Settings 选了 Qwen3 1.7B，这个按钮报告的是一个管线永远不会加载的模型，属于**主动误导**。而 Qwen3 离线引擎根本没有预下载入口，「开始处理」会静默变成一次 1 GB 下载。

一个统一面板可以一次性解决：可下载项清单、磁盘占用、下载 / 删除 / 在 Finder 中显示、以及两个引擎选择器的状态显示。

### 18. 队列持久化与窗口状态恢复

无 `@SceneStorage`、无 frame autosave、从不调用 `NSDocumentController.noteNewRecentDocumentURL`（所以「最近打开」永远是空的，尽管 File 菜单用 `CommandGroup(replacing: .newItem)` 顶掉了「新建」）。退出即丢失整个队列。

### 19. 翻译弹窗锚定到选中文本

`.popover(isPresented:arrowEdge:.trailing)` 挂在整个转录视图上，箭头指向面板边缘而非选中的文字。`NSTextView.firstRect(forCharacterRange:)` 能给出正确矩形，但 SwiftUI 的 `.popover` 用不上，需要由 `SelectableTranscriptView.Coordinator` 驱动一个 `NSPopover`。

另外翻译延迟缺少解释：400 ms 防抖 + 4 s Apple 框架看门狗 = 最长 4.4 秒只显示「翻译中…」，且成功前不显示用哪个引擎，也没有取消。建议显示「正在尝试 Apple 翻译…」并提供「立即改用 Google」。

（本分支已修复一个相关问题：转录视图原本每秒重建整个 `NSTextStorage`，**流式过程中用户的选中大约每秒被清除一次** —— 这正好破坏「选中即翻译」这个核心交互。现已改为增量渲染，且有选中时暂停重建。）

### 20. 其他 macOS 原生细节

- **没有撤销** —— `removeVideo`、`clearCompleted`、`clearTranscript` 都不注册 `UndoManager`，⌘Z 无效。`clearTranscript` 绑定在 ⌘⇧⌫，一小时的转录一键清空且不可恢复、无确认。
- **Help 菜单被显式移除**（`CommandGroup(replacing: .help) { }`），连带 ⌘⇧/ 的菜单搜索也没了。
- **没有自定义「关于」窗口** —— 缺少版本信息、以及 ffmpeg（DMG 里打包了 `ffmpeg-full`）和各模型许可证的署名，后者是许可义务。
- **关闭主窗口后 app 无法回来** —— `AppDelegate` 设了 `.regular` 激活策略，但既没实现 `applicationShouldTerminateAfterLastWindowClosed` 也没实现 `applicationShouldHandleReopen`。
- **⌫ 绑定在窗口级**（`ContentView.swift`），macOS 惯例是 ⌘⌫；而且 inspector 里的 API Key / prompt 输入框获得焦点时这是个隐患。
- **`ModelDownloadSheet` 的焦点是反的** —— `.cancelAction` 给了「关闭」，「下载模型」没有默认按钮，回车会关掉 sheet 而不是开始下载。
- **Settings 自动保存无防抖** —— `apiKey`、`baseURL`、`customPrompt` 每敲一个键都重新编码并重写整个 JSON，且经由 `try?` 吞掉失败。

---

## 附：本分支已顺带修掉的 UI 相关缺陷

以下原本属于 UI 清单，但因为是正确性问题而非设计问题，已在本次改动中修复：

- 「重置设置」在 inspector 关闭时是空操作（唯一的订阅者是一个只在 inspector 呈现时存在的视图）
- 流式过程中用户选中每秒被清除
- 转录视图对比度倒置（已确认内容比临时内容更暗）
- SRT 导出只产出一条字幕
- 「清空」只清视图状态，下一个 partial 会把整段文本灌回来
- 引擎选择器现在会在低内存机器上标注重量级引擎
- `Info.plist` 里「Scribe 不使用麦克风」的用途说明已删除（会因为一个 app 并不想要的权限去打扰用户）
