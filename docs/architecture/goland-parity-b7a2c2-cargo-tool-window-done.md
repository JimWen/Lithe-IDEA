# B7a2c2：Cargo 读取与右侧工具窗口

状态：已完成（2026-09-08）。双击运行修复、独立代码审查及修复复核、自动化回归、
真实 Cargo 读取与运行验收、ARM64 打包和最新系统安装替换均已完成。
本轮证据见[验收摘要](#cargo-acceptance)。原始刷新与右栏提交为 `4f41da49`。
承接 [读取策略](goland-parity-b7a2c-project-metadata-refresh.md) 与
[B7 总方案](goland-parity-b7a-go-cargo.md)。本批交付真实 Cargo 工作区树、manifest 选择、
刷新、取消和错误重试；Build/Test/Run/Clippy 等独立任务仍属于 B7a3。
Project 和用户已有三份语言方案的修改保持原样。

## 1. 操作与展示

Rust execution module 的静态 contribution 注册右侧 Cargo 入口；catalog、factory、
module instance、renderer 四处使用同一声明。入口资格只依赖已启用模块和当前已发布
文件清单中的 Cargo.toml，不启动探测进程。命令通过现有 catalog/action registry，
tooltip 使用实际生效快捷键。没有默认快捷键，不制造空任务按钮。

manifest 下拉来自同一文件清单：根目录优先，其余按路径深度和 UTF-8 路径排序。
选择一份 manifest 后读取其完整 workspace（包括其余 member）；打开目录与返回的
Cargo workspace 根可以不同。刷新或停止期间禁用 manifest 切换，避免并发读取。
树展示 workspace、默认 member、member、target、source 与 diagnostics，沿用工作台
字体、图标和按钮；声明数据不标为完整依赖解析或可构建证明。
隐藏恢复保留选择；切项目清空。复用既有右栏容器，本批不修改分隔条或声称停靠已对齐。

## 2. 分层与数据

`CargoMetadataNativeContracts` 是 package 级窄 port，不改变公开插件 v1 ABI。
request 冻结 workspaceURL、generation、manifestURL、候选顺序、显式 Cargo 选择、
环境输入和单调期限。`MacCargoProjectComposition` 从现有 ProjectRuntimeService
取配置；View 不查文件系统或解析 metadata。

native preparer 返回只属于本轮的 opaque session，保存工具/文件身份和相关输入
检查信息，提供 0 或 2 个工具解析 command、metadata command、一次性 root mapping
与最终 validate。所有同步工作在该 refresh 的串行 worker 执行；native 不启动进程。
本批不创建新的临时目录，使用经检查不落在源码内的系统临时目录。

Cargo 候选保持已有顺序；用户显式工具无效不能偷偷换工具链。被动检查原生可执行
格式和文件身份，拒绝未知 script shim；以已安装 rustup 的身份识别 symlink/hardlink
proxy。proxy 只经已有语言 capture 执行 `rustup which cargo`、`rustup which rustc`，
保留 RUSTUP_HOME/TOOLCHAIN 与真实 cwd，设置 RUSTUP_AUTO_INSTALL=0。严格核验
0/2 输出、UTF-8 和单路径行协议，实体工具及配对再次核验。metadata 使用实体 Cargo
和 `--no-deps --frozen --color never`，不通过 proxy 探测版本或触发安装。

环境从空字典按读取策略构造，保持正常 Cargo config/CARGO_HOME 和 registry index
解析；不继承任意 Run env、profiling、wrapper、credential、DYLD 等控制变量。
无 with-deps 或下载 fallback。

root 授权只读取 typed metadata 的 workspace_members 对应 packages、manifest_path、
dependencies.path 和 targets.src_path。所选 manifest 必须对应返回根或 member，
native 核验声明文件/目录及符号链接真实身份。外部 member/dep 只映射自身目录，
外部 source 只映射精确文件；不从 Core 错误推断授权，不映射 `/`。本轮映射一次冻结，
后续改变时重新建立 metadata incarnation，不能沿用旧目标。

## 3. 刷新所有权

Execution graph 持有 `CargoProjectFeatureModel`，状态明确为 idle/loading/stopping/
ready/failed，snapshot 与错误独立发布。语言 module 仍唯一拥有 native capture。
feature 从动作开始就持有工作任务和 lease；每轮及每个 capture/Core stage 使用新 UUID，
全流程共享 30 秒期限、16 MiB stdout 预算和单独 stderr 预算，逐 stage 缩减。
进入 normalizer 前逐项验证 operation ID、成功退出、真实双 EOF 与 cleanup。

worker 上的 native 准备、Rust normalization、宿主编解码都计入总期限；返回后重验
workspace/provider generation、工具配置和相关文件身份。取消会阻止下一 stage，
调用 Core cancel 并等待语言 capture 停止。Core cancel=false 不能代表未来操作已取消。

`LanguageProjectToolResource.retire()` 在旧 gate 首次关闭时同步发布一次 retirement
事件；现有 AppModel runtime observer 立即使对应刷新失效，覆盖 provider 激活等待、
两个 capture 间隙及 normalization。不能等 module.shutdown 事件才处理，因为资源
清理失败时该事件可能不发出。workspace 身份来自 AppModel，不能用 runtime 构造时
固定的 context.workspaceURL。

Execution graph 的 isActive/lease/stop 纳入 metadata。stop 真实异步等待，旧 gate
关闭后不能再刷新；cleanupFailed 保留 owner/session/lease，接收迟到 finished 后才
释放。Execution 激活拒绝 scope 内遗留 active graph resource；releaseGraph 不丢弃
未停止 graph。既有 Run 的替换行为不改，metadata 不生成运行配置或停止用户任务。

## 4. 双击运行与配置生成

二进制目标通过现有 Run 工作流执行。双击时先等待当前工作区扫描被执行模块消费，
然后按目标的稳定 configuration ID 查找配置。缺少配置时打开 Run，并进入现有的
Identify and Generate / Rescan 确认流程；用户确认后以当前扫描生成配置，保留项目和
本机覆盖配置，再运行原目标，不改跑生成器默认选中的入口。生成失败停止续跑；生成
成功仍找不到目标时只报告一次，不重复弹出生成确认。工作区切换或重新打开后，旧的
待运行动作不能跨 opening 继续执行。

Run 输出选择由 `RunFeatureModel` 持有：显式启动或重跑选中目标 session，视图隐藏
时也更新；后续输出到达不抢走用户手动选择。打开 Run 同时切换底部工具，避免
Terminal、References 等先前的选择遮住运行结果。

Rust 检测器按 Cargo 的 edition / autobins 规则发现目标：2015（含省略 edition）
在声明 bin 时默认关闭自动发现；新 edition 默认合并，显式 autobins 优先，支持
workspace 继承 edition。显式重命名的源码不能再被约定发现重复生成另一个 bin。

<a id="cargo-acceptance"></a>

## 5. 验收摘要（2026-09-08）

本轮基线 `3d97c080`（包含用户的架构文档整理）；以下修复与本验收记录一同提交。
复核修复了四类问题：输出未跟随第二个目标、其他底部工具遮住 Run、
Cargo 目标发现与实际 Cargo 不一致，以及缺配置时只报错而无法继续运行。
独立 `cargo_final_review` 审查发现一项 P2：检测器过早按名字合并候选，显式重命名
`src/main.rs` 后可能漏掉同名的 `src/bin/app.rs`。已改为先按显式路径过滤，再按
名称去重排序；新增回归覆盖 main、平铺 bin、目录 bin 的四种组合，旧实现确定失败。
修复经独立复核，无剩余阻塞问题。其余配置生成续跑、工作区身份、输出选择和测试
清理逻辑通过审查。原始记录为 `.artifacts/cargo-fix-validation/final-review.md`。

### 自动化与真实 Cargo

- Swift 全量 **1124 项通过**，Rust Core **354 项通过**。最新 Swift 全量用时
  34.663 秒；修改的 Swift 用例最长 408 ms，四个新增 Rust 用例分别为 6/7/7/8 ms。
  定向测试覆盖无视图输出选择、手动选择不被后台输出抢走、诊断 session、底部工具
  切换、扫描延迟、生成后运行原目标、生成失败不运行。等待有本地期限，测试不启动
  真实 Rust 工具链；模型和临时工作区均有清理路径。
- `verify-rust-core.sh`、test-stability 静态门禁、service/module boundary、shared
  contracts 和 `git diff --check` 通过。最新 Swift 修改后重新跑全量及边界检查。最终独立审查的小修仅改变 Rust
  检测器，本轮重新通过 Rust 全量、Core 桥接构建与 18 项真实 Swift metadata 测试；
  沿用已经完成的 GUI 点击与 Swift 全量验收，不重复运行 GUI。
- 真实 `cargo metadata --offline --no-deps --format-version 1` 与 C ABI
  `runConfig.generate` 对照 **12 种场景全部通过**，且逐个运行每个生成的 bin：
  modern 重命名入口、默认/显式 2015、autobins 开/关、继承 modern/2015、嵌套独立包，以及上述四种同名候选组合。
- 计时、JUnit 和 HTML 报告：`.artifacts/test-stability/cargo-fix-{swift,rust}.*`；
  定向报告为 `cargo-fix-focused-swift.*`。已检查报告及失败/性能数据；浏览器本地
  URL 策略不允许直接打开 HTML，因此从工作区读取 HTML 与对应 JSON 检查。

本轮主要命令（在仓库根目录执行）：

```sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  --report .artifacts/test-stability/cargo-fix-focused-swift.json -- \
  --filter 'RunEntryPointTests/cargo|RunConfigurationIntegrationTests/(explicitRunLaunchesFocusTheirOutputWithoutStealingLaterManualSelection|failedRunLaunchFocusesItsDiagnosticSession)' \
  -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  --report .artifacts/test-stability/cargo-fix-swift.json -- --skip-build
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
  --manifest rust/Cargo.toml --package lithe-core \
  --report .artifacts/test-stability/cargo-fix-rust.json
./scripts/verify-rust-core.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-module-boundaries.sh
./scripts/verify-shared-contracts.sh
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/cargo-fix-validation/package" \
  ./scripts/package-app.sh
```

### GUI 与安装

- 调试版和系统安装版均以 `PATH=/usr/bin:/bin`、`--open-project` 打开包含 legacy
  与 modern 两个嵌套独立包的测试工程，Cargo 能发现实体工具链并显示正确目标树。
- 实际点击通过：manifest 选择、Expand All / Collapse All、隐藏后恢复项目与展开
  状态、刷新、无效 TOML 的可见错误、恢复原清单后重试。读取前后 **12 个**源码、
  manifest、lock 文件的 SHA-256 完全一致，证据为 `refresh-validation.json`。
- 无配置时首次双击 beta → 确认生成 → 自动执行
  `cargo run --package modern --bin beta`，输出 `modern_BETA`。随后 alpha/beta
  切换、已有 session 重跑、隐藏 Run 后双击恢复、从 Terminal 双击切回 Run 均通过；
  显式重命名入口输出 `modern_RENAMED`，未出现多余包名 bin。
- ARM64 产品包构建通过（前轮 Swift 完整构建 172.33 秒，最终修复后增量构建
  5.10 秒）。已替换 `/Applications/Lithe.app`，安装前后
  `codesign --verify --deep --strict` 通过，已核对可执行文件 SHA-256 一致；原安装
  留在本轮产物目录的 `.backup` 中以便恢复。安装版实际输出 `legacy_RENAMED` 和
  `modern_BETA`，后者同时验证 Terminal 到 Run 的切换。最终 Rust 检测器修复后再次
  替换安装包，并重验签名与可执行文件哈希；按用户确认沿用已有真实点击证据，
  不重复 GUI 验收。最终安装标识与前轮 GUI 构建哈希均记录在 `installation.json`。
- 验收结束已退出调试版和安装版，删除临时调试应用目录，并核对没有遗留 Lithe、
  capture helper、终端宿主或本轮 Cargo 示例进程；最终 12 个文件哈希仍与基线一致。
- 原始证据位于 `.artifacts/cargo-fix-validation/`：`compare.py` / `compare.log`、
  `refresh-validation.json`、`debug-renamed.png`、`installed-legacy.txt`、
  `installed-beta.txt` / `.png`、`installation.json`。构建日志位于
  `/tmp/lithe-cargo-fix-package.log` 与 `/tmp/lithe-cargo-final-package.log`。前轮构建包含
  已有编辑器/Terminal 的 Swift actor
  isolation 编译警告，本轮修改没有引入新的编译错误。

### 范围与剩余项

本轮参考已打开的 RustRover Cargo 树和 Run 命令/输出行为；未声称像素完全一致、
亮色对照或全工具栏能力一致。没有改分隔条或新增拖拽状态写入。
lib/test/bench/example 的双击仍按已确认范围保持无动作；本轮实测 lib 不触发运行。
独立 Build/Test/Clippy/临时任务与完整 Cargo 参数支持仍属 B7a3，整体 GUI 对齐属
B7a4，Go 工作流仍未实施，父文档不应加 `-done`。

本功能范围已完成实现、独立审查及适用验证；按用户要求标记 `-done`，仅将
B7a2c2 结项，保留父方案及后续子批的未完成状态。
