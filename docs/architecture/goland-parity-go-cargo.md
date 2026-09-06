# Go Tools / Cargo 工具窗口实施方案

状态：B7a1 方案经两名独立 reviewer 放行；纯 Rust 基础实现已通过完整验证并提交 `4039f0f0`。B7a2–a4 尚未实施；Project 保持现状。前置 Terminal B4a6 已完成。

## 1. 最终体验与本批依赖

沿用统一 GoLand 工作台尺寸、字体、tooltip 和命令体系。Cargo 对照 RustRover 的 workspace → member → target 树、刷新、右键执行与配置；GoLand 原生 Go Tools 主要在 Tools 菜单，本产品按用户要求另提供右侧 Go Tools 入口，并复用同一动作。不能把 Go 入口位置声称为 GoLand 原生布局。

Go：module/workspace/package、任意文件名的 main package，Build/Test/Run/Vet、格式检查及实际格式化、模块与依赖工具。Cargo：workspace/default members/member/bin/lib/example/test/bench、Build/Check/Test/Run/Clippy、格式检查及实际格式化。支持刷新/取消/重试、双击默认动作、右键动作、编辑与保存配置、输出及错误定位、隐藏恢复；选择、展开和任务状态按项目独立。

构建/运行参数完整传到子进程：Go build tags、GOOS/GOARCH、参数/env/cwd；Cargo package/target/features/default features/profile/target triple、程序参数/env/cwd。工具链选择复用现有解析器。运行入口 gutter、语义 Structure/TODO 仍属后续 B7，不能用此窗口替代。实际格式化/依赖写入单独验收，格式检查不得标成完整格式化；格式化应用复用 B3/B6 的文档事务。

## 2. 当前证据与边界

- `WorkbenchModuleUIRegistry` 和 `rightSidebar` 已有通用注册/渲染，但无 Go/Cargo renderer。
- `RunService.run()` 先 stop 且依赖已就绪配置文件；工具任务必须独立，不生成配置文件以绕过检查，也不能停止用户运行中的服务。
- Go 插件和 bundled Rust execution 已有受模块拥有的执行会话、工具链解析、lease 与停用策略。新功能接入同一所有权，禁用/隔离/加载失败不得降级成宿主私自运行。
- 当前 detector 不足以发现完整 workspace/target；元数据由实际 `go list` / `cargo metadata` 提供，Rust Core 只解析/规范化，不访问文件或启动进程。
- `MacRawProcessSession` 虽分 stdout/stderr，但退出时立即撤 handler，无法证明已收到 JSON 最后片段；元数据 capture 需等待退出和双 EOF，不能使用合并输出。

## 3. 分批交付

### B7a1：真实元数据的共享模型与解析

新增纯命令 `execution.normalizeProjectMetadata`。输入包含 `language`、`workspaceDirectory`、显式宿主 roots `{id,path}` 及原始 stdout：Cargo `cargoMetadata`；Go `goModules` 和 `goPackages`（JSON 对象流）。输出版本 1：language/workspace location/members/default member IDs。member 带稳定 ID、名称、版本、manifest/directory、targets/features/dependencies；target 带稳定 ID、名称、kind、source locations、required features、run/test 能力及 Go import path。

paths 输出统一 `{rootID, relativePath}`，根目录用 `.`；不把 Cargo opaque package ID（可能含绝对路径）传为稳定 ID。宿主显式提供外部 root 的稳定 ID 和绝对地址映射，供 go.work 外部 module、Cargo workspace 外部 member/source 使用。Core 按最长组件前缀匹配，拒绝未映射路径、重复 root ID/地址、相对 native path 和越界 `..`。Core 不证明授权或 symlink containment：宿主先解析/核验实际文件和用户的 workspace/module 关系，避免把词法匹配当作文件系统安全校验。root ID 为 1–64 位 ASCII 字母/数字/`._-`，native 路径按 POSIX 绝对路径规范化（折叠重复 `/` 与 `.`，拒绝 `..`/NUL）；重复地址按规范化后检测。宿主在同一 workspace incarnation 冻结 roots 集合与 rootID 映射，改变 roots 必须重新建立 incarnation，不能在刷新时插入更长前缀导致 ID 漂移。member ID 为 language + manifest location 的 JSON 数组 SHA-256；target ID 为 member ID + canonical kind + name（Go 为 package + ImportPath），source 列表、版本、opaque Cargo ID 均不参与。

Cargo 校验 schema version 1、workspace members/default members 引用（defaults 必须是 members 子集）、重复 package ID/manifest/target identity；只投影 workspace members，依赖包不混为 member。保留 default member 缺失与空列表的区别（老 Cargo 缺失为 null，不能误选全部）。结合 kind 与 crate_types 区分 example library 与 example binary（两者 kind 都是 example）、custom-build 不可 Run，test/doctest/required-features 原值参与后续计划；未知新增 kind 保留但禁用未经定义的 Run。保留 raw kind/crate_types 与 canonical kind、default_run、edition，不用 kind 数组顺序构造 identity。声明依赖和解析后的完整依赖图不同，`--no-deps` 的数据只能显示声明依赖。保留依赖 rename/kind/optional/features/defaultFeatures/target/versionReq；path dependency 的根由宿主在首次快照前显式映射，包含 workspace 外部依赖，不能误报为 metadata 无效。

Go 支持多个拼接 JSON 对象，按 `Main` module 定位 package，不把依赖 module 列为 workspace member。校验 module 路径/目录、package import path/目录及 module 归属，不能靠包名 main 或文件名来选错 module。GoFiles/CgoFiles/TestGoFiles/XTestGoFiles/IgnoredGoFiles 按 Dir 拼接并规范化；保留 package 的普通/测试源、imports、build-tag 排除源、Incomplete 与 Error 状态；`-e` 返回的包级失败需可见，不能降格为空树。拒绝重复及可识别的合成 `go list -test` 包（ForTest 或方括号合成 ImportPath），避免同包重复运行；不因合法 import path 以 `.test` 结尾就拒绝。保留 DepsErrors，包括 Incomplete=true 但 Error=nil；Dir 组件祖先归属与显式 Module 必须一致。缺失 Dir/Module 的合法错误记录保留为项目级 diagnostics，不捏造 target；健康记录缺少必要定位字段整体失败。原始工具错误只放 diagnostics.details（可能含原生路径），不进入 ID。命令失败由宿主 capture 报告；仅退出成功且完整 stdout 才进入解析。

限制：原始 stdout 总计 16 MiB、最多 128 roots、10000 members、100000 targets/records；单个 JSON string token 64 KiB、native path 8 KiB、全部输入结构条目共同预算 200000、输出 32 MiB。超限整体失败。decode 前按 64 KiB 分片扫描字节/字符串/结构预算并检查 cancellation，decode 使用 typed structs 和 serde 默认深度限制（不关闭递归检查），decode 前后及逐 item 再检查；不先解无限制 Value 再逐项过滤。单次有界 typed decode 内无抢占保证；最大 16 MiB 的解码耗时计入命令期限。归一化重复展开的路径及诊断 import path 也在复制前计入共同输出预算，不能仅限制原文大小。无自动网络/磁盘/环境副作用。损坏子项整体失败，不 `compactMap` 丢弃后当作成功。用户已有三份语言方案文件不在本批提交。

本基础提交用 Rust dispatcher fixture / timing / C ABI linkage 验证；它本身没有新 UI，不以此声称右栏已交付，也不为无变化界面制造点击验收。B7a4 必须完整 ARM64 构建和真实 UI 对照。

### B7a2：可靠 capture 与只读刷新

平台 capture 复用 `MacManagedProcess` 的原子 process-group 创建和回收，分开累计 stdout/stderr；保持 UTF-8 bytes 到双 EOF 后解析。stdout 16 MiB、stderr 1 MiB、默认 30 秒 deadline。超限/timeout/cancel 均停 owned process group、等待清理；不能截断 JSON 后返回成功。退出/EOF/停止并发只完成一次；强停失败保留可见资源。总并发有界，新刷新取消旧 owner，旧结果不能写入另一 workspace/provider generation。

保留现有公开 `LanguageExecutionSession`/`LanguageRunExtensionProviding` v1；新增独立 `LanguageProjectToolsProviding` capability 与版本化 host service。Go/Rust 原 execution module 导出新能力，其资源实际持有 capture/action sessions；Execution 只拥有项目 feature 和任务状态。provider 发现步骤有顺序与数量上限，不建立任务 DAG。新宿主加载旧插件缺能力时提示更新，不破坏旧 Run/LSP，也不允许宿主 fallback。

首次读取禁止静默下载工具链、改源码/manifest/lock/module 文件。Cargo 用 `metadata --format-version 1 --no-deps --frozen`，防 rustup 首次自动安装须由解析器选择已安装实体工具链并验证。Go 从 `go env -json GOWORK GOMOD` 与 `go work edit -json` 只读定位，再以 `GOTOOLCHAIN=local`、`GOPROXY=off`、`GOSUMDB=off`、只读 module 模式读取 `go list -m -json` 和逐 module `go list -e -json ./...`；go.work 根不能简单执行 `./...`。以上 Go flags 只是候选读取策略，尚未证明 workspace 零写：Go modload 即使 readonly 仍可能写 go.work.sum。B7a2 实施前必须以官方源码及缺 sum/有缓存依赖 fixture 验证隔离 sum/work 文件的方案，或使用已证明不触发写入的元数据命令组合；未通过前不得接自动刷新。捕获层明确禁用 -modfile/-test/-compiled；审查 GOFLAGS、GOPRIVATE/GONOPROXY、GOCACHEPROG/GOAUTH 等会改变下载或外部命令行为的继承配置。清理/覆盖策略须在代码审查中落实，不用项目脚本启动工具。缓存缺失/不兼容显示可操作失败，不擅自执行 go mod tidy、cargo fetch 或安装工具。显式依赖更新/下载另有用户动作。

### B7a3：独立工具任务和配置

新增工具 task service，不改变已有普通 Run 的默认替换语义。独立 task ID、workspace/provider generation、输出缓冲、状态、停止/重跑；使用同一语言插件 execution ownership，lease 在进程实际停止后释放。无持久配置也可执行临时计划；编辑/另存为复用已有配置分层和工具链模型，禁止写入 generated.json。参数投影在 Rust Core/语言 capability；View 不拼 shell。多个任务不互相 stop，显式 Stop 只停选中任务。

复用 Run 输出视图的 ANSI/位置链接，独立 build diagnostics source，不能覆盖 LSP diagnostics。Cargo JSON compiler messages 与 Go 文件行列输出在拥有层投影，保留 exit code、stderr、取消/失败状态及定位根。

### B7a4：右栏与实际体验验收

contribution 必须同时在 `ModuleFactory.contributions` 声明（runtime 目录不读取实例的同名方法）。同步维护 Go plugin manifest、Rust bundled catalog、capability ID 和宿主最低兼容版本；停用后清理选中状态。通过 contribution/action catalog 注册 Go Tools/Cargo，按可用插件及项目检测显现。状态依赖专用 feature model；loading/failed/empty/ready 区分，当前树刷新时保持选择/展开，新成功快照按 stable ID 调和。右键、菜单、tooltip/快捷键共用命令。

右栏可调宽度复用 `LitheSplitPaneView` / `SplitHandleView`；尺寸局部持有，全局坐标/coalescing，结束后才持久化。明确相邻编辑器最小宽度、窄窗口 clamp、隐藏恢复；审查确认拖动不高频重建整个页面。

## 4. 必须验收的矩阵

1. Go 单 module 任意 main 文件名、go.work 多 module 同名包、build tags；Cargo virtual workspace/default members/显式 bin 路径/自动 bin/lib/example/test/bench/custom-build。外部 root 和 Unicode/空格路径、duplicate/unknown/default 缺失均有协议 fixture。
2. 无任何 run 配置可执行；参数/env/cwd/features/profile/target 实际到达 child；缺工具链、clippy/rustfmt、无缓存、损坏 manifest 可恢复。
3. 首次打开和 refresh 前后源码/manifest/lock hash 不变；元数据 stdout 分片、stderr 噪声、退出前最后一片、双 EOF 顺序、超限、超时均有稳定测试。
4. cancel/refresh/workspace switch/window close/plugin disable 实际进程有界退出；已有 long-running Run 存活；旧结果不跨项目，Stop 只影响选中任务。
5. UI 实际点击/双击/右键/键盘、设置配置、错误定位、窄窗口/拖动/隐藏恢复，对照同尺寸 RustRover 与 GoLand；截图和操作事实同时记录，退出所有 QA app/child/helper 后提交。

每批先独立审查方案，再实现、相关测试与 timing、边界和构建、独立代码审查、commit；不 push。自动检查不能代替 B7a4 的整体 GUI 验收。B6 重构、B3 事务、B5 资源插件和 L0–L7 语言能力保持原目标，未以 B7a 子集结项。

## 5. 官方依据

- [RustRover Cargo tool window](https://www.jetbrains.com/help/rust/rust-cargo-tool-window.html)：树与操作参照。
- [GoLand Go Tools](https://www.jetbrains.com/help/go/integration-with-go-tools.html)：工具动作参照。
- [Cargo metadata](https://doc.rust-lang.org/cargo/commands/cargo-metadata.html)：version 1、target kinds、default members、no-deps/frozen。
- [Go command](https://pkg.go.dev/cmd/go#hdr-List_packages_or_modules)：module/package JSON 与 list 参数。

官方资料复核日期：2026-09-06。实际布局仍需本机 GUI 证据；文档不是“完全对齐”的完成证明。

B7a1 的精确请求/响应和兼容边界见 [project-tools-metadata.md](../../shared/contracts/project-tools-metadata.md)。

B7a1 验收记录：[第十四批](goland-parity-iteration14-acceptance.md)。
