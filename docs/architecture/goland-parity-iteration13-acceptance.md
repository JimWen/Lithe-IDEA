# Terminal 虚拟环境验收（B4a6）

2026-09-06，分支 `dev/aiide`，代码提交 `3724ea20`。本批完成普通交互终端的虚拟环境检测、启动后应用、设置、Restart 快照和退出恢复。Project 保持不变；其他 Settings、Refactor、Go/Cargo 与语言/插件批次仍未完成。

## 审查与修复

[实现契约](goland-parity-terminal-venv.md) 经 `terminal_review` 原生 shell 原型和 `workbench_audit` 模型/生命周期独立审查后实施，代码与测试最终均 GO。

真实验证修复了四项问题：异步检测后启动失败仍显示“检测中”；手动切换标准 venv 后旧 PATH 残留；deactivate 将原本未 export 的变量导出；macOS 全局 zshrc 将默认历史文件指到集成资源目录。每项修复均再次执行对应验证。确认超时表示未确认，不伪装成回滚；readonly、已有用户环境或激活函数不会被覆盖。

产品仅新增 7 个固定 shell 资源，不安装 Python、不 source 项目 activate、不发送 PTY 初始化命令，也没有修改第三方代码。探测全局最多两个真实 worker，1 秒 deadline；初始化确认独立使用 5 秒 deadline。Startup 标签是产品启动结果，不是任意后续手动环境修改的实时追踪器。

测试曾出现一次等状态超时，随后固定测试继承环境，并在输入前等待明确的 fixture prompt。原生脚本同序“收到 ACK 立即 deactivate”额外 3 次通过；最终产品测试同时覆盖独立 ACK 与真实提示符，未将观察到 ACK 等同于 shell 已进入读行状态。GUI 驱动也修正了 AXStaticText 应读取 AXValue、AXValue 对象地址不适合作为焦点身份，以及打开 shell 菜单后不能把旧终端的 active 状态当成新终端就绪等断言问题。

## 自动验证

完整 macOS **1032 项 / 111 个套件通过**，测试运行 32.811 秒，包含增量编译的命令耗时 70.817 秒；0 失败、0 硬预算超限、12 项既有性能预警。新增 8 项共 507 ms，最慢为 Restart/恢复真实 PTY 259 ms、超时/Clear/迟到 ACK 236 ms。HTML 报告已实际打开并核对。

独立产品脚本 **42/42 场景通过**，8.804 秒，另有 **3/3** 立即 deactivate 顺序验证。覆盖 zsh/bash login/logout、特殊字符路径、实际 Python prefix、子 shell/subshell、用户 rc 环境、PROMPT_COMMAND 覆盖/追加、readonly、空/未设 ZDOTDIR、RCS、历史写回、命令哈希、标准 venv 切换、set/unset/export 恢复。资源集合及 7 个源脚本 SHA 均未被测试修改。

Swift 6.2.4 完整优化 ARM64 构建 **162.82 秒**通过，无 Swift 编译器崩溃，保留既有编译告警。服务边界、共享 fixture、测试稳定性门禁、双语资源 plist、`git diff --check` 均通过。SwiftTerm 66 个上游文件反向补丁校验通过；本批没有 Rust 或第三方源码变更。

主要命令（Swift 6.2.4 位于 PATH）：

```sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/goland-parity/iteration13-package" ./scripts/package-app.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
git diff --check
```

## ARM64 实际点击与截图

验证包 UUID：`BE6F22D2-9CA9-3F7C-80AB-646037F82D93`。隔离 QA app 与产品包移除签名后的可执行文件 SHA-256 同为 `5bbf1f6510e2bd84932d55799732fd68d21bdc87ebe6ce28c452f5139111678a`，实际运行的是同一份代码。

证据目录 `.artifacts/goland-parity/iteration13-venv/`：

| 实际操作 | 结果 / 证据 |
| --- | --- |
| Settings 添加并编辑候选目录，关闭/开启检测 | `release-venv-settings.png`、`release-venv-disabled-settings.png`；配置实际保存并影响新终端 |
| 新建 zsh，无额外终端点击直接输入命令 | `release-active.json` 中 Python executable、prefix、VIRTUAL_ENV、PATH 首项均指向选择的环境；`release-venv-activated.png` |
| deactivate，再 Restart | `release-deactivated.json` 环境清除、PID 不变；`release-restarted.json` 新 PID 恢复原环境；`release-venv-restarted.png` |
| 修改开关后检查已有终端和其 Restart，再建新终端 | `release-existing-after-disable.json`、`release-existing-restart-disabled.json` 保留原选择；`release-disabled-new.json` 不激活 |
| 移走所选目录、Restart、恢复同目录再 Restart | `release-missing.json` 普通 shell 可操作、显示设置入口；`release-restored.json` 恢复原选择；`release-venv-missing.png` |
| 返回最初普通终端 | `release-original-still-plain.json` 与 `release-original.json` PID 相同且无 venv，证明其他会话未重启或串环境 |
| 原生 bash login | `release-bash.json` 实际 Python prefix 对应所选环境；`release-venv-bash.png` |
| bash 用户 profile 覆盖 PROMPT_COMMAND | 实际等待确认 deadline 后显示未确认，`release-bash-unconfirmed.json` 证明普通命令仍可用；`release-venv-unconfirmed.png` |
| 用户 rc 等待期间切到编辑器，放行后确认激活 | `gui-focus-result.json` 焦点/选择保持，编辑器接受输入且撤销恢复；`release-venv-editor-focus-retained.png` |
| 初始化中的终端执行 Close Terminal 并确认 | `gui-cancel-result.json` 记录其 shell 与测试 helper 都退出；`release-venv-cancelled.png` |

设置、激活、缺失提示和焦点截图均已实际查看。此批没有修改 splitter、拖动行为或增加高频 UI 状态。

## 产物与清理

`resource-validation.json` 核对 QA/产品资源与源码完全一致，运行后无新增历史文件，签名仍有效。`full-test-report/` 冻结完整 HTML、JSON、JUnit、日志；`product-resources/review.html` 与 `review-findings.md` 记录独立脚本验收。

`cleanup-result.json` 确认 QA app 及最后 8 个自有后代退出，剩余 Lithe/helper 为零；已移除 QA LaunchServices 注册和 saved state，关闭测试报告浏览器及 HTTP 服务。验证包用于按既有授权替换安装，结果保存为 `install-result.json`；安装前后核对 revision、ARM64 UUID、去签名代码哈希，旧备份和 staging 不保留。

bash 任意用户 rc 覆盖、zsh 全局 rc 的 `.zkbd` 查找及第三方 activate 对旧空变量的自身语义边界，见实现契约。B4a6 的普通虚拟环境流程已验收，未将上述兼容边界、其他 Settings 或剩余功能计划标记为完成。
