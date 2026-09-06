# Terminal 虚拟环境支持方案（B4a6）

状态：范围与风险已由 `terminal_review` 只读核查；启动后应用机制尚待详细设计及独立审查，本文件不代表已实现或通过验收。B4a5b2 已验收，不改 Project，不扩展 Python 包管理器或 managed Run/Debug。

## 复用边界

B4a4 已完成 shell、参数、login、工作目录、自定义环境、创建与 Restart 快照；B4a5b1 已验收，b2 已验收。这些入口继续复用，不另建 PTY、解释器服务或设置存储。新增功能只针对新建的交互终端。

`TerminalShellConfiguration` 增加检测开关与有序候选目录，旧配置缺字段时采用默认值。macOS 检测器从最终解析的终端 cwd 读取候选，结果进入 `TerminalShellLaunch` 的内存快照。检测失败不阻止普通 shell；显示配置变化不触发检测或重启。Restart 复用最初选中的环境，失效时明确降级，不暗中改用另一个环境。

默认候选拟为 `.env`、`env`、`.venv`、`venv`，相对于终端 cwd，只检查指定目录，不递归扫描、不跨项目查找。参考 [Zed detect_venv 配置](https://zed.dev/docs/reference/all-settings#terminal-detect_venv)。候选顺序、范围、空白/NUL/长度校验、相对路径规范及未知字段兼容需要在实现前固化。

Python 设置分类依赖项目文件索引，不能作为检测是否运行的门槛。用户明确配置的当前项目解释器可作为后续候选来源，通过纯值上下文传入；一期不据此引入全局环境选择器。

## 发现与应用分开

发现阶段只读文件系统：检查候选目录、普通 `pyvenv.cfg`、可执行 `bin/python` 或 `bin/python3`。正常解释器符号链接应可用，不能把执行路径解析成基础 Python 后丢失 venv 的位置语义。`.env` 普通文件、缺失文件、断链或不可执行环境均不是有效候选。探测不启动解释器、包管理器或项目激活脚本。

环境发现不等于 shell 已激活。Python 可以直接使用环境内解释器而无需执行 activate；Zed 的终端实现则会向新 PTY 写入激活命令。不能将这两种机制混写为同一保证。参考 [Python venv 说明](https://docs.python.org/3/library/venv.html#how-venvs-work)、[Zed terminal 实现](https://github.com/zed-industries/zed/blob/main/crates/terminal/src/terminal.rs)。

Lithe 默认启动 login shell，本机系统 zsh/bash profile 会运行 `path_helper`；仅在 spawn 时把 venv/bin 前置到 PATH，之后可能被启动脚本重排。因此实施前必须确定受控的初始化阶段，而不能只验证 VIRTUAL_ENV 或创建进程成功。

下一次方案审查需定下：

- zsh/bash 在保留原参数、login 与用户初始化文件行为的同时，怎样在正确阶段应用环境；路径只作为数据，避免字符串拼接成可执行代码。
- 如何识别可支持的交互 shell；未知 shell、显式 `-c` 和脚本参数的降级行为。不能向任意程序盲写初始化命令。
- 完成/失败/取消的确认协议，绑定具体启动代次；不以固定延迟、首个输出或 isRunning 代替初始化完成，不覆盖抢先输入的用户命令。
- 显式 PATH、VIRTUAL_ENV、PYTHONHOME 与继承环境之间的优先级；已有虚拟环境是否保留。
- 新建、Restart、环境被删除、初始化超时之间的行为；错误可诊断，但不记录完整环境或脚本内容。
- 固定产品 hook 的生命周期与同一代次迟到执行的诊断；第二轮已选择不执行项目 activate、不发送 PTY 初始化命令。

Restart 使用该次启动保存的原始环境基线，不从当前设置或 ProcessInfo 重建。hook 若在修改中失败，撤销时应恢复用户 rc 已执行后、自动 venv 应用前的 PATH/VIRTUAL_ENV/PYTHONHOME 及各自 unset 状态，不能用 spawn 前 PATH 覆盖用户 rc 的合法更改。超时仅表示未确认，不承诺已经回滚。

这一阶段尚未定案，不先提供只有 UI 或只设置变量的“自动激活”开关。

## 启动机制的第二轮只读审查

`terminal_review` 对原生 shell 和接线复核后，建议采用启动 hook 加单向确认，不向 PTY 发送初始化命令。此处记录可实施方向及尚需固化的细节，不等同于功能已完成。

- **zsh：** 私有 `ZDOTDIR` 转发原 `.zshenv/.zprofile/.zshrc/.zlogin`，保留真实 `-l`；login 在用户 `.zlogin` 返回后应用，非 login 在 `.zshrc` 返回后应用。须恢复用户 ZDOTDIR 的设置或未设置状态，尊重 `RCS`，验证用户初始化文件改变 ZDOTDIR、history、logout 的行为。来源：[zsh 启动顺序](https://github.com/zsh-users/zsh/blob/master/Doc/Zsh/files.yo)。
- **bash：** `--rcfile` 不能直接与原生 login startup 叠加；VS Code 用手工加载 profile 模拟 login，不能据此声称完整保留 `login_shell`、argv 和 logout 语义。保留真实 `-l` 的候选方案是在原标量 `PROMPT_COMMAND` 后附加一次 hook；用户 rc 覆盖或重排时明确未确认，不强行覆盖。来源：[Apple Bash shell.c](https://github.com/apple-oss-distributions/bash/blob/main/bash-3.2/shell.c)、[VS Code shell integration](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh)。
- **应用内容：** 产品固定脚本只用带引号的变量值调整 PATH/VIRTUAL_ENV/PYTHONHOME，不 source 项目 activate，不执行项目 Python，不通过路径生成 eval，不改提示符。只对目标根 shell 执行一次；须验证用户 rc 启动子 shell 时不会提前激活或污染子环境。可评估固定 POSIX exec shim 保存根 PID，再 exec 原 executable/argv，shim 不读取 stdin。
- **确认：** 复用 `Terminal.registerOscHandler`，无需追加 SwiftTerm 补丁或自建流解析器。hook 发有界的 launch nonce、根 PID 和结果码；MacTerminalTransport 对当前 connection/代次校验后更新独立 activation state，不包含完整环境。实际输入仍照常交给 shell。
- **超时：** 定义为“未收到确认”，不能显示“已回滚”。不靠输入补救，不自动终止用户可操作的 shell；同一代次的迟到确认允许更新状态。Close/Restart 才通过现有拥有的进程终止链路取消旧启动。若进一步要求超时后绝不能激活，需单独设计原子的取消/应用协议。

`TerminalSession.startShell` 目前只向 transport 传 process/environment，需新增保留完整初始化计划的普通 shell 入口；managed `startProcess` 不接受该计划。Restart 保存原 cwd、argv、环境基线和选中环境路径，每次创建新的 nonce/hook 资源。`restart(using:)` 保留快照并重新判断新 shell 支持程度，不能悄悄重新发现另一个环境。

首批参数拟只接受空参数、`-i`、`-l/--login` 及明确解析的组合；`-c`、脚本、`-s`、restricted/POSIX、自定义 rcfile 和未知参数保持原启动行为并提示未自动激活。完整参数解析、继承环境优先级、hook 生命周期与资源清理还需在实施方案中形成确定契约。

任意 bash rc 的自动激活、严格原生 login 语义、无 stdin 注入三者目前不能同时保证；以明确兼容范围和未确认诊断交付，不用固定延迟或盲发命令掩盖边界。

## 验证与交付

只读检测使用临时自有目录验证候选顺序、cwd/多项目隔离、开关、普通 `.env` 文件、缺失/断链/权限以及含空格、引号、`$()` 的路径。恶意 activate 文件作为不可执行探测的回归素材，不能在扫描中运行。

真实 zsh/bash login PTY 验证 `command -v python`、`sys.executable`、`sys.prefix` 与选中环境一致；同时验证新建与 Restart 的不同语义、其他终端 PID 不变、环境消失后的降级，以及初始化取消后无剩余自有进程。测试遵守本仓库有界等待与进程身份清理规则。

完整方案审查通过后，按检测/启动接线、设置与真实验收分批实现；每批执行相关测试、全量 macOS 检查、ARM64 构建、实际点击截图、独立代码审查和本地提交。
