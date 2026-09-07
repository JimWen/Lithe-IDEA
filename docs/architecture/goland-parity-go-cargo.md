# Go Tools / Cargo 工具窗口实施方案

状态：B7a1 方案经两名独立 reviewer 放行；纯 Rust 基础实现已通过完整验证并提交 `4039f0f0`。B7a2a 原生进程清理亦已完成（`d6fb2d1f`）；B7a2b capture/插件资源完成（`daf43b7f`、`0003c624`）；B7a2c1 Swift 元数据消费/Unicode feature 完成（`8b8e7fe9`、`0b5dfcaa`）。B7a2c2 Cargo 只读刷新与右侧工具窗口代码完成（`4f41da49`），自动检查通过；2026-09-07 的首次 GUI 点击验收发现嵌套包工作区必然失败的元数据校验缺陷，**已当日修复并通过 GUI 复验**（见下），但树形展开/选择/失败重试/隐藏恢复的完整点击验收、RustRover 对照与 ARM64 包验收仍未完成，B7a2c2 不得结项。a3–a4 尚未实施；Go Tools 窗口尚未实施；Project 保持现状。前置 Terminal B4a6 已完成。

B7a2c2 已完成部分：Rust execution module 的静态 Cargo contribution（catalog/factory/instance/renderer 四处一致）、`CargoProjectFeatureModel` 的单轮刷新所有权（期限、输出预算、取消与迟到清理）、`MacCargoMetadataPreparer` 的被动原生准备（拒绝脚本 shim、尊重显式 Cargo 选择、rustup proxy 经语言 capture 解析、环境白名单构造、按 typed metadata 授权 root）、`LanguageProjectToolResource.retire()` 的同步 retirement 事件，以及 execution graph 把刷新计入执行工作并在停止前关闭刷新闸门。

B7a2c2 **未完成**部分，不得视为该子批结项：树形展开/选择/失败重试/隐藏恢复的完整点击验收与 RustRover 对照截图；刷新前后源码/manifest/lock 零改动的实测；ARM64 产品包验收；以及下述嵌套包校验缺陷的修复与回归测试。

## B7a2c2 首次 GUI 点击验收记录（2026-09-07）

图标接入批次（工作区未提交改动：`toolWindowCargo.svg`/`_dark.svg` 来自 intellij-rust 插件 commit `c6657c02`，MIT 许可随 `LICENSE-MIT.txt` 归档，NOTICE 已注明；`CargoProjectView` 头部与 `WorkbenchModuleUIComposition` 侧条接线）随本机 swift.org 6.2.4 工具链构建，在真实工作区以 `--open-project` 启动 ARM64 应用完成首次点击验收：

- 已验证：暗色系统外观下，工具窗口头部与右栏侧条的 Cargo 图标均以正确剪影渲染（模板着色，与既有六个工具窗口同一 `LitheIDEAIcon` 路径）；两个 SVG 与 RustRover 参考件逐字节一致；头部 Refresh 按钮可点击，manifest 选择器显示检测到的 `simple/scrap_url/Cargo.toml`；应用退出后实例目录与进程清理干净。
- 未验证：亮色外观的实际截图（验收期间系统处于暗色，未切换用户全局外观）；RustRover 同尺寸并排对照；ARM64 产品包。
- **新发现缺陷（已修复，待提交）**：Lithe 工作区根下嵌套的独立 Cargo 包（如 `simple/scrap_url/`，根目录无 `Cargo.toml`）必然显示「Invalid or inconsistent project metadata」。根因链：`refreshCargoProject` 把 Lithe 工作区根作为 `workspaceURL` 传入 → `MacCargoMetadataPreparer` 以同值作为 `workspaceDirectory` → Rust Core `project_metadata/cargo.rs` 要求 cargo 返回的 `workspace_root` 与该目录相等。对 `rust-in-prod` 实测：产品同参命令 `cargo metadata --format-version 1 --no-deps --frozen --color never --manifest-path …` 手工执行成功，故失败发生在 Core 的相等性校验，不是清单或工具链问题。工作区形态（根 workspace、`one/` 成员）在既有 fixture 中覆盖，嵌套独立包形态无 fixture。
- **修复与复验（2026-09-07 同日）**：`cargo.rs` 把 `workspace_root` 的等式要求放宽为包含（必须位于 `workspaceDirectory` 之内，Go 模块目录沿用同一规则），`project-tools-metadata.md` 契约补充了该规则成文。新增回归测试 `cargo_workspace_root_must_stay_inside_the_workspace_directory`（嵌套接受、外部根拒绝、`workspace-sibling` 前缀兄弟拼写拒绝）。修复后 `rust-in-prod` 实测：工具栏 Cargo 条目点击展开工具窗口，树渲染 `Workspace → scrap_url, default, 0.1.0 → bin (simple/scrap_url/src/main.rs)`，错误行消失；头部与侧条图标正确；退出清理干净。已跑 `verify-rust-core-comments`、`verify-rust-core`、`verify-shared-contracts`、`verify-service-boundaries`、`verify-module-boundaries` 与完整 Swift 套件（1108 项通过）。
- **第二个缺陷：GUI 启动找不到 Cargo（用户实测报告，已修复）**：安装版从 Dock/Finder 启动后点击 Cargo 显示「Cargo was not found. Install it or set its path in the project's tool settings.」。根因：`MacRuntimeToolDiscovery` 对 Go 有 `~/go/bin`/GOBIN/GOPATH 兜底、对 Xcode 有固定路径，唯独没有扫描 rustup 的标准安装位置；GUI 应用继承的 launchd PATH 不含 `~/.cargo/bin`（该机器登录 shell 亦不含），而开发终端里启动的实例继承终端 PATH，因此只有终端启动的实例能找到 cargo。修复：新增 rust 用户 bin 扫描（`$CARGO_HOME/bin` 与 `~/.cargo/bin`，覆盖 cargo/rustc/rustup，PATH 显式条目仍然优先），并补 `macToolDiscoveryFindsRustupProxiesInCargoUserBin` 回归测试；Swift 套件 1109 项通过。用 `open --env PATH=/usr/bin:/bin`（环境中无 cargo，等同 Finder 启动）重启安装版实测：Cargo 树完整渲染，两个错误均不再出现。
- **第三个迭代：工具窗口对齐 GoLand 参考图（11.png，2026-09-07）**。对照本机 RustRover v2024.x 的 Cargo 工具窗口实录后重构 `CargoProjectView`/`CargoTreePresentation`：头部仅保留标题 + ⋮ 选项菜单 + 隐藏按钮；新增工具栏行（Refresh / Attach=manifest 菜单 / Detach=重置清单 / Expand All / Collapse All，后两个为真实能力，Run Cargo Command、External Linter、Rustfmt、Settings 依赖 B7a3 执行服务**未提供假入口**）；树改为 GoLand 形态——单成员工作区（含嵌套包）直接以成员为根、多成员工作区保留 Workspace 层，成员下新增可折叠 `targets` 组节点，行内只显示图标+名称（kind 徽标与源路径移入 tooltip 与右键）。节点交互：单击选中；双击 target 打开其入口源文件（`cargoFileURL` 只解析 workspace 根，外部依赖根不映射）；右键菜单按节点提供 Go to Source / Open Cargo.toml / Refresh Cargo。**与 RustRover 的已知差异**：RustRover 双击 target = 创建并运行其 run 配置（实录证实），Lithe 当前双击 = 导航，待 B7a3 执行服务落地后对齐为运行，验收表保持未对齐标记。新增 `CargoTreePresentationTests` 6 项；Swift 套件 1115 项通过；安装版 GUI 实测（净化 PATH 启动）双击导航成功。
- **第四个迭代：以反编译实据校正树形与点击语义（2026-09-07）**。前一迭代的树形结论来自录屏观察，本次改为读取本机 `~/Applications/RustRover.app/Contents/plugins/intellij-rust/lib/modules/intellij.rustrover.core.jar` 中 `org/rust/cargo/project/toolwindow/*` 的字节码常量池，据此校正三处：
  - **树形（原结论有误）**：`CargoSimpleNode$Root.buildChildren` 无条件为每个 cargo project 生成 `Project` 节点，RustRover **从不隐藏顶层**；单成员时看起来「以成员为根」，是因为 `Project.buildChildren` 按 `pkg.contentRootPath == project.rootDirPath` 把**根包摘出来**、其 `Targets` 直接挂到 Project 下，而不是顶层消失。原 `showsWorkspaceNode(members.count != 1)` 在「多成员且有根包」形态下与 RustRover 不一致。现改为 `CargoTreePresentation.layout` 返回 `projectName`/`rootMember`/`nestedMembers`：项目节点恒在且取根包名（虚拟清单则取工作区目录名，不再是字面量 `Workspace`），根包 targets 提升，其余成员保留自身行；分组标签改为大写 `Targets`。
  - **双击（原「已知差异」已消除）**：`CargoProjectsTree$1.mouseClicked` 仅在 `clickCount >= 2 && isLeftMouseButton` 且选中节点为 `Target` 时，用 `launchCommand()` + `CargoCommandLine.forTarget(...).run(...)` 直接执行，取不到命令则只记 warn，**从不导航**。Lithe 去掉了 `openSource` 兜底：能解析到运行配置就选中并启动，否则无动作；导航保留在右键 Go to Source。
  - **检测器缺口**：`detectors/cargo.rs` 原只认 `[[bin]]` 与 `src/main.rs`，`src/bin/*.rs`、`src/bin/*/main.rs` 产生的 bin 目标在树里可见却无配置可跑。现补齐两种约定发现、与 `[[bin]]` 取并集（Cargo 语义：声明不关闭自动发现，`autobins = false` 才关闭），命令补 `--package`。
  - **仍未对齐（明确保留）**：lib/test/bench/example 双击。RustRover 走 `cargo build --lib` / `test --test N` / `bench --bench N` / `run --example N`，Lithe 的 `RunConfiguration` 只携带 id/name/kind、由 `RunService` 按 id 反查条目，没有临时运行通道；经确认按「不膨胀运行配置列表」取舍，这些目标双击保持无动作。`ProjectMetadataTarget.runnable`（含 example-bin）是「Cargo 能否构建」，`cargoBinaryConfigurationID` 是「检测器是否真的生成了配置」，两者语义不同，已在代码注释中写明。
  - **性能**：`cargoManifestURLs` 原在每次渲染重扫全量工作区文件表（两条侧条 `isVisible` + Cargo 头部约 7 处 disabled 判定）。实测该扫描 1k/5k/20k/50k 文件分别为 4.42/18.62/74.83/205.19 ms，全部在主线程。现改为先按文件名过滤再 `standardizedFileURL`（同输入结果逐项一致，实测提速 8–9 倍），并按「工作区 + 已应用扫描 id」记忆化到 `CargoTreePresentation.manifestCache`（不放 AppModel，聚合器有 1800 行上限）。另在 `loadProjectServices` 末尾加 `prewarmCargoProject()`：项目服务就绪后后台跑一次 metadata，点击图标不再触发 `rustup which` ×2 + `cargo metadata`。仅进程内预热，不做跨会话持久化。
  - 验证：`cargo test -p lithe-core` 350 项通过（含 3 项新检测器测试）；`CargoTreePresentationTests` 10 项通过；Swift 套件 1119 项通过（须传 `-Xlinker -force_load -Xlinker .../liblithe_core.a`，否则 53 项因 `RustCoreBridge().isAvailable == false` 失败）；`verify-rust-core-comments`、`verify-rust-core`、`verify-shared-contracts`、`verify-core`、`verify-service-boundaries` 均通过。**未做 GUI 实测**：本次仅跑自动化验证，未启动安装版对照 RustRover 并排截图。
- **第五个迭代：修复第四迭代遗留的两处 GUI 回归（2026-09-07 晚，用户实测报告）**。第四迭代自述未做 GUI 实测，用户点击即暴露两处：
  - **树形退化为四层**：`rootMember` 按 `snapshot.workspace` 匹配根包——但契约里 `workspace` 定位恒为宿主工作区根（`relativePath` 恒为 `.`），根包永远匹配不上，树多出宿主目录名根节点与成员行。改为以**附着 manifest 的目录**为锚（`layout`/`reconcile` 增加 `manifestDirectory` 参数，视图从 `cargoManifestURL` 相对宿主根计算）；第四迭代测试夹具把 `workspace.relativePath` 写成了 cargo 根（生产核心从不发出该值），已同步修正为真实契约值。
  - **双击无任何反应**：target 行被包成 Button + `simultaneousGesture(TapGesture(count:2))`，在 List 内双击手势被吞，`activateTarget` 从未触发。恢复为已验证的纯行 + `onTapGesture(count: 2)` 形态（List 保留单击选中，a11y 默认动作仍触发运行）。
  - 验证：Swift 套件 1119 项通过、Rust 检测器 28 项通过、注释门禁通过；调试实例 GUI 实测树为三层 `scrap_url → Targets → scrap_url`，双击后运行配置被选中且程序真实运行（rust.md mtime 22:53 为证）；重打包替换安装版后，以净化 PATH 启动复验三层树形，并通过 target 行的无障碍默认动作再次触发真实运行（rust.md mtime 23:04 为证）。第四迭代「未做 GUI 实测」的缺口至此补上：树形四层回归与双击失灵在自动化测试中不可见，只有真实点击能暴露——后续涉及点击语义的子批必须包含 GUI 点击验收。
- **双击运行可见性补齐（2026-09-07 深夜，用户实测报告）**：双击已能启动进程但 Run 工具窗口不打开、输出不可见，用户看到「弹出 run scrap_url 却没有像 RustRover 一样命令行运行 cargo run 并输出结果」。两处补齐：`startCargoTarget` 启动时打开底部 Run 工具窗口（`isRunVisible = true`）；`RunView` 新增 `onChange(of: feature.moduleSessions)`——session 出现且无手动选中时自动跟随 `feature.selectedConfiguration` 的 session。安装版 GUI 实测：双击后 Run 窗口自动弹出并选中 scrap_url，右侧显示配置详情（provider `cargo.binary`、工作目录 `simple/scrap_url`、参数 `run --bin scrap_url`）与带时间戳的进程输出（`$ cargo run --bin scrap_url`、Finished/Running/程序 stdout 三段齐全），与 RustRover 行为一致。

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

首次读取禁止静默下载工具链、改源码/manifest/lock/module 文件。Cargo 用 `metadata --format-version 1 --no-deps --frozen`，防 rustup 首次自动安装须由解析器选择已安装实体工具链并验证。Go 从 `go env -json GOWORK GOMOD` 与 `go work edit -json` 只读定位，再以 `GOTOOLCHAIN=local`、`GOPROXY=off`、`GOSUMDB=off`、只读 module 模式读取 `go list -m -json` 和逐 module `go list -e -json ./...`；go.work 根不能简单执行 `./...`。以上 Go flags 只是候选读取策略，尚未证明 workspace 零写：Go modload 即使 readonly 仍可能写 go.work.sum。B7a2 实施前必须以官方源码及缺 sum/有缓存依赖 fixture 验证隔离 sum/work 文件的方案，或使用已证明不触发写入的元数据命令组合；未通过前不得接自动刷新。**该验证已完成**：go1.24.4 上候选策略确实会写 `go.work.sum`，可行的隔离做法只有一种，结论与实施约束见[Go 元数据只读读取](goland-parity-go-metadata-isolation.md)。捕获层明确禁用 -modfile/-test/-compiled；审查 GOFLAGS、GOPRIVATE/GONOPROXY、GOCACHEPROG/GOAUTH 等会改变下载或外部命令行为的继承配置。清理/覆盖策略须在代码审查中落实，不用项目脚本启动工具。缓存缺失/不兼容显示可操作失败，不擅自执行 go mod tidy、cargo fetch 或安装工具。显式依赖更新/下载另有用户动作。

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

B7a2a 验收记录：[第十五批](goland-parity-iteration15-acceptance.md)。后续细化见[捕获方案](goland-parity-project-tool-capture.md)。

B7a2b 验收记录：[第十六批](goland-parity-iteration16-acceptance.md)。

B7a2c1 验收记录：[第十七批](goland-parity-iteration17-acceptance.md)。后续读取与工作流
细化见[项目元数据读取](goland-parity-project-metadata-refresh.md)。
