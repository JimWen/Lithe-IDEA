# Terminal 核心设置：启动、显示与虚拟环境

状态：基于 `5d4a45c6`，B4a4 已通过方案/代码独立审查、997 项完整测试与 ARM64 点击验收，实现提交 `db44d036`，见 [本批验收](goland-parity-iteration9-acceptance.md)。用户最新优先级为 Terminal、重构、Go/Cargo 与语言/插件；已验收 B4a0–B4a3 跳过，Project 暂停。本文细化 [B4 Terminal 方案](goland-parity-b4-terminal.md)，不缩减总目标。

## 现状与实施顺序

当前 Settings 只有 system/zsh/bash 默认 shell；启动固定 `-l`、当前项目目录和宿主环境，显示固定 13 pt / 2,000 行。已有独立 argv 的 `TerminalProcessLaunch`、environment set/unset、稳定 session/native surface、PTY 连接与停止清理继续复用。

Zed 参考为前轮本机截图 `.artifacts/goland-parity/iteration5-planning/zed-terminal.png`（本轮查询时 Zed 未运行），以及 [官方 Terminal 配置](https://zed.dev/docs/terminal)、[完整设置参考](https://zed.dev/docs/reference/all-settings#terminal)。主要对照 shell/arguments、工作目录、env、venv、font/fallback/line height、scrollback、cursor/blink、Option Meta、selection/copy/link。页面分组和控件遵循当前 Lithe Settings，参数必须有真实消费者。

| 子批 | 交付与依赖 | 完成证据 |
| --- | --- | --- |
| B4a4 | 自定义 shell、独立参数、login、cwd 策略、env set/unset、不可变 Restart 快照、启动错误 | 设置持久化/旧值迁移；原 PID 保留；真实 argv/env/cwd；Restart 同快照；另一项目与 managed process 不受污染 |
| B4a5 | 字体/字号/回退/行高、scrollback、光标/闪烁、Option Meta、复制与滚动/链接配置 | 保留 PTY/内容与 TUI 模式；实际字形/光标命中/选择/快捷键；配置重开与恢复默认；安全热更新证明后交付 |
| B4a6 | Python venv 探测/激活，支持关闭、目录顺序和已选环境 | shell rc 后 Python/PATH/VIRTUAL_ENV 一致、prompt/deactivate 契约、不同 shell 与显式配置优先级、无终端输入竞争 |

B4a4 是启动配置链路；字体和虚拟环境不会作为只有 UI 的占位项加入。B4a5/6 仍是 Terminal 完成条件。重构 B6、工具栏 B7 和语言 L0–L7 随依赖分批推进，不因本文拆分而取消。

## B4a4 契约与所有权

`LitheTerminalModule/Models/TerminalShellConfiguration.swift` 定义 Codable/Equatable/Sendable 的纯值配置、cwd policy、上下文与已解析 launch 快照；无 AppKit/进程/文件访问。配置含 system/zsh/bash/custom、custom program、`[String]` arguments、login、current project/current file/first project/home/custom directory、`[TerminalEnvironmentChange]`。每个参数独立编辑，空参数与含空格参数保持完整，不按空格切分，不做 shell 插值。

`AppSettings` 保存版本化配置到既有 KeyValueStore。缺少新配置时从 `settings.terminalShell` 迁移；保留旧 raw 值和访问器，旧 system/zsh/bash 行为一致。Restore Defaults 恢复整个终端配置，不触发会话 restart。新增字段有默认值；未知版本/损坏载荷保留原存储并给出设置页诊断，用户明确编辑或恢复后才覆盖。

诊断存在期间拒绝新启动，不能静默用默认配置代替。toggleTerminal 的首次激活也走同一个捕获/复核入口，不能在 await 后重新读取 settings。自动 `-l` 放在用户 argv 最前；关闭 login 不删除用户显式参数。失败 session 的 Retry 明示重用原始配置；修改设置后通过 New Terminal 使用新配置。完整继承 env 只在 session 内存中保存，不写入配置存储。

`TerminalTransport` 新增 prepare-shell-launch 端口。平台 adapter 提供系统 shell、home 和继承环境，调用纯值计划构造，再复用原生 executable/cwd 校验；最终快照包含绝对 executable/cwd、完整 argv 和完整 env。不得在 View/Service 构造 FileManager 或读取进程环境。普通配置不进入 Rust ABI，也不修改插件 API。

cwd 在点击新建时捕获：当前文件策略使用当时活动普通文件的父目录；没有文件则当前项目，再 workspace 首 root，最后 home。Lithe 当前每 workspace 只有一个 root，first project 指该 workspace 的首 root，不跨到另一项目 tab。custom 支持绝对路径、`~/` 和相对当前项目路径；失效/非目录明确失败，不悄悄换目录。

环境优先级为继承值 → 现有 TERM/COLORTERM/TERM_PROGRAM → 用户 set/unset；空字符串与删除不同。环境名采用 POSIX 标识符，拒绝重复名、NUL、超限配置；值保持字面文本，包括 `$`、反引号、换行和空格。shell/custom cwd 文本和 argv 拒绝 NUL。错误只给出类别和必要路径，不包含环境值或完整 argv。参数最多 128 项，环境最多 128 项，总 UTF-8 配置文本最多 256 KiB，集中命名限制。

login 开关保留既有 `-l` 行为，开启时仅在 argv 首项不是 `-l` / `--login` 时补入（脚本参数中的同名文本不算 login 选项）。自定义 program 可为绝对路径、`~/` 或 PATH 中名称；PATH 中相对/空项按所选 cwd 解析。最终 executable 校验为可执行的普通文件，允许指向普通文件的 symlink，不能把目录当可执行文件。cwd 同时检查目录存在和 search 权限；当前 SwiftTerm 不回报 child chdir 失败，因此检查到实际 chdir 之间的路径/权限变化仍需后续 startup error channel 解决。固定 SwiftTerm forkpty 回调的 wait status 归一化为 exit code；127 只报观察到的退出结果，不伪造 exec errno。

`TerminalSession` 保存一次已解析 shell launch（包括完整 env），Restart 使用同一份快照，不重新读取 AppSettings、活动文件或当前全局 env。显式 Restart using shell 只更换 program；session ID/native surface 与现有连接隔离保持。初次 prepare 失败保留请求用于用户修复目录/工具后 Retry，并公开可见 `lastError`；失败不能静默变为空白终端。输入/启动错误不复制到日志中的 env。

AppModel 在首次异步模块激活之前捕获配置、workspace/session 身份和活动文件；激活返回后复核所属项目。新的请求不能因 await 期间切换项目而落到别的 workspace。已存在 feature 的同步路径用同样的捕获值。启动失败的 session 仍可见错误并提供 Retry/Terminal Settings，成功重试清除错误。

DAP/Run 的 `startProcess` 使用调用方 executable/argv/cwd/env，完全绕过普通 shell 配置、login 和后续自动 venv。显示设置可共享，但不得把普通 shell 配置套到被调试程序上。

Settings 使用独立 TerminalSettingsView，沿用现有 select/checkbox/button 样式和双语资源；shell、arguments、directory、environment 分组。编辑值即时保存，与当前设置页一致；无效字段显示明确错误，新启动拒绝该配置，活动会话保持运行。参数/环境列表增删时使用稳定行身份，不能因数组索引复用把焦点或值移到另一行。

## B4a5/6 的专项审查点

SwiftTerm 1.15 的公开 font/lineSpacing setter 会经 resetFont/resize 调用 terminal.softReset，可能重置 application cursor/keypad、scroll region、wrap、颜色和 hyperlink。不能每次 SwiftUI 更新重设，也不能把 snapshot 不完整的 restore 当作无损热更新。实施前用公开 API 验证模式保全方案；必要时将字体变更作为原生 renderer 专项处理，保持现有 PTY 和完整状态。不修改第三方 checkout 来绕过审查。

可直接评估的公开入口包括 changeScrollback、setCursorStyle、optionAsMetaKey、scrollSensitivity、selection/getSelection/copy 和 linkReporting。设置要有 diff 和唯一应用所有者。CoreText cascade 字体回退需验证中文/emoji、粗斜体与 Metal 实际绘制；不能仅测 descriptor 属性。光标要明确用户默认与 TUI DECSCUSR 的优先级。

venv 不能在 shell 任意时间发送 `source`，也不能仅注入启动前 PATH 就宣称对齐：login/rc 可能重写它。后续方案明确可控 shell bootstrap/ready、激活脚本与参数引用、prompt/deactivate，以及未知 shell 的能力和错误。完整 argv/env 启动快照为该批提供基础，不依赖伪造按键时序。

## 验证与提交

独立 agent 先审本方案的 B4a4 放行边界，再实施与代码审查；B4a5/6 再细化。自动回归覆盖旧值迁移/未知版本/恢复默认、参数字面保真、全部 cwd/fallback、env set/unset/空值/重复/NUL/限额、Restart 快照、失败 Retry、managed process 隔离和激活期间项目变化。真实平台测试只用自有临时目录与系统 shell，观察输出事件，有 deadline 和失败清理。

运行 stable-tests 静态门禁和 Swift timing harness、完整 macOS 测试、service boundaries、ARM64 包、git diff --check。逐项查看 HTML/JUnit 时间；GUI 操作 Settings、现有长任务、新建/Restart、错误与恢复默认，截图并读取 fixture 的实际 argv/env/cwd。所有测试 app/子进程清理后，按用户授权分批 commit、更新 ARM64 安装，不 push。
