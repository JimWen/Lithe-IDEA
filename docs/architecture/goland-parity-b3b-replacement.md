# B3b 搜索范围与跨文件替换事务

状态：基于 `517b4584`。B3b1a Unicode matcher/候选修复已完成，方案与代码经 `workbench_audit` 独立审查通过，自动检查和 ARM64 真实点击见 [验收记录](#b3b1a-acceptance)。下述 scope 与事务为后续实施设计，原生 undo 仍须专项审查；本次审查未放行新的 Apply 事务。B3a 和 B4a0–B4a3 已验收，跳过；Project 按用户要求暂停。本批是 [B3 搜索方案](goland-parity-b3-search.md) 的细化，后续 B3c/B3d、设置、语言和 Git 批次仍保留。

## 1. 先解决什么

先修可能扩大替换范围、覆盖新内容和无法恢复的路径，再统一 Find/Replace 排版。本批继续使用 Rust matcher/index、Search 模块、EditorDocument 生命周期和原生编辑器，不替换引擎，不修改第三方代码。

| 优先级 | 核对结果 | 处理 |
| --- | --- | --- |
| P1 | Rust `replace_preview` 把 `paths: []` 当全项目；Open Files 直接复用此调用 | 区分未指定范围和明确空集合，空集合不扫描、不写入 |
| P1 | 应用预览只读取当前文本，没有与生成预览的原文比较，仍写入旧 `replacementText` | 预览携带源文本身份，应用前校验整个选中集合，过期则零写入并保留预览 |
| P1 | AppModel 的 `recordHistory` 会 await；返回后未验证工作区、文档和文本是否还是原来的版本 | 应用独立身份，捕获后不重新解析为另一工作区；每个异步准备阶段后复核 |
| P1 | 当前逐文件写入、失败后继续；打开文件调用 `saveDocument`，连带保存用户原来的未保存修改 | 关闭文件可回滚事务；打开文件留在编辑缓冲区，使用现有自动保存设置 |
| P1 | 没有跨文件 undo；`CodeEditorView` 同步全文使用 `textView.string = document.text`，不能由此推断已注册原生撤销 | 事务与原生 undo 必须一起验收，单文件撤销或 Local History 不能代替整批撤销 |
| P1 | 显式路径的预览可以跟随指向工作区外的 symlink；路径字符串前缀不足以约束文件写入 | 预览和提交分别检查实际目标；一期拒绝 symlink/hardlink 的替换目标并说明原因 |
| P1 | literal ignore-case 用 lowercase 文本的字节位置切原文；`İ needle`、`İ`、`K` 已复现进程 SIGABRT | B3b1a 已修复并验收；原文位置与 Unicode 匹配正确，索引候选覆盖 simple folding |
| P2 | Project/Directory 没有传未保存文本；即使给 Rust 全项目预览传 overrides，索引候选也可能漏掉新匹配 | 统一 scope，候选集包含有效 override 路径；打开文本覆盖磁盘文本 |
| P2 | Swift 用 NSRegularExpression 验证，Rust 用 regex 执行；Rust 错误在可选返回值后变成空结果 | Rust 返回结构化错误；UI 展示实际引擎错误，不显示“无匹配” |
| P2 | Rust 对 query 做 trim，不能准确查找两端空格 | 只把长度为零当空查询，保留文字中的空格；Find/Replace 使用同一语义 |

2026-09-06 使用当前 ARM64 release 动态库执行了 7 个隔离样例，结果在 `.artifacts/goland-parity/iteration8-replacement/baseline-core-probes.json`，包含库摘要和基线提交。确认了空 paths 扩大范围、未保存新匹配遗漏、query trim、Rust 不支持 lookbehind、显式 symlink 路径跟随。普通 literal 替换的 CRLF/末尾换行保留已通过，不重复修改。此记录是现有行为复现，不是新实现验收，也不代表 UI 已完成这些检查；临时目录已删除。

另有 `.artifacts/goland-parity/iteration8-replacement/baseline-unicode-probes.json`：前三个 Unicode 场景各自在有 6 秒超时的独立诊断子进程中运行，均退出 `-6`；第四个 `ſxſ`/`sxs` 场景显示现有 lowercase 语义不匹配。所有诊断进程已经结束，临时文件已清理。

## 2. 可复用边界

- `LitheSearchModule/Application/SearchFeatureModel.swift`：继续拥有结果、预览和 busy。保留 B3a 的独立请求代际以及 apply 期间 clear/reset 不提前解锁的行为。
- `Models/AppModel/AppModel+SearchModule.swift`：捕获项目身份、把视图参数映射到请求、展示结果。事务不能继续嵌在包含多次 await 的逐文件闭包中。
- `LitheSearchModule/Ports/SearchOperations.swift`、`Core/Rust/RustCoreBridge.swift`、`rust/lithe-core/src/project/files.rs`：复用 matcher、可见性和索引，补齐 typed 请求/错误及预览数据契约。
- `EditorDocument` 已有 UUID、revision、savedText、dirty/saving/conflict；`DocumentFeatureModel` 已有保存/自动保存/外部变更决策。事务借用这些事实，不另造一份文档缓存。
- `AppModel+Development.applyLanguageWorkspaceEdit` 已有关闭文件先写、打开文件最后变更且不立即保存的流程；只复用其方向。它会忽略回滚失败且没有版本与整体 undo，不能直接作为安全事务实现。B6 再接新事务，不在搜索修复中顺手重写全部 LSP 调用。
- `MacRunConfigurationStore` 的快照、逆序回滚、原子写和 `MacFileWriteEventSuppression` 可借鉴；配置存储不是代码文件通用事务，不直接扩展它承担编辑器功能。

## 3. 请求与预览契约

### 范围、错误和限额

Find 与 Replace 使用一个不可变请求值：工作区身份、query/options、Project/Directory/Open Files、目录相对路径或明确文件集合、文档快照。Directory 以原工作区为 root，按相对路径过滤，避免改 root 后 ignore 和 override 标识失配。Open Files 使用捕获时的真实集合；空集合在 Swift 和 Rust 两层都返回空结果。

Rust 保留现有调用的兼容语义，新增显式文件集合模式；新宿主总是发送模式。旧请求省略新字段时保持原行为，不能直接把旧 `paths: []` 改成另一含义。新模式下，未指定 paths 与明确空 paths 可区分；拒绝矛盾组合，绝不悄悄扩大范围。所有输出按工作区相对路径、行和匹配位置排序并去重。

override 不能依赖磁盘索引已经命中 query。Project/Directory 将满足范围与可见性规则的 override 路径并入候选；同一路径使用打开文本一次，不能再加磁盘结果。Open Files 明确选择已打开文本，但不越过工作区边界。只读文档可搜索，替换时明确拒绝。丢失文件、解码失败、权限错误、无匹配和取消使用不同结果，不再用 `nil ?? []` 混为一谈。

错误由实际 Rust matcher 生成；本阶段不增加另一个 regex 引擎。不支持的 lookaround/backreference 明确提示，不声称与 GoLand regex 完全相同。Unicode、零长度匹配、捕获组展开、大小写保留、行结束和 UTF-16 位置用 fixture 固定；逐行 matcher 的跨行限制也必须显示在能力说明中。

替换预览增加受控的文件数、匹配数、源文本及结果总字节预算，数值集中在命名 policy，并以性能样例选定。超过预算返回 incomplete 状态与缩小范围提示，不允许把被截断的预览当作完整范围执行“全部替换”。普通搜索仍可展示有明确截断标记的前 N 项。

### 原文与选择

预览每个文件带精确 `sourceText`、完整 `replacementText`、稳定匹配标识及 UTF-16 范围。采用原文而非单独摘要，减少另一套摘要端口，并直接作为回滚/undo 的依据。代价是增加源文本 payload，必须计入总预算。源文本按 UTF-8 字节精确比较，不能用 Swift String 的规范等价比较当作文件字节身份；保留 BOM、CRLF、末尾换行和 Unicode 规范形式。

App 层另保留工作区/session 代际、文档 UUID/revision/URL、磁盘文件身份和原始字节。文档关闭重开、迁移路径或外部文件替换后，即使内容偶然相同，也要重新校验当前目标与编辑权限。原文缺失的旧版预览可显示，Apply 必须拒绝并要求重新预览，不能退回不校验写入。

当前已有文件勾选和全选，复用。B3b 后段再添加 occurrence 级排除：从同一源文本和选中 edit 范围重新计算结果，先验证范围合法且不重叠；不可直接在已替换的字符串上依次替换。

## 4. 事务及生命周期

### 所有权

新增应用层 `WorkspaceTextEditCoordinator`，持有一次事务的状态、目标快照和恢复记录；通过 Core 端口调用 macOS 文件适配器，不在 Application/Services 创建 FileManager 或文件句柄。macOS 组合根创建适配器。Search 模块提交准备好的纯文本 edit 请求，不导入 AppKit，也不直接改 EditorDocument。

macOS 适配器在专属串行 worker 完成读取、目标检查、暂存、替换和回滚，异步端口桥接到应用层；不把同步 I/O 放进 MainActor 或 `Task.detached` 协作线程。事务状态为 preparing、committing、rollingBack、applied、cancelled、failed、recoveryRequired，包含 transaction ID 和所属 workspace identity。

### 执行顺序

1. 首个 await 前捕获 Apply 身份和完整 selection；冻结这一份 edit 请求，避免用户改变勾选后旧任务改写新选择。依赖激活后重新验证。准备阶段可取消，另一项目的切换不改变已捕获的所有者。
2. 校验所有目标源文本、文档版本、可写性和实际路径；收集打开缓冲区与关闭文件的独立原始快照。目标先按相对路径排序去重；同一实际文件的多个别名拒绝，不重复写。存在任何冲突则零写入。
3. 预计算所有最终文本和逆向恢复内容，预先分配恢复记录；Local History 使用同一不可变原文做辅助快照，不能代替事务快照。任何 history await 返回后再次校验。历史记录失败要明确反馈，不静默伪装记录成功。
4. 在 MainActor 同步取得目标文档的短期编辑租约，再校验一次。租约期间暂停目标文档的输入提交、自动保存、关闭/重命名和 watcher 文本采纳；同时处理 CodeEditorView 已排的 80ms document-change 回调，不能让旧回调越过租约又排入自动保存。事件保留并在释放后重评估，其他文档与项目仍可用。不能锁住整个页面或仅把 Apply 按钮设为 disabled。关闭项目/退出会等待所属事务收尾。
5. worker 为关闭文件准备同目录临时文件、保留必要权限/属性，全部准备成功后再逐文件校验并原子替换；每成功一步记录身份和前后字节。文件内容/身份变化则停下并逆序恢复已写部分。打开缓冲区此时尚未改变。
6. worker 返回后验证租约仍归该事务，在一个不含 await 的 MainActor 阶段提交所有打开缓冲区，并完成一次跨文件 undo 注册。预先准备的原生编辑会话仍须有效，不能跳过已经消失的编辑器目标后报告整体成功。
7. 释放租约，合并一次文档变更和索引刷新；按照用户的 autoSave 设置重新调度打开文档的保存。autoSave 关闭时，不写入打开文件原有的未保存文本；autoSave 开启时按正常策略保存，不能声称文件永远保持 dirty。

原生文件系统没有跨多个普通文件的全局原子提交。本批承诺应用内协调和失败补偿，单文件替换原子；不承诺外部进程看不到中间状态，也不把可回滚写入称为 ACID 事务。macOS 层限制实际目标到工作区内的普通独立文件；在访问/提交时重新检查父目录和文件身份，使用原生文件描述符相对操作避免只做字符串前缀校验。不能依靠静态一次 `resolvingSymlinksInPath` 消除路径切换竞争。

回滚仅在当前目标仍是本事务写入的内容与文件身份时覆盖；如果第三方又改过，保留其内容并将该项列为 recoveryRequired。报告包含失败路径、已恢复路径和未恢复路径；保留可取回的原始快照，用户确认恢复前不能清除记录。回滚失败不吞异常、不显示“替换成功”、不直接关闭预览。

取消在第一笔写入前零修改；commit 开始后进入可回滚收尾，不能只丢弃返回值。clear/reset/关闭预览只影响 presentation，不能结束活跃事务 busy 或释放恢复资源。项目 shutdown 必须等待收尾完成，不能让 Task 随 AppModel 弱引用消失。

## 5. 跨文件 undo 是独立审查点

一个 Replace 操作对应一个 transaction ID 和正/逆编辑集合。Undo/Redo 都要重新验证当前源文本和目标身份，通过同一文件事务执行；失败时保留可重试的栈项和恢复信息，不盲写旧内容。undo 之后新增编辑使对应 redo 失效。

原生 NSTextView 的文字输入、当前文件替换和跨文件替换要维护正确先后顺序：替换后输入一个字符，第一次 Cmd-Z 撤销该字符，下一次 Cmd-Z 才撤销整个 Replace；同批其他文件不能剩下一半。焦点在查询输入框或终端时仍走各自 undo，不可用全应用按键监视器抢占。

这一步不能仅添加 `UndoManager.registerUndo`：系统回调同步，而磁盘事务异步，且现有编辑器视图可能随切 tab 重建。实施前单独审查 macOS 文档级 undo 所有者、编辑器重新绑定、跨文件标记的顺序和原生菜单路由；明确异步失败后何时移动栈项，以及参与文档关闭/重开后的行为。测试证明这些规则之前，不接通新事务的正式 Apply，不宣称 B3b 完成。B6 的资源操作和 LSP versioned edits 仍独立扩展，不在此处预造全部重构能力。

## 6. 按依赖分批提交

首个独立修复 B3b1a 使用现有 `regex` 依赖：literal query 经 `regex::escape` 编译，匹配位置直接来自原文；literal replacement 仍手动拼接，`$1` 等不展开，preserveCase 使用真正的匹配原文。wholeWords 保留当前 ASCII 字母/数字/`_`/`$` 边界定义，regex 模式保持现有捕获组与零长度语义。case-insensitive literal 统一到 Rust regex 的 Unicode simple case folding，不做区域相关大小写转换；这会修正 Kelvin sign/long s/final sigma 的匹配，也明确不把 Turkish dotted/dotless I 都等同于 ASCII i。

索引的 lowercase trigram 不能完整表示 Unicode simple folding。每个 indexed file 记录是否含非 ASCII 文本；ASCII 长查询忽略大小写时，把这类文件并入原有 posting 交集，再由 matcher 精确过滤。即使 posting 缺失，也不能提前返回而漏掉这些候选。普通 ASCII 文件保留索引加速，非 ASCII query 与 regex 继续走现有保守候选。文件更新、删除和 ID 复用必须更新标志，结果稳定排序去重。该折中增加含非 ASCII 文件的精确匹配次数，验收记录需保留性能结果。

B3b1a 只改变 matcher/候选正确性，可在独立审查和完整验证后单独交付崩溃修复；它不解决 scope 或替换事务。B3b1 的其余部分仍按下表实施。

| 子批 | 内容 | 提交边界/放行条件 |
| --- | --- | --- |
| B3b1a（已验收） | 原文 UTF-8 匹配位置、Unicode simple folding、索引候选与生命周期 | 23 个共享场景、4 项 Rust 回归、完整 Rust/Swift 检查与 ARM64 查找/替换预览；独立方案与代码审查通过 |
| B3b1 | 明确 scope、空文件集合、override 候选、typed 错误、原文/匹配范围及预算契约 | Rust/Swift 同步消费者与 shared fixture；独立方案及代码审查；尚不替换旧 Apply |
| B3b2 | 文本事务协调器、文件适配器、文档租约、版本校验、准备/回滚/恢复 | 先通过协议故障注入与真实临时文件测试；不接通不完整的正式事务 UI |
| B3b3 | 文档级原生 Undo/Redo、顺序、异步失败栈恢复与 Search Apply 集成 | 先补充 undo 设计并独立审查，再实现；完整替换链路通过真实点击/截图才可替换安装 |
| B3b4 | 所有 scope 与 occurrence 选择/排除接入统一请求；错误/冲突/取消呈现 | Find/Replace 数据一致；B3d 再统一完整弹窗排版，不重复重做 Project |

B3b1–B3b2 可以作为准备性代码提交，但不能将总体状态标为完成或作为完整事务能力交付。已验收的菜单、键盘归属、Terminal 连接隔离不重复实施。源码准备提交均遵循独立 review → 实现 → 自动验证 → code review → commit，改变产品交互的批次还需 ARM64 实际验收。

## 7. 必测场景及验收产物

| 层 | 必需行为证据 |
| --- | --- |
| Rust/JSON | 旧请求兼容；明确空集合零结果；Project/Directory/Open Files 原文一致；新未保存命中与磁盘旧命中互斥；query 空格；Rust regex 错误；零长度与 Unicode；LF/CRLF/BOM/末尾换行；选区不重叠；排序与预算/incomplete |
| Feature/事务 | 预览后改文档/磁盘零写入；激活/history 等待后切工作区零串写；关闭重开身份；全部预检先于写；中途失败逆序回滚；回滚再失败保留快照；重复 Apply；取消与 reset 后 busy；释放所有租约 |
| 原生文件 | 临时文件清理；权限/属性保留；只读、缺失、symlink/hardlink、父路径变化、别名去重；外部修改不被回滚覆盖；外部 watcher 重评估 |
| 原生编辑器 | autoSave 关/开；未保存内容；IME 组合输入；替换后输入→Undo→整批 Undo→Redo；切 tab/重建视图/关闭文档；撤销失败不丢记录；查询输入框与终端 undo 归属 |
| 实际 GUI | 隔离 Go/Rust/配置文本 fixture；选择范围、预览、排除、应用、错误后保留预览、Cmd-Z/Cmd-Shift-Z；两个项目隔离；完整窗口与局部截图，磁盘字节和编辑器内容交叉核对 |

并发测试使用可控 gate 和事件，不用 sleep 等待；gate/任务/worker 均有本地 deadline 与失败清理。文件故障通过注入端口稳定复现，不能依赖宿主磁盘恰好满或个人权限。真实 UI 只修改临时 fixture，不写用户项目。

验证按技能执行：Rust comments/fmt、stable-tests 静态门禁、Rust/Swift 计时 harness、shared contracts、Rust Core、service boundaries、完整 macOS 测试、ARM64 包与 `git diff --check`；检查每个新增用例的 HTML/JUnit 耗时。实际启动的 Lithe/子进程在验收后全部关闭并核实。审查记录、截图、测试报告与安装信息放本批 `.artifacts`，通过后更新本文的验收摘要。

<a id="b3b1a-acceptance"></a>

## B3b1a 已完成验收

2026-09-06，Unicode 搜索提交 `b0dac7e2`，配套增量链接修复 `00a9f9c1`；
`workbench_audit` 独立方案与代码审查通过。matcher 在原始 UTF-8 文本上匹配，
索引补入非 ASCII 候选以避免 Unicode simple folding 漏项；literal `$1` 不展开。
23 个共享场景、Rust 331 项（17.744 秒）、Swift 985 项（34.806 秒）、7 项原生
链接回归及 Core/契约/边界/CI 分类检查通过，完成 ARM64 Release 实际验收。

GUI 预览确认 `İ needle KNEEDLE😀` → `İ $1 K$1😀`、`ſxſ SxS sxs` → `$1 $1 $1`，
切换 case-sensitive 后仅最后一项匹配；Find 正确定位并高亮。未点击 Apply，
fixture 原始字节不变，QA 与子进程、临时文件和 LaunchServices 登记已清理。
Find 当时仍按匹配行计数，跨文件写入与 Undo 未在此批验收。

证据在 `.artifacts/goland-parity/iteration8-replacement/`，包含
`unicode-replacement-release-expanded.png`、`unicode-replacement-release-folding.png`、
`unicode-find-release-full-mask.png`、`release-unicode-probes.json`、
`unicode-release-shutdown.json` 与 `test-stability/`。
1,500 个约 4 KB 文件的暖缓存测量：ASCII 查询中位数 0.174–0.274 ms，半数含中文时
10.052–11.607 ms，最大 12.370 ms；候选扩展有成本，不作为真实大项目性能保证。
链接产物身份与全局 force_load 的保留问题见 [链接方案](macos-rust-linking.md)。
