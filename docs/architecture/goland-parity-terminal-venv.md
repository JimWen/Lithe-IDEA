# Terminal 虚拟环境支持（B4a6）

状态：已实现，通过 `terminal_review` 和 `workbench_audit` 的方案、脚本及代码/测试独立审查，并完成完整 macOS 测试、ARM64 构建与实际 GUI 验收。Project 保持不变；此批只覆盖普通交互终端，不扩展 Python 包管理器或 managed Run/Debug。

## 复用与配置

复用 B4a4 的 shell、参数、login、cwd、环境变量与 Restart 快照，以及 B4a5 的持续终端视图。没有引入其他 PTY、解释器服务或设置存储。

`TerminalShellConfiguration` 新增自动检测开关和有序目录列表，旧配置缺字段时默认开启，候选为 `.env`、`env`、`.venv`、`venv`。候选相对于最终终端 cwd，不递归扫描；最多 16 个唯一相对路径，每项最多 512 UTF-8 字节。拒绝空白项、绝对路径、`~` 前缀、NUL、空/`.`/`..` 路径段。合法空格、引号及 `$` 均按原值保留。参考 [Zed detect_venv](https://zed.dev/docs/reference/all-settings#terminal-detect_venv)。

Settings → Terminal 支持添加、编辑、删除目录与开关。稳定行 ID 防止删行后迟到的文本事件修改另一项；使用现有设置持久化和校验提示。显示/字体设置变更不触发检测、重启或环境切换。

显式设置或 unset `VIRTUAL_ENV`/`PYTHONHOME`，或继承非空 `VIRTUAL_ENV`，均保留用户策略，不检测。应用阶段再次保护用户 rc 已有环境、`deactivate` 函数/alias 或 `_OLD_VIRTUAL_PATH`/`_OLD_VIRTUAL_PYTHONHOME`（包括已设置的空值）。PATH 的显式配置作为启动基线，自动环境在用户 rc 后前置。

## 原生发现与快照

`MacTerminalVirtualEnvironmentProbe` 只读检查候选目录、普通 `pyvenv.cfg`、可执行普通 `bin/python` 或 `bin/python3`。允许正常符号链接，保留 logical 环境路径；普通 `.env` 文件、断链、缺失或不可执行文件不能作为环境。探测不执行 Python 或项目 activate。

原生探测全局最多两个实际 worker，无无界等待队列。每次请求 1 秒截止；忙、超时或读取错误返回 unknown，不能伪装成 notFound。取消/超时不释放仍阻塞在系统文件调用的工作槽；真实调用返回才归还槽位，旧结果不继续扫描或启动 shell。最终环境路径含 `:` 时明确降级，因为 PATH 无法表达该单个目录。

`TerminalShellLaunch` 保存原 cwd、argv、继承/显式环境与 disabled、preserveExisting、discover、selected、notFound、unknown 决策。首次发现冻结为具体结果，Restart 不重新扫描；selected 消失时普通启动并保留该 selection，恢复同路径后下一次 Restart 可再校验。新终端才读取新设置。`restart(using:)` 保留快照，重新判断新 shell 的兼容性。

普通 `startShell` 接收完整计划，以完成回调返回已解析快照和进程结果，允许同步完成。Session/native 两层检查代次，native 在 spawn 前也拒绝过期结果，完成回调每请求至多一次；即使 spawn 失败也保存已解析选择并清除检测状态。managed `startProcess` 保留原同步入口，不检测或注入初始化数据。

## 启动后应用

仅设置 spawn 环境不够：macOS login profile 的 `path_helper` 会重排 PATH，含特殊字符的预置 PATH 还可能被其生成的 shell 文本重新解释。Lithe 将路径作为独立环境数据传入，在初始化阶段结束后用带引号的变量修改 PATH。参考 [Python venv](https://docs.python.org/3/library/venv.html#how-venvs-work)、[Zed terminal 实现](https://github.com/zed-industries/zed/blob/main/crates/terminal/src/terminal.rs)。

固定 exec shim、zsh 转发文件和 bash hook 共 7 个只读脚本随应用资源打包，不创建每次 launch 的临时 rc 文件。原环境快照不含注入变量。资源缺失时普通启动并提示，UI 始终展示真正 shell 名称。shim 通过 exec 保持 PID，root PID 加 `ZSH_SUBSHELL/BASH_SUBSHELL == 0` 防止用户 rc 中的子 shell 提前应用。

- **zsh：** ZDOTDIR 转发用户 `.zshenv/.zprofile/.zshrc/.zlogin`，按 unset-only 语义选择 rc 路径，保留原参数和真实 login；非 login 在用户 `.zshrc` 后应用，login 在 `.zlogin` 后应用。最终保留用户 ZDOTDIR，尊重 RCS。macOS `/etc/zshrc` 产生的 bundle 默认 HISTFILE 在用户 `.zshrc` 前被修正为用户目录；用户自定义 HISTFILE 仍最后生效。参见 [zsh 启动顺序](https://github.com/zsh-users/zsh/blob/master/Doc/Zsh/files.yo)。
- **bash：** 保留原生 login，在原标量 PROMPT_COMMAND 后添加一次固定 hook。仅完整 PROMPT_COMMAND 未被用户 rc 修改时应用并恢复原值；用户覆盖时不强行改写，显示未确认；追加等可检测的改动明确跳过。没有用 `--rcfile` 模拟 login。参见 [Apple Bash](https://github.com/apple-oss-distributions/bash/blob/main/bash-3.2/shell.c)、[VS Code 集成脚本](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh)。

兼容参数为无参数、`-i`、`-l`、`--login` 及仅含 i/l 的短选项组合。其他 shell、`-c`、脚本、`-s`、restricted/POSIX、自定义 rcfile 和未知参数维持原启动行为，不自动应用。readonly PATH/VIRTUAL_ENV/PYTHONHOME 被提前识别并跳过，避免赋值中断 shell。

固定应用脚本不 source 项目 activate，不执行项目 Python，不向 PTY 写初始化命令，不使用路径生成 eval，也不改 PS1。保存用户 rc 后的 PATH/VIRTUAL_ENV/PYTHONHOME、set/unset 及 export 属性；`deactivate` 恢复它们、刷新命令哈希并移除自身，不会在下一提示符自动重激活。同步维护标准 `_OLD_VIRTUAL_*`，支持之后手动 source 常规 Python venv 时先移除 Lithe 环境路径。

## 确认、取消与显示

每个 transport 仅注册一个弱引用 SwiftTerm OSC handler，无第三方补丁。固定 OSC 6973，最多 160 字节 ASCII payload，仅包含协议版本、随机 nonce、root PID、结果码。只接受当前 connection/PID/nonce；先完成快照发布，再推进激活状态。

spawn 后 5 秒为确认截止，与文件探测 deadline 分开。超时表示 unconfirmed，保留可操作 shell，不声称回滚；同代次迟到 ACK 可更新。Close/Restart/自然退出/失败会取消定时器和旧状态；Clear 仅清屏，同一 shell 的后续 ACK 仍有效。进程 running/ready 与激活状态分离。

紧凑状态显示启动时环境或跳过/未确认诊断，并提供 Terminal Settings 入口。`Startup virtual environment` 表示最后一次产品启动结果，不假装跟踪用户之后任意手动 source 或环境赋值。异步完成不强制抢焦点。

## 已验证范围与兼容边界

完整 1032 项测试、8 项新增用例、42 个真实 shell 场景和额外 3 次立即 deactivate 场景通过。GUI 使用实际 ARM64 产品代码，验证目录设置、开关、新建、`sys.executable/sys.prefix`、deactivate、Restart、删除/恢复环境、已有终端 PID 隔离、bash 未确认、编辑器焦点与关闭初始化中的进程。详细证据见 [B4a6 验收记录](goland-parity-iteration13-acceptance.md)。

保留两项明确边界：任意 bash rc 的覆盖行为不保证自动激活；zsh 全局 rc 执行期间会看到转发 ZDOTDIR，因此 macOS 全局 `.zkbd` 查找等任意全局脚本逻辑未完整转发，不重复 source 全局 rc。Python 标准 activate 自身对空/未设置的旧 PATH/PYTHONHOME 使用非空判断，跨第三方脚本后的精确空值恢复不由 Lithe 保证；产品自身 deactivate 则已验证 set/unset/export 恢复。
