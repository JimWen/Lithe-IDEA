# B4 Terminal 设置分批方案

状态：B4a0–B4a3 已完成独立方案/代码审查、985 项完整 Swift 测试及 ARM64 实际点击验收，见 [本批验收记录](goland-parity-iteration7-acceptance.md)。其余 B4 核心设置仍未完成。Project 保持当前实现，B1 已完成项跳过。

## 首批 B4a0：设置不得中断活动终端

审计基线中，Settings → Terminal 的默认 shell 控件存在 `.onChange` 副作用，调用 `restartActiveTerminal`；后者沿 TerminalFeatureModel → TerminalSession.start → stop 终止现有进程。这与页面“用于新终端会话”的说明冲突，优先于添加其他设置。

最小修复：删除这个设置控件的自动重启副作用，继续通过 AppSettings 保存默认 shell，不改现有终端启动、停止和显式 Restart API。

新会话已经由 AppModel.createTerminalSession 每次读取 settings.terminalShellPath；System 通过 transport 解析默认 shell。TerminalSession.start 已保存实际 selectedShellPath，旧 session.restart() 使用该快照，保留原 native surface。无需新增配置层或更换 SwiftTerm。Restore Defaults 修改 shell 也不得重启现有会话。

验收必须操作真实已挂载的 Settings 控件：

1. 隔离 QA 创建两个终端，记录各自 shell PID，运行有持续输出的测试命令。
2. 打开 Terminal 设置，切换默认 shell；原 PID 与命令保持，第三个新终端采用新 shell。
3. 显式重启旧终端仍采用它原本的 shell，Restore Defaults 不额外重启活动会话。
4. 清理测试命令、终端和 QA 应用，保留用户自己打开的安装版与内容。

不新增仅设置 AppSettings 值的伪回归测试：旧故障位于 SwiftUI onChange，不挂载真实控件不会触发。沿用现有 terminalSessionKeepsNativeSurfaceAndOwnsLifecycle / terminalSessionRestartUsesExistingSurfaceAndSelectedShell 生命周期测试；后者只覆盖显式 restart(using:)，无参 Restart 的旧 shell 保留由本批真实点击记录补齐，加完整 Swift 检查、产品构建、边界与 diff 检查；独立代码审查后单独 commit。

## 停止进程的验收修复

### 验收发现的 B4a1：重复回收子进程崩溃

2026-09-06 实际点击旧终端 Restart 时，QA 崩溃栈落在 MacStoppedChildProcessReaper.reapWhenExited 的重复注册分支，libdispatch 报 `Release of an inactive object`。当前代码先创建未激活的 DispatchSourceProcess，再发现同一 PID 已有 source 后提前返回，导致新建 source 被未激活释放。

最小修复在同一锁内先合并同一 PID 的 completion，再为首次注册创建、设置 handler 并激活唯一 source。WNOHANG 的立即回收与登记同样放在这个临界区内，避免登记/回调删除交错；完成回调仍在锁外调用，不能引入锁内等待进程退出。平台文件所有权不变，不修改 SwiftTerm。

回归使用 stdin 管道保持存活的真实系统子进程，连续对同一 PID 注册两次回收；关闭写端释放进程后两个回调各一次完成，并验证已经 waitpid 回收。所有 fd、子进程、gate 有明确清理与 deadline；另保留现有立即退出子进程用例。独立审查此修复后实施，并重新执行完整测试、构建和实际 Restart / Restore Defaults 验收。此问题使此前 ARM64 包不能作为最终验收包。

### B4a2：Restart 后旧 bash 及作业残留

修复崩溃后实际点击再次发现旧 bash 仍存活。交互 bash 忽略 SwiftTerm 发送的 SIGTERM，单纯等待回收不能使其退出。独立 agent `terminal_review` 已审核以下设计：

- 启动成功时在 macOS adapter 保存 PID 与启动时间；停止时确认同一进程仍是本应用的独立 PTY session，先取一次有限成员快照，再关闭 SwiftTerm transport，避免旧退出回调污染重启后的 surface。
- 对同 session 的正 PID 逐个复核身份后发送 HUP/CONT，子进程先于 root。按 session 枚举覆盖前台作业自己的进程组；200ms 后复核并 KILL，随后 1s 截止检查。旧 worker 只持有旧 launch 的数据，不访问新 view.process。
- 重扫必须存在仍存活的已知成员作为身份锚点；身份改变或离开 session 不发送信号。启动时间检查与 kill 之间仍有很短的系统调用竞争窗口，不声称完全消除 PID 复用风险。
- 首次 stop 取走 launch ownership；后台清理由平台静态 DispatchGroup 持有并有固定截止。AppDelegate 在已有异步项目关闭后等待该组，再回复退出，涵盖已关闭 tab 的清理；普通 Restart 不阻塞等待退出。
- 测试真实交互 bash、忽略 HUP/TERM 的独立 job group、有界升级、重复 stop、新终端存活、不同 session/启动身份不接收信号。以实际点击验证 Restart 的旧 shell/命令退出，并验证恢复默认不打断活动终端。

### B4a3：隔离重启前后的 PTY 回调

强化 B4a2 回归后发现：新 shell PID 存活，但 `terminal.isRunning` 为 false，发送的新 printf 标记无返回。SwiftTerm 的 LocalProcess 在旧 PTY 的 EOF 回调中修改 running/childfd；复用同一个 LocalProcess 会使旧回调破坏新启动。

保留同一个 LitheTerminalView / SwiftTerm.TerminalView（renderer、nativeView 身份不变），每次启动创建独立 MacTerminalProcessConnection / SwiftTerm.LocalProcess。停止时先使连接回调失效，再关闭 transport；旧回调只触及旧 LocalProcess，不能向当前视图 feed 内容或通知新会话终止。MacTerminalTransport 通过公开 TerminalViewDelegate 接通当前连接的输入、PTY resize、标题、cwd、剪贴板和链接，保持既有行为；不修改 SwiftTerm 源码、不更换终端引擎。

回归必须在旧清理完成后验证新连接 isRunning、实际输入/输出标记、nativeView 身份、另一会话状态；实际 UI 还需点击 Restart 后输入命令，核对 resize/stty、标题和终端右键行为。该设计再次经 terminal_review 审查后实施。

## 后续 B4a 核心设置

在已有 PTY/SwiftTerm 上补 shell 参数/login、cwd 策略、env、venv、字体/字号/回退/行距、scrollback、光标和选择行为。启动配置只影响新会话，显示配置按 transport 能力应用；配置快照、路径失效、env 不入日志和恢复默认逐项验证。Zed 为核心设置参考，具体参数方案需再次独立审查后实施。

Keymap 预设/导入、Editor 核心行为、Plugins 设置入口及资源主题分开推进，仍按总计划 B4/B5 验收，不在修复默认 shell 副作用后勾选完成。
