# B7a2c2：Cargo 读取与右侧工具窗口

状态：刷新与右栏实现已提交（`4f41da49`），后续修复与交互对齐见 B7 总方案中的
GUI 记录；完整点击、零写入、对照、ARM64 产品包验收及独立代码审查尚未全部完成。
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

## 4. 验收

先做 native 身份、环境、root 和输入失效测试；workflow 用确定性 gate 控制取消、
停用、迟到结果及清理失败，再核验 catalog/factory/renderer 一致和多 manifest 选择。
运行 focused/full Swift timing、Core/边界/稳定性检查、ARM64 产品构建和独立代码复审。
实际打开应用，点击 Cargo/选择 manifest/展开目标/刷新/失败重试/隐藏恢复，截图与
RustRover 对照；检查真实 Cargo 读取前后源码/manifest/lock 零改动。结束关闭测试
应用及其 owned processes，分批本地 commit，不 push。最终结果另写验收记录。
