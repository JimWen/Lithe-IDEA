# B3a / B4a0–B4a3 验收记录

日期：2026-09-06。分支：`dev/aiide`，实施基线：`cb892c85`。本批跳过已验收 B1，按用户要求保持 Project 当前实现；仅交付搜索请求/输入正确性和终端设置/进程生命周期修复，不代表 B3/B4 整体完成。

## 审查与交付内容

| 批次 | 结果 | 独立审查 |
| --- | --- | --- |
| B3a | 激活前后请求代际与工作区身份校验；清空/关闭拒绝旧返回；替换 preview/apply busy 分离；键盘监听绑定所属窗口并尊重 IME、修饰键和原生光标编辑 | `search_review` 方案及代码通过 |
| B4a0 | 默认 shell / Restore Defaults 仅影响新会话，活动终端不自动重启 | `terminal_review` 方案及代码通过 |
| B4a1 | 同 PID 回收注册共享唯一已激活 DispatchSource，修复 Restart 的 libdispatch 崩溃 | `terminal_review` 方案及代码通过 |
| B4a2 | 按进程启动身份与 PTY session 清理 shell/独立作业组；有界升级信号；退出应用等待已关闭 tab 的清理 | `terminal_review` 方案及代码通过 |
| B4a3 | 每次启动独立 LocalProcess/连接，保留原 TerminalView；旧 EOF/输出/退出回调不影响重启后的输入 | `terminal_review` 方案及代码通过 |

审查发现的 root/成员快照丢失、进程清理失败路径、回调可重入及应用退出提前结束问题均已修正。未修改 SwiftTerm 或其他第三方源码。

## 自动检查

使用 Swift 6.2.4，执行：

```sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./scripts/verify-service-boundaries.sh
git diff --check
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/goland-parity/iteration7-package" \
  ./scripts/package-app.sh
```

- 完整测试 **985 项、103 个 suite，通过，32.133 秒**；harness 调用 `scripts/test-macos.sh`。HTML/JUnit 已生成并查看。
- 最慢新增用例 `restartStopsBashAndResistantJobWithoutStoppingNewOrOtherSessions` 为 **1.552 秒**，包含真实 PTY 与强制停止宽限期；超过 1 秒提示阈值，未超过 15 秒上限。重复回收回归 **0.001 秒**。
- 新增 **2 处 `swift-real-sleep` scanner 例外**，均只在测试失败清理中使用：分别有 2 秒单调时钟 deadline，对真实 OS 子进程进行独立回收；不用于等待正常业务状态。正常路径通过事件/gate 同步。
- 强化测试时，`#expect(AnyObject === AnyObject)` 触发 Swift 6.2.4 SIL reabstraction 断言崩溃；改为宏外计算 Bool 再断言，保持比较语义，重新编译通过。
- ARM64 Release 完整构建通过。保留 3 处基线已有 actor-isolation 警告，位于 EditorAreaView、EditorTabFlowLayout、TerminalTabDragPayload；与此前构建日志一致，本批未增加同类诊断。
- 无 Rust Core/共享协议修改；不要求已移除的 Windows 产品构建。

日志与归档：`.artifacts/goland-parity/iteration7-search/` 中的 `full-tests-terminal-final.log`、`arm64-package-final.log`、`test-stability/index.html` 与 `test-stability/macos-swift.junit.xml`。

## 实际应用验收

使用隔离 QA bundle 和 fixture，先调试构建定位问题，再以最终 ARM64 Release 二进制及资源验收。所有操作由真实鼠标、AppleScript 键盘事件和 AX 状态观测完成；截图已逐项核对。

| 操作 | 可观察结果 | 主要证据（相对上述目录） |
| --- | --- | --- |
| 双 Shift、查询内左移插入、Tab、Esc | `abcd` → 左移 → 插入 `X` 得到 `abcXd`；Tab 选中 Classes；Esc 关闭 | `search-release-caret.png`、`search-release-category.png` |
| Find in Files 查询与键盘预览 | `package` 在 9 个文件中找到 9 处；Down 将预览切换到 command_registration.go；Esc 关闭 | `find-release-results.png`、`find-release-keyboard-next.png` |
| 更改默认 shell | 两个原 zsh PID 与持续输出保留；新建终端采用 bash | `terminal-pids-after.json`、`terminal-new-default-bash.png` |
| Restore Defaults | zsh/bash 两个原 PID 保留、两个测试命令继续输出，默认 shell 回到 System default | `terminal-debug-restore.json`、`terminal-debug-restore-defaults.png` |
| Restart | Release 中 bash 34150 退出、新 bash 34230 正常接收命令并输出；另一 zsh 33515 保留 | `terminal-release-restart.json`、`terminal-release-restart-working.png` |
| 缩放与 OSC 标题/cwd | PTY 尺寸从 26×166 变为 22×136；标题变为 Lithe PTY QA，实际 cwd 为 /tmp | `release-tty-before.txt`、`release-tty-after.txt`、`terminal-release-resize-title-cwd.png` |
| 粘贴和剪贴板 | Cmd+V 命令执行；OSC52 写入与查询返回预期标记；测试后恢复原剪贴板全部格式 | `terminal-release-clipboard.png`、`release-clipboard-query.txt` |
| 终端文件链接和右键 | Command-click 打开 fixture notes.md；右键显示 Copy/Paste/Select All/Clear/Restart/Close Terminal | `terminal-release-link-opened.png`、`terminal-release-context-menu.png` |
| 应用退出 | 含忽略 HUP/TERM 的前台作业时，应用及其 4 个子进程全部退出，约 1.424 秒；Release QA 及子进程亦全部退出 | `terminal-debug-shutdown.json`、`terminal-release-shutdown.json` |

QA 应用与命令已清理，并移除 QA 的 LaunchServices 登记。用户原安装版未参与破坏性验收。IME、其他窗口、嵌套 sheet、请求倒序及重启 surface 身份通过原生/可控回归验证，不把这些自动测试写成已进行人工输入法验收。

## 保留事项

搜索 scope 的未保存缓冲区、替换原文校验/跨文件事务/整体 undo、最近项与统一 Find/Replace 布局继续归 B3b–B3d。其他 Settings、主题/插件、重构、入口运行、Go/Cargo、Structure/TODO、语言 L0–L7 与 Git G1 仍按总计划实施；本批不勾选这些项目。

终端以启动时间和 session 复核身份，避免常见延迟 PID 复用错误；检查与发送信号之间仍有系统调用竞争窗口。主动脱离 PTY session 的 daemon 不纳入本批停止范围。无法确认身份时不向任意 PID 或进程组兜底发送信号，截止异常写入诊断。
