# Terminal 字体更新前置修正验收（B4a5a）

2026-09-06，分支 `dev/aiide`。方案提交 `c2fd2115`，实现提交 `68d51977`；本批修复原生字体/行高更新重置终端模式及同步绘制问题。完整 Terminal 显示设置尚未完成，B4a5b 与 venv B4a6 继续待实现。Project 保持不改。

## 实现与审查

SwiftTerm 仍固定在 1.15.0 / `dd2fb8ac5b861e7bf617c872895e338f38165648`，改为编译最小本地源码包。上游文件清单记录原始 SHA-256；所有上游修改包含于可逆补丁。构建/测试先在临时副本反向应用补丁再核验 66 个原始文件，并检查新增补丁行的空白规范。缺文件、额外文件、未记录源码改动、坏补丁、错误 notice、补丁新增尾空格的负例均失败。原样保留许可证和源码空白；MIT license 与修改说明随 runtime bundle 安装。swift-testing/swift-syntax 版本保持不变，移除仅属于上游 CLI 的 argument-parser 依赖。

字体更新共用正常窗口尺寸变化路径，不执行 DECSTR；批量入口一次更新 font 和 lineSpacing，保留 emulator/view/PTY。字体相关 Metal row、shaping、glyph 和派生字体缓存、caret、搜索与无障碍几何全部刷新，同网格 cascade 变化也生效。公开 resize、parser 和 PTY 未改变。

同步输出期间完整暂存最新字体组合，提交后异步应用，避免嵌套 resize。CoreGraphics 先保存原生 redraw policy，再绘制已标脏的上一提交帧，返回后复核重入结束情况才设置 `.never`；同步结束后恢复原值。Metal 暂停未提交绘制，窗口移动时延迟 rebind，提交后使用当前 window。没有新建屏幕位图缓存，也没有原地修改在途 GPU atlas。

独立方案/依赖审查放行后实现，`workbench_audit` 对最终补丁、缓存、重入、窗口移动、来源与测试再次独立审查，结论 GO。`terminal_exit_review` 确认坏解释器测试的 proc_pidinfo 默认不包含 zombie，改用测试私有 arg=1 查询在主队列回收前捕获完整身份；不消费退出码、不改产品进程行为，最终代码 GO。

## 自动验证

使用 Swift 6.2.4，执行：

```sh
node scripts/verify-swiftterm-source.mjs
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  --filter 'TerminalTypographyTests|MacTerminalConfigurationTests' \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./scripts/verify-service-boundaries.sh
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/goland-parity/iteration10-package" ./scripts/package-app.sh
git diff --check
```

- 最终 focused8：12 项 / 2 suites，通过，执行 0.424 秒。
- 最终 full：1006 项 / 107 suites，通过，执行 30.498 秒，命令总时长 32.001 秒。计时 HTML 已实际打开，失败/超时/硬预算超限均为 0，12 项已有性能提示。新增真实 PTY 测试 230 ms；typography 测试单项 1–7 ms。
- 协议测试检查真实 DECRQM 回复、颜色、OSC8、主/备用 buffer、保存光标/字符集、应用光标/键盘、origin/insert/wrap、bracketed paste。回归覆盖同网格变化、两 setter 顺序、重复同步、即时新配置覆盖 queued 旧配置、dirty draw 重入、窗口 resize 结束同步、零/极小 surface。
- 真实 PTY 测试由系统 Bash 开启 DECCKM 并等待事件；字体变化后原 PID/view/Terminal 保持，原生 Up 输入产生 ESC OA，stty 尺寸与实际 emulator 网格一致，子进程有界退出并回收。

最终源码对应报告冻结为本批 `final-macos-swift.json`、JUnit 与 HTML，原始日志为 `focused8.log`、`full-tests-final.log`。早期 focused/full 文件只是迭代记录，不作为最终验收。

## 图形与交付证据

ARM64 完整优化编译 201.97 秒，UUID 为 `50858866-97FA-34C1-876F-316FC0737A17`，本轮没有 Swift 编译器崩溃。签名、ARM64 架构、数据库 helpers、SwiftTerm Metal shader、完整 license/notice 与双语资源核对通过。没有验收 universal/DMG，不用 ARM64 结果代替它们。

原生图形 QA 链接本次 release 的同一 SwiftTerm 对象文件并使用实际应用的资源 bundle，通过按钮更新字体、继续输出、切换 renderer 和移动同一个 TerminalView。先验证 debug，再复验 release；没有用替代终端或假截图证明成功。

| 场景 | 实际结果与证据 |
| --- | --- |
| Metal 字体与持续绘制 | 明确 `isUsingMetalRenderer=true`，14→16 pt 后中文/emoji/粗斜体正常，继续输出两行；`native-metal-before.png`、`native-metal-after.png` |
| 同步输出时改字体 | Metal 与 CoreGraphics 的提交前/等待中截图逐像素相同；提交后字体和内容才改变。包括同步前已有脏 backing layer；`native-visual-result.json`、`sync-before/pending/after-*.png` |
| 同步期间移至另一窗口 | 保持同一 Terminal 与旧画面，提交后 rebind/字体刷新并继续输出；`native-move-result.json`、`move-before/pending/after-metal.png` |
| Lithe 内真实 shell | 实际点击 Terminal、输入命令，原 PTY PID 21606 输出标记及 `stty size=26 166`；`product-terminal-input.png`、`product-pty.txt` |
| 工具窗隐藏/恢复与菜单 | 恢复后 PID 21606 保持；Terminal actions 可持续展开，Restart 等真实菜单项可见；`product-terminal-restored.png`、`product-terminal-actions.png` |

以上 artifacts 位于 `.artifacts/goland-parity/iteration10-terminal/`。原生 harness 是这次字体 API 的验收入口，产品尚未暴露字体配置页；上述证据不代表完整字体回退矩阵、Settings 热更新或 B4a5 全部完成。

产品 QA 使用隔离 bundle ID 保护安装版偏好，因此重新签名后的二进制 SHA 与原包不同；在临时副本移除签名后两者代码 SHA-256 完全相同（`b5913b97e81937aa32858c910e48d47e79fd0988e8adf923542e136e2e45ced7`）。不是拿旧应用冒充本次构建。

## 清理与后续

原生 QA、产品 QA 和其 PTY 均已退出；检查没有 Lithe 或数据库 helper 残留。QA 已取消 LaunchServices 注册、临时 saved state 已清理，报告预览 HTTP 服务与浏览器页已关闭。证据见 `cleanup-final.json`。文档提交后将按既有授权以 staging 核对并替换安装 ARM64 包，删除旧备份；完成后生成 `install-result.json`。仅本地 commit，没有 push。

下一批依据 [显示设置方案](goland-parity-terminal-display.md) 实现 B4a5b：独立持久化、字体目录、全部现有/新会话热更新、复制/链接策略与 Settings UI，并继续 B4a6、Refactor、Go/Cargo、语言/插件计划。依赖前置已完成不等于 Terminal 或一期整体完成。
