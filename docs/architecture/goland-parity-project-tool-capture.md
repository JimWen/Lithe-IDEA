# B7a2：项目工具捕获与只读刷新

状态：细化方案待独立审查。B7a1 元数据契约已完成（`4039f0f0`），本方案不改变
原 B7 的 Go Tools/Cargo 右栏、独立任务、配置和实际 GUI 验收目标。

## 1. 进程所有权前置修复（B7a2a）

继续复用 `MacManagedProcess` 的 posix_spawn 原子进程组、PID 注册、waitpid 和
已有 registry。当前 reapRootProcess 忽略子组清理失败后清空 group，而现有
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

成功需要：根进程已 reap、stdout/stderr 均实际 EOF、进程组确认清理、reader source
及读端已关闭。非零 exit 仍排空后返回完整两流，但不交给 normalize。主动关闭
read fd 不算 EOF。首个失败原因锁定；错误结果的 partial stdout 不得当完整 JSON。

清理失败可以有界返回失败结果，但 session 继续处于 cleanupFailed/active，
持有 registry、模块 lease、并发槽及必要资源；后续 stop 可重试。一次 capture
只返回一个结果，迟到真实退出仅完成剩余资源回收，不重放成功。调用者取消
capture 会发起所属进程清理，不能仅丢弃 continuation。并发 stop 共用一个 attempt
和固定期限，不因为新等待者重置宽限期。

## 3. Native 实现

原始字节及所有 pipe/state 状态由 dedicated native serial owner 管理；View/MainActor
不按每个 chunk 接收 Task。用两个非阻塞 DispatchSourceRead，固定小块 read；
0 是 EOF，EINTR 重试，EAGAIN 等下一次就绪，其他错误锁定 readFailed。每轮读取
有工作量上限并续排，让 deadline/stop 有机会执行。到 EOF 后 cancel source，
cancel-handler 是读端唯一关闭者，并向 owner 报 readerClosed。

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

资源有 closed/activationEpoch 门禁。停用后已有 capability/session 引用不能再次
start；仅 capability=nil 不足以失效外部引用。关闭门禁需在 release/sleep/shutdown
显式调用，因为 ModuleResourceScope 只停止 active resource。不引入 Execution
静态依赖 Go/Rust 来阻止用户停用插件。

旧插件在新宿主缺 capability 时提示更新，保留既有 Run/LSP；新插件用最低宿主
版本和加载检查防止旧宿主调用不存在的符号。contribution 注册仍由 B7a4 在 factory
层接入；本批不能以存在 host service 声称右栏已完成。

## 5. 只读读取策略（B7a2c，仍需最终审查）

Cargo 使用已安装实体工具链执行 metadata version 1/no-deps/frozen，不能触发
rustup 自动安装；Cargo 配置与环境的外部 helper/网络行为逐项校验。

Go 官方实现及隔离探测证实：readonly 下仍可能写 go.work.sum；-find 仍会写且
清空 Imports/TestImports/XTestImports。因此保留正常 go list，复制原始 go.work
到会话临时目录，调整其中 use 和本地 replace 的相对路径，并隔离临时 work.sum。
原始工作区 go.mod/go.sum/go.work/source 只读；普通 module、workspace、多 module、
cached/missing dependencies 和 build tags 保留真实包级诊断。

不能直接从 go work edit -json 重建 work：已装 Go 的 JSON 可能遗漏 Toolchain/
Godebug 指令。原始文本改路径必须使用可靠 Go 语法处理或保留全部指令的受控编辑；
`-replace` flag 的 @/尾空白解析不能改变目录语义。具体路径投影、私有临时别名、
sum 生命周期、telemetry helper 禁止机制待独立审查和完整零写 fixture 证明。

清理继承 GOFLAGS/GOCACHEPROG/GOAUTH、代理与私有模块策略、自动 toolchain、VCS
和 telemetry 行为。GOCACHEPROG 即使字段限定 list 也可启动 helper，不能只清
GOFLAGS。不得把 QA 专用内部环境开关冒充稳定生产 API。无兼容工具链/无缓存
时显示真实失败或 Incomplete，不擅自安装/下载、改 manifest 或生成假树。

## 6. 验证门槛

纯状态测试使用可控 backend/reader 和 manual scheduler：rootExit/双 EOF 六种顺序、
最后片段、跨块 UTF-8、stderr 噪声、exact cap/+1、readError、取消、缺单 EOF、
迟到 timer/launch、cleanup false→retry true、stop 重入与多 waiter、旧 generation
不发布但继续清理。每个等待均有本地 deadline。

真实 native 测试：两个超过 pipe capacity 的独立流完整字节；短命进程最后 JSON；
root 退出后 TERM-resistant 后代分别持有 stdout/stderr 或关闭双流；停止确认根
reaped/后代退出；缺 executable/cwd 的 FD 清理。所有失败路径也 await 自有清理，
不能仅 defer 发 kill 或用包含 ready 的旧测试代表双 EOF 完整性。

只读 fixture 必须覆盖缺 sum 的 cached dependencies、已有 sum、本地/远端 replace、
外部 module、Unicode/空格/@/尾空白路径、build tags、too-new toolchain、缺缓存、
外部 helper 哨兵；前后源码/manifest/lock/sum 内容与目录清单都比较。临时目录
在取消、失败和进程未清理完时按 owner 生命周期保留/回收。

各子批先独立方案/代码审查，再 focused/full timing、边界、ARM64 构建、分批 commit。
B7a4 按完整方案实际打开应用、点击/右键/配置/取消/窄窗口/对照并截图；纯后台
基础验证不能代替用户要求的最终 GUI 验收。
