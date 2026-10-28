# L0–L2：语法引擎、增量协议与三语言高亮

状态：第二版；2026-09-08 已按首轮 6 项 P1、3 项 P2 修订并完成本轮复核，
**方案通过，未实施**，见 [审查闭环](#l0-l2-plan-review)。首轮源码基线 `e14309d4`，
文档验证时 HEAD 为 `7e0887a1`；期间 Go 工作台改动不属于本轮审查。
本文负责逐文件清单、分批边界与验证门槛；公共语义以
[语法与插件总方案](syntax-and-completion.md) 为准，wire 以
[Rust Core API 待实现章节](../../shared/contracts/rust-core-api.md#planned-syntax-v1) 为准。
修改公共决策时同步两文，不保留相互冲突的规则。

L3–L8 后续细案仍需逐批细化和审查，本轮不宣称这些批次已经有独立细案或已经交付。
2026-09-21 [体验对齐复核](goland-parity-implementation.md#experience-parity-review-2026-09-21)
把原 L4 拆为 L4a（LSP 直通能力，不依赖本文交付物）与 L4b（消费文档 Tree 与 query 槽位），
见 [拆分依据](syntax-and-completion.md#l4a-split)。本文 L0–L2 的范围、依赖与验收门槛不变。

## 1. 交付范围

| 交付 | 批次 |
| --- | --- |
| 候选稳定身份、真实插入格式、可恢复失败回退、取消/版本保护 | L0 |
| syntax v1、accepted/parsed 双版本、增量 ledger、坐标、缓存与预算 | L1 |
| Go / Rust / Python grammar/query、离线高亮与主题投影 | L2 |
| 自动 popup、文档/排序/snippet 会话 | L3，后续 |
| LSP 直通的 signature/inlay/semantic tokens、documentSymbol→Structure、documentHighlight | L4a，不依赖本文交付物 |
| locals/outline 与离线 hover/symbols/folding | L4b，后续 |
| 安装资源包、常规格式、新 grammar worker、语法编辑行为 | L5–L8，后续 |

L2 的可观察终点：不启动语言服务器，Go/Rust/Python 打开即有语法着色，连续编辑不会留下旧色，
切主题不重新解析。补全界面仍为现有手动 NSMenu；L0 会修其回调、身份及接受路径，
不把“不更换外观”理解为禁止接线改动。完整 GoLand 风格补全体验仍由 L3 交付；参数提示、
类型提示与 Structure 由 L4a 独立交付，不排在本文三批之后，其余语法产物消费留 L4b。

## 2. 现状与可复用边界

以下源码基线为 `e14309d4`；既往测试不计作本轮验收。

| 事实 | 接入方式 |
| --- | --- |
| Rust 现有 Tree-sitter 0.25（lock 为 0.25.10）与 Java grammar，无三语言 grammar | L1 用 Java grammar 验证新运行时；L2 添加三语言资源 |
| Java walker 每次新建 Parser 整文 parse，无通用文档树缓存 | 保留现有 Java 产品路径，不作为三语言迁移前置 |
| provider、manager、AppModel 有 label 去重，completion payload 丢失插入格式 | L0 覆盖完整往返链路，不能只改 DTO |
| `SyntaxHighlighter.applyJavaSemanticHighlights` 只 add foreground，空列表直接返回 | 复用 role/palette 映射；新投影另接 coveredRanges，不能原样复用叠加语义 |
| `CodeEditorView.highlight` 仍调旧 adapter | L2 加唯一来源切换，不能再追加第二遍绘制 |
| `RustCoreBridge` 同步；dispatcher 有后置取消检查，Scope 为线程局部 | L1 明确平台执行器、domain-finalized 响应及独立任务 token |
| 语言模块仅依赖 ModuleAPI/CoreContracts，不依赖 Lithe executable | port/DTO 放 CoreContracts，native adapter 留宿主 |
| manifest/API 当前为 1，无正式 languageResources/worker 支持 | L1 内部资源身份为后续 L5/L7 预留，不能伪装为已可安装包 |

保护现有 `Config/Env/INI/JSON/Properties/TOML/XML/YAMLSyntaxHighlightingAdapter.swift`
八个配置 adapter；L0–L2 不改这些文件。公共高亮入口修改后仍须运行其回归用例。
不能把公共入口 `SyntaxHighlighter.swift` 也列为“禁止修改文件”。

## 3. 分批依赖与提交边界

| 子批 | 交付 | 硬前置 | 验证边界 |
| --- | --- | --- | --- |
| L0 | 完整补全身份/格式/故障/版本保护 | B6b2（含 B6b1 同步事务） | Rust/Swift 往返、原生接受与一次 Undo |
| L1a | DTO、坐标、资源身份、Java 单语言 parser 原型 | 无功能前置 | 纯契约/坐标/原型，不注册半成品 syntax 命令 |
| L1b | 状态机、ledger、任务/取消/waiter、全部 L1 命令 | L1a | 真实 dispatcher 的文本确认与恢复 |
| L1c | 平台执行器、文档事件、模块生命周期 | L1b；文档接线在 L0 后 | 原生输入/Undo/IME/关闭，尚无新高亮 |
| L2a | 固定三语言 grammar/query、许可、语义白名单 | L1a | 编译与实际 query 语义负例 |
| L2b | highlights 命令、capture/role/覆盖范围 | L1b、L2a | 真桥接 query/waiter、资源隔离 |
| L2c | 单一高亮来源、视口/主题/IME 投影 | L1c、L2b | 完整 ARM64 GUI/性能验收 |

默认实施顺序：B6b2 完成 → L0 → L1a → L1b → L1c → L2a → L2b → L2c。
L0/L1 都会修改 dispatcher、command enum、RustCoreBridge、契约和文档接线，**不并发修改**。
L2a 资源准备有独立空间，但不以此宣称整个 L0/L1 无文件交叠。
L2c 与 B7b2 共改 CodeEditorView，也须串行。每个子批可独立提交，未到公开接线阶段不广告能力。

## 4. L0：完整补全链路

### 4.1 已定契约

执行总方案 [候选身份 v1](syntax-and-completion.md#completion-identity-v1)：

- Rust 是唯一规范编码/摘要实现，使用现有 sha2；批量 `lsp.completionIdentities` 让 Swift
  关键字、本地符号和 LSP 候选消费同一规则，Swift 不再另写摘要。
- 身份覆盖 provider、label/签名、实际主范围与文本、插入格式、additional edits、原始 resolve data；
  排序/过滤/文档展示字段不进入身份。缺主范围先捕获 fallbackRange，不能接受时再取当前光标。
- 所有消费者按 ID 去重，同名不同 import/范围仍可选。resolve 固定原 provider/session、data、
  请求快照和选中 ID；碰撞不得覆盖菜单字典。
- L0 `snippetSupport: false`；缺省/null 格式视为 plain(1)，普通 `$1`/`${name}` 原样插入。
  返回 snippet(2)、未知 edit 形状或非法附加 edit 时拒绝候选并保留结构化诊断，不损坏模板。
- 可恢复 provider missing/notReady/timeout/crash/rejected 才 fallback；空成功继续路由。
  用户取消、关闭、stale 结束会话，不通知刷屏、不重新弹菜单。
- 请求、provider 返回、resolve、菜单展示、接受前均核对 session/document/generation/revision、
  provider epoch、光标范围。输入/IME/切文件/Esc 立即失效；失败时应用原 item 也要重验。
- 主 edit 与附加 edits 经 B6b1 同步事务一次校验/应用，B6b2 一次 Undo。只处理当前已打开文档的
  completion edits，不再调用将被 B6 删除的旧 workspace edit 实现。

### 4.2 逐文件清单

| 文件（相对仓库根） | 工作 |
| --- | --- |
| `rust/lithe-core/src/lsp/lightweight/completion_identity.rs`（新）及该目录 mod | 固定字段编码、SHA-256、批量身份校验 |
| `rust/lithe-core/src/lsp/lightweight/symbols.rs` | 与标准化候选输入对齐，不提前 label 去掉需保留的候选 |
| `rust/lithe-core/src/lsp/interface/client.rs` | snippet 能力关闭、格式与原始 data/edits 归一化、非法 item 整项拒绝 |
| `rust/lithe-core/src/lsp/languages/swift.rs` | resolve 往返字段核对，避免适配层丢失格式/data |
| `rust/lithe-core/src/protocol/command.rs`、`runtime/dispatcher.rs` | 注册 lsp.completionIdentities |
| `macos/Sources/LitheCoreContracts/Language/LanguageToolingContracts.swift` | identity/provider/format DTO、可取消请求上下文与稳定失败分类 |
| 同目录 `BuiltinLanguageFeatureCore.swift`、`LanguageServerRuntimeContracts.swift` | 批量身份端口及保留 error code/stage |
| `macos/Sources/LitheLanguageIntelligenceModule/Providers/LanguageFeatureProvider.swift` | 去除 label 合并，携带来源和捕获范围 |
| 同模块 `Services/LanguageToolingSessionManager.swift` | 三类路由恢复规则、最终统一身份、原 provider resolve |
| 同模块 `Runtime/LanguageServerSession.swift` | CompletionItemPayload 格式、typed error、请求取消句柄和终态单完成 |
| 同模块 `Application/CompletionRequestState.swift`（新） | 轻量手动会话身份/取消；不是 L3 popup 状态机 |
| `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift`、`RustLanguageServerRuntimeAdapter.swift` | 批量身份调用、resolve 编码、协议桥接与取消句柄 |
| `macos/Sources/Lithe/Models/AppModel/AppModel+Development.swift` | 移除末端 label 过滤，请求/resolve/接受守卫，调用 B6 事务 |
| `macos/Sources/Lithe/Views/Editor/CodeEditorView.swift` | 菜单按 ID 取同一候选，绑定捕获范围、dismiss/IME/光标失效 |
| `macos/Sources/Lithe/Models/Editor/EditorDocument.swift` 与 Application 文档事件桥 | 复用 lifecycle revision，提供同一文档 generation/失效事件供 L1 接入 |
| `shared/contracts/rust-core-api.md`、`docs/architecture/language-support.md` | 实施时把拟议操作/真实故障回退转为当前事实 |
| `shared/fixtures/language-completion/`（新） | 签名/导入/范围/排序/null/Unicode/resolve 往返与普通美元字符 |

身份批量最多 200 项/1 MiB，按既有 provider 排序截取后归一化；超限明确诊断，不能回到 label
去重。保留服务关闭后的 builtin 能力，包禁用不能启动其拥有的 LSP 进程。

## 5. L1：文档与解析运行时

### 5.1 Rust 所有权与原型

新目录 `rust/lithe-core/src/languages/syntax/`：

| 模块 | 职责 |
| --- | --- |
| `mod.rs` | 模块文档、re-export，不堆积实现 |
| `contracts.rs` | syntax typed 请求/状态/失败 context 与输出，依赖 protocol，不反向 import dispatcher |
| `registry.rs` | 已校验资源目录及 `(resourceRevision, queryKind)` cache |
| `coordinates.rs` | UTF-8 byte / UTF-16 半开范围 / 行索引，拒绝 surrogate 切分、负数和溢出 |
| `document.rs` | accepted/parsed 双版本与短临界区的原子提交、幂等 ack |
| `edits.rs` | 逐项以前一 edit 后文本解释的 ledger，私有 Tree clone 上 InputEdit |
| `runtime.rs` | 2 worker 调度、每文档一跑一待、waiter/操作登记与清理 |
| `task.rs` | 独立 Arc token、单调 deadline、完成信号；不借用 TLS Scope |
| `budget.rs` | 总方案预算常量、队列/快照/结果边界与降级 |

L1a 使用已有 Java grammar 跑新 parser 原型和增量/全量等价；不把 Java walker 产品路径迁入。
L1b 才注册 `syntax.open/change/resync/close/closeWorkspace/cancel/retry`，同步修改
`protocol/command.rs`、`protocol/error.rs`、`runtime/dispatcher.rs` 与 API/fixture。
L2b 再注册 highlights。L1 的 waiter 内部测试先用原型查询，L2b 补真实公开 highlights 入口。

### 5.2 文本确认、错误与取消

以总方案 [取消边界](syntax-and-completion.md#syntax-cancellation-boundary) 和
[五个 wire 示例](../../shared/contracts/rust-core-api.md#planned-syntax-v1) 为唯一语义：

1. change 验证完成后原子提交文本/行索引/accepted 版本/ledger，立即返回 applied，不等 parse。
   syntax dispatcher 分支自行完成 deadline 判定，返回后不得被 generic 取消覆盖；其他命令不变。
2. ack 使用原始 operationID 幂等缓存 32 项；同 ID 不同 payload 返回 operationConflict。
   同版本 open/resync 还比对语言/资源/文本 digest，不允许同版本替换内容。
3. `CoreError.details` 继续字符串；新增可选 `error.context` JSON，经 typed SyntaxFailureContext
   生成和消费。已有 snake_case error 不变，新增 syntax 错误显式 wire rename。
   缺 context/解码失败视为未确认，不能推断 notApplied。
4. 文本取消在提交前得到 notApplied；提交后返回原 applied ack。后台 parse 另有 parseOperationID，
   用 syntax.cancel(targetKind: parse) 取消，不能在 change 返回时丢掉其 token。
   取消早于 text/query 登记时保留有界 early-cancel 标记；不假定同步 FFI 有登记回调。
5. query 使用有界 waiter；单视图取消只释放该 waiter，parse 终态/超时唤醒所有依赖者。
   Retry 使用 syntax.retry，再发一次查询；滚动不自动重启已超时版本。
6. ledger 超过 128 项/256 KiB 丢旧 Tree，从 accepted 快照全量 parse；传输待办超限/状态未知
   才一次 resync。撤销旧 generation/连接前不与未知在途提交并发恢复。
7. 旧任务的 generation/resource/parseOperationID/accepted version 不全匹配就只释放资源。
   close 撤销身份后不能被旧 open/resync/parse 复活；新资源显式新 generation。
8. 文档目录与重缓存分开，Tree 被淘汰可从保留文本重建；文本也被淘汰则一次快照恢复。
   目录保留 accepted digest/版本和关闭高水位，不把缓存缺失误作未打开的新文档。

对 `cancellation.rs`/`runtime/ffi.rs` 进行兼容性检查，既有 C ABI 保持；
所有 syntax 取消走 typed 命令，无须把后台 parse 注册成同步 TLS operation。
执行真实 `execute_json` 的提交边界 gate 测试，不能只调用 document helper 得出桥接正确结论。

### 5.3 Swift 接线与资源所有者

| 路径 | 工作 |
| --- | --- |
| `macos/Sources/LitheCoreContracts/Language/SyntaxDocumentContracts.swift`（新） | 请求/确认/失败/资源/视口 DTO，复用文档身份，不含 AppKit |
| 同目录 `SyntaxDocumentPort.swift`（新） | async 文档/查询/取消/重试窄端口，可跨 target 注入 |
| `macos/Sources/LitheLanguageIntelligenceModule/Application/SyntaxDocumentFeatureModel.swift`（新） | 每文档会话、一个未确认文本事务、合并待办、恢复、视图 waiter |
| 同模块 `Module/LanguageIntelligenceFeatureGraph.swift` | syntax 文档/任务纳入 isActive、prepareForSleep、stop，不能只看 LSP |
| `macos/Sources/Lithe/Platform/MacOS/Language/MacSyntaxDocumentAdapter.swift`（新） | typed bridge、4 query worker/64 pending、独立有界文本与控制通道 |
| `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift` | 注入 adapter，注册模块资源/租约，关闭时有界收回 |
| `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift` | typed 命令、error.context 保真；保留同步底层，不在主线程等待 |
| `macos/Sources/Lithe/Models/Editor/EditorDocument.swift` | 所有文本写入的已提交事件，复用 lifecycleState.revision |
| `macos/Sources/Lithe/Application/Features/SyntaxDocumentEventBridge.swift`（新） | 把原生文档事件转为共享值，连接模块会话/资源所有者 |
| `macos/Sources/Lithe/Views/Editor/CodeEditorView.swift` | 提供准确编辑范围与 replacement、视图 attach/detach、marked range；不调 C ABI |
| AppModel 文档打开/关闭、reload、项目休眠/销毁入口与 B6 文档事务提交点 | 全部通过同一事件桥，不能仅监听 textDidChange |

具体规则：

- `EditorDocument.replaceText/applyLiveEditorText/reloadFromDisk`、B6 completion/format/rename
  事务、Undo/Redo、整文替换均在文本和 revision 提交后发一次事件；有可信 delta 时送顺序 edits，
  未知 delta 时送一次完整快照。属性变化不产生文本版本。reload 不能继续绕过统一事件。
- 以文档模型为所有者，一个文档会话供多个视图共享；视图只拥有 query 订阅。窗口合并/拆分转移
  视图引用，最后一个文档所有者关闭才 close。项目休眠释放 syntax cache/任务，不丢编辑文本；
  唤醒新 generation open，项目重开新 sessionID。
- query/control 等待在平台原生工作线程；Swift async 只等待 continuation，所有终态只恢复一次。
  排队、开始、取消用原子门控；满队列返回显式预算失败，不 spawn 无限 detached task。
- 复用现有输入不逐字符唤醒 SwiftUI 的策略，尺寸/视口/高亮结果留编辑器局部；
  不由新 feature model 每次输入发布整个 AppModel。关项目后不能有 waiter/任务/lease。
- 资源关联变更先撤销旧 generation，再以当前快照打开新语言/资源；同 digest 回滚也用新 generation。

### 5.4 L1c 原生验收

L1c 尚无新着色，但已进入高频编辑路径，**必须**验证真实键入、Undo/Redo、跨行替换、
中文 IME、外部 reload、格式化后继续输入、双视图关闭/转移、请求中关闭项目。
对照原生文本、Core accepted 快照、revision 与光标/选区；无全页逐字符重绘、无残留任务。
L1a/b 用 fixture；不能以“无可见变化”删除 L1c 的交互门槛。

## 6. L2：三语言高亮与可扩展资源

### 6.1 资源准入

grammar/query 成对固定版本与来源 revision；L2a 选定兼容 Tree-sitter 0.25.10 的
Go/Rust/Python crate，写 Cargo.lock。grammar crate 与每份 highlights.scm **分别**
核对许可证、revision、修改内容与 NOTICE，不推定来源同名便同许可。
资源放 `rust/lithe-core/resources/languages/{go,rust,python}/`。

执行总方案 [query 白名单](syntax-and-completion.md#syntax-query-validation)：
L2 仅支持列出的 text predicates，拒绝所有 general/property predicates/settings。
编译成功但包含未实现 #is?/#set! 也拒绝整份资源；未知 capture 才能诊断后忽略。
不得通过删除有意义过滤条件来让 query 编译通过，改写资源须有语义对照语料。
失败保留上一可用集/adapter，按资源身份给一次诊断，不 panic。

内部资源身份先按 [ResolvedSyntaxResourcesV1](syntax-and-completion.md#resolved-syntax-resources)
固定；缓存键为 (resourceRevision, queryKind)，八槽位从 L1 起明确，L2 只消费 highlights。
L4b 消费 locals/outline，L5 才发布安装 schema；不同 owner/grammar 内容的相同包内版本不会共用缓存。
资源的 content digest 与启用 epoch 分离，禁用/回滚隔离旧结果。

### 6.2 逐文件与投影

| 文件 | 工作 |
| --- | --- |
| `rust/lithe-core/Cargo.toml`、`rust/Cargo.lock` | 固定三个 grammar，验证 parser/scanner ABI |
| `rust/lithe-core/resources/languages/{go,rust,python}/highlights.scm` 与 NOTICE | query 来源、语义对照与许可证 |
| `languages/syntax/registry.rs` | 已校验 predicate/property 白名单、资源/槽位 cache |
| `languages/syntax/highlight.rs`（新） | 视口 query、captures 全序裁决、不重叠 spans、当前版本 coveredRanges |
| `languages/syntax/roles.rs`（新） | 现有 20 wire role 的显式映射/优先级，无随意猜测 |
| `protocol/command.rs`、`runtime/dispatcher.rs`、API 与 Swift bridge/DTO | 注册 highlights，真实 waiter/失败 context 往返 |
| `macos/Sources/Lithe/Views/Editor/SyntaxHighlighting/SyntaxHighlighter.swift` | 新增 `applySyntaxHighlights(snapshot:to:formatID:isDark:)`，复用 palette，按覆盖范围清理自身 foreground |
| `macos/Sources/Lithe/Views/Editor/CodeEditorView.swift` | syntax/fallback 单一来源，视口请求、完整身份守卫、局部属性合并 |
| `shared/fixtures/syntax/`（新） | capture-role、覆盖/清色、资源隔离、三语言正确性 |

Java 的旧函数可调用同一 role→palette 小辅助函数；不能把缺乏 coveredRanges 的 Java 旧结果
硬当成可清整文颜色的新 snapshot，不更换其分析方式。

### 6.3 正确性与性能规则

- 整文上下文解析，视口只限制 query/绘制；文本 edit、Tree changed ranges、祖先和后续注入依赖
  一起确定失效范围，旧范围经 ledger 转成当前 UTF-16 坐标。无法缩小时保守扩大当前视口。
- spans 重叠按显式资源/capture/depth/pattern/capture index 全序切分。空列表也清 coveredRanges，
  禁止用旧 add-only 函数留下颜色；不通过 setAttributes 擦掉诊断/搜索/选择装饰。
- syntax loading/ready 不运行旧正则基础高亮；资源不可用/终态失败才切 fallback，新编辑或 Retry
  再尝试 syntax。避免“每次先正则再 Tree-sitter”的双遍绘制。
- 返回时比对完整 session/document/generation/version/language/resource/connection/view request
  身份；主题只重映射当前 palette，不 parse、不启动 LSP。没有缓存的视口可 query 已有 Tree。
- marked range 相交属性延迟到 IME 结束，重验版本后应用；不改文本、焦点、undo 或光标布局。
  查询/滚动调度复用现有合并机制，不在父页按高频事件重建。

## 7. 实施验证命令与预算

以下是**实施阶段**的要求，不代表本轮文档修订已运行产品检查。使用 Swift 6.2 工具链，
不要把某台机器的缓存路径当成构建前置。ARM64 验收示例：

```bash
swift --version
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./scripts/verify-rust-core-comments.sh
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core
./scripts/verify-rust-core.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-module-boundaries.sh
swift build --target LitheLanguageIntelligenceModule
RUST_SYNTAX_LIBRARY="$(./scripts/build-rust-core.sh --debug --target aarch64-apple-darwin)"
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --report .artifacts/test-stability/macos-syntax.json -- -Xlinker -force_load -Xlinker "$RUST_SYNTAX_LIBRARY"
git diff --check
```

timing harness 会调用 test-macos.sh；每个新/改用例必须出现在 HTML/JUnit，不能用现有
ProjectMetadata 的计时结果代替 syntax/completion lane。迭代先用 --filter 聚焦，交付跑完整受影响
套件。gate 两端有本地 deadline，断言失败也 defer/teardown 释放 gate、取消/等待任务；
只有退出信号已到才 join。真实服务/SDK 验收另列集成，不进入确定性单测。

| 子批 | 最低验证 |
| --- | --- |
| L0 | 身份/格式 Rust timing，Swift 完整 timing + 真 Core、共享契约/边界；服务停启与菜单接受/Undo |
| L1a/b | Rust comments/timing/Core/契约；原型等价，dispatcher 取消/确认/恢复 |
| L1c | 加模块独立构建、Swift 完整 timing、§5.4 原生交互/生命周期 |
| L2a | 三 grammar 编译、query 编译及语义白名单负例、NOTICE |
| L2b | 加真正 highlights 的 Rust/Swift 往返与 waiter timing、role/资源隔离 fixture |
| L2c | 全套、真实 ARM64 包与 §8.4 GUI/性能 |

每个生产 Rust 模块写英文 `//!`，导出 API/语义字段写 `///`，unsafe 有 Safety；
comments gate 在慢检查前。性能记录机器/构建模式、冷/热 p50/p95/max、RSS、cache、
包体和冷编译增量；普通编辑目标 p95 20 ms，解析/query 100 ms、文件 4/8 MiB 分级等
以总方案 §4.3/§9 为准，超限降级且能取消，不能只抬预算宣称通过。

## 8. 验收矩阵

### 8.1 L0

| 场景 | 判据 |
| --- | --- |
| 同 label 不同签名/import/范围 | 全部到菜单，各自提交正确 edits |
| sortText 变化、null/空串、Unicode/data 键顺序 | 排序不改 ID；同规范输入同 ID，不误合并不同输入 |
| provider throw/回调失败/超时/未就绪 | 结构化诊断后 builtin 可用；无每次通知 |
| 用户取消、关闭、切文件、光标/IME/文本变更 | 无 fallback 复活、旧菜单或旧 resolve edit |
| plain 格式、缺省格式、普通美元字符 | 原样插入；snippet/不支持 edit 拒绝而非损坏 |
| resolve 原 provider、data、附加 edit | 往返字段保真、一次事务、Undo 一次恢复 |
| request→回包→resolve→提交的 gate | 每个边界都能注入 stale，不仅测最终 helper |

### 8.2 L1

| 场景 | 判据 |
| --- | --- |
| A→B→C 传输合并/parse 落后 | 与逐次应用、完整解析等价，不丢中间 edits |
| 提交前后取消（真实 dispatcher） | 前 notApplied A，后 applied B，B→C 可继续 |
| ack 后取消 parse | 独立 token 生效、线程终止；文本 B 保留 |
| 旧 parse 晚到、cancel/retry | 不覆盖新任务；重建与全量等价 |
| ack 重试/同 ID 不同 payload/同版本不同文本 | 不重复应用，冲突明确拒绝 |
| resync/close 两种顺序、传输未知 | 不复活文档，一次恢复；旧 generation 无提交权 |
| 一次 query + gate、超时 + 注入时钟 | 静止输入也收到结果；超时释放全部 waiter，不自动重发 |
| UTF-8/16、CRLF/BOM/emoji、非法边界 | 转换与坐标准确，整笔非法事务不应用 |
| 超限 ledger/队列/cache | ledger 直接重建；传输/文本淘汰才一次 resync；不清 UI 文本 |
| 文档 reload/格式化/Undo/Redo、双视图/项目关闭 | 同一 revision 流，视图转移不 close，关闭无 task/waiter/lease |
| error.context 与旧 error.details | 真 Swift 解码保留状态，旧失败兼容；未知 context 不猜 notApplied |

文本 fixture 同时断言 acceptedTextVersion、parsedVersion、disposition 及 UI 可用结果版本；
query/control 的 disposition 为 null，另核对关联文本 ack，不把其终态当作文本提交结论。

### 8.3 L2

| 场景 | 判据 |
| --- | --- |
| Go 泛型、raw string、iota、struct tag | 正确 role |
| Rust lifetime、raw string、嵌套块注释、宏 | 正确 role |
| Python decorator、嵌套 f-string、三引号 | 正确 role |
| 重叠 captures、树形不变文本修改 | span 不相交且旧颜色更新 |
| 删除 token 后空结果、闭合注释 | coveredRanges 清旧前景色 |
| 跨视口/迟到结果/语言或资源切换 | 无空白残影，无旧身份应用 |
| theme/IME/诊断/搜索/选择 | theme parse 计数不增；IME 与其他属性保留 |
| 未知 predicate/property 编译成功 | 资源拒绝且有诊断，不静默扩大匹配 |
| 同 grammar 两个 owner/资源内容、更新/禁用/回滚 | cache 与结果身份隔离，回滚旧任务不复活 |
| 单一来源与配置/Java 回归 | 没有双遍全量着色，原有路径行为不回退 |

### 8.4 真实 ARM64 GUI（L2c）

禁用 gopls、rust-analyzer、Python server，分别打开真实三语言文件；
连续键入 200 字符、快速滚动、补闭合注释/删除 token、明暗切换、中文 IME、
撤销、请求中关文件/项目、双视图转移。截图使用相同样例/字体/窗口尺寸，
Go/Rust/Python 分别对照 GoLand/RustRover/PyCharm，性能同时记录。
测试启动的 Lithe、worker/helper 与临时包全部清理，确认无残留；不关闭用户原有应用实例。

## 9. 与其他批次的接口

| 对方 | 定案 |
| --- | --- |
| B6 | L0 依赖 B6b2，复用事务快路径/Undo；L1 接同一文档变更事件，不另建计数器/事务 |
| B7b | L2c 编辑器接线串行；L8 runnables 接其 DocumentRunnableProviding，不重做 gutter |
| L4b | 复用文档 Tree/cache，locals/outline 槽位有明确归属 |
| L4a | 不依赖本文交付物，仅扩展 `client.rs` 方法白名单与编辑器装饰；与 L2c 共改 `CodeEditorView.swift`，两批串行 |
| B5/L5 | 八槽位及内部资源 identity 已定；manifest v2/资源 schema 1 实施时适配，旧 v1 仍显式兼容 |
| L6 | 注入/常规格式/formatter 各有真实语料，配置 adapter 不因“全 Tree-sitter”删除 |
| L7 | 新 grammar 进独立受信任 worker；复用 syntax 身份、context/cancel/retry 和 conformance，不复制运行时 |

## 10. 完成边界

本次修订不实现补全 popup、不迁移 Java、不移除配置 adapter、不引入 WASM/WASI、
不复制 Zed 代码。资源 schema 声明不等于插件安装完成；L7 仍须真实 Lua 安装、离线能力、
StyLua、授权/升级/禁用/卸载与进程清理。
预算是待实测初值，方案通过不等于代码、性能或产品验收通过；全范围尚未完成，不加 -done。

<a id="l0-l2-plan-review"></a>
## 11. 2026-09-08 审查闭环：第二版方案通过

基线：`e14309d4`；首轮针对未提交细案发现 6 项 P1、3 项 P2，结论不放行。
第二版修订正文、语言总方案和 Rust Core API 待实现章节；下表保留历史问题和具体闭环位置。
2026-09-06 的独立设计基线复核是历史记录，本轮不将其当作第二版或产品验收证据。

| 编号 | 首轮问题与影响 | 第二版修订及复核入口 |
| --- | --- | --- |
| R1 / P1 | 候选摘要遗漏 edits/provider，AppModel label 去重仍会丢项或错插 | §4.1/§4.2：Rust 唯一批量身份、全消费者清单、原 provider resolve、同名菜单实际提交；[总方案身份](syntax-and-completion.md#completion-identity-v1) |
| R2 / P1 | snippet 声明/格式、取消/stale/接受快照没有端到端接线 | §4：真实 false 能力、plain 默认、unsupported 明确拒绝、typed issues/error、每阶段 guard；硬前置 B6b2 同一事务；§8.1 原生接受/Undo |
| R3 / P1 | dispatcher 会覆盖 applied，TLS Scope 不覆盖后台 parse | §5.2：syntax 分流、任务独立 token、cancel/retry、注册前取消；[总方案取消边界](syntax-and-completion.md#syntax-cancellation-boundary)；真 dispatcher gate |
| R4 / P1 | details 对象与现有 Rust/Swift 字符串 envelope 不兼容 | §5.2/§8.2：保留 details，增加可选 context；[五个待实现 JSON 示例](../../shared/contracts/rust-core-api.md#planned-syntax-v1) 覆盖 applied/非法范围/resync/取消/query 超时；缺 context 不猜提交 |
| R5 / P1 | port 位于可执行 target，模块不可依赖；执行器/生命周期缺项 | §5.3：CoreContracts port、平台 adapter/注入、独立受限 executor、统一文档事件与双视图/休眠/关闭所有权 |
| R6 / P1 | add-only Java 投影不能清空结果颜色，旧 adapter 会双重绘制 | §6.2/§6.3：snapshot coveredRanges、foreground 所有权、完整身份、唯一来源/IME；§8.3 清色/主题/装饰共存 |
| R7 / P2 | Query::new 接受未知 predicates/properties，编译不能证明语义 | §6.1：固定 text 白名单、拒绝 general/property、负例与语料；[总方案资源准入](syntax-and-completion.md#syntax-query-validation) |
| R8 / P2 | revision 无包命名空间，outline 在槽位清单缺失 | §6.1/§9：owner/grammar/content digest、八槽位与 L4b outline、启用 epoch、新 generation、回滚隔离；[资源身份](syntax-and-completion.md#resolved-syntax-resources) |
| R9 / P2 | 未要求 syntax timing，取消了 L1c 原生验收，原型无 grammar | §5.1/§5.4/§7/§8：Java 原型、Rust/Swift HTML/JUnit、gate deadline/清理、真实 Core、L1c 输入/Undo/IME 验收 |

复核仍以当前源码的缺口为依据：
[dispatcher](../../rust/lithe-core/src/runtime/dispatcher.rs)、
[cancellation](../../rust/lithe-core/src/protocol/cancellation.rs)、
[CoreError](../../rust/lithe-core/src/protocol/error.rs)、
[Swift bridge](../../macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift)、
[completion 应用](../../macos/Sources/Lithe/Models/AppModel/AppModel+Development.swift)、
[Package target 依赖](../../Package.swift)、
[高亮入口](../../macos/Sources/Lithe/Views/Editor/SyntaxHighlighting/SyntaxHighlighter.swift)。
Tree-sitter predicate 行为以 Cargo 缓存的 0.25.10 binding 为依据，原始摘录在
`.artifacts/syntax-l0-l2-review/2026-09-08/source-evidence.txt`。

第二遍复核另补齐四个接线边界：取消早于请求登记的标记、query/control 的 null disposition、
纯数据包 nullable ownerModuleID、worker 自身 ABI 与授权后 query 预编译。
这些属于第二版具体语义修订，没有用缩小 L0–L2 目标消除首轮问题。

**本轮复核通过：R1–R9 在方案层全部闭环，无未解决的 P1/P2。** 复核逐项对照源码、调用链、
模块依赖和 wire 状态推演；这是本轮修订后的方案复核，不冒称新增独立审查者或已通过实现验收。
新增 cancel/retry/context 的实施、真实 Rust/Swift fixture 执行、三语言版本/许可落地、性能与 GUI
仍须按 §7/§8 完成；L0 的 B6b2 硬依赖也保留。

实际文档检查：四份涉及文档的 79 处本地链接/锚点通过；5 个 syntax JSON 示例可解析且确认字段
自洽，资源示例八槽位一致；实施命令经 `zsh -n` 语法检查；范围内 `git diff HEAD --check` 通过。
这些检查没有调用拟议 API，不计作 Rust/Swift 产品测试。本轮未修改生产/测试实现、未运行 GUI，
未启动 Lithe/LSP/worker。工作区并行 Go 元数据/检测器/工作台改动不在本轮范围。
首轮记录与第二版输入备份、复核记录和检查日志位于
`.artifacts/syntax-l0-l2-review/2026-09-08/revision-2/`。上述记录属于历史方案复核；
2026-09-08 提交前审查确认细案、总方案和待实现 wire 需要一并保留。文档仍保持未实施，
不加 `-done`；本次文档提交不代表产品能力交付。
