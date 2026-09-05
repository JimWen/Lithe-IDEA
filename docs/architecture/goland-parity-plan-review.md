# GoLand 对齐方案独立审查

审查日期：2026-09-06。审查对象：`goland-parity-implementation.md`、`goland-parity-b1-commands.md`、`syntax-and-completion.md`，以及对应 Commands、窗口/session、快捷键、插件校验、文件操作和 Rust runtime 源码。审查者为独立 `parity_plan_review` agent。

状态：**本轮 6 项方案发现均已修订并复核；B1 可以开始 B1a/B1b/B1c 实现。总体和语言方案可作为后续批次设计基线，各批次仍须完成具体接口审查及产品验证。此结论不代表实现或验收通过。**

本轮遵循 `develop-lithe` 与 `write-stable-tests`。fast-context 因缺少 API key 不可用，改用 `rg` 和直接源码阅读；没有提取凭据。没有修改产品源码、测试或提交，也没有启动 Lithe 测试实例。运行了已安装应用的只读 `codesign -dv --verbose=4` 来核实插件签名交付条件。

## 1. 判定

B1 的核心方向可行：缩窄菜单状态、等值去重、正确处理 Combine willChange、原生 tracking 期间冻结展示、携带原始 context 路由，以及真实 AppKit A/B 验证，均覆盖了原有方案的主要风险。

首轮 B1 不可按原文开始。修订复核后，**R1、R2、R6 的方案阻塞已解决，B1 可以开始实现**，无需用户重新批准已授权工作。新增的真实 focus 门禁、可见 host 路由和受限后台 I/O 都必须随本批实现和验收，不能在实现中再退回旧路径。B1 通过不代表 B2–B7、L0–L7 或新增 Git 对齐完成。R3–R5 在其依赖批次开始前必须解决，不能通过缩减最终门槛绕过。

## 2. Findings

### R1 · P1 · 最近项目 ID 无法代表真实命令焦点，当前快捷键还会提前吞掉事件

**影响批次：B1a/B1b。状态：方案已解决，实施待验证。**

B1 原第 3 节把 `ProjectWindowManager.activeWindowID` 和 `activeSessionID` 定为权威活动身份，同时要求 Settings 等窗口禁用后台项目操作。源码中 `activeWindowID` 是非 optional，只有另一个已注册项目 `activate` 才改变；Settings 聚焦不会清空它。`ProjectSettingsWindow` 仍借用最后项目模型。因此观察这两个 ID 无法区分“项目仍为最后活动项目”和“其窗口现在具有命令资格”。

此外，`MacShortcutDetector.start()` 在找到注册项后先 `return nil` 消费事件，再在 Task 中调用模型。只在菜单或异步动作里加 `canPerform` 会继续吞掉 Settings 的输入；只更新冻结状态也不能阻止后台项目操作。

修订要求：独立的 native key-window eligibility，明确 project/welcome/standalone/Settings/未知窗口/modal/无焦点；不能用永久 fallback 到最近项目来恢复资格。区分冻结的 render context 与实时执行资格；消费前同步判断，执行前再次验证 origin context。保留 Settings 下 Open/Settings 等应用级快捷键，未接管事件必须传回 responder。补“按键捕获后、异步执行前切项目”与 Settings/modal 聚焦回归。

源码：`Models/Workspace/ProjectWindowManager.swift:9,31,102`、`Platform/MacOS/UI/MacShortcutDetector.swift:178–196`、`Models/AppModel/AppModel.swift:616,685`、`LitheApp.swift:444`。

### R2 · P1 · 应用级 Open/Recent/Settings/Clone 的所有权与可见承载点未定义

**影响批次：B1a。状态：方案已解决，实施待验证。**

B1 要求没有 project context 也能使用全局动作，并禁止创建隐形 AppModel，但只列 coordinator 路由名，未说明怎样调用现有能力。当前 chooseProject/chooseEditorFile 依赖模型的 platformUI 和 project-open 回调；Settings 与 Clone 分别写模型状态，再由 RootView 打开窗口/挂 sheet。`activeSessions` getter 在无 registry 项时还可能创建 session，不能作为无副作用的 lookup。

修订要求：明确应用级 UI 请求端口和可见 host 解析；在 Settings/welcome/无项目窗口时 Open、Recent、Clone 分别开到哪里、怎样保留项目打开策略和取消语义。使用非创建的 registry lookup；需要新 host 时显式创建并排队请求，不能调用后台模型但不展现其 sheet。Settings 命令要能直接聚焦既有 Settings 窗口。补取消 Open 不新增 session、Clone 窗口实际可见、完成后打开正确项目的验收。

源码：`Models/AppModel/AppModel.swift:256,859–891`、`Models/AppModel/AppModel+FeatureState.swift:8`、`Views/App/RootView.swift:164–171`、`Models/Workspace/ProjectWindowManager.swift:31,51`。

### R3 · P1 · L7 的同 Team 外部 worker 安装与当前 ad-hoc 交付链路不兼容

**影响批次：B5/L5/L7。状态：方案已解决，实施待验证。**

语言方案第 6.3 节选同 Team 签名 syntax worker，要求在当前宿主外部安装全新 grammar；然而已安装 `/Applications/Lithe.app` 的只读签名结果为 `Signature=adhoc`、`TeamIdentifier=not set`。`scripts/package-app.sh:13` 默认签名身份也是 `-`。现有 `MacOfficialPluginSignatureVerifier` 对双方均无 Team 的唯一例外要求插件在宿主 bundle 目录内。故沿用现有信任策略不能安装外部示例包，也不能证明最终插件扩展门槛成立。

修订要求：在 B5/L7 前明确可执行的签名交付路线，以及该路线在本机和正常产品安装后的验收方式。可选择具备有效签名身份的正式交付，或另行设计范围明确、可审查的开发信任机制；不得把所有 ad-hoc 外部可执行文件自动视为可信，也不得把仅 mock verifier/重新打包宿主代替独立安装。纯数据包的校验路线须与可执行 worker 分开。若需要当前不存在的外部条件，应在该批次实质受阻时报告，不能先写成可验收。

源码：`Platform/MacOS/Plugins/MacPluginPackageStore.swift:458–495`、`scripts/package-app.sh:13,148`。证据命令：`codesign -dv --verbose=4 /Applications/Lithe.app`。

### R4 · P2 · 新语言示例的验收低于主方案最终门槛

**影响批次：L7，以及主方案语言验收矩阵。状态：方案已解决，实施待验证。**

主方案要求新语言插件安装后真实高亮、导航、补全、格式化；语言方案 L7 的 Lua 示例只验证编辑、高亮、本地补全和启停，且明确 syntax worker 不负责 formatter。按目前 L7 表完成后仍不能满足主方案门槛。

修订要求：保留原门槛，给 Lua 示例补明确导航实现及 formatter/module 路由、安装声明与真实验收。语法 worker 继续只负责语法；formatter 使用受管理的独立工具/LSP 能力。验证未保存文本版本、取消/Undo、禁用/卸载后能力撤销。新 grammar 不在主包的证明与这些功能证明须同时成立。

对应原文：主方案第 3 节及 L0–L7 节；语言方案第 6.3 节末尾和第 8 节 L7 行。

### R5 · P2 · 增量合并、文本接受与解析取消缺少同一状态机

**影响批次：L1/L7。状态：方案已解决，实施待验证。**

syntax.change 的 baseVersion 必须精确匹配，同时每文档只留一项运行、一项合并待办；原文未定义合并中间编辑，以及请求已更新缓存文本后解析取消/超时的确认语义。例如 A→B→C 连续编辑时若仅保留 B→C 的最后 delta，Core 仍在 A 将反复 resync；若 change 更新到 B 后返回 cancellation 错误，客户端也不知道接受的是 A 还是 B。严格版本校验能避免直接错用范围，但不能保证稳定增量处理和可证明的重试。

修订要求：区分 accepted text version 与 parsed result version；明确 change 文本事务的提交点、取消发生在提交前/后的响应、解析失败时旧树归属。待办必须合并有序 edits 或转换成有界一次 resync，不得丢掉依赖的中间 delta。新增受控 A/B/C、提交后取消、旧解析迟到、resync 与 close 交错 fixture，并保持 UI 仅应用所请求版本结果。

对应原文：语言方案第 4.1–4.3 节。

### R6 · P2 · 最近项“异步检查”目前没有真正后台执行契约

**影响批次：B1a。状态：方案已解决，实施待验证。**

B1 第 4 节指定通过现有文件操作 port 异步检查最近项，但 `WorkspaceFileOperations.fileExists` 是同步接口，macOS 实现直接调用 FileManager。Application Feature Model 又位于 MainActor，仅加 `Task` 仍会在主线程执行 I/O；慢盘/网络卷会冻结菜单，抵消本批修复目的。

修订要求：平台适配器拥有受限后台执行器，经异步窄 port 返回状态；明确 deadline、最多在途数量、取消及晚到丢弃。超时保持 unknown，不能把 timeout 当不存在；不可通过不断派发无法取消的检查耗尽工作线程。菜单 body 和 tracking begin 均不得同步 stat。测试检查主线程不执行 port 的阻塞部分，并验证超时/旧列表结果。

源码：`LitheCoreContracts/Workspace/WorkspaceFileOperations.swift:3–5`、`Platform/MacOS/FileSystem/MacWorkspaceFileOperations.swift:4–5`。

## 3. 新追加要求的纳入检查

- Rust 部分以用户已打开的 RustRover 实际版本与截图补充参考，至少覆盖 Cargo 工具窗、入口 Run/Debug、补全/参数提示与 Rust 设置。不要把 GoLand 的 Go 特有语义直接复制给 Rust。
- 主方案需新增 G1：全部上述能力之后重新打开底部 Git，对比 GoLand 的布局、分支列表与 graph 线条。`c09f2cc4` 只作为已有样式基线，不能作为本轮最终验收。包括窄窗口、提交筛选/搜索、选择/详情、滚动、merge commit 分叉/汇合、多个 refs、两主题；如果修改 graph 布局/算法，运行 `verify-git-graph.sh`，并保留 parent 拓扑正确性，不能只为更少线条而丢分支关系。

这两项已由主 agent 补入主方案与语言方案，并已复核其要求映射：G1 明确在上述方案完成后重新验收；RustRover 基线版本和四项采样证据已列出，尚未实际核对的补全/重构仍标为后续工作。本审查未自行操作用户的 RustRover 或 GoLand 窗口，也不以方案中列出的截图名称代替最终 GUI 验收。

## 4. 复核记录

| 项目 | 首轮结果 | 修订后结果 |
| --- | --- | --- |
| R1 实时焦点与事件消费 | 阻塞 B1 | 已复核：第 3/3.1 节区分 native eligibility 与最近项目；事件消费前同步门禁、执行前再校验；全局/项目注册分离；菜单 tracking 和局部 Return handler 不抢键 |
| R2 应用级操作承载 | 阻塞 B1 | 已复核：第 3.2 节非创建 registry lookup；Open/Open File 先 chooser，取消不建 model；明确可见 project/standalone/welcome host 及 attach 后排队呈现 |
| R3 签名交付与独立安装 | 阻塞 B5/L7 | 已复核：语言 6.3 和主方案 4.4 一致；正式签名默认不变，仅用户主动本地安装独立 worker/formatter 可走内容与版本绑定授权；探测也在授权后，升级失效，QA 必须实际安装 |
| R4 新语言完整验收 | 修订后才能进入 L7 | 已复核：Lua 加 Structure/同文件 definition 和独立 StyLua adapter；声明/路径/配置/版本/取消/Undo 与安装启停回滚验收同列，主包不得包含 Lua grammar |
| R5 增量/取消状态机 | 修订后才能进入 L1/L7 | 已复核：语言 4.1.1/4.1.2 明确 accepted/parsed 版本、applied/notApplied、完整有序 ledger、幂等确认与一次 resync；应用查询通过同一 completion 有界等待 parse，不依赖再次输入或轮询，成功/超时/取消/close 释放 waiter |
| R6 最近项后台 I/O | 修订后才能进入 B1a | 已复核：第 4 节窄 async port、真实并发 1/最新待办 1、1 秒响应预算；不可取消 stat 保留 busy，超时 unknown，点击不追加主线程同步检查 |
| RustRover 与 G1 | 追加目标待纳入 | 已纳入并复核方案；基线采样与未来实际验收明确区分 |

此记录是设计审查，不是源码审查或运行验收报告。方案问题修订后仍须按批完成真实实现、测试、AppKit 点击/输入/截图与独立代码审查。

B1 复核还确认休眠模块的入口与 Git 写操作资格已经分开：Git/Commit 工具入口允许唤醒并检测仓库；Push/Fetch 等要求 ready repository。避免 `gitFeatureIfActive == nil` 将可唤醒工具永久置灰。该行为也已加入本批测试门槛。
