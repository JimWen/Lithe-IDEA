# Terminal 启动设置验收（B4a4）

2026-09-06，分支 `dev/aiide`。方案提交 `71756d9e`，实现提交 `db44d036`。本批自定义 shell、参数、login、工作目录、环境变量、Restart 快照和失败恢复已验收；Terminal 显示设置与 venv 仍分别属于 B4a5/B4a6，不能据此认定 Terminal 或第一期整体完成。Project 保持不改。

## 实现与审查

复用 Terminal 模块、现有原生 PTY 和 Settings 控件。启动配置按版本保存并迁移旧 system/zsh/bash 选项；不可读/未来版本保留原载荷并阻止新启动。参数逐项传递，环境支持设值、空值和取消定义，明确拒绝重复名、NUL 与超限输入。

工作目录支持当前项目、当前普通文件、工作区首项目、home 和自定义路径。平台校验目录可访问性、可执行普通文件及 PATH 相对项；首次模块激活之前捕获配置和项目 generation。Restart 保留原 executable/argv/cwd/env；普通设置不进入 Run/DAP 启动计划。

`terminal_settings_review` 独立审查方案并放行，随后审查 native 实现及测试。修复 login 判断位置、隐藏普通文档的 cwd、Restart executable 绝对化、SwiftTerm wait status、坏解释器错误、目录 search 权限和测试清理时的 PID 身份问题。测试在 start 后第一次 await 前冻结并确认子进程身份，不能在 cleanup 时认领复用 PID。

`workbench_audit` 独立复核产品代码、另一个 agent 新增的真实 AppModel 激活测试、截图和进程证据，结论通过。截图验收发现的 Program / Value / Environment variables 三个中文资源遗漏已补齐；再次打包、重开并实际核对中文标签。

## 自动验证

所有正式 Swift 构建/测试使用 Swift 6.2.4。下列测试通过既有 wrapper 解析与当前 Rust archive 内容对应的链接路径，保留上一批原生链接修复。

```sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh --platform macos
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  --filter 'TerminalConfiguration|TerminalActivation|terminalSession|TerminalPlacement|TerminalModule' \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./scripts/verify-service-boundaries.sh
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/goland-parity/iteration9-package" ./scripts/package-app.sh
plutil -lint macos/Resources/en.lproj/Localizable.strings macos/Resources/zh-Hans.lproj/Localizable.strings
git diff --check
```

- Focused：28 项 / 6 suites 通过，测试执行 0.181 秒。
- Full：997 项 / 106 suites 通过，测试执行 35.152 秒。已有 Git watcher 等测试有性能提示，无失败或硬预算超限；新增测试最慢为项目切换/同路径重开 23 ms，其次真实 argv/env/cwd 16 ms。
- 新增 native 测试执行真实系统 shell、坏 shebang 退出 127、相对 PATH、目录与权限拒绝；临时目录允许空格，以文件系统 device/inode 比较 cwd，避免 macOS `/var` 与 `/private/var` 写法差异造成误报。
- AppModel 测试实际控制异步模块激活：改设置仍使用捕获值；切换项目和同路径重开后拒绝旧请求；损坏配置保留且不激活终端。等待均有 deadline，结束释放 gate、会话和 runtime。
- ARM64 优化构建完成，最终应用 UUID 为 `780E24C8-3B1D-38D3-98C2-994F5DEAA0FB`。末轮仅补本地化资源，重新打包后 UUID 相同，双语资源语法和签名校验通过。数据库 helpers、官方 Go 插件与 SwiftTerm Metal 资源齐全；退休资源未重新打入。

计时 HTML/JUnit 在 `.artifacts/test-stability/`；本批原始日志、冻结计时 JSON、包资源检查位于 `.artifacts/goland-parity/iteration9-terminal/`。期间曾以 `--help` 探查不支持该参数的 `verify-macos-package.sh`，误触发默认 universal 流程并因系统 Swift 6.0.3 退出；这不计作通过的验证。本批交付与上述独立资源/架构/签名检查范围均为 ARM64，未验收 universal/DMG。

## 实际点击与进程证据

复用隔离 QA 项目，调试包先验证列表，随后使用上述优化包操作。没有用修改偏好文件替代设置页点击。

| 场景 | 观察到的结果与证据 |
| --- | --- |
| 参数、环境行增删与继续编辑 | 删除中间行后首项不变，编辑仍写入 surviving 行；`debug-argument-row-deletion.png`、`debug-environment-row-deletion.png` |
| 设置保存与重开 | 自定义程序、逐项参数、env 重开后保留；`release-settings-persisted.png` |
| 新终端真实配置 | PID 1302，含空格和 `$()` 的参数、空参数原样传入；cwd 为选中目录，env 为原配置；`release-terminal-first-launch.png`、`gui-launch-proof.json` |
| 修改设置不影响现有会话 | PID 1302 保持，计数任务从 1 持续输出至 19；`release-settings-preserve-running-terminal.png`、`gui-running-proof.json` |
| Restart 与新建 | Restart PID 4490，除 PID 外原快照完全一致且旧进程退出；New PID 4510，采用改后 cwd/env/参数；`release-terminal-restart-snapshot.png`、`release-terminal-new-settings.png` |
| 缺目录与 Retry | 错误卡提供原配置重试和设置入口；修改全局目录后 Retry 仍失败，创建原目录后 PID 4766 在该原目录启动并清除错误；`release-terminal-missing-directory.png`、`release-terminal-retry-recovered.png`、`gui-retry-proof.json` |
| 坏解释器与中文 | 明确显示退出码 127，重试/设置操作可见；`release-terminal-exit-error-chinese.png` |
| Restore Defaults | 清除参数/env 与自定义路径，已运行 PID 4490/4510 保持；再次启动应用仍为默认值；`gui-defaults-proof.json`、`release-restored-after-relaunch.png` |
| 双语与布局 | 默认及自定义项、增删后控件无重叠；最终中文程序/环境变量/值均已翻译；`release-chinese-labels-final.png` |

以上截图和 JSON 均位于本批 artifact 目录；目录中的 launch helper 仅供本机验收，不进入产品。恢复默认设置仅操作 QA 应用，不改安装版用户偏好。

## 清理、交付与后续

QA 应用及三个活动 PTY 已逐一退出；末轮资源验证实例也已退出。原生进程清理记录在 `cleanup-first.json`、`cleanup-final.json`；没有剩余 Lithe/helpers，QA 已取消 LaunchServices 注册，临时 shell/目录/计数文件已移除，保留截图与验收结果。安装按既有授权以 staging 校验后替换 `/Applications/Lithe.app`，删除旧版备份；最终安装身份和清理结果见 `install-result.json`。没有 push。

当前 SwiftTerm 不回报 child chdir 失败，父进程预检与实际 chdir 间的路径/权限变化仍需后续启动错误通道。B4a5 的只读审计确认字体/行高 setter 会 softReset，现有公开接口不足以完整保留 VT 状态；不可用零散状态还原或临时编辑 checkout 冒充完成。详细原生 API 证据在本批 `b4a5-native-audit.md`，下一批继续细化显示配置与正式依赖适配方案。B4a6、重构、Go/Cargo、语言/插件和其余已规划要求继续保留。
