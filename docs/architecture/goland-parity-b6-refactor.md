# B6 重构：语义编辑事务与 Refactor This

状态：基于 `4f41da49`。第一版方案经独立审查**不放行**，本文是按 12 条阻塞问题修订后的
第二版，待重审，未实施。承接 [B6 设计基线](goland-parity-implementation.md) 与
[B3b 跨文件替换事务](goland-parity-b3b-replacement.md)。B3b 设计的
`WorkspaceTextEditCoordinator` 当时未放行实施，本文把它作为 B6 的第一等交付，
Search 替换与重构共用同一个事务，不做两份。

第一版的核心错误：只核查了 LSP 的**解析侧**，漏掉**协商侧**（client initialize
capabilities）和**反向请求侧**（`workspace/applyEdit`）。按第一版实施，B6a 全量做完后
Go 的重构能力会比现在更差。本版把这两处列为 B6a 的首要交付。

## 1. 现状核查

以下每条都在源码中核对过；标注「实测」的另用本机 gopls v0.20.0 验证过实际报文。

### 1.1 解析侧

| # | 事实 | 位置 |
| --- | --- | --- |
| C1 | `LanguageServerWorkspaceEdit` 只有 `changes: [URL: [TextEdit]]`；无顺序、无版本、无资源操作 | `LanguageToolingContracts.swift:491` |
| C2 | Rust 客户端把 `documentChanges` 压平进同一个 map，`textDocument.version` 直接丢弃 | `client.rs:1150` |
| C3 | `documentChanges` 中没有 `textDocument.uri` 的条目一律 `continue`：`create`/`rename`/`delete` 资源操作被**静默丢弃** | `client.rs:1151-1157`（`continue` 在 1156） |
| C4 | `parse_lsp_text_edit_value` 用 `filter_map`：range 畸形的 edit 被静默丢弃，其余照常当成功 | `client.rs:1174` |
| C4b | `parse_lsp_position_value` 对 `line`/`character` 用 `unwrap_or(0)`：非整数或缺字段被**静默改写成 0**，比 C4 的丢弃更危险 | `client.rs:1188-1196` |
| C5 | 请求白名单（`client.rs:561-577`）无 `prepareRename`、`selectionRange`、`documentSymbol`、`linkedEditingRange` | `client.rs:561-577` |

### 1.2 协商侧（第一版遗漏）

| # | 事实 | 位置 |
| --- | --- | --- |
| N1 | client capabilities 的 `rename` 只有 `dynamicRegistration`，**无 `prepareSupport`** | `client.rs:57` |
| N2 | `textDocument` 下无 `documentSymbol`、无 `selectionRange`、无 `rangeFormatting` | `client.rs:31-90` |
| N3 | `workspace.workspaceEdit` 只有 `documentChanges: true`，**无 `resourceOperations`、无 `changeAnnotationSupport`、无 `failureHandling`** | `client.rs:95-97` |
| N4 | 实测：不声明 `prepareSupport` 时 gopls 返回 `renameProvider: true`（裸 bool）；补齐后返回 `{"prepareProvider": true}` | 本机 gopls v0.20.0 |
| N5 | 实测：不声明 `documentSymbol` 的 hierarchical 支持时 gopls 返回扁平 `SymbolInformation[]`；补齐后返回带 `selectionRange` 的 `DocumentSymbol[]` | 同上 |

### 1.3 反向请求侧（第一版遗漏）

| # | 事实 | 位置 |
| --- | --- | --- |
| R1 | client 向 server 声明 `workspace.applyEdit: true` | `client.rs:92` |
| R2 | 但 `workspace/applyEdit` 落入 `_ =>` 分支，返回 `-32601 Method not found` | `client.rs:399-403` |
| R3 | 实测：gopls 的 `Extract constant` 是 `hasEdit=false, hasCommand=true`（`gopls.apply_fix`，`ResolveEdits: false`）；编辑在 `executeCommand` 之后由 server 反向发起的 `applyEdit` 中送达 | 本机 gopls v0.20.0 |

R1+R2 合起来是**当前最严重的既有缺陷**：我们告诉服务器支持 applyEdit，然后拒绝它。
Go 的绝大多数 code action 类重构因此没有任何 edit 送达路径。

### 1.4 宿主侧

| # | 事实 | 位置 |
| --- | --- | --- |
| C6 | `LanguageServerFeatureSet` 共 11 位，无 prepareRename/documentSymbol/selectionRange | `LanguageToolingContracts.swift:34-55` |
| C7 | `requestLanguageCodeActions` 用光标处零宽 range，选区从不传给 server；实测零宽 range 下 gopls 不返回任何 `refactor.extract.*` | `AppModel+Development.swift:1725-1747` |
| C8 | `applyLanguageWorkspaceEdit` 无版本校验；回滚只覆盖未打开文件（1889）且用 `try?` 吞掉回滚失败（1894）；工作区归属用 `path.hasPrefix(root + "/")` 字符串前缀（1866） | `AppModel+Development.swift:1858-1907` |
| C9 | 选区已存在于编辑器（UTF-16 offset，按 document ID 保存），只服务于滚动/恢复，没有出口 | `CodeEditorView.swift:630-647,1120` |
| C10 | rename 入口直接 apply server 返回的 edit，无预填名、无预览、无冲突处理 | `AppModel+Development.swift:1679-1700` |
| C11 | 文件/目录重命名**已有完整既成实现**：`recordHistory(.beforeRename)` → 递归计算受影响文件 → `moveItem` → `directoryMarks` 迁移 → 逐文件 `relocateHistory` → `relocateOpenDocuments` → `document.relocate(to:)` | `WorkspaceFeatureModel.swift:507-570`、`RustLocalHistoryOperations.swift:25`、`DocumentFeatureModel.swift:667` |

C3、C4、C4b、C8、R2 是**当前已存在的正确性缺陷**，不是待补功能。

## 2. 分批与依赖

| 子批 | 交付 | 依赖 | 不属于本批 |
| --- | --- | --- | --- |
| B6a1 | 协商侧：client initialize capabilities 补齐；反向请求侧：`workspace/applyEdit` 接收与响应 | 无 | 任何新菜单 |
| B6a2 | 解析侧：workspace edit 保真（顺序/版本/资源操作/畸形整体失败）、prepareRename、selectionRange、documentSymbol；feature flag 与 server capability 探测 | B6a1 | 编辑的实际应用 |
| B6b1 | `WorkspaceTextEditCoordinator` 事务：版本校验、编辑租约、资源操作、失败回滚、恢复记录、LSP 回同步。**不含跨文件 undo** | B6a2、B3b1 | 跨文件 undo |
| B6b2 | 原生跨文件 undo/redo | B6b1 + 独立 undo 设计审查 | — |
| B6c | Refactor This 入口 + Rename（符号/文件/包） | B6b1 | Extract/Inline/Change Signature |
| B6d | Extract/Inline/Change Signature、Move/Copy/Safe Delete | B6c | 非 Go 语言的 Go 特有语义 |

**B3b1 是 B6b1 的前置且当前未实施**（B3b 分批表 `:100-103`，B3b1–B3b4 全部未开始）。
Search 侧「提交准备好的纯文本 edit 请求」依赖 B3b1 的 `sourceText`、稳定匹配标识与预算契约。
B6b1 不能在 B3b1 之前进入实施；B3b1 归属需在本文重审时明确指派，不能默认由 B6 顺手带做。

B6a1/B6a2 不产生用户可见新功能，验收是 fixture 与回归，不做点击验收，也不得据此声称
"重构已对齐"。

## 3. B6a1：协商与反向请求

### 3.1 client capabilities 补齐（逐字列出）

`client.rs` 的 initialize 请求新增以下字段，**这是 B6a 的第一项交付**：

```
textDocument.rename.prepareSupport = true
textDocument.rename.prepareSupportDefaultBehavior = 1
textDocument.documentSymbol.hierarchicalDocumentSymbolSupport = true
textDocument.documentSymbol.dynamicRegistration = true
textDocument.selectionRange.dynamicRegistration = true
workspace.workspaceEdit.resourceOperations = ["create", "rename", "delete"]
workspace.workspaceEdit.failureHandling = "transactional"
workspace.workspaceEdit.changeAnnotationSupport = { "groupsOnLabel": false }
```

`failureHandling: "transactional"` 是对 server 的承诺，必须由 B6b1 的全量回滚兑现；
B6b1 交付前不得声明它。因此 B6a1 只声明 `resourceOperations` 与 `prepareSupport`，
`failureHandling` 与 `changeAnnotationSupport` 随 B6b1 一起打开，避免承诺没有实现的语义。

不新增 `rangeFormatting`：实测 gopls v0.20.0 的 `documentRangeFormattingProvider` 为 `null`，
直接请求返回 `-32601`，且 B6 全文没有消费方。它属于后续格式化批次，不在 B6 范围。

验收加 **initialize 请求 JSON 快照 fixture**，字段增删都必须显式改快照。

### 3.2 `workspace/applyEdit` 反向请求

`client.rs` 增加对该 method 的处理，不再落入 `-32601`。语义：

- 收到后解析 `WorkspaceEdit`（与 3.3 同一解析器），交给宿主。
- 宿主**延迟**该 JSON-RPC 响应，直到事务给出结论，再回
  `{"applied": bool, "failureReason": string?}`。预览被用户取消时回 `applied: false`
  并带 `failureReason`，不能回 `applied: true` 后再撤销。
- 解析失败、目标越界、无活动事务上下文时回 `applied: false` 且附原因，**不回 `-32601`**。
- 延迟响应有独立上限（与所属操作的 deadline 共享）；超时按 `applied: false` 回复并结束，
  不能让 server 无限等待。

这条改变了 client 的请求/响应时序（此前所有响应都是同步生成的），属**协议级变更**，
需要在 `shared/contracts/rust-core-api.md` 说明，并单独设计 fixture 覆盖
「延迟响应期间收到取消」「延迟期间连接断开」「同时有两个 applyEdit」。

## 4. B6a2：解析保真

### 4.1 契约变更

`LanguageServerWorkspaceEdit` 从"路径→编辑"改为**有序操作列表**：

```
enum LanguageServerWorkspaceOperation {
    case edit(LanguageServerTextDocumentEdit)   // uri + version: Int? + [TextEdit]
    case createFile(url, overwrite, ignoreIfExists)
    case renameFile(oldURL, newURL, overwrite, ignoreIfExists)
    case deleteFile(url, recursive, ignoreIfNotExists)
}
```

`changes` 形式归一化为单一 `edit` 序列，顺序按 URI 的 UTF-8 字节序固定以保证确定性。
**`documentChanges` 的顺序是 LSP 语义顺序，必须原样保留，不参与排序。**
`documentChanges` 存在时**忽略** `changes`（LSP 3.17 明文要求），不再按 uri 覆盖合并。

**不保留 `changes: [URL:[TextEdit]]` 的 Optional 派生访问器。** 第一版设想的
"含资源操作时返回 nil 强制调用方显式处理"是错的：Swift Optional 只强制*语法*处理，
`?? [:]` 或 `guard let … else { return false }` 即可编译通过并静默退化——而现有
`applyLanguageWorkspaceEdit` 的失败分支恰好就是不发通知的 `return false`（1859）。
改为：所有消费者一律走 B6b1 的协调器，旧的 `applyLanguageWorkspaceEdit` **删除**（见 §5.4）。

`changes` 从存储属性改为不存在，以下**构造**调用点全部要改，本批一并交付：
`RustCoreBridge.swift:482`、`LanguageServerSession.swift:978`、
`AppModel+Development.swift:1717`、`AppModel+Development.swift:1852`，
以及测试 `RunConfigurationIntegrationTests.swift:2309`、`LanguageIntelligenceModuleTests.swift:1048`。

**兼容面核查结论**：`LanguageServerWorkspaceEdit` 与 `LanguageServerFeatureSet` 都是
`package` 访问级，不在动态插件公开面上；插件的语言服务器 ABI 是
`LanguageServerExtensionConfiguration` + `LanguageServerExtensionLifecycle`
（`LanguageExtensionContracts.swift:86-139`），不引用这两个类型。**本批不触碰插件 v1 ABI**。

### 4.2 Rust 侧

`parse_workspace_edit` 改为返回 `Result`，畸形条目**整体失败**并给出稳定错误码
（`lsp.workspaceEdit.malformedEdit` / `.unknownOperation` / `.missingURI` /
`.unsupportedScheme`），不再 `filter_map`。`parse_lsp_position_value` 的
`unwrap_or(0)` 一并改为整体失败——静默把坐标改写成 0 会产生位置正确但内容错误的编辑。

`AnnotatedTextEdit` 按普通 TextEdit 处理但保留 annotation ID；`changeAnnotations` 的
`needsConfirmation` 传给宿主（仅在 B6b1 打开 `changeAnnotationSupport` 后才可能出现，
且无证据 gopls 会发，因此定位为「server 提供时才生效」，不作为交付承诺）。
不认识的 `kind` 整体失败。资源操作 URI 经 `file_path_from_uri`，非 `file:` scheme 整体失败。

新增方法 `textDocument/prepareRename`、`textDocument/selectionRange`、
`textDocument/documentSymbol` 进白名单、参数构造与结果解析。`prepareRename` 三种响应形态
（Range、`{range,placeholder}`、`{defaultBehavior:true}`）全部保留，不把 `defaultBehavior`
折叠成"无结果"。`documentSymbol` 同时支持 `DocumentSymbol[]` 与 `SymbolInformation[]`，
两者不混用。server capability 探测新增 `renameProvider.prepareProvider`、
`selectionRangeProvider`、`documentSymbolProvider`，沿用现有 `add_capability` 模式。

Rust Core 只做协议解析与规范化：不访问文件、不判断路径是否在工作区内、不执行资源操作。
路径归属与权限一律由宿主判定（与 B7a1 同一原则）。

### 4.3 Swift 侧与能力门控

`LanguageServerFeatureSet` 新增 `prepareRename`、`selectionRange`、`documentSymbol` 三位。

**Rename 的门控用 `renameProvider` 是否存在，不是 `prepareRename`。**
`prepareProvider` 只决定「是否先调 prepareRename 取 placeholder 与可重命名范围」。
第一版写的"有 prepareRename 才出 Rename"会把 Go 现在可用的 Rename Symbol
（`CodeEditorView.swift:3601,3659` 按 `.rename` 位挂载）从菜单里删掉，是功能回退。
§5 的措辞随之修正：**不做能力回退**指的是不猜测、不用全文替换冒充语义重构，
不是把已有可用能力按新位门控掉。

`requestLanguageCodeActions` 接受真实选区：编辑器把 UTF-16 selection 转成
`LanguageServerRange`，零宽选区保持零宽（行为不变），非零选区如实传递。选区跨行、
含 IME 未确认文本、或 document revision 与请求时不一致时不发请求。

### 4.4 契约文档与 fixture

`shared/contracts/rust-core-api.md:810-815` 显式枚举 `lsp.request` 的 operation 集合，
本批新增 3 个 operation、改 workspace edit 结果 payload、新增 4 个错误码、
新增 applyEdit 反向请求时序，**必须同步更新该文档**。
新增 `shared/fixtures/lsp/workspace-edit-v1.json` 覆盖 §7.1 的全部形态
（现有 `shared/fixtures/lsp/` 的 6 个 JSON 均为 JDT 相关，不能复用）。

## 5. B6b1：语义编辑事务（不含 undo）

实现 B3b 第 4 节设计的 `WorkspaceTextEditCoordinator`，位置在 Application 层
（该层归属经核查与 SKILL 所有权表及 B3b §4 一致），通过 Core 端口调用 macOS 文件适配器；
资源操作的实际执行落在 `Platform/MacOS`。事务状态沿用 B3b 的
preparing/committing/rollingBack/applied/cancelled/failed/recoveryRequired。

### 5.1 版本校验

- **只对宿主已同步给 server 的文档比对 `TextDocumentEdit.version`。** 实测 gopls 对
  客户端未打开的文件返回 `"version": 0`（不是 `null`），而宿主对未打开文件根本没有
  同步版本（`client_open_document` 从 version 1 起，`client.rs:126`）。第一版的
  "非 null 即比对，不符整体拒绝"会否掉**每一次**跨文件 rename。
- 未打开文件改用内容/文件身份快照校验：读取时记录 (dev, inode, size, mtime) 与内容哈希，
  提交前复核。
- 已打开文档另比对 `EditorDocument.revision` 与请求发起时的快照。
- 任一不符整体拒绝，提示"文件已变化，请重试重构"，不做部分应用。

### 5.2 资源操作

**目标域包含目录。** 实测 gopls 的包重命名返回
`{"kind":"rename","oldUri":"file:///…/mod/inner","newUri":"file:///…/mod/renamedpkg"}`，
`oldUri` 是目录；`deleteFile` 的 `recursive` 也只对目录有意义。因此本批明确支持
文件与目录两种目标，并写清：

- 目录的身份校验与文件同法（fd 相对操作复核父目录与身份，不用路径前缀字符串）。
- 目录 rename 的恢复记录只记录 rename 本身；目录 delete 走 trash 并记录被删子树，
  子树条目数与总字节有预算上限，超限则**拒绝该操作**而不是做无法回滚的删除。
- 目标必须在工作区内。

**复用已有的重命名副作用协议，不另起一套**：`WorkspaceFeatureModel.swift:507-570`
已实现 `recordHistory(.beforeRename)` → 递归计算受影响文件 → 迁移 `directoryMarks` →
逐文件 `relocateHistory` → `relocateOpenDocuments` → `document.relocate(to:)`。
B6b1 把该协议抽为可被事务调用的步骤，事务与项目侧重命名共用同一实现。
现有实现用 `Task.detached` + 裸 `moveItem` 且无 fd 相对身份校验，本批统一到事务的
校验路径上——这是**行为变更**，需在该批单独说明并复验项目侧重命名的既有行为。

### 5.3 提交后的 LSP 回同步

资源操作与文本编辑提交成功后，按确定顺序推送：
`lsp.closeDocument`（被删除/被重命名的旧路径）→ `lsp.syncDocument`（新路径与被改文档）
→ `lsp.workspaceFilesChanged`（`workspace/didChangeWatchedFiles`，已存在于
`engine.rs:543,932,3291`）。**部分失败也必须推送已生效的部分**，否则 server 视图与磁盘
不一致，下一次 rename 会基于陈旧包路径产出错误 edit。第一版完全遗漏了这一步。

### 5.4 旧路径的去留

`AppModel+Development.applyLanguageWorkspaceEdit`（1858-1907）**在本批删除**，
completion、formatting、code action、rename 全部改走协调器。否则 C8 列的缺陷
（无版本校验、`try?` 吞回滚、字符串前缀当工作区校验）会在这些路径上原样保留，
而 §1 是把 C8 当既有缺陷陈述的。第一版 §6 与 §7.4 在这点上自相矛盾，本版取消该矛盾。

### 5.5 端口与门禁

- `WorkspaceFileOperations`（`WorkspaceFileOperations.swift:3-14`）现有 11 个粗粒度方法，
  **无 fd 相对操作、无原子替换、无属性保留**，不足以支撑本批。本批新增独立的
  `WorkspaceTransactionFileOperations` 端口，所有权在 `Platform/MacOS`；不扩张原端口。
- `scripts/verify-service-boundaries.sh` **不扫描** `macos/Sources/Lithe/Application/`
  （只扫 Core、Services、Views、`AppModel.swift`、`Models/`，见 17-24 行）。协调器放
  Application 意味着"不构造 FileManager/FileHandle"当前**没有任何自动门禁**。
  本批随 B6b1 扩展该脚本的扫描路径，否则分层约束只是文字。

### 5.6 诚实边界

原生文件系统没有跨多文件的全局原子提交。本批承诺应用内协调、单文件替换原子与失败补偿，
**不承诺外部进程看不到中间状态**，不把可回滚写入称为 ACID。回滚只在目标仍是本事务写入的
内容与身份时覆盖；第三方已改过的保留其内容并列为 recoveryRequired，报告区分
"已恢复/未恢复"，用户确认前不清除记录。

## 6. B6b2：跨文件 undo

B3b `:87` 明确要求：「不能仅添加 `UndoManager.registerUndo`……实施前单独审查 macOS
文档级 undo 所有者、编辑器重新绑定、跨文件标记的顺序和原生菜单路由；明确异步失败后
何时移动栈项……测试证明这些规则之前，不接通新事务的正式 Apply」。

第一版用三句结论越过了这道门。本版把跨文件 undo 拆为独立子批，**必须先提交一份回答
B3b 上述四问的 undo 设计并单独审查**，才能实施。在 B6b2 交付前：

- B6b1 交付的事务**没有一次性跨文件 undo**，验收表中该项保持未完成。
- UI 明确告知本次重构不能一次撤销，不提供假的"撤销重构"入口。
- 因此 B6a1 的 `failureHandling: "transactional"` 与 B6b1 一起打开即可（回滚已具备），
  与 undo 无关。

## 7. B6c / B6d：Refactor This 与重构矩阵

`Refactor This` 作为一个命令进入 `LitheCommandCatalog` / `LitheActionRegistry`，
编辑器右键、主菜单与快捷键共用同一命令，tooltip 显示实际生效快捷键。
弹出列表条目由当前语言 provider 的实际能力生成。

Rename：有 `prepareProvider` 时先 `prepareRename` 取可重命名范围与 placeholder，
否则直接用编辑器的标识符范围与当前符号名预填 → inline 输入框预填并全选 → 提交时
`textDocument/rename` → 结果进事务并先显示预览（按文件分组、可逐文件/逐 occurrence
取消勾选）→ Apply / Cancel。取消零修改。文件与包重命名走 §5.2 的资源操作路径。

字符串与注释中的出现：只有 server 在 workspace edit 里给出时才包含。gopls 不提供
"search in comments/strings"开关，本批**不提供该选项**，在验收表中标为未对齐。

B6d 的 Extract/Inline/Change Signature/Move/Copy/Safe Delete 一律走
`textDocument/codeAction` 的标准 kind，带真实选区与 diagnostics。**实测 gopls 的
`Extract constant` 不带 edit 也不带 data，只带 `gopls.apply_fix` command**，因此
执行路径是 `workspace/executeCommand` → server 反向 `workspace/applyEdit` → §3.2 的
延迟响应 → 事务与预览。这条路径不存在时 B6d 无法交付，所以 §3.2 是 B6d 的硬前置。

逐项以实际 gopls 能力为准，缺失项才由 Go language-support 插件的语义工具补足；
补足方案（Go AST/types）单独立项审查，不在本文放行。**没有真实证据的条目在验收表中
持续标记未完成**。Rust/Python 只使用各自 provider 可用的重构。

## 8. 验收矩阵

1. **B6a1**：initialize 请求 JSON 快照 fixture；`workspace/applyEdit` 的
   applied/未applied/解析失败/目标越界/延迟期间取消/延迟期间断连/并发两个请求。
2. **B6a2**：`changes` 与 `documentChanges` 并存；资源操作三种 kind（含目录目标）；
   AnnotatedTextEdit；非 file scheme；range 畸形；position 字段缺失或非整数；未知 kind；
   `version` 有/无/为 null/**为 0 且文档未打开**；prepareRename 三种形态；
   documentSymbol 两种响应。畸形一律整体失败并有稳定错误码。
3. **B6b1 事务**：多文件成功；中途写失败全量回滚；第三方并发改写进 recoveryRequired；
   版本不符拒绝且零修改；取消在首次写入前零修改；目录 rename/delete 的恢复与预算上限；
   提交后 LSP 回同步的顺序与部分失败；打开文件的 dirty/保存语义——
   **autoSave 关闭时保持 dirty 不保存，autoSave 开启时按 B3b §4.7 的策略保存**
   （第一版只写了前者，与 B3b 自相矛盾）；关闭项目时事务收尾以
   「协调器发出 applied/failed/cancelled 终态信号」为可观测判据，等待上限 5 秒，
   超时记录 recoveryRequired 并放行关闭。
4. **B6b2**：一次 undo 全量恢复、redo 再校验、异步失败后栈项处置——按其独立设计审查。
5. **B6c/B6d Go 矩阵**：Rename 符号/文件/包，Move/Copy/Safe Delete，Extract 五项，
   Inline 三项，Change Signature——每项独立多文件 fixture，操作前后 `go build` /
   `go test` 通过，取消零改动，版本冲突拒绝。不通过的条目留在表中标未完成。
6. **不回归**：completion、formatting、单文件 code action 切到协调器后，
   为这三条路径**新增行为快照测试**（当前没有基线，"行为不变"无法证伪）；
   Search 侧真正会变的是 open document 的 save/dirty 语义
   （现在 `AppModel+SearchModule.swift:213` 明确调 `saveDocument`，正是 B3b P1 列的缺陷），
   该项列为可判定条目。注意 B3b 实际已验收的只有 B3b1a（Rust matcher/Unicode/索引候选），
   与事务无关，不能拿它当事务回归基线。

## 9. 校验与提交

每批：独立 agent 审方案 → 实施 → 下列检查 → 真实 ARM64 应用逐项点击验收并截图 →
独立代码审查 → 分批 commit，不 push。

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
"Rust Core is unavailable" 失败，那是调用方式问题而非回归。

## 10. 官方依据

- [LSP 3.17 WorkspaceEdit / ResourceOperation / ChangeAnnotation](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspaceEdit)
- [LSP 3.17 workspace/applyEdit](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_applyEdit)
- [LSP 3.17 textDocument/prepareRename](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_prepareRename)
- [LSP 3.17 textDocument/selectionRange](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_selectionRange)
- [LSP 3.17 CodeActionKind](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#codeActionKind)
- [GoLand Refactoring](https://www.jetbrains.com/help/go/refactoring-source-code.html)

规范条款需在实施前逐条对照实现；文档引用不是对齐的完成证明。
本文所有「实测」结论来自本机 gopls v0.20.0，换 server 版本需重新验证。
