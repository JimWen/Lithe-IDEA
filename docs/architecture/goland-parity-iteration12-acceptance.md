# Terminal 历史、输入与选择设置验收（B4a5b2）

2026-09-06，分支 `dev/aiide`。本批实现 B4a5b2，代码提交 `266c0c52`；焦点、窗口路由、完整测试及 ARM64 Release GUI 已复验，测试进程已清理，按功能与文档分批提交。Project 保持不改；venv、其他 Settings、Refactor、Go/Cargo 与语言插件计划继续保留。

## 行为与边界

Settings → Terminal 新增历史行数、光标形状/闪烁、Option as Meta、滚动倍率、选择即复制、手动复制后保留选区、链接识别和打开修饰键。所有选项接入既有显示配置订阅与原生 transport，不重建会话。旧字体配置缺少新字段时按原默认行为解码。

历史默认 2000，允许 0–100000；0 禁用 scrollback，减小容量前取消拖选并清除选区，界面提示历史裁剪。滚动倍率为有限数 0.05–10。字体、历史、滚动和其他字段独立校验、应用；缺失字体不阻塞合法输入设置，也不将失败字体请求记为成功。

光标设置是用户默认，新进程 reset/setup 后重新应用；运行程序可用 DECSCUSR 覆盖，其他设置变化不会夺回程序选择的样式。Option as Meta 复用 SwiftTerm 原生输入，不改 PTY 协议。

选择即复制比较实际端点、Buffer 身份及裁剪代次，仅复制改变后的非空本地选区；相同文字的不同位置仍视为不同选区。自动复制保留选区，手动复制按选项保留或清除。程序鼠标报告优先，并保留 Shift capture 语义。点击终端先把键盘焦点从编辑器移回原生终端，避免 Metal 绘制层转发鼠标后键盘仍停在编辑器。

链接的 click、hover、report、preview 共用识别策略，关闭会清掉旧预览。无修饰键单击等待系统双击间隔，第二次按下、拖选、隐藏、重置、历史裁剪及策略改变会取消待打开动作；Command-click 立即打开。鼠标归属在按下时确定，程序随后关闭 reporting 不会让松开事件误打开链接。取消手势同时取消原生选区自动滚动，旧定时回调不能续滚。

SwiftTerm 固定 1.15.0，扩展现有可逆补丁中的选择快照、链接策略、鼠标手势取消和窗口事件分发，不修改 parser、PTY 或升级依赖。第一方拥有配置、复制规则、焦点与延迟动作；没有新增 SwiftUI 鼠标高频状态、父页面重建或自定义 splitter。

窗口内终端与编辑器共用第一响应者链。跟踪区域使用 `inVisibleRect`，在初始零大小、布局、缩放和裁剪后自动跟随可见区域；移动和修饰键事件复用 SwiftTerm 已有的按窗口共享监控，所有支持的 macOS 版本采用同一方式。第一响应者走 AppKit 原有投递，其余可见终端由监控补发鼠标移动；两条路径均过滤错误窗口、隐藏父视图和可见范围之外的移动。最后一个终端注销后恢复窗口原来的 `acceptsMouseMovedEvents`，跨窗口和释放均清理监控。

修饰键显示与 Kitty 键盘输入分开：后台终端仅更新链接显示，键盘事件仍归当前第一响应者。鼠标事件使用自身 flags；修饰键事件读取窗口真实鼠标位置，避免键盘事件无意义的坐标。Command 松开先清旧预览，再判断是否需要无修饰键 hover；不要求继续移动鼠标。该窗口监控仅在应用活跃期间投递，不承诺后台应用鼠标悬浮报告。没有新增 SwiftUI 高频状态或独立手势系统。

## 审查与验证

`terminal_review` 放行 b2 方案；`workbench_audit` 审查实现，要求补齐完整双击序列、原生拖选定时器清理和按下时的鼠标归属，三项修复后通过。`terminal_exit_review` 审查真实 PTY 用例的超时/清理，要求保存重启前后全部进程身份，修复后通过。GUI 发现的点击焦点修复、统一窗口路由与非焦点 Command 悬浮方案及实现亦经独立审查放行。

实际 GUI 驱动最初极速提交四个 CGEvent，系统漏送第二次 mouseUp；事件 trace 确认后，验收驱动采用明确的 40 ms 事件节奏。临时 trace 已从源码移除，不随产品交付。另修正验收脚本将 Project 文件按钮误认为编辑器标签的断言。上述验证问题与随后发现的真实焦点缺陷分别记录。窗口路由测试通过真实 NSApplication local monitor；命令行测试宿主没有 key window，modifier 用例在监控之后显式补齐 fixture NSWindow 的正常 responder 投递。完整前台窗口链路由实际 GUI 复验。视图释放由 deinit TestGate 有界等待，覆盖 SwiftTerm 已排队 redraw 对视图的短期持有。

证据目录为 `.artifacts/goland-parity/iteration12-terminal/`。最终完整 macOS 测试 **1024 项 / 110 个套件通过**；测试运行 31.296 s，包含增量编译的命令总耗时 69.856 s。12 项既有耗时预警，0 失败、0 硬预算超限。HTML 仪表盘已实际打开，核对模块健康度和新增用例：原生 PTY 225 ms、视图释放 20 ms、Command 悬浮 4 ms。报告冻结为 `verified-macos-swift.json/.junit.xml/.html` 和 `verified-index.html`。

使用 Swift 6.2.4，完整优化构建 178.70 s，通过 ARM64、严格签名、资源/许可证/修改说明核对；SwiftTerm 66 份上游文件反向补丁校验通过。保留既有编译告警，无编译器崩溃。服务边界、稳定性静态门禁、双语资源 plist 与 `git diff --check` 均通过；未修改 Rust 源码。

主要命令（均在仓库根执行，Swift 6.2.4 位于 PATH）：

```sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/goland-parity/iteration12-package" ./scripts/package-app.sh
./scripts/verify-service-boundaries.sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
node scripts/verify-swiftterm-source.mjs
git diff --check
```

## ARM64 实际操作证据

最终验证包 UUID 为 `FA730AA0-497D-3B72-BC3E-A3608FC533ED`。隔离 QA app 只改 bundle 身份；移除签名后的临时副本 SHA-256 与产品一致，证明实际运行同一份代码。测试宿主中的 CoreGraphics 原生窗口用例和正式应用的 Metal 绘制分别验证，没有把测试中的 renderer fallback 当作 Metal 验收。

| 实际操作 | 结果与证据 |
| --- | --- |
| 编辑器持焦点的普通/Command 悬浮，鼠标不动时 Command 按下/松开 | `release-routing-hover-results.json` 全部通过；`release-routing-editor-focused.png`、`release-routing-command-hover.png` |
| Settings 关闭返回、窗口改宽、隐藏与恢复终端、移出终端 | 同上 8 项结果全部通过；`release-routing-settings-return.png`、`release-routing-resize.png` |
| 完整双击选择链接而不打开，单击打开本地 `.go` 文件 | `verified-release-selection-results.json`；`verified-release-double-link-selection.png`、`verified-release-single-link-open.png` |
| 同文字不同位置均自动复制，手动复制清选区 | 同上；`verified-release-copy-same-different-range.png`、`verified-release-manual-copy-clears.png`，剪贴板由隔离 guard 恢复 |
| Option as Meta、TUI 按下后关闭鼠标报告再松开、不误开链接 | `verified-reporting-result.json`：字节 `1b781b5b3c303b343b314d71`；收到 ESC+x、SGR press、q，无超时 |
| TUI 改成 steady bar 后调整滚动倍率 | `verified-release-reporting-cursor.png`，光标仍为程序选择的样式 |
| 历史 500 可回滚，改成 0 不保留 scrollback | `verified-history-results.json`；0 模式滚动前后图像一致 |
| 同一滚轮事件，倍率 1.5/0.5 改变移动量 | `verified-history-fast-after.png` 首行 566，`verified-history-slow-after.png` 首行 574 |
| 禁用链接与其修饰键控件 | `verified-disabled-results.json`；无预览、无打开，`verified-release-disabled-settings.png` 显示禁用控件 |

拖选越过终端上沿时隐藏面板，恢复后迟到 drag/up 不再继续选择或滚动；`verified-drag-results.json` 全部通过，恢复前后截图保持一致。

显示与输入更新全过程保留当前 PTY。新进程/Restart 的默认光标和真实 Option 字节由原生 PTY 测试覆盖；前批启动快照和字体热更新验收继续有效。


## 清理与后续范围

`verified-cleanup.json` 确认最终 QA app、其 shell 及全部自有后代进程已退出，剩余 Lithe/helper 为零；已移除 QA LaunchServices 注册和临时 saved state，关闭报告浏览器与 HTTP 服务。没有向外部仓库发送消息或 push。

B4a5 显示/输入批完成。venv 仍为预研，见 [虚拟环境方案](goland-parity-terminal-venv.md)；未将它或其他 Settings、Refactor、Go/Cargo、语言/插件批次标记完成。Project 保持不改，用户原有语言方案未纳入本批提交。
