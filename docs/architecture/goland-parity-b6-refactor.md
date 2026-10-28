# B6 重构：语义编辑事务与 Refactor This

状态：第 1–10 节保留基于 `3680935d` 的第四版设计与历史验收；2026-10-06 已按当前源码复核，实施边界以第 11 节修订为准。**B6a2 首个文本编辑切片已实现并通过 Rust/Swift 自动验证；2026-10-28 已随轻量维护安装，基础编辑与跨标签 Undo/Redo 冒烟通过，语义动作实机验收仍待完成。B6a2 整体仍未完成。**

历史状态：**第四版，B6a1a 能力纠正与报文快照已实现并通过 Rust 计时及真实 gopls 协议回归；真实编辑/点击及独立候选复验通过；`94af8e89` 已替换系统安装并复验，其余功能未实施（见 §3.4–3.6）。** 第一版因「只核查 LSP 解析侧」被否；
第二版补上协商侧与反向请求侧后仍被独立审查**不放行**，列出 9 条阻塞问题。本版按那 9 条
逐条修订，并采纳其对 B3b 归属冲突的处置建议。承接
[B6 设计基线](goland-parity-implementation.md) 与
[B3b 跨文件替换事务](goland-parity-b3b-replacement.md)。

第二版的核心错误有两类：
1. **仍从"当前这份不完整协商声明下测到的服务器行为"推架构结论**（与第一版同型）；
2. **仍有一个方向完全没核查**——宿主 → 服务器的**出站**再序列化。

本版把这两处列为最高优先级，并把 B6a1 拆为 a1a / a1b 两批，让 a1b 的形状由 a1a 的重测结果决定。

## 0. 第二版审查结论与本版处置

| # | 第二版阻塞问题 | 本版处置 | 落在本文 |
| --- | --- | --- | --- |
| B1 | `§3.1` capabilities 清单漏 `codeAction.dataSupport` 与 `workspace.didChangeWatchedFiles` | 补入清单；两者新列为既有协商缺陷 N6/N7 | §1.2、§3.1 |
| B2 | R3 实测在受污染的协商下取得，却用来推 B6d 硬前置 | R3 降级为「当前协商下的观测」；B6a1a 出口条件含**重测** | §1.3、§3.3、§8 |
| B3 | 出站 workspace edit 用绝对路径而非 `file://` URI，且丢 documentChanges/version | 新列为缺陷 C12；出站序列化纳入 B6a2 交付 | §1.4、§5.3 |
| B4 | `§4.1` 调用点清单过期且不完整 | 按实测重列，区分构造点与 `.changes` 消费点 | §5.4 |
| B5 | `WorkspaceFeatureModel` 引用位置错误，真实实现在独立 target，`§5.2` 实为跨模块重构 | 更正路径；明确抽取目标模块与依赖方向 | §1.5、§6.3 |
| B6 | `§3.2` 延迟响应缺相关性规则与契约面定义 | 定义 per-session 单飞、新事件、新命令、超时与断连清理 | §4 |
| B7 | `§5.3` 回同步与 `rust-core-api.md:788-790` 冲突，集合未定义 | 定义三个**不相交**集合与顺序 | §6.5 |
| B8 | `failureHandling: "transactional"` 与 `§5.6` 诚实边界自相矛盾 | **决定：不声明 `failureHandling`**，并给出重开条件 | §3.2 |
| B9 | B3b 归属冲突未解决，`§5.4` 与 B3b 放行条件冲突 | 采纳审查建议：协调器归 B6b1；解除 B3b1 硬绑定 | §2.2 |

非阻塞项 N1–N11 的处置：N1 采纳（协调器改归 **Services** 层，见 §6.1）；N2、N3 采纳
（§2.3）；N4、N5、N7、N8、N9、N10、N11 采纳并落在对应节；N6 结论正确，行号已更正。

## 1. 现状核查

行号为 `3680935d` 实测值，**带模块路径**。第二版的行号已漂移，本版统一更正。
标「实测」的另用本机 gopls v0.20.0 验证过实际报文。

### 1.1 解析侧（入站）

| # | 事实 | 位置 |
| --- | --- | --- |
| C1 | `LanguageServerWorkspaceEdit` 只有 `changes: [URL: [TextEdit]]`；无顺序、无版本、无资源操作 | `macos/Sources/LitheCoreContracts/Language/LanguageToolingContracts.swift:491` |
| C2 | Rust 客户端把 `documentChanges` 压平进同一个 map，`textDocument.version` 直接丢弃 | `rust/lithe-core/src/lsp/interface/client.rs:1150` |
| C3 | `documentChanges` 中没有 `textDocument.uri` 的条目一律 `continue`：`create`/`rename`/`delete` 资源操作被**静默丢弃** | 同上 `:1151-1157` |
| C4 | `parse_lsp_text_edit_value` 用 `filter_map`：range 畸形的 edit 被静默丢弃，其余照常当成功 | 同上 `:1174` |
| C4b | `parse_lsp_position_value` 对 `line`/`character` 用 `unwrap_or(0)`：非整数或缺字段被**静默改写成 0** | 同上 `:1188-1196` |
| C5 | 请求白名单无 `prepareRename`、`selectionRange`、`documentSymbol`、`linkedEditingRange` | 同上 `:559-580` |

### 1.2 协商侧

| # | 事实 | 位置 |
| --- | --- | --- |
| N1 | `textDocument.rename` 只有 `dynamicRegistration`，**无 `prepareSupport`** | `client.rs:58` |
| N2 | `textDocument` 下无 `documentSymbol`、无 `selectionRange`、无 `rangeFormatting` | `client.rs:31-90` |
| N3 | `workspace.workspaceEdit` 只有 `documentChanges: true`，**无 `resourceOperations`、`changeAnnotationSupport`、`failureHandling`** | `client.rs:95-97` |
| N4 | 实测：不声明 `prepareSupport` 时 gopls 返回 `renameProvider: true`（裸 bool）；补齐后返回 `{"prepareProvider": true}` | 本机 gopls v0.20.0 |
| N5 | 实测：不声明 `documentSymbol` 的 hierarchical 支持时 gopls 返回扁平 `SymbolInformation[]`；补齐后返回带 `selectionRange` 的 `DocumentSymbol[]` | 同上 |
| **N6** | `textDocument.codeAction` 只有 `dynamicRegistration` / `resolveSupport.properties` / `codeActionLiteralSupport`，**无 `dataSupport`**。而宿主恰以 `action.data != nil` 决定是否走 `codeAction/resolve` | `client.rs:72-82`；`macos/Sources/Lithe/Models/AppModel/AppModel+Development.swift:1829` |
| **N7** | `client.rs` 全文**无 `didChangeWatchedFiles` 键**（grep 命中数 0）。而 §6.5 的回同步正要发这个通知 | `client.rs`；`rust/lithe-core/src/lsp/interface/engine.rs:3291` |

### 1.3 反向请求侧（server → client）

| # | 事实 | 位置 |
| --- | --- | --- |
| R1 | client 向 server 声明 `workspace.applyEdit: true` | `client.rs:92` |
| R2 | 但 `workspace/applyEdit` 落入 `_ =>` 分支，返回 `-32601 Method not found` | `client.rs:398-403` |
| R3 | **当前协商下的观测**（不是服务器能力上限）：gopls 的 `Extract constant` 是 `hasEdit=false, hasCommand=true`（`gopls.apply_fix`，`ResolveEdits: false`）；编辑在 `executeCommand` 之后由 server 反向发起的 `applyEdit` 中送达 | 本机 gopls v0.20.0，**在缺 `dataSupport` 的条件下测得** |

R1+R2 合起来是**当前最严重的既有缺陷**：我们告诉服务器支持 applyEdit，然后拒绝它。

**R3 的重要限定**：该结论是在 N6 的缺陷条件下取得的。文档自己在 N4/N5 已证明 gopls 的
响应形态随 client capabilities 变化。因此 **R3 不能用来推出「B6d 只能走 executeCommand →
反向 applyEdit」这个架构结论**，第二版 §7 的「§3.2 是 B6d 硬前置」在重测前不成立。
B6a1a 的出口条件之一就是重测 R3（§3.3）。

### 1.4 出站侧（client → server）——第二版完全遗漏

| # | 事实 | 位置 |
| --- | --- | --- |
| **C12** | `makeWorkspaceEditRequest` 反向编码 workspace edit 时，`changes` 的键用 `url.standardizedFileURL.path`——**本地绝对路径，不是 `file://` URI**，即发出去的是协议非法报文 | `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift:2961-2971` |
| C12b | 该请求用于 `codeAction/resolve` 的参数；Rust 侧原样透传，无 path → URI 转换 | `RustCoreBridge.swift:2943`、`client.rs:649` |
| C12c | 出站方向同样丢 `documentChanges` / `version` / 资源操作——与入站的 C1/C2/C3 同族 | 由 C1 的类型形状决定 |

B6d 高度依赖 code action 的 resolve 往返。**只修入站不修出站，"保真"只保了一半。**

### 1.5 宿主侧

| # | 事实 | 位置 |
| --- | --- | --- |
| C6 | `LanguageServerFeatureSet` 共 11 位（bit 0..10），无 prepareRename/documentSymbol/selectionRange | `LitheCoreContracts/Language/LanguageToolingContracts.swift:34-55` |
| C7 | `requestLanguageCodeActions` 用光标处零宽 range，选区从不传给 server；实测零宽 range 下 gopls 不返回任何 `refactor.extract.*` | `AppModel+Development.swift:1801-1825` |
| C8 | `applyLanguageWorkspaceEdit` 无版本校验；工作区归属用 `path.hasPrefix(root + "/")` 字符串前缀；回滚只覆盖未打开文件且用 `try?` 吞掉回滚失败 | `AppModel+Development.swift:1934-1983`（前缀判定 `:1942`，回滚 `:1969`） |
| C9 | 选区已存在于编辑器（UTF-16 offset，按 document ID 保存），只服务于滚动/恢复，没有出口 | `macos/Sources/Lithe/Views/Editor/CodeEditorView.swift:630-647,1120` |
| C10 | rename 入口直接 apply server 返回的 edit，无预填名、无预览、无冲突处理 | `AppModel+Development.swift:1755-1776` |
| **C11** | 文件/目录重命名**已有完整既成实现**，但它在**独立 SwiftPM target `LitheWorkspaceModule`**（1067 行），**不在**应用的 Application 层（同名文件只有 78 行，是 typealias + 转发）：`recordHistory(.beforeRename)`（`:510`）→ 递归计算受影响文件（`:511-515`）→ `Task.detached` + 裸 `moveItem`（`:521,532`）→ `directoryMarks` 迁移 → `relocateHistory`（`:568`）→ `relocateOpenDocuments`（`:570`） | `macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift:487-577` |
| C13 | `document.text` 外部变更时编辑器整体重设 `textView.string` 并把选区塌缩为 `length: 0`；`textView.string =` **不注册原生 undo** | `CodeEditorView.swift:908-916` |
| C14 | `add_capability` 只按**顶层 key** 判 bool/object，表达不了 `renameProvider.prepareProvider` 这类嵌套子标志 | `client.rs:1351-1357` |
| C15 | `WorkspaceFileOperations` 协议实际在 `LitheCoreContracts`；`Lithe/Core/Ports/` 下同名文件只是 3 行 typealias | `macos/Sources/LitheCoreContracts/Workspace/WorkspaceFileOperations.swift:3-14` |
| C16 | `verify-service-boundaries.sh` 扫 Core / Services / Views / `AppModel.swift` / `Models/`，**不扫** `macos/Sources/Lithe/Application/` | `scripts/verify-service-boundaries.sh:15-23` |

C2、C3、C4、C4b、C8、C12、N6、N7、R2 是**当前已存在的正确性缺陷**，不是待补功能。

## 2. 分批、依赖与归属

### 2.1 分批

| 子批 | 交付 | 依赖 | 不属于本批 |
| --- | --- | --- | --- |
| **B6a1a** | 独立探针重测 + 纠正不实能力声明；新增生产能力按 §3.1 门控 | 无 | 尚无可用消费方的能力声明 |
| **B6a1b** | `workspace/applyEdit` 反向请求：延迟响应、相关性、新事件与新命令 | B6a1a（其必要性与形状由 a1a 的重测决定） | 编辑的实际应用 |
| B6a2 | 解析保真（入站 + **出站**）、prepareRename/selectionRange/documentSymbol、feature flag 与嵌套 capability 探测 | B6a1a | 编辑的实际应用 |
| B6b1 | `WorkspaceTextEditCoordinator` 事务：版本校验、编辑租约、资源操作、失败回滚、恢复记录、LSP 回同步。**不含跨文件 undo** | B6a2 | 跨文件 undo、Search 接入 |
| B6b2 | 原生跨文件 undo/redo | B6b1 + 独立 undo 设计审查 | — |
| B6c | Refactor This 入口 + Rename（符号/文件/包） | B6b1 | Extract/Inline/Change Signature |
| B6d | Extract/Inline/Change Signature、Move/Copy/Safe Delete | B6c、B6a1b（若 a1a 重测确认仍需要） | 非 Go 语言的 Go 特有语义 |

B6a1a 的探针结论已回写 §3.4；生产能力修正及测试结果见 §3.5。B6a2 的 symbol/selectionRange 分支可以先交付协议与类型，但生产能力声明、自动请求及产品完成状态必须与真实消费者共同启用，见第 11 节。

### 2.2 B3b 归属冲突的处置（采纳审查建议）

第二版把「B3b1 归属需在重审时明确指派」留给评审，这本身不是可实施方案。本版直接定案：

1. **`WorkspaceTextEditCoordinator` 的唯一归属批次是 B6b1。** 当前已在
   `macos/Sources/Lithe/Services/Workspace/WorkspaceTextEditCoordinator.swift` 落地纯协调器、
   `WorkspaceTextEditFileOperations` 端口和 macOS 原子替换适配器，并通过两项补偿/源版本测试；
   文档租约、LSP 回同步、Undo 和现有编辑入口接入仍未完成。需同步修改
   `goland-parity-b3b-replacement.md` 的分批表：
   B3b2 一行改为「交付物并入 B6b1」；B3b3 拆为「跨文件 undo → 并入 B6b2」与
   「Search Apply 集成 → 留在 B3b」。B3b 保留 B3b1（契约批）与 B3b4（scope/occurrence 接 UI）。
2. **B3b1 指派给 B3b 批次自身（Search 侧 owner），不由 B6 顺手带做。** 理由是文件集完全不重叠：
   B3b1 改 `rust/lithe-core/src/project/files.rs`、`LitheSearchModule/Ports/SearchOperations.swift`、
   `SearchFeatureModel.swift`；B6 改 `lsp/interface/client.rs`、`engine.rs`、
   `LanguageToolingContracts.swift`、`AppModel+Development.swift`。符合总方案
   `goland-parity-implementation.md:215` 的「实施阶段按拥有文件划分」。
3. **解除「B6b1 不能在 B3b1 之前实施」的硬绑定。** B6b1 的 LSP 侧事务不需要 Search 的
   `sourceText` / 稳定匹配标识 / 预算契约——需要它们的是 **Search 接入协调器**那一步，
   归 B3b4。B6b1 的依赖列因此只有 B6a2。
4. **修订 B3b 的放行条件措辞**：`goland-parity-b3b-replacement.md:87` 的
   「测试证明这些规则之前，不接通新事务的正式 Apply」只约束 **Search Replace 的 Apply**，
   不约束 B6b1 的 LSP 编辑路径。事实依据见 §6.6：这四条 LSP 路径**今天本来就没有原生 undo**
   （C13），接入无 undo 的事务不构成撤销能力回退。

上述 1、3、4 需要实际修改 `goland-parity-b3b-replacement.md`，与本文一并提交，
**不能只在本文单方面声明**。

### 2.3 明确排除项

- **`linkedEditingRange`**（C5 列出后第二版全文再无交代）：**不在 B6 范围**。
  它服务于「同步编辑同名标识符」的输入体验，与语义重构无关，归后续编辑体验批次。
- **`selectionRange` 与 `documentSymbol` 在 B6 内没有消费方**。B6 的选区来自编辑器的
  UTF-16 selection（§5.5），rename 回退用编辑器标识符范围（§8）。
  `documentSymbol` 的真实消费方是 [B7b 运行入口](goland-parity-b7b-run-gutter.md)
  与 B7 的 Structure。
  **处置：仍在 B6a2 交付**（它们与 workspace edit 共用同一解析器与白名单，分开做会两次改同一函数），
  但在本文与验收表明确标注「为 B7 预交付，B6 内无消费方，不以此声称 B6 能力」。
- **`rangeFormatting`**：实测 gopls v0.20.0 的 `documentRangeFormattingProvider` 为 `null`，
  直接请求返回 `-32601`，B6 全文无消费方。属后续格式化批次。

## 3. B6a1a：协商侧补齐与服务器行为重测

探针与生产初始化声明分开验收。独立探针可声明计划中的完整能力，用来测量服务器行为；
产品只声明当前 parser、handler 和原生消费方共同兑现的能力。不得把探针的 initialize JSON
直接复制到生产客户端。

### 3.1 能力启用门槛

| 能力 | 产品启用条件 |
| --- | --- |
| `workspace.applyEdit` | 当前无处理器，先纠正为不支持；B6a1b 请求相关性/延迟响应与 B6b1 编辑消费方均可用后启用 |
| `codeAction.dataSupport` | B6a2 入站与出站保真、resolve 往返和既有 Source Actions 回归通过后启用 |
| `rename.prepareSupport` / `prepareSupportDefaultBehavior` | B6a2 保真解析三种 prepareRename 结果，Swift 入口真正调用后启用 |
| `documentSymbol.hierarchicalDocumentSymbolSupport` | 与 B6a2 请求白名单、两种响应归一化及 B7b 消费能力一起启用 |
| `workspace.workspaceEdit.resourceOperations` | B6a2 不丢资源操作，B6b1 的 create/rename/delete 及失败恢复均通过后逐项启用；之前不声明 |
| `documentSymbol` / `selectionRange` / `didChangeWatchedFiles.dynamicRegistration` | 实际支持注册、取消注册、过滤/生命周期及相应通知后才启用；手动文件变化通知不等于动态注册 |

`prepareSupportDefaultBehavior = 1` 对应 LSP 3.17 的 `Identifier`；只有消费者支持默认范围推导时
才启用。`workspace.didChangeWatchedFiles.relativePatternSupport` 本批仍不声明。
每个生产能力改动必须有执行该 initialize fixture 的测试，且验证其消费链路。

### 3.2 `failureHandling` 与 `changeAnnotationSupport`：本批与 B6b1 都不声明

第二版计划在 B6b1 打开 `failureHandling: "transactional"`。**本版决定不声明该字段**，理由：

LSP 3.17 的 `FailureHandlingKind.transactional` 语义是「全部成功，或工作区完全不变」。
而 §6.7 的诚实边界明确承认：第三方在事务期间已改过的目标**保留其内容**并列为
`recoveryRequired`——即存在「部分应用且不可回滚」的终态。`textOnlyTransactional` 也兑现不了，
因为该终态同样可能发生在纯文本 edit 上。声明做不到的语义，正是本文 §1.3 批评 R1+R2 的同一错误，
而且会改变 server 的行为选择（server 可能据此放心发送更大批量的含资源操作 edit）。

**重开条件**：若 B6b1 实施后能以测试证明「纯文本 edit 的事务在**包括第三方并发改写在内**的
全部失败路径上都能回到零修改」，则可在该批单独申请声明 `textOnlyTransactional`，
并附证明。没有该证明前保持不声明。

`changeAnnotationSupport` 同样不声明：无证据表明 gopls 会发送 annotation，
且声明后需要兑现 `needsConfirmation` 的 UI 语义，本文未设计该 UI。

### 3.3 出口条件（全部可证伪）

1. **initialize 请求 JSON 快照 fixture**，字段增删必须显式改快照。
   该 fixture 必须被一个具体的 Rust 测试读取并断言——`verify-shared-contracts.sh:7-9`
   对 `shared/fixtures/**/*.json` 只做 JSON 语法解析，**加个文件不构成验收**。
2. **用真实 gopls v0.20.0 重测 R3**：补齐 `dataSupport` 后，`Extract constant` 是否仍为
   `hasEdit=false, hasCommand=true, ResolveEdits=false`。结论写回 §1.3 与 §9，
   并据此**确认或推翻**「B6a1b 是 B6d 硬前置」。
3. **既有能力不回归复测**（真实 gopls 会话）：Rename Symbol
   （`CodeEditorView.swift:3601,3659` 按 `.rename` 位挂载）与 Source Actions 仍可用。
   capabilities 变更会改变 `renameProvider` 与 `documentSymbol` 的响应形态；
   `add_capability`（C14）对 bool 与 object 都识别，所以 `.rename` 位**应当**保住——
   但这是巧合而非保证，必须实测。
4. `./scripts/verify-rust-core-comments.sh`、`./scripts/verify-rust-core.sh`、
   `./scripts/verify-shared-contracts.sh`。

第二版 §2 说 B6a1 「不做点击验收」，§9 又说「每批真实 ARM64 逐项点击验收」，两处矛盾。
**本版定为**：B6a1a 不做新功能点击验收（没有新功能），但**必须做上述第 3 项的既有能力
不回归复测**，因为它实际改变了服务器返回的报文形态。

### 3.4 真实协议重测（2026-09-08）

本机 gopls v0.20.0、Go 1.24.4 darwin/arm64，独立 JSON-RPC 探针在同一隔离 fixture 上测了
三个 profile。请求、读取、进程组清理均有局部期限；不应用 server 发来的编辑，结束校验源码未变。
原始请求/响应与摘要在 `.artifacts/plan-implementation/b6-probe/`。

| profile | Rename provider | symbols | Extract constant（resolve 后） | server applyEdit 次数 |
| --- | --- | --- | --- | --- |
| 当前 baseline | `true` | 扁平 | command，无 edit / data | 1 |
| 仅增加 dataSupport | `true` | 扁平 | edit + data，无 command | 0 |
| 计划能力全集（仅探针） | `prepareProvider: true` | 层级 | edit + data，无 command | 0 |

三组 Rename 都返回 edit，Source Actions 都返回 7 项。单独增加 dataSupport 已足以让本次
Extract constant 经 resolve 返回 edit；因此该动作不再以 B6a1b 为硬前置，仍以 B6a2 出站保真、
B6b1 编辑事务为前置。此结论不外推到未测的 Inline、Change Signature 等 command。
反向 applyEdit 分支仍保留，待逐动作证明必要性后接入。

这只是协议实验，**不是产品 B6a1a 验收完成**；后续生产能力修正见 §3.5，既有能力点击回归仍待实施；B6b1/B6b2 未实现，Search Apply 不能据此接通。

### 3.5 B6a1a 能力纠正实施（2026-09-08）

生产初始化现在声明 `workspace.applyEdit: false`，等待反向请求关联和宿主事务都可用后再启用。
其余新增 refactoring 能力保持 §3.1 的门槛；此次没有照搬探针的计划能力全集。
新增 `shared/fixtures/lsp/client-initialize-v1.json` 保存完整 initialize 请求，现有
`client_core_initializes_and_applies_server_capabilities` 读取并逐字段比较实际发出的 JSON。
只有版本占位符 `PACKAGE_VERSION` 用 crate 版本替换，不忽略任何 capabilities 字段。

Rust 计时 **368 项通过**，报告 `.artifacts/test-stability/rust-b6-initialize.*`。
真实 gopls 的修正声明 profile 保持 `renameProvider: true`、Rename edit 和 7 项 Source Actions，
源码未修改，进程有界退出；报文在 `.artifacts/plan-implementation/b6-initialize-probe/`。
**gopls 的旧式 Extract constant command 即使看到 applyEdit=false，仍发送一次反向请求。**
因此能力声明纠正不能替代 B6a2 resolve 保真与 B6b1 事务；这次未声称该重构可用。
产品链接及既有操作真实点击已通过，见 §3.6。

<a id="b6a1a-acceptance"></a>

### 3.6 B6a1a 产品复验与插件配置修复（2026-09-08）

B6a1a 的产品复验发现独立于协议的既有缺陷：Go 插件提供了 gopls launch configuration，
session manager 却只创建 runtime，没有发布到有效目录；设置页因此显示没有启动命令，
工具发现也没有执行插件要求的 `gopls version` 验证。

修复使用通用插件接线：已注册扩展投影有效目录，设置页和工具发现共用；注销与目录变更移除
投影。缓存匹配完整 descriptor，刷新保留 operation identity，取消/注销后的迟到验证不再发布。
模块停止前取消并等待有界验证任务；首次启动等待候选验证完成后再判定工具缺失。
没有把 Go 硬编码回 bundled catalog，也没有安装新的 gopls。

本轮实际 GUI 已完成：`greeting` → `salutation` Rename 更新定义与另外两个源文件；编辑器内
加入未使用的 `os` 导入后，Source Actions → Organize Imports 删除它；保存后在 Go Tools
双击测试目标，真实 `go test` 成功（0.481 s）。设置页显示 gopls 已验证且 LSP Running。
证据为 `.artifacts/plan-implementation/b6-gui-evidence/01-gopls-verified.png` 至
`04-go-test-after-edits.png`，以及 `after-rename-and-organize.json`。
最终独立候选首次打开无缺失工具误报，自动进入 Running；关闭 LSP 后 gopls 进程退出，
重新启用恢复 Running。截图 `06-isolated-restart-running.png`，首次 AX 记录
`05-isolated-startup.txt`。各轮 Cmd-Q 后核对应用和本批 gopls 子进程全部退出。

完整工作区 Swift 1181 项 / 130 suites 通过（35.556 s），剔除未完成 Search 改动的独立
候选 1173 项 / 129 suites 通过（33.480 s）。报告为 `.artifacts/test-stability/`
下的 `macos-b6-lsp-final.*` 与 `macos-b6-isolated.*`；新增候选时序和目录投影测试均约 1 ms，
没有新增稳定性例外。Rust 368、Rust bridge verifier、service boundaries、shared contracts、
test stability、ARM64 release build、codesign 和 diff 检查通过。目录只在配置变化时发布，
不增加按键或拖动时的全页面刷新；UI 继续使用已有布局组件。

代码复核通过：静态识别保持惰性，插件启动配置、工具发现与设置页一致；注销后不借用旧
候选，延迟验证被取消/作废后不重启插件；能力声明仍遵守 §3.1。

实现提交 **`94af8e89`** 已从干净检出打包并替换 `/Applications/Lithe.app`，dirty=false。
安装包与系统二进制 SHA-256 一致，deep/strict codesign 通过。安装版首次打开无误报，
再次执行 `salutation` → `welcomeMessage` 跨文件 Rename，保存后的项目由实际
`go test ./...` 验证通过（0.433 s）。本批应用内 Go Test 点击结果见前述 `04` 截图；
安装复验使用的 CLI 输出保存在 `installed-edit-go-test.log`，不混称为安装版按钮验收。
窗口同时操作打断了安装版 Go Test 菜单复验，未把该点击尝试记为通过。
`07-installed-rename.png` 与 `installation.json` 保存安装证据；最终 Cmd-Q 后确认无 Lithe
或本批 gopls 进程残留。原系统安装保留于 `.artifacts/plan-implementation/b6-install-backup/`。
本节不代表 B6a2/B6b1/B6b2 已完成。

## 4. B6a1b：`workspace/applyEdit` 反向请求

**前置**：B6a1a 的重测结论确认本批仍然必要。若重测显示 gopls 在 `dataSupport` 下改走
`codeAction/resolve` 返回 edit，则本批的优先级与 B6d 的依赖关系都要重排。

第二版只给了行为描述，没有给协议设计，因此无法实施。本版补齐三处。

### 4.1 相关性（correlation）规则

LSP 的 `workspace/applyEdit` **不携带**任何指向发起它的 `workspace/executeCommand` 的标识。
多窗口是真实存在的（每个 `ProjectWindowScene` 独立，`macos/Sources/Lithe/LitheApp.swift`），
因此必须定义归属规则。

**决定：per-session 单飞。** 同一 LSP session 在同一时刻只允许**一个** executeCommand 型
重构在途；该操作在途期间到达的 `workspace/applyEdit` 归属于它。其余情况一律回
`{"applied": false, "failureReason": "..."}`：

| 情形 | 响应 |
| --- | --- |
| 无在途 executeCommand 型操作 | `applied: false`，reason = 无活动事务上下文 |
| 已有一个 applyEdit 在等待事务结论，又来第二个 | 第二个立即 `applied: false`，reason = 并发请求 |
| 解析失败 / 非 file scheme / 目标越界 | `applied: false` + 具体原因，**不回 `-32601`** |
| 预览被用户取消 | `applied: false` + reason，**不能先回 `applied: true` 再撤销** |
| 超时 | `applied: false` + reason，结束等待，不让 server 无限等 |

session 与 AppModel 的映射沿用现有 `lsp.*` 命令的 sessionID 归属，不新造路由。

### 4.2 契约面（新增，必须写入 `shared/contracts/rust-core-api.md`）

Rust 侧目前所有 server→client 响应都在读循环里**同步生成并立即下发**
（`engine.rs:2123,2143` 的 `send_messages_or_fail(..., "serverResponse")`）。
延迟响应需要三样新东西，`rust-core-api.md:91-113` 的命令表与 `:826-828` 的事件枚举
（`stateChanged / featuresChanged / diagnostics / requestCompleted / serverInfoChanged / log`）
目前都没有：

| 新增 | 名称 | payload |
| --- | --- | --- |
| 事件 | `applyEditRequested` | `{ sessionId, serverRequestId, edit }`（`edit` 为 §5.1 的有序操作列表） |
| 命令 | `lsp.completeApplyEdit` | `{ sessionId, serverRequestId, applied: bool, failureReason: String? }` |
| 状态 | 待决 server-request 注册表 | 每 session 至多 1 项（§4.1 的单飞） |

超时归属：延迟响应的 deadline **从属于所属操作的 deadline**，不独立延长。
连接断开时的清理顺序：先关闭待决注册表并把所有等待者以 `applied: false` 结束，
再释放 session 资源；不得让宿主侧的事务无限等待一个已死的连接。

`lsp.completeApplyEdit` 对未知 `serverRequestId` 返回稳定错误而非静默成功。

### 4.3 fixture

覆盖：applied / 未 applied / 解析失败 / 目标越界 / 延迟期间取消 / 延迟期间连接断开 /
并发两个 applyEdit / 未知 serverRequestId / 超时。每项断言**实际发回 server 的 JSON-RPC 响应**，
不只断言宿主内部状态。

## 5. B6a2：解析保真（入站与出站）

### 5.1 契约变更

`LanguageServerWorkspaceEdit` 从「路径 → 编辑」改为**有序操作列表**：

```
enum LanguageServerWorkspaceOperation {
    case edit(LanguageServerTextDocumentEdit)   // uri + version: Int? + [TextEdit]
    case createFile(url, overwrite, ignoreIfExists)
    case renameFile(oldURL, newURL, overwrite, ignoreIfExists)
    case deleteFile(url, recursive, ignoreIfNotExists)
}
```

- `changes` 形式归一化为单一 `edit` 序列，顺序按 URI 的 UTF-8 字节序固定以保证确定性。
- **`documentChanges` 的顺序是 LSP 语义顺序，必须原样保留，不参与排序。**
- `documentChanges` 存在时**忽略** `changes`（LSP 3.17 明文要求），不再按 uri 覆盖合并。
- **不保留 `changes: [URL:[TextEdit]]` 的 Optional 派生访问器。** Swift Optional 只强制
  *语法*处理，`?? [:]` 即可编译通过并静默退化。所有消费者一律走 B6b1 的协调器。

### 5.2 Rust 侧（入站）

`parse_workspace_edit` 改为返回 `Result`，畸形条目**整体失败**并给出稳定错误码
（`lsp.workspaceEdit.malformedEdit` / `.unknownOperation` / `.missingURI` /
`.unsupportedScheme`），不再 `filter_map`。`parse_lsp_position_value` 的 `unwrap_or(0)`
一并改为整体失败——静默把坐标改写成 0 会产生位置正确但内容错误的编辑。

`AnnotatedTextEdit` 按普通 TextEdit 处理但保留 annotation ID。未知 `kind` 整体失败。
资源操作 URI 经 `file_path_from_uri`，非 `file:` scheme 整体失败。

新增方法 `textDocument/prepareRename`、`textDocument/selectionRange`、
`textDocument/documentSymbol` 进白名单、参数构造与结果解析。`prepareRename` 三种响应形态
（`Range`、`{range,placeholder}`、`{defaultBehavior:true}`）全部保留，不把 `defaultBehavior`
折叠成「无结果」。`documentSymbol` 同时支持 `DocumentSymbol[]` 与 `SymbolInformation[]`，两者不混用。

**嵌套 capability 探测**：新增 `renameProvider.prepareProvider`、`selectionRangeProvider`、
`documentSymbolProvider`。`add_capability`（C14）只判顶层 key，表达不了
`renameProvider.prepareProvider`，**必须新增嵌套访问器**，不能声称「沿用现有模式」。

Rust Core 只做协议解析与规范化：不访问文件、不判断路径是否在工作区内、不执行资源操作。
路径归属与权限一律由宿主判定（与 B7a1 同一原则）。

### 5.3 Rust/Swift 侧（出站）——本版新增

`makeWorkspaceEditRequest`（`RustCoreBridge.swift:2961-2971`）当前把 URL 编码为**绝对路径**，
发出的是协议非法报文（C12）。本批修正：

- 出站键改为 `file://` URI，与入站的 `file_path_from_uri` 互为逆运算，
  用同一组测试同时锁定两个方向（round-trip fixture）。
- 出站同样支持 `documentChanges` / `version` / 资源操作，与 §5.1 的类型形状一致。
- **或者**：改为透传 server 返回的原始 JSON，不经模型降级。
  两方案二选一，在实施前的方案确认中定案并说明理由；**不得两者并存**。
- `codeAction/resolve` 的往返必须**无损**：resolve 前后的 edit 语义等价，
  由 round-trip 测试证明，不靠人工比对。

### 5.4 受影响的调用点（按实测重列）

第二版此表过期且不完整。**构造点**（`LanguageServerWorkspaceEdit(`）：

| 文件 | 行 |
| --- | --- |
| `macos/Sources/LitheLanguageIntelligenceModule/Runtime/LanguageServerSession.swift` | 978 |
| `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift` | 482 |
| `macos/Sources/Lithe/Models/AppModel/AppModel+Development.swift` | 1793 |
| `macos/Sources/Lithe/Models/AppModel/AppModel+Development.swift` | 1928 |

**`.changes` 消费点**（会编译失败，第二版漏了两处）：

| 文件 | 行 |
| --- | --- |
| `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift` | 2966（`edit.changes.map`，即 §5.3） |
| `macos/Tests/LitheTests/RunConfigurationIntegrationTests.swift` | 2362（`.changes[...]` 下标） |
| `macos/Tests/LitheTests/RunConfigurationIntegrationTests.swift` | 2462（`.edit?.changes[...]`） |

**仅类型引用**（不会因形状变更失败，第二版误标为构造点）：
`RunConfigurationIntegrationTests.swift:2340`、
`macos/Tests/LitheLanguageIntelligenceModuleTests/LanguageIntelligenceModuleTests.swift:1048`。

实施前重跑一次全仓 grep 复核本表——行号会随 B6a1a 的提交漂移。

### 5.5 Swift 侧与能力门控

`LanguageServerFeatureSet` 新增 `prepareRename`、`selectionRange`、`documentSymbol` 三位
（bit 11/12/13）。

**Rename 的门控用 `renameProvider` 是否存在，不是 `prepareRename`。**
`prepareProvider` 只决定「是否先调 prepareRename 取 placeholder 与可重命名范围」。
写成「有 prepareRename 才出 Rename」会把 Go 现在可用的 Rename Symbol 从菜单里删掉，是功能回退。
**「不做能力回退」指的是不猜测、不用全文替换冒充语义重构，不是把已有可用能力按新位门控掉。**

`requestLanguageCodeActions` 接受真实选区：编辑器把 UTF-16 selection 转成
`LanguageServerRange`，零宽选区保持零宽（行为不变），非零选区如实传递。合法跨行选区同样发送；逆序、越界、非法 UTF-16 边界、
含 IME 未确认文本，或文档身份/revision 与请求快照不一致时拒绝请求。响应、resolve 和
实际应用前再次检查原快照，不能把较新缓冲区当作旧请求的来源（第 11 节修订）。

### 5.6 契约文档与 fixture

`shared/contracts/rust-core-api.md` 的 `lsp.request` operation 集合本批新增 3 个 operation、
改 workspace edit 结果 payload、新增 4 个错误码，**必须同步更新**。
（applyEdit 的新事件与新命令属 B6a1b，见 §4.2。）

新增 `shared/fixtures/lsp/workspace-edit-v1.json` 覆盖 §9.2 的全部形态——现有
`shared/fixtures/lsp/` 的 6 个 JSON（`java-navigation-v1`、`java-workspace-policy-v1`、
`jdt-cache-retention-v1`、`jdt-direct-launch-v1`、`jdt-workspace-fingerprint-v1`、
`jdt-workspace-key-v1`）均为 JDT 相关，不能复用。
**必须写明哪个 Rust 测试与哪个 Swift 测试读取该 fixture**；只加文件不构成验收（§3.3 同理）。

## 6. B6b1：语义编辑事务（不含 undo）

### 6.1 层归属：Services，不是 Application

第二版把 `WorkspaceTextEditCoordinator` 放 Application 层，只写「经核查与 SKILL 所有权表一致」
而无论证。本版改为 **Services 层**，理由：

- SKILL 所有权表把「Product workflow orchestration」分给 `macos/Sources/Lithe/Services/`，
  把「Feature models, state transitions, and user actions」分给 `Application/`。
  协调器持有事务状态、租约、回滚与恢复记录，执行「预检 → 写入 → 回滚 → 回同步」的工作流，
  属于前者。
- `verify-service-boundaries.sh` 已经扫 Services（`:15-23`），选 Services **门禁天然生效**；
  选 Application 等于先绕开现成门禁、再花一批去补门禁（第二版 §5.5 正是这样安排的）。

因此第二版 §5.5「本批扩展 `verify-service-boundaries.sh` 的扫描路径」这项工作**取消**。
`goland-parity-b3b-replacement.md:61` 写的「新增应用层 `WorkspaceTextEditCoordinator`」
需一并更正为 Services 层。

事务状态沿用 B3b 的 preparing/committing/rollingBack/applied/cancelled/failed/recoveryRequired。

### 6.2 版本校验

- **只对宿主已同步给 server 的文档比对 `TextDocumentEdit.version`。** 实测 gopls 对
  客户端未打开的文件返回 `"version": 0`（不是 `null`），而宿主对未打开文件根本没有同步版本
  （`client_open_document` 从 version 1 起，`client.rs:126`）。「非 null 即比对，不符整体拒绝」
  会否掉**每一次**跨文件 rename。
- 未打开文件改用内容/文件身份快照校验：读取时记录 (dev, inode, size, mtime) 与内容哈希，
  提交前复核。可复用 `MacCargoMetadataPreparer.swift:228-250` 的 `CargoFileIdentity` 模式。
- 已打开文档另比对 `EditorDocument.revision` 与请求发起时的快照。
- 任一不符整体拒绝，提示「文件已变化，请重试重构」，不做部分应用。

### 6.3 资源操作与跨模块重命名副作用

**目标域包含目录。** 实测 gopls 的包重命名返回
`{"kind":"rename","oldUri":"file:///…/mod/inner","newUri":"file:///…/mod/renamedpkg"}`，
`oldUri` 是目录；`deleteFile` 的 `recursive` 也只对目录有意义。因此明确支持文件与目录两种目标：

- 目录的身份校验与文件同法（fd 相对操作复核父目录与身份，不用路径前缀字符串）。
- 目录 rename 的恢复记录只记录 rename 本身；目录 delete 走 trash 并记录被删子树，
  子树条目数与总字节有预算上限，超限则**拒绝该操作**而不是做无法回滚的删除。
- 目标必须在工作区内。

**复用已有的重命名副作用协议，但这是一次跨模块重构。** C11 更正后可见：真实实现在
独立 SwiftPM target `LitheWorkspaceModule`（`Application/WorkspaceFeatureModel.swift:487-577`），
不在应用 Application 层。因此必须在本批明确三件事，第二版对此一字未提：

1. **抽出的步骤归哪个 target。** 建议抽为 `LitheWorkspaceModule` 内的
   `WorkspaceRenameSideEffects`（`package` 级），由该模块继续拥有 history/marks/document
   重定位逻辑；协调器通过一个定义在 `LitheCoreContracts` 的窄协议调用它。
2. **依赖方向不得倒置。** 位于 `Lithe/Services` 的协调器依赖 `LitheCoreContracts` 的协议，
   由组合根注入 `LitheWorkspaceModule` 的实现；协调器**不直接 import `LitheWorkspaceModule`**。
3. **`scripts/verify-module-boundaries.sh` 必须通过**，且要说明
   `LitheWorkspaceModule` 侧新增的 `package` 面是否属兼容改动。

现有实现用 `Task.detached`（`:521`）+ 裸 `moveItem`（`:532`）且无 fd 相对身份校验；
本批统一到事务的校验路径上——这是**行为变更**，需单独说明并复验项目侧重命名的既有行为。

### 6.4 端口

`WorkspaceFileOperations`（`LitheCoreContracts/Workspace/WorkspaceFileOperations.swift:3-14`，
注意 C15：`Lithe/Core/Ports/` 下同名文件只是 typealias）现有 11 个粗粒度方法，
**无 fd 相对操作、无原子替换、无属性保留**，不足以支撑本批。
新增独立的 `WorkspaceTransactionFileOperations` 端口，实现所有权在 `Platform/MacOS`；
不扩张原端口。

### 6.5 提交后的 LSP 回同步：三个不相交集合

第二版只给了 `closeDocument → syncDocument → workspaceFilesChanged` 的顺序，
没说哪些路径进哪个通知。按字面实现，「被改文档」里已打开的那部分会**同时**出现在两个通知里，
违反 `shared/contracts/rust-core-api.md:788-790`：
*"Open documents remain owned by versioned `lsp.syncDocument`; adapters must not duplicate
those edits as watcher events."*

**本版定义三个不相交集合**，按此顺序推送：

| 步骤 | 集合 | 通知 |
| --- | --- | --- |
| 1 | 此前已 open 且被删除的路径，以及重命名的**旧**路径 | `lsp.closeDocument` |
| 2 | 已打开且内容被改的文档；重命名后的**新**路径中此前已打开的那些 | `lsp.syncDocument`（带版本） |
| 3 | 未打开的被改文件、新建文件、删除文件、重命名的旧/新路径中**未打开**的那些 | `lsp.workspaceFilesChanged` |

同一路径**只能出现在一个集合中**，实现时以断言保证（debug 下 `precondition`，
release 下记录诊断）。重命名后原文档仍打开时的顺序是：先 close 旧路径，
再以新路径 sync（宿主侧 `document.relocate(to:)` 之后）。

**部分失败也必须推送已生效的部分**，否则 server 视图与磁盘不一致，
下一次 rename 会基于陈旧包路径产出错误 edit。

### 6.6 旧路径的去留与四条路径的迁移

`AppModel+Development.applyLanguageWorkspaceEdit`（`:1934-1983`）**在本批删除**，
completion、formatting、code action、rename 全部改走协调器。否则 C8 列的缺陷
（无版本校验、`try?` 吞回滚、字符串前缀当工作区校验）会在这些路径上原样保留。

第二版 §8.6 只说「新增行为快照测试」，覆盖不了真实风险面。completion 插入是同步、低延迟、
单文档、缓冲区内操作；改走带版本快照 / 文件身份校验 / 租约 / 异步 worker 的事务是
**行为与时序双重变更**。因此本版必须先定义两件事：

1. **保留单文档、无文件 IO 的快路径。** 目标全部为「已打开且在本进程内的文档」且无资源操作时，
   协调器走同步快路径：只做 revision 校验与文本替换，不进异步 worker、不做文件身份快照。
   这条路径的延迟特性与今天一致。
2. **区分「要保留的现有行为」与「要顺带修的缺陷」**，逐条列出，不把缺陷当基线锁死：

| 现有可观测行为 | 处置 |
| --- | --- |
| `document.text` 外部变更时整体重设 `textView.string`，选区塌缩为 `length: 0`（C13） | **缺陷，本批修**：completion 后光标应落在插入文本之后 |
| `textView.string =` 不注册原生 undo（C13） | **本批不修**（属 B6b2 范围），但据此证明「接入无 undo 的事务不构成撤销能力回退」（§2.2 第 4 点） |
| 失败时的通知：主失败分支会 `showNotification(..., title: "Could not apply language edit")`（`:1981`）；静默的只有 `:1935` 的 `guard let workspaceURL else { return false }` | **保留通知行为**；静默分支改为可见失败 |
| autoSave 关闭时保持 dirty 不保存 | **保留** |
| autoSave 开启时的保存策略 | 按 B3b §4.7 执行（第二版此处与 B3b 自相矛盾，本版取 B3b） |

行为快照测试**只作为补充**，不作为这四条路径的唯一验收手段。光标落点、IME、延迟必须有
针对性测试。

### 6.7 诚实边界

原生文件系统没有跨多文件的全局原子提交。本批承诺应用内协调、单文件替换原子与失败补偿，
**不承诺外部进程看不到中间状态**，不把可回滚写入称为 ACID。
回滚只在目标仍是本事务写入的内容与身份时覆盖；第三方已改过的保留其内容并列为
recoveryRequired，报告区分「已恢复 / 未恢复」，用户确认前不清除记录。

**正因为存在 recoveryRequired 这个终态，§3.2 决定不声明 `failureHandling`。**

## 7. B6b2：跨文件 undo

`goland-parity-b3b-replacement.md:87` 明确要求：实施前单独审查 macOS 文档级 undo 所有者、
编辑器重新绑定、跨文件标记的顺序和原生菜单路由；明确异步失败后何时移动栈项。

**必须先提交一份回答上述四问的 undo 设计并单独审查**，才能实施。在 B6b2 交付前：

- B6b1 的事务**没有一次性跨文件 undo**，验收表中该项保持未完成。
- UI 明确告知本次重构不能一次撤销，不提供假的「撤销重构」入口。
- 注意 C13：这四条路径今天本来就没有原生 undo，因此这不是能力回退，是**既有缺口的延续**。
  文案要说明现状，不能暗示曾经可以撤销。

## 8. B6c / B6d：Refactor This 与重构矩阵

`Refactor This` 作为一个命令进入 `LitheCommandCatalog` / `LitheActionRegistry`，
编辑器右键、主菜单与快捷键共用同一命令，tooltip 显示实际生效快捷键。
弹出列表条目由当前语言 provider 的实际能力生成。

**Rename 流程**：有 `prepareProvider` 时先 `prepareRename` 取可重命名范围与 placeholder，
否则直接用编辑器的标识符范围与当前符号名预填 → inline 输入框预填并全选 → 提交时
`textDocument/rename` → 结果进事务并先显示预览 → Apply / Cancel。取消零修改。
文件与包重命名走 §6.3 的资源操作路径。

**预览 UI 的归属**（第二版全文未指派）：预览模型归 Application
（`macos/Sources/Lithe/Application/Features/`），视图归 Views。
`macos/Sources/Lithe/Views/Search/ProjectReplaceView.swift` 已有形态高度相似的替换预览，
B3b §3 也已定义 occurrence 级排除。**决定：抽取共用的预览呈现组件**，
Search 替换与重构预览复用同一组件、各自持有自己的预览模型；不并存两套视图代码。
若实施中发现两者的交互差异大到无法共用，在该批说明理由后再分开——但不能默默分开。

字符串与注释中的出现：只有 server 在 workspace edit 里给出时才包含。gopls 不提供
「search in comments/strings」开关，本批**不提供该选项**，在验收表中标为未对齐。

**B6d** 的 Extract/Inline/Change Signature/Move/Copy/Safe Delete 一律走
`textDocument/codeAction` 的标准 kind，带真实选区与 diagnostics。
执行路径**取决于 B6a1a 的重测结果**（§1.3、§3.3）：

- 若重测确认 gopls 在 `dataSupport` 下仍只给 `gopls.apply_fix` command，
  则路径为 `workspace/executeCommand` → server 反向 `workspace/applyEdit` → §4 的延迟响应，
  B6a1b 是 B6d 的硬前置。
- 若重测显示 gopls 改为经 `codeAction/resolve` 返回 edit，
  则主路径改为 resolve 往返（§5.3 的出站无损是硬前置），B6a1b 的优先级下调。

Extract constant 以 §3.4 的 resolve 结果为准；其他动作仍逐项实测，不从单一动作外推。

逐项以实际 gopls 能力为准，缺失项才由 Go language-support 插件的语义工具补足；
补足方案（Go AST/types）单独立项审查，不在本文放行。
**没有真实证据的条目在验收表中持续标记未完成。**
Rust/Python 只使用各自 provider 可用的重构。

## 9. 验收矩阵

1. **B6a1a**：initialize 请求 JSON 快照 fixture（**含读取它的具体测试**）；
   R3 重测结论；Rename Symbol 与 Source Actions 的真实 gopls 不回归复测。
2. **B6a1b**：applied / 未 applied / 解析失败 / 目标越界 / 延迟期间取消 / 延迟期间断连 /
   并发两个请求 / 未知 serverRequestId / 超时。每项断言**实际发回 server 的 JSON-RPC 响应**。
3. **B6a2 入站**：`changes` 与 `documentChanges` 并存；资源操作三种 kind（含目录目标）；
   AnnotatedTextEdit；非 file scheme；range 畸形；position 字段缺失或非整数；未知 kind；
   `version` 有/无/为 null/**为 0 且文档未打开**；prepareRename 三种形态；
   documentSymbol 两种响应。畸形一律整体失败并有稳定错误码。
4. **B6a2 出站**：URI round-trip（入站解析 → 出站序列化 → 再解析，逐字段等价）；
   `codeAction/resolve` 往返无损；含资源操作与 version 的 edit 出站不丢字段。
5. **B6b1 事务**：多文件成功；中途写失败全量回滚；第三方并发改写进 recoveryRequired；
   版本不符拒绝且零修改；取消在首次写入前零修改；目录 rename/delete 的恢复与预算上限；
   §6.5 三集合的**不相交性断言**与部分失败下的推送；打开文件的 dirty/保存语义
   （autoSave 关→保持 dirty，autoSave 开→按 B3b §4.7）；
   关闭项目时事务收尾以「协调器发出 applied/failed/cancelled 终态信号」为可观测判据，
   等待上限 5 秒，超时记录 recoveryRequired 并放行关闭。
6. **B6b1 四条路径迁移**：按 §6.6 的表逐条验收。**completion 后光标落点**、
   IME 组合期间的插入、快路径延迟特性各有针对性测试，不只靠行为快照。
7. **B6b2**：一次 undo 全量恢复、redo 再校验、异步失败后栈项处置——按其独立设计审查。
8. **B6c/B6d Go 矩阵**：Rename 符号/文件/包，Move/Copy/Safe Delete，Extract 五项，
   Inline 三项，Change Signature——每项独立多文件 fixture，操作前后 `go build` / `go test` 通过，
   取消零改动，版本冲突拒绝。不通过的条目留在表中标未完成。
9. **跨模块**：`LitheWorkspaceModule` 的项目侧重命名（新建/重命名/删除文件与目录）
   在抽取后行为不变，含 local history、directory marks、已打开文档重定位。
10. **明确标注未对齐/未交付**：`selectionRange` 与 `documentSymbol` 在 B6 内无消费方；
    字符串/注释重命名选项不提供；`failureHandling` 不声明；跨文件 undo 未交付。

## 10. 校验与提交

每批：独立 agent 审方案 → 实施 → 下列检查 → 真实 ARM64 应用逐项点击验收并截图 →
独立代码审查 → 分批 commit，不 push。B6a1a 的「点击验收」按 §3.3 第 3 项执行
（既有能力不回归复测，不是新功能验收）。

```bash
export PATH="$PWD/.artifacts/toolchains/swift-6.2.4/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin:$PATH"
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./scripts/verify-rust-core-comments.sh
./scripts/verify-rust-core.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-module-boundaries.sh
./scripts/test-macos.sh -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
git diff --check
```

本机没有 Xcode，`/usr/bin/swift` 是 CLT 的 6.0.3，不满足 `Package.swift` 的 tools
version 6.2；实际使用仓库内解包的 swift.org 6.2.4 工具链，必须按上面先置于 PATH。
不传 `-force_load` 时 `RustCoreBridge().isAvailable` 为 false，约 50 项测试会以
「Rust Core is unavailable」失败，那是调用方式问题而非回归。

**§2.2 要求的 `goland-parity-b3b-replacement.md` 修订与本文一并提交**，
不得只在本文单方面声明归属。

## 11. 官方依据

- [LSP 3.17 WorkspaceEdit / ResourceOperation / ChangeAnnotation](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEdit)
- [LSP 3.17 workspace/applyEdit](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_applyEdit)
- [LSP 3.17 textDocument/prepareRename](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_prepareRename)
- [LSP 3.17 textDocument/selectionRange](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_selectionRange)
- [LSP 3.17 CodeActionKind](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeActionKind)
- [LSP 3.17 FailureHandlingKind](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#failureHandlingKind)
- [GoLand Refactoring](https://www.jetbrains.com/help/go/refactoring-source-code.html)

规范条款需在实施前逐条对照实现；文档引用不是对齐的完成证明。
本文所有「实测」结论来自本机 gopls v0.20.0，换 server 版本需重新验证。
**R3 另有协商条件限定，见 §1.3。**


<a id="b6-current-implementation-rulings"></a>

## 11. 2026-10-06 实施前复核与衔接裁定

当前源码基线为 `e380bc38`。前置原生编辑器门禁已在 `d7973669` 系统安装版完成，
包括跨文件 Undo/Redo、emoji、未保存 HTML 预览、Git 行标记、设置窗口及 Go LSP 重启；
完整 Swift 1544 项测试通过，实际范围和证据见
[原生编辑器验收](ai-ide-phase-one.md)。本节是 B6 的实施前复核，不是 B6a2 功能验收。

### 11.1 已有能力与实际缺口

- `fd7d3cd1` 之后已经存在混合缓冲区/磁盘文本事务、mutation lease、身份保护补偿、
  Search Replace 的实际 Apply、选中文件/occurrence 排除及共享 Undo/Redo；`8ec7e1eb`
  又修复了原生输入历史的生命周期。第 2、6、9 节中“租约/Undo/Apply 均未实现”的历史
  说法不能继续作为实施依据，也不应重新引入已删除的上游 owner。
- 这些能力不等于 B6b1/B6b2 整体完成：实施前的 `AppModel+Development.applyLanguageWorkspaceEdit`
  是旧 map 路径，缺有序资源操作、LSP 版本和请求身份校验；既有 coordinator 的文本
  批次会去重并排序，不能直接解释有序 create/edit/rename/delete。
- B6a1b 的反向 applyEdit 处理器和完成命令仍未实现。§3.4 已证明 Extract constant 可以
  走 resolve，所以 B6a2 继续只依赖 B6a1a；不能把 a1b 永久删除，也不把它错误地放回
  所有 B6a2 工作的硬前置。

### 11.2 第一条可交付链：保真协议与安全文本接入

出站方案确定为**有类型的统一序列化**，不并行保留 raw JSON 退路，也不提供会降级的
`.changes` 派生访问器。有序模型必须包含全局 `changeAnnotations`、文本/资源 annotation ID、
版本与资源选项；§5.1 的简略 enum 不是完整 wire 定义。协议语义依据为
[官方 LSP 3.17 WorkspaceEdit 定义](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/workspaceEdit.md)。

B6a2 发布前先完成 B6b1 的**最小纯文本适配**：完整预检 ordered operations，按顺序在
临时文本中解释重复 URI 的编辑，再生成每路径 source → final replacement，交给既有
`WorkspaceTextEditUndoController` 和 `WorkspaceTextEditCoordinator`。不能拼接同 URI 的
编辑数组、逐项写入，或为规避适配而拒绝全部 versioned documentChanges；后者会破坏
已有 Go Rename。资源操作以及需要确认而尚无确认界面的 annotation，当前整单明确拒绝、
零修改，但仍完整保存并可往返，相关 capability 暂不声明。完整资源事务仍归 B6b1。

同步快照来自现有 RuntimeSession 的实际 session 身份、同步版本及其对应的来源文本/字节身份，经 Session 协议和
Manager 暴露；不得从 `EditorDocument.revision` 猜测 LSP 版本。当前 Manager 的
rename/format/codeActions 忽略传入的 text/root，所以必须实际同步请求缓冲区后再捕获
上下文。请求上下文保留 workspace generation、document ID、locationRevision、编辑
revision 与同步快照，并贯穿响应、动作选择、resolve 和 apply。已同步版本精确比较；
真正未打开目标的 gopls version 0 按 §6.2 使用内容/磁盘身份快照，不能与不存在的版本比较。
所有目标都查询产生动作的原 session，不按目标扩展名另行路由；已打开但未同步、或同步
版本对应文本与当前缓冲区不同的目标整单拒绝，包括 dirty 的 version-0 目标。

Rename、Formatting、Code Action、Completion 四条入口一起迁移。全为打开文档的
Completion 保留同步、无文件 IO 的提交路径，复用同一租约、Undo 与选区恢复 owner；
additionalTextEdits 对光标位置的影响纳入验证。Code Action 的 command 必须等 edit
实际 applied 后执行，并核对原 workspace/session 与事务产出的后置文档身份；不能在本次
修改推进 revision 后仍要求原 revision 不变。磁盘等待期间切项目/重启 session 则取消命令，
已提交的编辑据实报告。打开文件使用既有文档回同步；未打开文件使用 watcher 通知，集合不重叠。

以上接口、版本零值、取消/补偿、同步快路径和消费者衔接已完成独立只读方案审查。
审查未运行新产品测试，也未修改源代码；补充的同步内容身份、applied→command 身份复核与悬空 annotation 整单失败用例已纳入
执行计划，独立审查允许开始失败回归；后续仍须先观察失败回归，再实施和验收。
本地执行步骤与裁定记录位于 `.artifacts/b6a2/workspace-edit-plan.md` 和 `progress.md`。

### 11.3 后续方法、选区和消费者门控

- prepareRename 按 §5.2 的三种结果实现，Rename 仍按 `.rename` 能力门控，不要求服务器
  必须支持 prepareRename。已有 Rename 入口消费其范围/placeholder；内联重命名完整交互
  仍归 B6c，不能用 prepareRename API 代替它。
- 合法多行 UTF-16 选区与零宽选区都可请求 Code Actions。原 §5.5 的“跨行不请求”会
  阻断 Extract Function，已更正；未提交 IME、非法范围、过期文档身份/revision 拒绝，
  返回与 resolve 后再次检查。
- selectionRange/documentSymbol 的类型、请求、解析、能力探测和共享 fixture 可以作为
  B6a2 协议预交付。documentSymbol 产品消费者仍是 B7b/L4a，selectionRange 的选区扩展
  消费者归 L8；消费方尚未接入时，不开启新的生产声明或自动请求，不称产品分支完成。
  B7b 依赖该协议交付，不能反过来阻塞 B6a2 的纯文本迁移。既有 Go/Rust runnable gutter
  继续保留；它不自动证明 B7b 的剩余协议计划已经完成。

本节没有完成或删除 B6a1b、B6a2 的其余方法、B6b 的资源事务与 Undo、B6c/B6d。
第一条文本链完成后，继续上述方法与消费者，按原验收矩阵实际构建、安装、对照和分阶段提交。


### 11.4 首个文本切片实现与自动验证（2026-10-06）

本批基于 `df2196c0` 实现有序 workspace edit 与四个既有文本入口迁移；自动验证通过，
当时安装与实机验收待完成（2026-10-28 补记见本节末尾），不表示 B6a2 整体完成。Rust 严格模型保留操作顺序、版本、资源
选项及注释，Swift 两个解码入口和 resolve 出站共用 typed codec。非法编辑整单失败，
解析错误保留 operation ID，响应与超时归约使用同一状态锁，避免同请求双终态。

宿主四个入口迁至 `AppModel+LanguageEditing`，通过原 session token、workspace generation、
文档 UUID/locationRevision/revision 和精确 UTF-8 同步来源校验。Planner 在修改前拒绝
资源/确认操作，顺序解释重复 URI，向既有文本事务输出每个路径的唯一最终替换。
全缓冲区补全使用同一控制器的同步路径，保存前后选区；Undo 身份使用原生历史世代，
不绑定已经因自身修改推进的 LSP version 或请求 revision。内建补全与 LSP 候选分别保留来源。
补全 Undo/Redo 同样同步结束，使用仅允许同步缓冲区操作的 lease；保存中的已捕获内容
独立于 live buffer，异步磁盘事务的 lease 不放宽。完整同步成功后，仅原会话已接受且与
当前 UTF-8 字节相同的快照可以清除已覆盖的原生增量，避免 debounce 重复升版本。

独立只读复核要求并已纳入实现/回归：磁盘补偿快照保留到 MainActor 最终提交；失效或
忙时响应不得取消现有事务；关闭/切项目等待所属编辑及磁盘 Undo/Redo 补偿后再释放
原 workspace；文档重开/重新载入后不得重放旧补全历史；初始化 version 0 不推算为 1。
无变化目标保留为事务前置条件，再次核对磁盘身份/内容，不写盘、不登记历史、不发送
变化通知；其 lease 收尾仍排空延迟文件观察事件。Code Action 命令仅在实际应用完成、
提交后身份仍匹配并回同步原会话后发送。最终静态复核无剩余阻断项。

自动验证与复现证据如下（报告均在 `.artifacts/test-stability/`）：

- Rust 完整计时回归 523 项通过，92.063 秒：
  `b6a2-workspace-edit-uri-final-rust.json`。严格 URI、空 action edit、格式化/补全整单失败、
  响应与超时竞争均有实际失败回归，随后修复。
- `verify-rust-core.sh` 通过，122.277 秒，包含 Rust/Swift bridge 和相关集成；日志与有界
  进程结果在 `.artifacts/b6a2/verify-rust-core.log`、`verify-rust-core-result.json`。
- 最终 Rust-linked 完整 Swift：控制台 1574 项、186 suites 全部通过，45.912 秒；
  `b6a2-text-verified.json` 记录 1563 个计时条目，全部通过，无超时或硬预算失败。
  14 项超过 1 秒预警；本批修改中最慢为原生释放检查 1.015 秒，补全提交 30ms。
  HTML 模块健康度与预警已在浏览器检查，截图在 `.artifacts/b6a2/ui/test-report-final.png`。
- Swift-only 定向检查 41 项通过，0.168 秒，无性能预警：`b6a2-swift-fallback-final.json`。
  测试夹具注入原生读取与窄生命周期决策，独立覆盖无 Rust 实现的回退；不绕过宿主事务。
- 补全无法 Undo、旧会话版本化动作被接受、同步遗留 native delta、无变化目标丢失
  前置条件、磁盘 Undo 补偿中提前切项目均有实际 red/green 回归。原始证据包括
  `b6a2-workspace-edit-host-red-corrected.json`、`b6a2-completion-undo-sync-red.json`、
  `b6a2-pending-native-sync-red.json`、`b6a2-preconditions-replay-red.json`。
  单次观察事件排空使用禁用重复原生投递的夹具，真实失败后修复，见
  `b6a2-noop-watcher-controlled-red.json`。
- 原生磁盘回滚先因锁屏保护 EPERM 失败；用户解锁后两个分支通过，最终完整套件再次
  通过，未改变文件保护策略。原生 storage 释放检查的超时后内存图证明唯一强引用为
  主线程 autorelease pool；测试现通过原生 RunLoop 回调逐轮排空池，每轮最多 20ms，
  三项释放共用固定 2 秒期限。保留原 A→释放→B 顺序、所有弱引用/选区/历史断言，
  未修改生产生命周期、清空历史或拆卸 TextKit 图。修复前失败、修复后定向及完整通过；
  内存图在 `.artifacts/b6a2/native-storage-after-timeout.memgraph`。未新增静态扫描例外。
- Rust 注释/fmt、共享 JSON、service/module 边界、测试稳定性静态门禁及 diff/新增文件
  空白检查通过。测试与探针启动的 Lithe/helper/gopls 进程已结束。

真实 gopls 0.20.0 经当前 Core 检查跨文件 Rename（打开版本 1 / 未打开版本 0）、
非 ASCII 文件 URI、格式化和 Organize Imports（版本 4）通过；修改前后 `go test` 均正常。
记录 `.artifacts/b6a2/real-gopls/core-probe.json`。当前能力组合未返回可 resolve 的 data，
故真实 resolve 验收仍待完成；此探针不代替安装应用的 UI 验收。

2026-10-28 补记：本切片已随轻量维护构建并安装至系统，Go/Rust 基础 Unicode 编辑、
保存及跨标签 Undo/Redo 冒烟通过，见[本批安装验收](ai-ide-phase-one.md#13-2026-10-28-轻量维护按需-cherry-pick)。
重命名、格式化、代码动作、补全及其撤销仍需 Lithe/GoLand/RustRover 实机对照和
真实 resolve 验证；基础编辑冒烟不替代这些验收。后续恢复迭代时继续 §11.3 其余
方法/消费者。prepareRename、真实选区 Code Action、符号/selectionRange、资源事务、
反向请求和 B6c/B6d 仍未完成。
