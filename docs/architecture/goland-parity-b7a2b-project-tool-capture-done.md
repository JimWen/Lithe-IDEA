# B7a2b：项目工具捕获与插件资源（已完成）

状态：已完成。本文只覆盖 B7a2a 原生进程清理（`d6fb2d1f`）与 B7a2b
双流捕获/插件资源（`daf43b7f`、`0003c624`），均通过独立方案与代码审查、完整
Swift 测试和 ARM64 构建。后续只读工作流见
[B7a2c 项目元数据刷新](goland-parity-b7a2c-project-metadata-refresh.md)，
工具任务与右栏最终验收见 [B7a 总方案](goland-parity-b7a-go-cargo.md)。

## 1. 进程所有权前置修复（B7a2a）

继续复用 `MacManagedProcess` 的 posix_spawn 原子进程组、PID 注册、waitpid 和
已有 registry。修复前 reapRootProcess 忽略子组清理失败后清空 group，而现有
MacStreamingProcess 在 await 前移除 registry。这些行为不能作为新捕获的完成证据。

`MacManagedProcess.isRunning` 保留既有完成时序：waitpid 之后立即冻结 rootReaped
和 exit code，但只有根进程已回收且本次清理 attempt 完成，才发布 running=false
和旧 termination callback。同步 runner 依赖这一次序；防止 zombie 死锁依靠先
实际 waitpid，不提前改变旧 running。新增 owned-processes / group-cleanup 状态。
自然退出与显式 terminate
共享同一个清理 attempt；失败保留 group，下一次显式 stop 可重试，不能把没有
活根进程当成停止成功。旧 termination callback 签名保留，仍只发送一次根进程
退出通知；在锁外调用，通知前冻结 root exit 和该次 cleanup outcome。

清理 attempt 由独立 native 队列运行已有 TERM → grace → KILL → bounded wait，
异步调用通过 continuation 等待；已有同步 native runner 通过有界同步等待复用
同一 attempt，不能重叠发送两套信号。同步等待不能占用 reaper、cleanup queue、
state queue 或状态锁；本地 waiter 超时不表示 attempt 已完成。使用单调时钟；
等待者取消不取消真实清理。结果先冻结，再在锁外恢复等待者及调用 callback。
attempt 完成后成功释放 group，失败保留 owner 并允许重试。新 capture 依赖
hasOwnedProcesses/cleanup outcome，不能依赖旧 isRunning。不同时重写旧 Run 的
默认单会话替换行为或旧插件 execution v1。

失败后的重试和延迟升级不能裸用保留的 PGID。native helper 在根 PID 尚未 reap
时记录组成员的 PID + start-time incarnation；每次枚举前后验证至少一个旧 anchor
仍属于原组，才纳入新成员。发送信号前再次校验身份和组，使用 positive-PID signal。
没有 anchor 且同号组仍存在时保留 cleanupFailed，不能重新认领；确认组消失才
结束所有权。未完整枚举不能当空组成功。此修复限于 ManagedProcess，不重写 Terminal。
真实 native 查询与窄注入 backend 分离，编号复用用受控测试模拟，不依赖 OS 实际复用。

此提交先单独验证自然退出/并发 stop 去重、失败保留→重试、root-reaped 时序、
真实后代清理、waiter 超时后的迟到完成、callback 重入且只一次、编号复用不发
信号，完整 Swift 测试和 ARM64 构建通过后再接捕获。旧 v1 wrapper 提前释放 registry
仍是已知限制；本批不能宣称所有旧 session 的所有权都已修复。

## 2. 独立单次捕获契约（B7a2b）

新 `LanguageProjectToolSession` 和独立版本化 host service，不向旧
`LanguageExecutionSession` 添加必需方法。请求持有 operation ID、已解析的
executable/argv/cwd/完整 env、timeout、stdout/stderr byte limit。明确拒绝 NUL、
无效 env key、越界预算；不通过 shell 拼命令，不隐式继承未审查的环境。

单次 `capture(request)` 异步返回 typed result；同步可观察 state 与 state-change
回调用于 feature/resource。`stopAndWait()` 必须真实实现，不能使用旧轮询默认值。
状态区分 idle、starting、running、draining、stopping、cleanupFailed、finished。
结果区分 succeeded/processFailed/startFailed/cancelled/timedOut/outputLimit/readFailed/
cleanupFailed，保留独立原始 Data、exit code 和 cleanupConfirmed。

成功需要：spawn worker 已返回、宿主 writer 已确认关闭、根进程已 reap、
stdout/stderr 均实际 EOF、进程组确认清理、reader source 及读端已关闭。非零 exit 仍排空后返回完整两流，但不交给 normalize。主动关闭
read fd 不算 EOF。首个失败原因锁定；错误结果的 partial stdout 不得当完整 JSON。

清理失败可以有界返回失败结果，但 session 继续处于 cleanupFailed/active，
持有模块 lease、全局并发槽及必要资源；PID 监控 token 在根进程 reap 时注销，避免把
已复用的 PID 计入旧模块。监控 token 以 UUID 独立配对，跨会话不会相互删除。
进程组清理所有权继续由 native owner 和资源持有；后续 stop 可重试。一次 capture
只返回一个结果，迟到真实退出仅完成剩余资源回收，不重放成功。调用者取消
capture 会发起所属进程清理，不能仅丢弃 continuation。并发 stop 共用一个 attempt
和固定期限，不因为新等待者重置宽限期。

## 3. Native 实现

原始字节及所有 pipe/state 状态由 dedicated native serial owner 管理；View/MainActor
不按每个 chunk 接收 Task。用两个非阻塞 DispatchSourceRead，固定小块 read；
0 是 EOF，EINTR 重试，EAGAIN 等下一次就绪，其他错误锁定 readFailed。每轮读取
最多执行四次 16 KiB read（EINTR 也消耗次数），后续交回 Dispatch 就绪通知，
让 deadline/stop 有机会执行。到 EOF 后 cancel source，
cancel-handler 是读端唯一关闭者，close 成功才向 owner 报 readerClosed。关闭失败
保留 cleanupFailed；不能重关可能已复用的裸 fd。writer 逐句柄保存成功关闭证据，
首次关闭失败后不再访问 FileHandle 或裸 fd；macOS 的失效 wrapper 连读取
fileDescriptor 都可能抛 Objective-C 异常。后续重试必须稳定保留“未确认”。

stdout 默认/上限 16 MiB、stderr 默认/上限 1 MiB，超限前拒绝继续累计，不能先无限
排队到 MainActor 再限流。整体 deadline 默认 30 s，覆盖 starting、root exit 后
等待 EOF 与排空；停止与清理有独立有界期限。最终 stdout 由消费者严格 UTF-8
解码，stderr 仅诊断；不将合并流或截断 JSON 交给 Rust。

spawn 使用全局有界 native worker（捕获至多两个并发），不阻塞 MainActor 或
state owner。先记录 starting/generation/permit，再启动 worker。spawn 卡住时
timeout/stop 仍能返回清理未确认；保留 permit 和 owner，迟到 onLaunch 立即进入
已请求的停止流程，禁止失管。spawn 成功立即关宿主写端，失败关闭全部自有端。
旧 operation 的 root/EOF/readerClosed/cleanup 事件直到回收完成都必须被接收；
workspace/provider generation 只禁止向当前 feature 发布旧结果。

## 4. 插件与模块资源

Go/Rust 原 execution module 导出独立 project-tools capability，其 module resource
持有 metadata 与工具 sessions；Execution feature 只拥有 UI/任务状态。资源活动
包括 starting、draining 和 cleanupFailed。shutdown/disable/window close 先要求
所有自有会话停止，再有界等待；停止失败保留 owner/lease 并可重试。

共享的 `LitheLanguageExtensionSupport` 库只依赖 Module API/Core Contracts，复用
Go 与 bundled Rust 的 capture resource、activity lease 和会话门禁。它不是新的
runtime module，不声明 ID/manifest；不承担 Go/Cargo 策略、native I/O 或 UI。
OfficialPluginVerifier 直接链接该库，官方插件构建检查其 swiftmodule；CI 中库
源码变更选择 Swift、Plugins、macOS release，测试变更选择 Swift 与 Plugins。

资源有 closed/activationEpoch 门禁。停用后已有 capability/session 引用不能再次
start；仅 capability=nil 不足以失效外部引用。关闭门禁需在 release/sleep/shutdown
显式调用，因为 ModuleResourceScope 只停止 active resource。不引入 Execution
静态依赖 Go/Rust 来阻止用户停用插件。

重激活也要检查 context.resources 中尚未清理的同类 capture owner，不能只看
module 实例属性：ModuleRuntime 可能重用清理失败实例，也可能在失败 activate
后清空实例但保留活跃 resource。旧资源停止重试确认前禁止建立新 owner/epoch，
确认后才允许重新激活；无需为此扩大 kernel 的修改范围。

旧插件在新宿主缺 capability 时提示更新，保留既有 Run/LSP；新插件用最低宿主
版本和加载检查防止旧宿主调用不存在的符号。contribution 注册仍由 B7a4 在 factory
层接入；本批不能以存在 host service 声称右栏已完成。

独立预审发现旧 Go 插件通过 dynamic_lookup 调用宿主
`OfficialPluginCatalog.moduleManifest(for:)`。必须冻结该旧 accessor 的 v1 返回值；
新插件使用独立版本化 accessor 或自有声明。否则宿主追加 capability 后旧插件
factory 与其已安装 manifest 不一致，会触发 factoryCatalogMismatch，连旧 Run/LSP
也被拒绝。不能放宽严格校验。新 host/Go 插件采用兼容的 0.3.1 门槛（旧包接受
`<0.4.0`）；Plugin API/schema 仍为 1。旧 protocol/struct 布局保持，沿已有
executionModuleID 定位新 capability，不向 LanguageSupportDeclaration 追加字段。
新 factory 保持惰性，`context: .empty` 的官方插件校验仍可执行；Python/Node
不得随 bundled execution module 意外声明 Go/Rust 专用能力。验收必须包含真实
旧版 Go 动态插件在新宿主的 Run/LSP、旧宿主加载新插件前拒绝，以及两个 workspace
共享两个并发槽；单纯比较 mock manifest 不足以证明 dynamic_lookup 兼容性。

## 5. 下游读取边界

捕获层只返回完整双流和清理结果，不负责元数据读取策略。
Cargo 实体工具链、Go work/sum 隔离、特殊路径、vendor、telemetry 与零写验证
由 [B7a2c 项目元数据刷新](goland-parity-b7a2c-project-metadata-refresh.md) 和
[B7a2c3 Go 读取隔离](goland-parity-b7a2c3-go-metadata-isolation.md) 管理。
这些下游范围不因捕获层完成而结项。

## 6. 验证门槛

纯状态测试使用可控 backend/reader 和 manual scheduler：rootExit/双 EOF 六种顺序、
最后片段、跨块 UTF-8、stderr 噪声、exact cap/+1、readError、取消、缺单 EOF、
迟到 timer/launch、cleanup false→retry true、stop 重入与多 waiter、旧 generation
不发布但继续清理。每个等待均有本地 deadline。

真实 native 测试：两个超过 pipe capacity 的独立流完整字节；短命进程最后 JSON；
root 退出后 TERM-resistant 后代分别持有 stdout/stderr 或关闭双流；停止确认根
reaped/后代退出；缺 executable/cwd 的 FD 清理。所有失败路径也 await 自有清理，
不能仅 defer 发 kill 或用包含 ready 的旧测试代表双 EOF 完整性。

各子批先独立方案/代码审查，再 focused/full timing、边界、ARM64 构建、分批 commit。
B7a4 按完整方案实际打开应用、点击/右键/配置/取消/窄窗口/对照并截图；纯后台
基础验证不能代替用户要求的最终 GUI 验收。

B7a2a 的逐项证据见[B7a2a 清理验收](#b7a2a-acceptance)。

B7a2b 的逐项证据见[B7a2b 捕获验收](#b7a2b-acceptance)。

## 已完成验收

<a id="b7a2a-acceptance"></a>

### B7a2a 原生进程所有权与清理

2026-09-06，方案 `d34c109f`、实现 `d6fb2d1f`；`workbench_audit` 与
`terminal_exit_review` 独立审查通过。定向 28 项、Swift 全量 1047 项 / 113 suites
（33.098 秒）通过，含 15 项新增测试；Core、服务边界、共享契约、稳定性、diff 与
ARM64 调试构建通过。真实后代清理与受控失败重试、三路合并、等待者超时/取消、
回调重入、首次结果冻结、编号复用、查询恢复均验证。

证据在 `.artifacts/goland-parity/iteration15-tools/`：`focused-fixed/`、`full/`、
`verify-core.log`、`build.json` 与 `cleanup.json`。
没有替换安装或新 UI 点击验收；报告浏览器/HTTP 服务及测试进程已退出。
身份检查与信号仍有系统调用间隙；旧 execution v1 wrapper 的 registry 限制保持，
新 capture 使用独立 owner/lease，不能以旧 isRunning 证明清理完成。

<a id="b7a2b-acceptance"></a>

### B7a2b 双流捕获与插件资源

2026-09-06，native 捕获 `daf43b7f`、模块/插件接线 `0003c624`；独立方案、
代码、插件兼容和跨模块审查均通过。定向 65 项、Swift 全量 1090 项 / 119 suites
（33.897 秒）通过；真实 native 双流/EOF/后代清理、生命周期/共享两槽/lease 门禁、
Core/服务与模块边界/共享契约/CI 分类/稳定性/diff 及 ARM64 完整构建通过。

真实新 Go Bundle 的 Run/LSP/capture/停用与旧 0.3.0 Bundle 在新 verifier 的 Run/LSP/
停用通过。动态插件验证使用无进程内存宿主，native 捕获另由集成测试验证；
旧宿主拒绝新包来自版本契约与生产加载前拒绝路径，未实际启动旧版 App。
证据在 `.artifacts/goland-parity/iteration16-capture/`：`focused/`、`full/`、
`compat/verify.log`、`arm64-build.log`、`build.json` 与 `cleanup.json`。
报告与测试进程已清理，未新增 UI 或替换安装；不将本批后台验证当作右栏点击验收。
