# Lithe 性能优化、老代码审查闭环与演进方案

> **最后同步**：2026-11-27（分支 `feat/t3code-ai-agent`，整合全仓源码实审 + `2026-11-26-cc-code-review.md` 逐行复核）
> **核心目标**：保持 **轻量、高性能、原生 macOS 界面（AppKit / `NSTextView` + Rust Core）**，零热路径 O(N²)、零 `@MainActor` 阻塞 I/O、零空闲轮询唤醒、零静默数据丢失。
> **配套规范**：详见 [engineering-principles.md](engineering-principles.md)（Rust/Swift 开发原则与闭环验证门禁）与 [goland-parity-implementation.md](goland-parity-implementation.md)（总架构与功能进度）。

---

## 1. 性能基线与已落地优化成果（Done & Verified）

### 1.1 核心实测基线（Apple Silicon / macOS）

| 维度 | 指标 | 实测结果 / 状态 | 来源 / 提交 |
| --- | --- | --- | --- |
| **默认轻量智能模式** | 进程内 Rust Core RSS / LSP 子进程数 | **18.36 MB RSS · 0 个 LSP 子进程**（定义 1.09ms、Hover 0.96ms、签名 0.37ms、2,088 行折叠 0.59ms、补全 2.16ms、跨文件引用 3.35ms） | `dev/aiide` Release C-ABI 实测 |
| **顶部 Tab 切换与大文件编辑** | 切换卡顿 / EOF 全文扫描 / 全量 `ensureLayout` | 已落地 **Warm Tab Pool**（最多 8 个 ≤512 KiB 纯代码文档，切换免重建 `NSTextView`，自动断开 Undo 合并与同步视口）、移除 4 处全文件 `ensureLayout`、修复 4 个语法适配器未缓存尾行扫描至 EOF 缺陷、离线文档符号移出 `@MainActor` | `882543ce`（20k 行 Go 视口高亮测试通过） |
| **Go / Rust / Python 语法与语义高亮** | 单趟词法 + `gopls` 语义层 | 单趟词法增强（Go `//go:` 指令、内建类型/函数、函数与接收者声明、调用、字段、Rust 宏/文档注释、统一暗色 `type=#4ec9b0`）+ `gopls` `ui.semanticTokens: true` + `LanguageSyntaxProfileRegistry.revision` O(1) 增量失效 | `01e709bb`、`882543ce` |
| **AI Agent 流式渲染** | 长回复流式重绘开销 | 原生 SwiftUI 分块 Markdown 渲染（零 `WKWebView`、`Equatable` 块缓存、`SyntaxHighlighter` + 有界 `NSCache`）+ `AIAgentFeatureModel` 40ms 首尾合并流式 delta（结构事件/审批/完成同步冲刷） | `c540921c` |
| **老代码审查第 1 批高收益性能与安全修复（本轮已完成）** | 12 项高风险/热路径卡顿与缺陷 + 4 轮 Codex CLI 复审零阻塞 | Rust 计时测试 **577/577**（`lithe-core` 548 / `lithe-db-sidecar` 19 / `lithe-db-mcp` 4 / `lithe-git-host` 6），macOS Swift 全量套件 **1,741/1,742**（207 suites；唯一失败为 macOS 27.0 beta `hdiutil` >10s 既有超时），全部 10 项静态/边界/合约/官方插件门禁（Go/Rust/Python 3/3）通过 | 本轮提交（`feat/t3code-ai-agent`） |

---

## 2. 本轮已落地的审查修复与性能优化（Done — 2026-11-27）

下表对应 `2026-11-26-cc-code-review.md` 中**风险最高 / 收益比最大 / 改动最克制**的第 1 批条目，全部已在本轮源码修复并补充确定性回归测试：

| 审查编号 | 类别 | 位置 | 根因与影响 | 已落地修复 |
| --- | --- | --- | --- | --- |
| **P1-3** | Rust 安全 / 防闪退 | `rust/lithe-core/src/lsp/interface/process.rs` | `lithe-core` 作为静态库无 Rust `main()` 的 SIGPIPE 屏蔽，`gopls`/`rust-analyzer` 崩溃瞬间写入会直接杀掉整个 Lithe | macOS `spawn` 后对 `ChildStdin` 设置 `libc::fcntl(fd, F_SETNOSIGPIPE, 1)`，写入失败转为 `EPIPE` 走正常 `transportFailed` 恢复路径 |
| **P2-35** | Rust FFI 安全 | `rust/lithe-core/src/runtime/ffi.rs` | `extern "C"` 边界无 `catch_unwind`，任何 Rust panic 跨越 C ABI 都会直接中止宿主进程 | 所有 FFI 入口包一层 `catch_unwind(AssertUnwindSafe(...))` 返回结构化 `ErrorCode::Unknown` JSON / 安全哨兵 |
| **P1-25** | Rust 性能 / 健壮性 | `rust/lithe-core/src/execution/configuration.rs` | `project_inputs` / `project_manifest_paths` / `main_class_exists` 用 `path.is_dir()` 跟随符号链接（自环或 Bazel `bazel-*` 引发指数扫描），遇到单个不可读目录即整命令失败 | 改用 `entry.file_type()` 禁止目录软链遍历、保留指向常规文件的软链 manifest 哈希、跳过不可读目录；`project_inputs` 流式执行 20,000 项扫描预算并在超限时持久化 `incomplete:entry-budget-exceeded` 哨兵直至重新生成（永不发布残缺指纹）；补充自环软链、软链 manifest 与预算超限回归测试 |
| **P1-20** | Swift 主线程性能 | `macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift` | 外部批量文件变更（`gofmt -w .`、`cargo fmt`、切分支）在 `@MainActor` 执行 O(n²) 去重与 O(变更数 × 项目文件数) 线性扫描 | `Set<URL>` O(1) 去重，复用 `knownPaths` Set，单趟合并 `fileExists`/`isDirectory` 检查，降为 O(变更数 + 文件数) |
| **P2-15** | Swift 热路径性能 | `macos/Sources/Lithe/Services/Language/LanguageServerTextEditApplicator.swift` | 每次 LSP 格式化/重命名都为每条 TextEdit 重建 `Array(text.utf16)` 并从头扫行（O(k·n)） | 新增单次预计算 `UTF16LineIndex` 行首偏移表，每条 edit O(1) 定位，整体降为 O(n + k log k) |
| **P1-24** | Swift 主线程卡顿 | `macos/Sources/Lithe/Services/Java/ProjectRuntimeService.swift` | `runConfigurationToolchainCandidates()` 无条件在 `@MainActor` 触发同步 `runtimeLocator.discover()`（`java_home -V` + `java -version`），Go/Rust/Python 项目加载或保存运行配置也会被阻塞 | `runConfigurationToolchainCandidates` 仅读取已缓存的 `javaRuntimes.first`（无显式覆盖时不触发主线程同步发现），`javaHomeURL()` 也优先命中缓存，兼顾遗留 Java 集成测试兼容 |
| **P3-23** | 空闲功耗 / CPU | `macos/Sources/Lithe/Services/Monitoring/FrameRateMonitor.swift` + `LitheApp.swift` | `CVDisplayLink` 常驻 60–120Hz 投递且永不停止，App 在后台仍持续唤醒 CPU | `FrameRateMonitor` 新增幂等 `stop()`；在 `LitheApp` 监听 `didResignActiveNotification` 停止、`didBecomeActiveNotification` 恢复 |
| **P1-13 + P2-27** | 常用功能 / 并发 | `macos/Sources/LitheExecutionModule/Services/RunService.swift` | `finishProcess`/`finishModule`/输出回调缺少 `operationID` 守卫，Go/Rust/Python 重启后旧进程退出回调清空新会话引用、端口无法释放、尾部输出串台 | 拆分 `activeOperationID`（生命周期/终止）与 `outputOperationID`（输出缓冲归属，单会话及多模块一致）：Stop 期间保留同步冲刷的尾部输出、配置重扫失败不中断在跑进程回调、重启/清屏/启动失败严格拦截旧会话残留输出与退出码；补充 Combine 事件驱动回归测试 |
| **P1-15** | Git 常用功能 | `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift` | 未打开过 Git Log 或外部切分支后，Commit and Push 读到空的或陈旧的 `currentGitReference` | 提交成功后先 `await refreshGitReferencesForSettings()` 再解析当前分支推送 |
| **P1-5** | Git 数据安全 | `macos/Sources/Lithe/Views/Git/GitChangeSelection.swift` | 同路径存在 staged 删除 + untracked 替换时，右键按 `id` 过滤会同时选中两条，Discard 误删磁盘 `.env` | 未选中的右键目标改为按值匹配 `$0 == clicked`；补充单元测试 |
| **P1-17** | IME 体验 | `macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift` | `MacReturnKeyMonitor` 未检查 `hasMarkedText()`，中文/日文输入法在查找/替换/Diff 框按回车确认组字会被当作 Find Next | 增加 `MacShortcutInputPolicy.shouldDeferToMarkedText(window.firstResponder)` 让行 |
| **P1-18** | 工作台 UI 刷新 | `macos/Sources/Lithe/Views/Workbench/WorkbenchModuleUIComposition.swift` | `git.log` / `execution.run` / `execution.tests` / `debug.session` 缺少 `contentIdentity`，`.equatable()` 可能导致视图停留在 `"Starting module..."` | 全部补齐 `featureIdentity(...)`（并同步补全 `toolWindowTerminal.svg`） |
| **P2-25** | AI 配置导入缺陷 | `macos/Sources/Lithe/Models/Settings/AppSettings.swift` | `"lithe.(snapshot.source.rawValue).imported.apiKey"` 缺少插值反斜杠，导入 Claude 会覆盖 Codex provider | 修正为 `"lithe.\(snapshot.source.rawValue).imported.apiKey"` 并补单元测试 |

---

## 3. 下一批优先优化与修复方案（Priority Todo — 分批推进）

结合 `2026-11-26-cc-code-review.md` 与轻量高性能目标，按「**数据安全 > 核心功能与主线程卡顿 > 空闲功耗与大仓扩展性**」排定后续 3 个可执行批次（每批均遵循先写失败回归测试 -> 最小修复 -> Codex Review -> 全量验证 -> 文档同步）：

### Batch A：数据安全与强边界兜底（最高优先）

| 优先级 | 编号 | 目标与位置 | 推荐修复方案（克制改动） | 验证方式 |
| --- | --- | --- | --- | --- |
| **P0** | **P0-2 + P1-10** | 数据库 `query`/`explain` 只读强保证（`rust/lithe-db-sidecar/src/main.rs`、`rust/lithe-db-mcp/src/main.rs`、`DatabaseSQLSupport.swift`） | 在 sidecar 唯一收口点强制只读事务（PG `BEGIN READ ONLY … ROLLBACK`、MySQL `START TRANSACTION READ ONLY`、SQLite `PRAGMA query_only=ON`）；MCP 侧拒绝 `statementCount != 1`；Swift 分类器修正 `EXPLAIN` 与含 `=` 的 `PRAGMA` | `lithe-db-sidecar` / `lithe-db-mcp` 单测 + 真实 SQLite/PG 只读拒绝冒烟 |
| **P0** | **P0-1 + P1-11** | 数据库恢复点与 `<unsupported>` 保护（`rust/lithe-db-sidecar/src/main.rs`） | `sql_literal` 完整解包 `decimal/date/time/uuid` 单键标签；PG/SQLite 将 DROP 纳入事务原子执行；`sqlite_text` 回落 i64/f64/bytes、`pg_text` 增加 `try_get_unchecked::<String>`；`write_insert_row` 遇 `<unsupported>` 直接报错拒绝生成坏备份 | 含 `DECIMAL`、反斜杠、特殊类型列的导出 -> 还原往返单测 |
| **P1** | **P1-1** | 项目替换 Apply 原文新鲜度强校验（`SearchFeatureModel.swift`、`AppModel+SearchModule.swift`） | 提交事务前校验 `currentText.utf8.elementsEqual(target.sourceText.utf8)`，任一过期则零写入保留预览；读失败计入 `failedFiles`；事务分支用 `isApplyingProjectReplacement` + `defer` 防重复点击 | 新增预览后修改文件再点 Apply 的零写入回归测试 |
| **P1** | **P1-2** | 重复打开路径防 `Dictionary(uniqueKeysWithValues:)` 崩溃（`DocumentFeatureModel.swift`、`WorkspaceFeatureModel.swift`、`AppModel+SearchModule.swift`、`AppModel+LanguageEditing.swift`、`WorkspaceTextEditUndoController.swift`） | 重命名前检查目标子树是否含已打开文档；三处字典构造改为 `uniquingKeysWith: { first, _ in first }`；会话恢复对 `openPaths` 去重 | 新增外部删除后重命名覆盖路径的回归测试 |
| **P1** | **P1-4** | 独立文件模式 `Cmd+O` 未保存保护（`AppModel.swift:1201-1213`） | 切换前复用 `beginProjectClose()` 脏检查，并在 `reset()` 后同步 `workspaceTextEditUndoController.reset()` | 新增独立文件未保存切换测试 |
| **P1** | **P1-6 + P1-7 + P1-8 + P1-9** | 目录 Diff 隐藏 hunk 写操作；HTML 预览拒绝 `.` 开头路径组件；Database 视图 `await` 前捕获局部 `feature`；Find 通知按 `documentID` 过滤防焦点落入隐藏编辑器 | 均限定 5–15 行局部修复（HTML 预览是否默认禁 JS 待产品决策） | 对应 Swift 单元/集成测试 |

### Batch B：高频功能正确性与 Go/Rust/Python 体验补齐

| 优先级 | 编号 | 目标与位置 | 推荐修复方案 |
| --- | --- | --- | --- |
| **P1** | **P1-12** | Project 替换预览跳过索引中的二进制/超大文件（`rust/lithe-core/src/project/scoped_replacement.rs`） | 非显式 `Files` 范围跳过非纯文本解码失败，同步更新 `shared/contracts/rust-core-api.md`（预算统计口径变更单独决策） |
| **P1** | **P1-14** | 运行配置参数含空格引号往返保真（`MacRunConfigurationStore.swift`、`configuration.rs`） | 增加 `RunArgumentParser.format(_:)` 对称转义，替换两处 `joined(separator: " ")` |
| **P1** | **P1-16 + P2-55** | Git Log 重开刷新与分支弹窗轻量化（`AppModel+GitOperations.swift`、`GitFeatureModel.swift`、`WorkbenchView.swift:520`） | 增加 `historyNeedsRefresh` 标志，取消加载同步清 `canLoadMoreGitHistory = false`；分支弹窗打开改用轻量 `refreshGitReferencesForSettings()` 替代整历史重载 |
| **P2** | **P2-29 + P2-38** | Rust 根目录 `tests/*.rs` / Go 根包测试范围修正 + `gopls` 外部文件变更通知（`AppModel+LanguageServerRuntime.swift`） | 对 `.go`/`go.mod`/`go.sum`/`go.work` 转发 `notifyWorkspaceFilesChanged(providerID: "go")`；修正 Go/Rust 单测范围参数 |
| **P2** | **P2-39 + P2-40 + P2-41 + P2-42 + P2-43** | 插件目录冲突降级告警而非 `preconditionFailure`；交互式 Shell 运行 >2s 后非零退出自动关闭标签；`posix_spawn` 重置 `SIGMASK`；`MacURLSessionTransport` 取消防挂起与 `.waiting` 快速失败；`MacRawProcessSession` 串行队列 + 有界读尽 | 逐项加确定性单测并验证无进程/线程泄漏 |

### Batch C：深度性能优化（大仓 / 长会话 / 空闲功耗）

| 优先级 | 编号 | 热点位置 | 根因与复杂度 | 推荐优化方案 |
| --- | --- | --- | --- | --- |
| **P1** | **P1-19** | Git Log 每次保存文件全量重载历史（`WorkspaceFeatureModel.swift`、`MacDirectoryWatcher.swift`、`GitFeatureModel.swift`） | 任意工作区写入触发 5,000 提交 graph 重算，重置分页 | Watcher 仅在命中 `.git` 元数据路径或分支/仓库根变化时置位 `gitMetadataDirty`，普通文件保存只刷新 Changes |
| **P1** | **P1-22** | Rust 轻量补全/悬停/导航位置换算 O(n²)（`rust/lithe-core/src/lsp/lightweight/symbols.rs`、`edits.rs`）+ `@MainActor` 同步调用（`LanguageFeatureProvider.swift`） | 每个标识符从文件开头重算行号与 UTF-16 列 | 单次扫描累加 `(line, utf16_col)` 降为 O(n)，Rust `edits.rs` 预建行偏移表，Swift 侧离线调用移出 `@MainActor` |
| **P2** | **P2-36 + P3-3** | 空闲轮询 CPU 唤醒（`rust/lithe-core/src/lsp/interface/engine.rs`、`rust/lithe-git-host/src/lib.rs`） | 每个 LSP 会话 2 个 10ms 轮询线程（3 会话 ≈ 600 次/秒唤醒）；`lithe-git-host` 固定 10ms 轮询 | `maintenance` 改 `Condvar`，`monitor` 无 pending 请求时降至 100–250ms；`git-host` 自适应退避（1ms 起倍增） |
| **P2** | **P2-11 + P2-19 + P2-20** | Diff 搜索重复扫行；`workspace.snapshot` 误使 Trigram 索引失效；中文注释禁用 Trigram 剪枝 | 大仓搜索与大 Diff 卡顿 | Diff 搜索顶部算一次向下传；移除 snapshot 全局 invalidate 改走增量；Trigram 仅对 `ſ`/`K` 禁用大小写折叠 |
| **P2** | **P2-10 + P2-45 + P2-46** | 多选暂存逐文件启 git 进程；`OutputTextView` 含 ANSI 后每批全量重绘；工作台背景图按会话重复解码（~33 MB/会话） | 批量暂存、高频构建日志、多窗口内存膨胀 | Rust 侧已支持 `--pathspec-from-file`，增加批量暂存 port；`OutputTextView` 记录段尾默认 SGR 允许增量追加 + 缓存 `fileExists`；背景图跨会话共享降采样缓存、滑块松手再落盘 |
| **P3** | **P3-10 + P3-15 + P3-31 + P3-32 + P3-33** | LSP 引擎频繁整份 clone 状态；`RustCoreBridge` 大响应多拷贝；Undo/Redo 替换全量 `NSTextView` 文本；非 Java 文件跑 Java import 正则 | 细节内存与大文件响应进一步压低 | 增加 `&mut` 内部方法、`bytesNoCopy` 解码、前后缀最小差分替换、按扩展名守卫 Java 正则与 20k 括号扫描上限 |

---

## 4. 暂缓与显式不做（保持轻量边界）

- **暂缓引入多 Worker Tree-sitter / 替换 `NSTextView`（Monaco）**：当前单趟词法状态机 + LSP `semanticTokens/full` + Warm Tab Pool 足以在极低内存下满足 Go/Rust/Python 高亮与编辑流畅度。
- **暂缓强行拆分 `CodeEditorView.swift` / `GitFeatureModel.swift`**：所有优化均可在现有归属层内以小切面完成，避免人为制造大规模合并冲突。
- **暂缓删除仍接入 `MacServiceContainer` 的遗留 Java 适配层与 `third_party/jdk|jdtls` 兼容清单**：打包产物已保证 0 JDK / 0 JDTLS / 0 Linux.do，源码兼容层留待显式决策后再清理。
- **暂缓 `MacRuntimeLocator` 移除 `GOROOT`/`GOPATH` 探测（P2-44 复核结论）**：源码实审确认当前 `MacRuntimeLocator.swift:107-123` 使用的是 `homeDirectoryURL.appendingPathComponent(".g/go")` 与 `/usr/local/go`、`homeDirectoryURL.appendingPathComponent("go")` 的通用标准路径探测（并优先尊重用户进程/Shell/`go env` 配置），并未硬编码特定开发者用户名，无需删除。
