# GoLand 对齐 B1：菜单生命周期、命令与工具窗口入口

状态：2026-09-06 B1a 已在 `8b8f21be` 提交并安装；B1b/B1c 已通过独立代码审查、976 项测试及 ARM64 发布包实际点击验收。方案复核见 [审查记录](goland-parity-implementation.md#plan-review)。B1 是完整 GoLand/Zed 对齐目标的首批，Structure、TODO、Pull Requests、搜索、设置、语言工具等后续批次仍须实现。

## 实现记录与方案调整

以下各节保留实现前的设计与验收矩阵；实际落地以本记录及源码为准。

- B1a 采用原生窗口观察器作为命令输入上下文的唯一来源，移除设计中的第二条 `FocusedValue` 路径。菜单携带窗口、会话和工作区代际身份，执行时仍重新验证。
- 最近项目闪退的实际根因包含 `LitheApp` 根层观察 FPS/内存对象引起 Scene 重建。根层改为稳定持有，状态栏保留自身观察；配合菜单投影与 tracking 冻结，10 次原生菜单持续显示检查全部通过，发布包再次保持 3.5 秒并成功选择项目。
- B1b 引入一次计算、共享消费的有效键位投影。已有用户覆盖优先于新增默认键；多个显式覆盖冲突时停止注册该键并保留配置，Keymap 显示冲突供修复。工具栏、菜单、提示和 detector 使用同一结果。
- Project/Commit/Find 与底部工具通过稳定命令 ID 执行。Run 使用模块激活流程，Commit 从休眠恢复时重新激活 Git。关闭项目先取消所有动作生产者，再等待其结束，避免清理后生成新任务。
- B1c 扩展原生 View 菜单，保留系统全屏入口；Tool Windows 从 Window 移至 View，避免重复注册键位。Appearance 和 Editor Tabs 使用冻结的设置投影；设置窗口每次收到显示请求都恢复请求分类，覆盖同分类重复打开。
- B1a 证据位于 `.artifacts/goland-parity/iteration5-menu/acceptance.md`；B1b/B1c 的截图、时序采样、测试及发布包验收位于 `.artifacts/goland-parity/iteration6-commands/`。只将实际执行的条目标记通过，不将下文全部验收矩阵视为已完成。

## 1. 本批交付与证据

B1 交付三个可实际操作的结果：File → Recent Projects 可以稳定悬停和选择；左侧工具栏、菜单和键盘使用同一命令及真实快捷键；View → Tool Windows / Appearance 接入当前已经实现的能力。

对照版本为本机 GoLand 2025.2.4（GO-252.27397.100）。规划时对安装版 Lithe 的只读 AX 采样发现：展开最近项目 0.19 秒后仍有 16 个可见菜单项，其中 3 个是项目；0.73 秒起全部消失。期间没有额外点击或按键。原始证据位于 `.artifacts/goland-parity/iteration5-planning/recent-lifetime-baseline.json` 和 `recent-expanded.jsonl`。这证明故障存在，不能单凭它证明内部根因。

代码证据：

- [LitheProjectCommands.swift](../../macos/Sources/Lithe/Views/App/LitheProjectCommands.swift) 顶层 `@FocusedObject AppModel` 和三个子 Commands 的 `@ObservedObject AppModel` 会收到聚合对象的所有变更；最近项 ForEach、`fileExists` 和 disabled 判断都在 body 内计算。
- [AppModel.swift](../../macos/Sources/Lithe/Models/AppModel/AppModel.swift) 的 `scheduleObjectWillChangeRelay` 汇集 Git、终端、运行等后台事件。菜单状态不变也会触发 Commands 更新，这是本批首先验证的根因候选。
- [ProjectWindowPresentation.swift](../../macos/Sources/Lithe/Views/App/ProjectWindowPresentation.swift) 已对 tabbingIdentifier/tabbingMode 做差异判断；[RootView.swift](../../macos/Sources/Lithe/Views/App/RootView.swift) 已按差异更新窗口标题等属性；[ProjectSessionManager.swift](../../macos/Sources/Lithe/Models/Workspace/ProjectSessionManager.swift) 已只转发 workspaceURL 变化。保留这些修正，不能重复宣称发现它们。
- [EditorChromeModel.swift](../../macos/Sources/Lithe/Models/Editor/EditorChromeModel.swift) 的 `findMatchCount` 不是 `@Published`，`updateFindState` 是先手工 `objectWillChange.send()` 再赋值；只订阅 AppModel 会遗漏 Find Next/Previous 的有效状态。
- [LitheAction.swift](../../macos/Sources/Lithe/Models/LitheAction.swift) 的 `toggle-run` 直接翻转 `isRunVisible`，菜单和工作台却调用 `toggleRun()`。前者绕过模块激活，必须统一。
- review 补查：[ProjectWindowManager.swift](../../macos/Sources/Lithe/Models/Workspace/ProjectWindowManager.swift) 的 activeWindowID 非 optional，只记录最近激活的项目；Settings 成为 key window 时它不变。[LitheApp.swift](../../macos/Sources/Lithe/LitheApp.swift) 的 SettingsWindowReference 没有更新项目执行资格；[MacShortcutDetector.swift](../../macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift) 匹配键后先吞事件再异步回调，当前也不验证 event/key window。这是需要和菜单一起修正的跨窗口门禁缺口。

本批不修改 Git 图、搜索引擎、语言协议、项目窗口归属模型，也不添加无实现的 Structure/TODO 按钮。

## 2. 责任与对象生命周期

新增名称可按现有命名习惯微调，职责和所有权保持以下约束。

| 对象/文件 | 责任 | 生命周期 |
| --- | --- | --- |
| `Models/Commands/ProjectCommandState.swift` | 可等值比较的菜单事实、有效快捷键和最近项数据；不含 AppKit、SwiftUI、闭包或 AppModel | 不可变值 |
| `Application/Features/ProjectCommandStateFeatureModel.swift` | 合并源事件，读取完整事实，发布真正变化的快照；维护最近项可访问性缓存 | 每个 AppModel 一个，由该会话持有 |
| `Models/AppModel/AppModel+Commands.swift` | 将已拥有的 feature 状态投影为命令事实，提供命令可用性检查与统一执行入口 | AppModel 扩展；不拥有平台资源 |
| `Views/App/ProjectCommandContext.swift` | `FocusedValueKey`、纯 ID 的 focus context | scene 发布值，不发布 ObservableObject |
| `Views/App/MenuPresentationCoordinator.swift` | 选择活动项目、窗口级可用性、tracking 缓冲、供 Commands 读取的最终快照、菜单动作路由 | 应用级一个，由 LitheApp 的稳定 StateObject 持有 |
| `Platform/MacOS/UI/MacMenuTrackingObserver.swift` | 监听 NSMenu tracking 通知，把开始/结束转为注入的回调 | 应用级一个；由 composition root 构造并注入；退出时 stop |
| `Platform/MacOS/UI/MacCommandFocusObserver.swift` | 维护注册 native window 身份、key window / app active / modal / attached sheet 资格；提供同步事件窗口验证 | 应用级一个，不用 activeWindowID 代替 native focus |
| `Core/Ports/RecentProjectAccessChecking.swift` / `Platform/MacOS/Workspace/MacRecentProjectAccessChecker.swift` | 窄 async 可访问性查询、独立截止时间和受限后台文件检查；返回 present / missing / unknown | 应用级共享检查器，真实在途 I/O 至多一个，不随菜单重建创建 |
| `Application/Features/ApplicationCommandRouter.swift` | 应用级 Open/Recent/Settings/Clone 请求的 host 选择和显式窗口呈现排队；不创建 AppModel、不持有 AppKit | 应用级一个，依赖纯 ID 的已有窗口 registry 与 presentation 回调 |
| `Views/App/LitheProjectCommands.swift` | 只根据最终快照生成菜单，提交带上下文的命令请求 | SwiftUI 可重建的值，不在 init/body 创建订阅或观察器 |

ProjectCommandStateFeatureModel 可由 AppModel 的惰性属性创建，创建后先生成一次完整初始状态，再订阅变化；快照读取闭包及订阅 closure 对 AppModel 使用弱引用，避免环。项目关闭后取消其 pending update，解绑模块订阅，删除 coordinator 中对应 session 的缓存。不能在 ProjectSessionContent 的反复 onAppear 中建立第二套订阅。

MenuPresentationCoordinator 仅 `@Published private(set) renderState`；tracking 根集合、latestState、pendingState、focus generation 和 subscriptions 都不 Published。否则“冻结菜单”仍会被内部 bookkeeping 的 willChange 打断。Commands 的子结构接收不可变 `renderState` 与稳定路由器引用，移除其对 AppModel、ProjectWindowManager、UpdateChecker、ProjectWindowPresentation 的直接观察。

Application 快照存稳定标题 key 和语言事实，presentation coordinator 生成同一版本的本地化标签、help、shortcut 文本。tracking 期间 Commands 使用已经冻结的标签，不能另读实时 AppSettings 或让 `.help` 再订阅原 AppModel；否则切换界面语言/快捷键仍会绕过缓冲。SwiftUI 的普通 body 重算不得隐式生成新 UUID item ID。各工具 item 用 command ID，最近项目用规范化 URL；所有排序确定。

平台层只返回 tracking 事件，不调用 Rust、不构造 feature；Application 不 import AppKit。遵守[仓库边界](repository-layout.md)及[应用契约](../../shared/contracts/application-boundary.md)。

## 3. FocusedValue、窗口和执行对象

在 `ProjectWindowScene` 为当前 session 发布：

```swift
struct ProjectCommandContext: Equatable {
    let windowID: UUID
    let sessionID: UUID
    let workspaceGeneration: UInt64
}

// 使用兼容当前部署目标的 key-path FocusedValueKey API。
.focusedSceneValue(\.projectCommandContext, context)

// Commands 不再通过 @FocusedObject 订阅整个 AppModel。
@FocusedValue(\.projectCommandContext) private var focusedContext
```

这段是接口示意，不是可直接复制的完整代码。context 的 generation 只在同一 session 替换/关闭工作区时变更；编辑、光标、后台输出不能改变它。不要采用要求新系统 `Observable` 的 type-based overload。Apple 文档说明 scene focus value 可在整个活动 scene 内提供值，见 [focusedSceneValue](https://developer.apple.com/documentation/swiftui/view/focusedscenevalue(_:_:))。

现有 `ProjectWindowManager.activeWindowID` 和相应 `ProjectSessionManager.activeSessionID` 只提供最近项目与 session 选择，**不是原生焦点资格**。它们在 Settings 成为 key window 时不会清空。另建 `CommandFocusState`：`eligibleProjectContext: ProjectCommandContext?`、`focusedWindowKind`（project / welcome / standalone / settings / modal / none）、`isApplicationActive`、`generation`。native `windowDidBecomeKey` 继续使用现有 activate 流程，但菜单/执行必须同时消费独立 focus state。

`MacCommandFocusObserver` 订阅 `NSWindow.didBecomeKeyNotification`、`didResignKeyNotification`、`willCloseNotification`、应用 didBecomeActive / didResignActive，以及 sheet 开始/结束通知。每次以 `NSApp.keyWindow`、`NSApp.modalWindow`、已注册窗口的 attachedSheet 和 application active 状态重算，原生 NSWindow 只留在平台层。ProjectWindowPresentation 的 attach/closed 注册、注销 `(nativeWindow, windowID)`；SettingsWindowAccessor 注册 `.settings`；其它未注册窗口默认无项目资格。所有事件在主线程先同步更新执行门禁，再按第 4 节排队更新展示投影。防止“键窗口已经变了，但下一轮快照还没变”的空档。

注册 session 窗口成为 key 时，结合该窗口实际 `activeSessionID` 生成 context；注册的 standalone / welcome 也有 session context，但只有各自模式允许的命令可以执行，context 不等于 workspace 存在。Settings/modal/无 key window/应用失活时，`eligibleProjectContext=nil`。单纯 `.activeWindowID` 未变也必须发出资格变化。不要调用 `setProjectSessionActive(false)` 来表示 Settings 抢焦点：那是会话选择状态，还会关闭 Search Everywhere；另加独立的命令输入资格（并与 shortcut recording 的暂停原因做 OR），不能用一个 bool 互相覆盖暂停原因。

FocusedValue 负责声明 scene 上下文；Commands 不在 body 中调用 coordinator 的变更方法。FocusedValue 与 native focus / session registry 不一致时，项目操作先拒绝，待下一轮对齐再启用，不能沿用最近项目补空值。窗口/session 的正常切换信号保证随后刷新，而不是永久停留在 disabled。

Settings 等无编辑项目上下文的窗口不继承后台编辑器的命令资格。Open、Settings、Check Updates 等应用级动作仍可执行；编辑、Git 和工具窗口动作禁用。欢迎窗口允许 Open/Recent/Clone，禁用需要 workspace 的动作。独立文件窗口允许适用的 Save/Find/Navigate，禁用 workspace Git/Terminal 等。

必须区分 `renderContext` 与 `executionContext`：tracking 时前者冻结，后者持续核对原生焦点。SwiftUI FocusedValue 因菜单 tracking 暂时 nil，但 native keyWindow 仍是原项目、无 modal/sheet 时，可以继续执行该项目的 item；如果 native keyWindow 本身确实变成 nil，就不把冻结 context 当作执行资格。只有 AppKit 仍保持原项目 keyWindow 且 registry 校验相符才允许该项目动作。Settings 抢焦点、原项目关闭或应用失活立即使执行资格失效，菜单显示则按第 5 节等 tracking 结束再刷新。由此既不因 SwiftUI 的临时 nil 提前重建菜单，也不把真正失焦误当作菜单事件而放行。

所有项目动作提交值型 `ProjectCommandRequest(commandID, originContext, payload)`：

1. 菜单 item 闭包捕获生成该 item 时的 context 和参数（最近项 URL、reference ID 等），不能捕获旧 AppModel 强引用，也不能只捕获全局“当前项目”。
2. 用户点击时从窗口/session registry 解析对应存活实例；校验 workspaceGeneration、native eligibleProjectContext、event origin（有时）及 action 的实时 enabled predicate。不得用 activeWindowID 相同代替资格检查。
3. 如果 tracking 期间已经切到另一个项目或关闭原项目，旧请求不执行，不默默改投新项目。关闭菜单并在新项目重开后，动作路由到新项目。
4. 显示时可用但点击前变为无效的动作必须拒绝；显示快照只用于展示，不是执行授权。
5. 没有项目 context 的全局动作由下节应用级路由处理；不能为了 Open 创建一个隐形后台 AppModel。
6. 快捷键、工具栏、Search Actions、菜单 keyEquivalent、原生 responder/context menu 的项目级动作在发生事件时取得合格 context，进入同一执行路径。异步动作只保留开始时解析的目标和 operation identity；任务稍后恢复时不得重新取另一项目的 activeModel。

`didEndTracking` 和发送 menu action 的顺序不能作为正确性前提：item 自己携带 originContext，即使菜单结束刷新先发生，原动作也不会用到新的全局 snapshot。合并/拖出 native project tab 只更新 window 归属；尽量保留 sessionID；旧请求若 window 已变必须通过 registry 明确验证后拒绝，不能误投其他窗口。

### 3.1 快捷键的消费前门禁

仅在 `performShortcutCommand` 里增加 guard 不够：现有 MacShortcutDetector 已先 `return nil` 吞掉事件，Settings 内的键盘行为仍然损坏。项目 detector 在匹配后、消费前必须同步验证：应用 active、无录制暂停、事件窗口与 native keyWindow 对应当前 eligible context、该 command 当前可执行。失败返回原 event。成功时携带 context/focus generation 进入异步回调，执行前再验证一次，覆盖匹配后切换窗口的竞争。

将平台窗口验证通过 `ShortcutDetectorFactory` 注入的共享 focus registry 与纯 context ID 实现；执行可用性由 main-actor 同步 predicate 提供。Application/Core port 不暴露 NSEvent/NSWindow。keyDown 以 event.window 及 keyWindow 双重检查；flagsChanged 可能无 event.window，使用当时 keyWindow；focus generation 改变、录制开始、app 失活时重置 doubleShift recognizer，不能把 A 项目一次 Shift 和 Settings/B 项目一次 Shift 拼成双 Shift。

应用级 `open-project`、`settings`（以及已注册的应用级命令）从每个项目 detector 的 registrations 中剥离，交给应用级一份 disjoint registrations 的 detector，避免 Settings 下禁用项目 detector 后全局自定义键失效。它也受 app-active、modal/已有 chooser、shortcut recording 门禁，但不要求 eligibleProjectContext。全局和项目两组先使用同一 resolved-binding 集解决冲突，再分发；任何 binding 至多由一组拥有。只保留一份全局 detector、至多一个有资格的项目 detector；B1 不另加一套与现有绑定重叠的 monitor。

UI 可复用现有 detector 实现及 factory；AppModel 的项目 detector 保留会话生命周期所有权，新增 `commandInputEligible` / recording 等暂停原因聚合，禁止在 Settings 失焦事件中启动第二个项目 detector。局部 `MacReturnKeyMonitor` / Search keyboard handler 同样要校验其挂载 view.window 就是 keyWindow；否则挂在后台 Find 输入框的 Return monitor 仍可能抢 Settings 的 Enter。

NSMenu 正在 tracking 时，普通全局/项目 detector 和局部 Return handler 把按键留给原生菜单，不自行触发项目搜索、吃掉箭头或 Enter；menu keyEquivalent/action 仍可通过正常菜单路径进入同一个实时路由器。这是输入消费的门禁，不是撤销原项目的 menu action 资格。begin/end 改变此暂停原因时同样重置双 Shift 序列。

### 3.2 无项目焦点的全局命令如何落地

复用 `chooseProject`、`openProject`、`showSettings`、`showCloneRepository` 的现有工作流，补一个不会创建会话的 registry 查询 `existingCommandHost(preferredWindowID:)`。只能从已注册、未关闭、可呈现的 window/session 中选 host；不能读取 `activeSessions` 来选 host，因为它的 getter 最后会调用 `sessions(for:)` 创建实例，且可能返回已关闭窗口的 mostRecentSessions。也不能直接对保留着的关闭 AppModel 设 `isCloneRepositoryPresented=true`，那不会有 sheet 可显示。

| 全局请求 | 已有可呈现 host | 没有 host / 所有项目窗口已关闭 |
| --- | --- | --- |
| Open / New from Existing Folder | 捕获确定 host，调用其 `chooseProject`；chooser 结束后验证该 host 仍注册，沿用其打开位置策略 | 用应用级注入的 `PlatformUI.chooseDirectory` 先显示 chooser；取消不创建 AppModel。选定 URL 后调用新增的 `ProjectWindowManager.openProjectFromApplication(url)`：沿用现有 modelFactory、session 注册和 `presentWindow` 流程创建用户可见项目窗口，不需要伪造 sourceWindowID |
| Open File | 捕获确定 host，复用 `chooseEditorFile`；有 workspace 时进当前项目编辑器，welcome/standalone 按现有独立文件路径打开 | 应用级 `PlatformUI.chooseFile` 先选择；取消不创建 AppModel。选择后通过显式 `openStandaloneFileFromApplication(url)` 注册并呈现正常 standalone 窗口，再调用其 session 的既有独立文件打开流程；不用 `activeSessions` 的可能创建 fallback。chooser 期间原 host 关闭时也走这一可见 standalone 路径 |
| Recent Project | 已点击 item 的 URL，经 host `openProject` 保留现有打开策略 | 直接 `openProjectFromApplication(url)`；先检查已有同项目窗口可激活 |
| Settings | 若 Settings window 已存在则直接呈现它并选择请求的 category；否则已注册 host `showSettings(category:)` | 当前 SettingsView 需要 AppModel，B1 不复制一份 settings 模型。显式呈现正常 Welcome Window，等其 host 注册后调用该 host `showSettings`。这是用户可见的标准欢迎窗口，不是隐藏会话；后续设置解耦批可消除此依赖 |
| Clone | 先使确定 host 的普通 project/welcome 窗口可见并成为 key，再调用 `showCloneRepository`，让 Root 的 ActiveSessionChrome 承载 sheet | 显式呈现 Welcome Window，等它注册后调用 `showCloneRepository`；Clone 完成仍走现有 clone/openProject 工作流 |
| Check Updates / 纯应用外观设置 | 直接由应用已有 UpdateChecker/AppSettings 处理 | 相同；不需要 AppModel |

ApplicationCommandRouter 仅持有带 request ID 的 pending action。创建可见窗口用 LitheApp 已安装的 `openWindow`/`presentWindow` presentation 回调；窗口 attach 注册后显式回调完成 pending，不通过睡眠等窗口出现。仅在这一用户明确的全局动作要求显示新窗口时，正常窗口流程才允许调用 modelFactory。请求取消、窗口创建失败、host 关闭、应用退出均清理 pending；重复点击不能生成重复 host 或第二个 chooser。队列 host 失效时 Open 已选 URL 可转用户可见新项目窗口，依赖旧编辑内容的项目动作不迁移。

对于在 Settings 中触发的 Open/Recent，host 选择表示该全局操作的打开位置策略来源，**不赋予该 host 编辑/Git/Terminal 快捷键资格**。Clone 将 host 呈现为 key 后 native eligibility 自然更新。所有 chooser/sheet 打开期间全局 router 的 `isPresentingRequest` 与 modal gate 禁止重复进入。

## 4. Combine 时序与更新合并

不能在 `objectWillChange.sink` 同步读取 `model` 再 `removeDuplicates`：此时底层字段可能尚未赋值。也不能只删观察来阻止菜单消失，造成 disabled、最近项和快捷键永远不更新。

使用注入的 `CommandProjectionScheduler`，生产实现把一次刷新排到 main-actor 当前同步修改结束之后；同一轮多个 invalidation 只保留一个排队任务。测试使用显式 `drain()` 的手动 scheduler，不 sleep、不依赖 Task.yield 猜测时序。实现可用主队列异步调度，并用 generation / cancellation token 使 teardown 后的任务无效；任务开始时清除 scheduled 标记，投影过程中出现新事件可排下一次。

流程：源 willChange / property publisher → `invalidate()` → 合并任务读取最新事实 → 比较 `candidate == current` → 只有不等才赋 Published snapshot。初始投影在对象创建时完成；打开菜单不依赖随后的异步首次填充。

优先订阅菜单实际依赖的字段。必须同时覆盖：

- AppModel：workspaceURL、standaloneFileURL、recentProjects、sidebar/工具窗显示、当前 modal 资格及模块可用性变更。
- Document feature：active text/media/editor-terminal 的身份、可保存状态、dirty 汇总；关闭/切换活动文档后刷新。
- EditorChrome：Find 可见性和匹配数，以及语言动作启用状态。`updateFindState` 的手工 willChange 走上述 deferred invalidation；不把每次 caret 位置放进菜单 state。
- Git feature：repository、current reference、branch operation busy；替换/唤醒/休眠/禁用模块时更新订阅。不要为了读取菜单而激活尚未启动的 Git 模块。
- Language feature：活动文档支持 definition/implementation/references 的 capability 变化；LSP 从 unknown 到 ready/failed 时刷新。
- Navigation history：canBack/canForward。
- KeyboardShortcutFeatureModel / AppSettings：有效 binding、语言、当前 theme/mode/tab layout。现有 keyboardShortcutFeature 的 willChange 也在 settings.$overrides 赋值前发出，仍需 deferred read。
- Window presentation：窗口列表、当前 native tab group 是否可 detach/切换、全屏状态（如果列入 View）；UpdateChecker：是否 checking。

AppModel 的聚合 willChange 可作为首版兼容兜底 invalidation，但不直接 Published 给 Commands。其处理只读取上述 O(命令数+最近项数) 小事实，不遍历文本、图节点、终端输出或整个树。投影中禁止 `fileExists`、遍历磁盘或启动子进程。若兜底导致高频无意义计算，应在同批转为对应字段事件，测试同时量化发布次数和投影次数，不能只证明最终值正确。

最近项访问检查不能把同步 `WorkspaceFileOperations.fileExists` 包进 `Task { @MainActor ... }` 冒充异步。新增窄 async port `RecentProjectAccessChecking`，实现只在平台层，使用独立受限后台执行器调用文件元数据 API；Application 等待异步值，不创建 DispatchQueue/FileManager。输入为 URL 列表、request ID、预算，返回每项 `present` / `missing` / `unknown(reason)`，其中访问拒绝、超时和暂不可用都不是 missing。

具体预算与取消规则：

- 默认每批回复截止时间 1 秒（命名配置常量，可注入测试时钟），一个应用共享检查器，真实执行并发最多 1，待处理批次最多 1（只保存最新批次）。最近项列表已有上限，先查询用户实际最近列表，不扫描其他目录。
- 同步文件 API 可能因慢盘/网络挂载不可取消。截止时间只保证调用者及时得到 unknown，**不能将后台 stat 标为已经终止**。真实 worker 未返回时保持 busy，不因为请求超时/取消而启动另一个 worker；新列表替换 queued batch，绝不每次 hover 再派发不可取消的 stat。等待中的新请求同样在自己的 deadline 内返回 unknown。
- 后台操作每完成一个 URL，回到所有者 actor 判断 request generation / cancellation；旧请求不再开始下一个 URL。在途操作最终返回后释放唯一槽位，晚到旧结果不覆盖新 cache。取消清除逻辑等待者与 queued batch；不承诺强行终止正在内核等待的同步调用。
- cache 键为标准化 URL 和 recent-list generation。启动和列表变化时检查；begin tracking 可请求一次去重验证，期间结果只进 pending snapshot。已确认 missing 才 disabled；unknown 保持可选，用户点击后进行同一 async port 的按需验证。
- 点击查询超时/拒绝访问时给可执行的“暂时无法访问该项目”反馈，可重试；不再在 main actor 追加同步 fileExists。只有 present 后才进入已有 openProject 流程；之后目录消失等 TOCTOU 失败仍由打开工作流正常报告，不能依赖检查保证永远存在。
- shutdown 停止接收、取消等待者、清空队列并关闭结果投递；不在 main actor join/wait 后台 worker。若验证时底层 stat 仍被挂载阻塞，报告残留的任务状态，不声称已取消全部 I/O；应用退出会结束其进程资源。这个限制不能放大成无限 worker/线程增长。

测试注入可控 worker 和 clock：卡住第一个 URL，deadline 返回 unknown，反复菜单打开/取消只能仍有 1 个真实 worker；更换列表后释放旧 worker，不发布旧数据，按规则处理最新批次。fixture 的阻塞 gate 在 defer 中释放并等待终止，有自己的 deadline。真实运行验收应包含可用的慢盘/暂断挂载，确认菜单不冻结、回复 unknown 而非“目录不存在”、重复进入不增长线程；若机器无此类挂载，明确记录真实慢盘场景未执行，不能以同步本地 SSD 查询代替。

## 5. Tracking 期间冻结、结束刷新

使用 `NSMenu.didBeginTrackingNotification` / `didEndTrackingNotification` 的公开 API，保留现有 macOS 部署目标。Apple 说明结束通知即使没有发送 action 也会发出，通知 object 为主菜单或 popup 根菜单，见 [didEndTrackingNotification](https://developer.apple.com/documentation/appkit/nsmenu/didendtrackingnotification)。不按鼠标 hover 猜测菜单生命周期，不使用固定延时自动关闭。

处理顺序：

1. begin：以通知 object 的身份登记根菜单；重复 begin 幂等。保存当前已发布 renderState 及项目 context 作为本轮基线，不在通知回调中发布新状态或替换 NSMenu。
2. tracking：计算 latestState，但不改变 renderState；只保存最新 pendingState。最近项、Git busy、快捷键、语言、native window availability 都走同一缓冲规则。
3. end：移除匹配根，忽略未知/重复 end；仍有根在 tracking 则继续冻结。最后一个根结束后排一个 main-actor commit，避开 AppKit 正在发送动作的调用栈。
4. commit：重读活动 context 和最新事实；若期间又 begin，则保留 pending，等待下一次 end；否则按等值判断最多发布一次。不能把队列中旧项目 snapshot 覆盖当前项目。
5. action 的实时验证不受冻结影响；即时变化的危险动作即使画面未灰也会被拒绝执行。
6. stop / 退出：移除 notification observer，取消 scheduled commit，清理 tracking roots 和缓存。测试主动调用 stop 验证清理；不要依赖 deinit 顺序。

主菜单和工具栏原生 popup 共用根跟踪集合可避免同时 tracking 造成提前解冻；Begin/End 一一按根身份管理，不为每个子菜单额外计数。app resignActive 不应粗暴清空跟踪并立刻重建；正常交给 end，应用退出 stop 兜底。若验证发现某 SDK 的通知顺序不同，先记录根身份和事件顺序再调整，不能添加周期 polling。

SwiftUI 的 focus 改变会使 Commands 值重新求 body，这是允许的；要求它读到的是同一个 renderState、同一 ordered item IDs 和同一 originContext。**实际菜单保持 tracking 必须通过 AppKit/AX 验证**，不能用“快照没变化”的单元测试代替。若 A/B 后菜单仍在没有用户输入时结束，暂停本批验收，继续定位 RootView/native tab/title 更新和 SwiftUI menu 重建；禁止以绕过自动状态更新或人为长延时作为修复。

## 6. 完整 enabled / selected 投影表

`ProjectCommandState` 至少包含下表所有事实。使用同一纯 predicate 生成 snapshot 和执行前检查，不能在 Commands 里另写一版。以当前功能为准保留禁用行为；纠正现有菜单与快捷键不一致时在测试明确记录。

| 菜单/动作 | enabled 输入与规则 | selected / payload |
| --- | --- | --- |
| New → Existing Folder、Open、Open File、Recent、Clone | 应用可接受新打开请求；不依赖 workspace | Recent 有固定 URL/path identity；缺失项单独 disabled |
| New File / Directory | workspace 存在 | 点击时对应 workspace 根 |
| Close Project | 存活项目窗口且 workspace 存在 | 复用 `ProjectWindowPresentation.closeSelectedProject` / 现有关闭确认流程；避免 shortcut 仅关闭内部 session |
| Save | active text document 存在且允许保存；不把只读虚拟文档标为可写 | 当前 document ID |
| Save All | 当前项目存在可保存 dirty 文档 | 汇总 dirty，不包含每行文本 |
| Close Editor Tab | 活动 text/media/editor-terminal/standalone 任一存在 | 活动 workbench item ID |
| Synchronize | workspace 存在；已有 refresh 状态按既有工作流处理重复请求 | 无 |
| Settings | 应用可用 | isSettingsPresented |
| Check for Updates | !isChecking | checking 布尔，进度不入菜单 |
| Project / Commit / Find | workspace 存在；Commit 要求 Git 模块在策略上可使用，Find 要求 Search 模块可用；Commit 不要求休眠 feature 仍持有 repository | isSidebarVisible && selectedSidebar 对应项 |
| Git | workspace + Git 模块在策略上可使用；inactive/sleeping/仓库状态 unknown 仍允许用户打开检测 | isGitLogVisible |
| Terminal / Run / Debug / Problems / Tests | workspace + 对应模块在策略上可使用；active 非必要 | 对应工具窗 visible |
| Merge All Project Windows | workspace 存在，至少两个可合并项目窗口 | 现有 presentation 的真实目标数，不用所有无关窗口数 |
| Move Project to New Window / Previous / Next Project Tab | 当前窗口在可拆分的 native tab group | `canDetachSelectedProject` 和 context |
| Back / Forward | canNavigateBack / canNavigateForward | 无 |
| Search Everywhere / Find in Files / Replace in Files | workspace + Search 模块可用 | 无；Find 工具窗不是 Find in Files 弹窗 |
| Go to Line / Find in File / Replace in File | active text document；Replace 排除只读 | active document ID |
| Find Next / Previous | Find 可见且 count > 0 | count 只投影 hasMatches，避免每次当前位置更新菜单 |
| Definition / Implementation / Find Usages | active text document 对应 capability 可用 | capability 集合，非整个 LSP 状态 |
| Edit Configurations / Rescan | workspace + Execution 模块可用 | 复用现有 editor/rescan 行为 |
| Language Support Settings | 应用可用 | 无 |
| Restart Language Servers | workspace + Language 模块可用 | 无 |
| Local File / Project History | active document / workspace + history 能力 | 对应稳定路径 |
| Git Commit…（显示面板） | workspace + Git 模块在策略上可使用；不是提交写操作 | 确保显示 Commit pane，不与 toggle 动作混淆 |
| Push / Update / New Branch | Git feature active 且 repository ready、current reference 存在 && !isPerformingBranchOperation | reference ID；执行前验证仍属于当前 repository |
| Fetch | Git feature active 且 repository ready && !isPerformingBranchOperation | repository identity |
| Branches | Git feature active 且 repository/reference 元数据 ready | 当前 repository identity |
| Show Log | workspace + Git 模块在策略上可使用 | 确保打开并激活 Git；toggle-git-log 切换可见性 |
| Appearance → Theme / Mode | settings 可更改 | colorTheme、themePreference 的 raw value |
| Editor Tabs → Single Line / Multiple Rows | 编辑器可用；设置本身为应用级 | editorTabLayoutMode |

模块“可用”包含 enabled/未隔离/实现注册正常；inactive/idle/sleeping 可以由用户动作唤醒，disabled/failed 不得假装可操作。菜单状态读取不触发 module activation。工具栏与菜单可以分别使用 toggle / ensure-visible 语义，但要在命令定义中显式区分，不能同一个 ID 对不同入口做相反操作。

工具窗打开资格与 Git mutation 资格明确分离：当前 `gitRepositoryRoot` 来自 `gitFeatureIfActive`，休眠/清理后变 nil 不能当作“项目没有仓库”锁死 Git/Commit 入口。打开/恢复工具窗先按已有模块工作流唤醒，再检测仓库并显示 loading/ready/not-a-repository/failed；非仓库展示真实状态，不保留上个项目结果。Push/Fetch/Update 等在准备期间保持 disabled，repo/reference ready 后才更新。折叠已打开工具窗无需等待检测完成，并取消该工具自己拥有的加载。单元/集成测试必须从 module inactive 或 sleeping 开始实际执行 tool command，验证激活、仓库检测、进入 ready 及随后 mutation enabled，不能只检查一份构造的 enabled 布尔。

Recent Projects 空列表保留不可点击的空状态；同名目录显示可区分的简短父路径并用完整路径 help，不改变 recent store 排序/打开策略。动态项目消失后，已显示 item 的 payload 不变，点击进行实时校验。

## 7. 命令、默认快捷键及冲突

继续复用 [LitheCommandCatalog](../../macos/Sources/Lithe/Models/Keymap/LitheCommandCatalog.swift)、[KeyboardShortcutFeatureModel](../../macos/Sources/Lithe/Application/Features/KeyboardShortcutFeatureModel.swift)、[LitheActionRegistry](../../macos/Sources/Lithe/Models/LitheAction.swift)。不另建只供工具栏使用的键表。

| 工具窗 | command ID | B1 默认 macOS binding | 实际执行 |
| --- | --- | --- | --- |
| Project | **新增** `toggle-project` | ⌘1 | `toggleSidebar(.project)` |
| Commit | **新增** `toggle-commit` | ⌘0 | `toggleSidebar(.changes)`；展示名统一 Commit |
| Find | **新增** `toggle-find` | ⌘3 | `toggleSidebar(.search)`，保留已有查询与结果 |
| Run | `toggle-run` | ⌘4 | 改为 `toggleRun()`，确保模块激活 |
| Debug | `toggle-debug` | ⌘5 | `toggleDebug()` |
| Problems | `toggle-problems` | ⌘6 | `toggleProblems()` |
| Git | `toggle-git-log` | ⌘9 | `toggleGitLog()` |
| Terminal | `toggle-terminal` | ⌥F12 | `toggleTerminal()` |
| Tests | `toggle-tests` | 不新增猜测默认键 | `toggleTests()` |
| Settings | `settings` | 保留 ⌘, 和用户 override | `showSettings()` |

上述默认键已由主任务核对 GoLand 官方 macOS keymap；Structure/TODO 常用键也不能提前绑定到假动作。`search-in-project`（Find in Files）、`replace-in-project`、`find-in-file`、`replace-in-file`、`search-everywhere` 等 ID 全部保留原义和既有默认/override。不要拿 ⌘3 替换 Find in Files 的 ⇧⌘F。

`performShortcutCommand` / `canPerformShortcutCommand` / LitheActionRegistry 必须覆盖新增 ID。动作目录与菜单状态共用 predicate；现有测试对命令总数写死 37，需要更新为有意义的命令集合约束，仍验证唯一性、完整动作实现和默认键互不冲突。

有效快捷键规则必须优先保护用户已有配置：

1. 持久化 override 的合法条目完全保留，包括空数组（显式不绑定）。B1 不批量 reset，不因新默认键与旧 override 冲突而删除用户条目。
2. 增加统一的 resolved-binding 投影：显式 override 优先于所有 defaults。新 ⌘1 等被现有用户命令占用时，该工具窗的冲突默认键暂不注册；菜单/tooltip/设置均显示实际剩余 binding，并在 Keymap 标识冲突由哪个命令占用。
3. 若已存储的两个显式 override 本身冲突，不靠 matcher 的 first-wins 随机执行；保留两条原始配置、标识双方冲突，冲突 binding 暂不注册，其他无冲突 binding 继续生效。用户解决后立即恢复。
4. 默认键之间继续由 catalog 静态验证互斥。程序内部排序稳定，不能由 Dictionary 遍历顺序决定归属。
5. `effectiveBindings`、`registrations`、`primaryKeyPress`、`displayText`、conflict 检测和菜单 keyEquivalent 必须共用 resolved 结果。设置若展示原始 binding，需要清楚区分“已设置但冲突未启用”，不能误当生效。
6. 单项 Reset 前计算其默认键与别的显式 override 是否冲突；保留对方绑定，展示本命令受阻状态。Restore All Defaults 仅由用户明确点该既有动作时清空 override。
7. 原持久化 schema 不必为 B1 改版：resolved conflicts 可即时计算。reload/多项目共享 settings 后必须得到相同结果。

工具栏 hover 用本地化标题加 `keyboardShortcutFeature.displayText(for:)` 的有效结果，例如 `Project (⌘1)`；无绑定只显示 Project。AX label 保持干净的动作名称，AX help/tooltip 包含快捷键。保持原生 `.help` 延迟和 hover 行为，不用自建 floating window。底部 module contribution 的 action ID 必须显式映射到 catalog command ID，不以显示标题匹配；右侧已有可执行入口如没有 catalog 命令只显示真实标题，后续批次再注册。

避免一次按键执行两次：按第 3.1 节修正现有 MacShortcutDetector 的消费前门禁，menu keyEquivalent 是同一注册的系统入口。应用级与项目级 registrations 分离且绝不重叠；Settings 下只保留允许的应用级输入，inactive project 的 detector 继续 stop。快捷键录制期间暂停两类普通 detector，结束录制不能意外解除 Settings/modal 暂停。验证从编辑器、Project tree 和 Terminal 聚焦时每次按键只切换一次。

## 8. View 菜单的实际内容

在默认 View 菜单通过适用的 `CommandGroup` 扩展点加入 Tool Windows 和 Appearance，避免再造第二个同名 View 菜单。实现前在本机菜单树确认系统已有项的位置。保留系统 Full Screen 等原生命令及其 keyEquivalent，不重复安装。

- **Tool Windows**：Project、Commit、Find；Git、Terminal、Run、Debug、Problems、Tests。可用性、勾选、快捷键按上表。Window 中可保留相同项目作为兼容入口，但两处必须共享同一 command ID 和 payload，不能重复配置键位。
- **Appearance**：当前已支持的 Color Theme（Lithe/Codex/Linear）、Appearance Mode（System/Light/Dark）；打开 Appearance Settings 的入口复用 Settings 的现有 General/Appearance 内容。此批不声称已经支持动态主题插件。
- **Editor Tabs**：Single Line / Multiple Rows，直接绑定现有 editorTabLayoutMode，实际标签渲染立即更新。

隐藏全部工具窗、工具栏可见性、Presentation/Distraction Free、行号、软换行、whitespace 等未有完整状态保存/恢复契约的项留在整体方案的后续批次。B1 不加 disabled 占位项。Project/Commit 已打开时再次点击应隐藏；再次打开保留展开、搜索和选中状态。

## 9. 分步实施与 commit 边界

1. **B1a menu lifecycle**：增加投影、focus context、native key-window eligibility、root tracking coordinator 和消费前/执行前门禁；全局动作路由明确可见 host / 无 host 路径；迁移全部现有 Commands enabled/selected 数据，接受限异步最近项检查。先验证最近菜单稳定且实时状态仍正确。相关行为测试与修复同一 commit。
2. **B1b tool commands**：注册 Project/Commit/Find、修正 Run route、增加默认键与冲突解析、接 tooltip 和菜单。自定义键迁移/冲突与路由测试同一 commit。
3. **B1c View**：加入已有 Tool Windows、Appearance 和 Editor Tabs，完成状态一致性及真实点击验收。内容相对少时可与 B1b 同批，但不能与未验收的 B1a 混成一个大提交。

每步先查当前文件状态，保留其他 agent/用户修改。本文只计划 Swift/macOS 变更，不需要新增 Rust command 或插件 wire schema。

## 10. 测试与运行验收

先按 [write-stable-tests](../../.agents/skills/write-stable-tests/SKILL.md) 编写必要行为测试；现有 [KeyboardShortcutTests](../../macos/Tests/LitheTests/KeyboardShortcutTests.swift)、[MacKeyboardShortcutTests](../../macos/Tests/LitheTests/MacKeyboardShortcutTests.swift)、[ProjectWindowManagerTests](../../macos/Tests/LitheTests/ProjectWindowManagerTests.swift) 可复用。新测试 fixture 用合成项目和测试 store，不访问个人项目/网络。

**投影与时序**：

- 初始 welcome、workspace、standalone 三种状态的菜单权限覆盖上表。
- 手动 scheduler 触发 willChange → 修改底层值 → drain；断言得到新值。多次修改合并到一次、值不变不发布、dispose 后不发布。
- Git terminal/run 文本输出或 cursor 连续变化一千次，命令事实不变：不发布菜单状态；对投影任务的合并数量设明确预期，防止只把千次重绘变为千次昂贵计算。
- Find count 0→1→0、能力未知→可用、dirty→saved、Git busy→idle、模块 enable/disable、native tab 合并/拖出、键位修改都更新相应 enabled/selected；被动模块不被菜单唤醒。
- 旧最近项检查在新列表/新 workspace 后才返回，结果丢弃；失效 URL 不产生错误路由；文件检查次数证明 body 没有 I/O。

**tracking 与动作**：

- begin(A)、多次低/高频状态更新、end(A)、drain：tracking 期间 renderState 恒定，结束只发布最终状态。
- 重复 begin、未知/重复 end、两个 popup 根、end 后排队未提交又 begin 均不能提前解冻或永久冻结。
- 菜单取消也刷新；stop 撤销观察器与 pending task；项目关闭使旧 context 无效。
- A/B 项目不同 active doc、Git busy 和 tool selection；菜单来自 A，A 关闭或切 B 后旧 action 不执行；B 新菜单只操作 B。测试 action-before-end 与 end-before-action 两种顺序。
- Settings/welcome/standalone context 行为明确；菜单 focus 暂时 nil 不清空 tracking item。
- activeWindowID 不变但 Settings 成为 key：即时 native eligibility=nil，旧项目 Cmd1/CmdF/双 Shift 不执行且不吞 Settings 键；返回项目后恢复。覆盖菜单 tracking 造成仅 SwiftUI focus nil、真正 native keyWindow=nil、sheet/modal、app resignActive 及点击/回调之间切窗。
- 全局 CmdO/自定义 Settings binding 在 Settings 内仍执行；所有项目窗口关闭后取消 Open 不增加 modelFactory 次数，确认 Open 只创建可见项目，Settings/Clone 显式 Welcome host 只创建一次。host 注册回调晚到、host 中途关闭、重复请求、退出全部清空 pending。
- Open File 无 host 的取消同样不创建 model；选文件后只出现对应可见 standalone 窗口，项目相关工具命令保持禁用；已有 project host 时复用当前编辑器，chooser 期间 host 关闭则创建明确的 standalone 窗口。
- 显示 Push 可用后 busy，点击时拒绝；不能以冻结 snapshot 为准执行 Git mutation。

**快捷键**：

- 默认工具键映射、tooltip/menu/recorder/detector 显示一致；旧 override、显式空 binding、覆盖新默认、两条旧 override 冲突、reset/reload、多项目 settings 更新。
- 新命令在 catalog、registry、canPerform、实际执行全覆盖。Run 动作实际激活模块，不能只断言一个 Bool。
- Cmd3 是 Find 工具窗，ShiftCmdF 仍是 Find in Files。菜单与 detector 单次事件仅执行一次。
- 全局/项目 registrations 的 binding 交集为空；不合格事件必须原样返回，不能只断言 action 回调没发生；异步 command dispatch 再验证阻止旧窗口操作。局部 Return handler 不劫持 Settings/chooser 的 Enter。

**真实 AppKit / AX 验收**：

1. 构建隔离 ARM64 QA app，打开两个合成项目；按现有生命周期规则只运行一个 QA 实例。
2. File → Recent Projects 展开后不再输入，至少保持 3 秒，覆盖现有 0.73 秒消失故障窗口；随后实际点击末项并确认对应项目打开。重复 10 次包含主菜单横向切换和子菜单悬停；AX 记录 item 数和时间，截图仅作布局证据。
3. 在可控终端持续输出、后台 Git 状态更新、文件 dirty/保存变化时重复。记录 tracking begin/end 根身份与 menu-state publish 次数，A/B 比较证明故障与修复关联。日志不记录终端内容或环境变量。
4. 打开 View/Tool Windows，点击每个现有工具；再次点击隐藏，再打开状态保留。逐项 hover 验证实际快捷键；Settings 修改键位后 menu/tooltip/键盘同步变化。
5. 两项目交替、合并、拖出，分别从菜单与快捷键执行 Project/Find/Terminal，确认没有跨项目操作；Settings 独立窗口聚焦时不误操作后台项目。
   在 Settings 中实际键入普通文本、Enter、CmdF、双 Shift，确认未被后台 handler 吞键；CmdO 与 Settings 自定义全局键仍有效。关闭所有项目后逐项验收 Open/取消、Recent、Settings、Clone 的可见 host 流程。
6. 小窗口与默认窗口确认菜单在屏幕可达范围；终端聚焦下 OptionF12 打开/关闭一次；输入法中英文状态不影响 command modifiers。
7. 退出 QA 和其子进程，注销临时 app 注册；确认没有遗留 QA 进程。用户的常规应用按授权正常退出，不强杀。

静态和测试命令：

```sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter '<B1 affected suites>'
./scripts/test-macos.sh
./scripts/verify-service-boundaries.sh
git diff --check
```

按当前项目工具链使用 Swift 6.2 和现有 Rust 静态库链接参数。最终需完成产品 ARM64 build，并在 `.artifacts/goland-parity/iteration5-b1/acceptance.md` 记录实际 build/test 命令、timing HTML/JUnit、GUI 检查结果及截图；不要把未运行的条目写成通过。

B1 完成要求是菜单生命周期修复、状态不丢更新、动作不跨项目、快捷键不覆盖用户配置以及 View 现有项实际生效全部成立。独立 reviewer 必须同时审查本方案与整体方案；B1 通过不意味着全部 GoLand 对齐目标完成。
