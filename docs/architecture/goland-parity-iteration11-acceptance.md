# Terminal 字体设置验收（B4a5b1）

2026-09-06，分支 `dev/aiide`。实现提交 `4f74218a`，本批落实已审查方案 `e8f75688` 中的字体、字号、有序回退、行高和持久化。B4a5b2 的历史、光标、输入、复制/链接以及 B4a6 venv 仍待实施；不将本批等同 Terminal 或一期整体完成。Project 保持不改。

## 行为与边界

Settings → Terminal 提供原生可输入字体下拉、字号、行高、回退列表增删/排序、刷新字体目录和失败重试。字体目录通过 macOS port 延迟加载，显示名称与 PostScript ID 分开；保存真实 ID，拒绝 CoreText 静默替换缺失字体。目录刷新不创建终端进程，未开启 Terminal 时也能提示缺失字体。

`TerminalDisplayConfiguration` 与 shell 启动快照独立持久化。未知/损坏载荷保留并给出诊断，运行终端不受阻；显式编辑或恢复默认可修复。字号、行高与完整字体列表为一个原子组；任一字体无效时已有会话保留整组最后成功值，新会话采用默认组。失败不更新成功缓存，可用同一请求重试。

AppModel 持有唯一的 capability 配置订阅，使用发布值而非 willSet 期间的旧属性；未激活模块不被唤醒，激活后使用最新值。普通、运行、调试三类会话均在进程启动前应用显示配置；现有会话热更新保留 native view、PTY 和进程，不重建 shell 或重写启动参数。原生 transport 调用前批已经验收的 `updateTypography`，本批没有再改 SwiftTerm。

实际点击发现原生输入未失焦时直接 OK 丢失草稿，已修复：关闭/恢复默认前结束原生编辑；字体控件同时在所属窗口将关闭时提交草稿，迁移/销毁清理观察者。外部值更新同步文本与下拉选择索引，防止恢复默认后显示旧选中项。

## 审查与自动验证

`terminal_review` 放行分批方案与原子失败语义；`workbench_audit` 独立复核实现、原生选择索引、无会话诊断、编辑提交生命周期，以及实际 GUI 证据。Release 回退字形补证后最终结论 GO。

Swift 6.2.4；本批执行：

```sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./scripts/verify-service-boundaries.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  --filter 'TerminalDisplayConfigurationTests|TerminalActivationTests|MacTerminalConfigurationTests' \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/goland-parity/iteration11-package" ./scripts/package-app.sh
git diff --check
```

最终 focused4：13 项 / 3 suites，0.429 秒；full：1012 项 / 108 suites，执行 30.304 秒，命令总时长 32.102 秒，全部通过。实际浏览 HTML，失败/超时/硬预算超限为 0，12 项已有性能提示。新配置测试 1–4 ms，订阅回归 7 ms，真实 PTY 协议测试 228 ms。报告冻结为本批 `final-macos-swift.json`、JUnit 与 HTML，原始日志为 `focused4.log`、`full-tests.log`。

覆盖独立持久化、损坏/未来版本恢复、有限范围/字体列表校验、目录懒加载与刷新、三类会话更新顺序、订阅取消和激活期间最新配置、无效字体原子保留与恢复。真实 PTY 回归通过 transport 的显示配置入口改变字体，验证 PID/view/Terminal 不变、DECRQM 回复和 Up 的 ESC OA 字节、实际窗口网格同步。

早期 focused2 触发 Swift 6.2.4 在 Swift Testing 宏内处理 AnyObject `===` 的编译器 signal 6；将身份比较先计算为 Bool 再断言，保留同一验证语义后 focused/full 编译通过。保留失败日志，不改语言模式或关闭优化。

## 实际点击与截图

证据位于 `.artifacts/goland-parity/iteration11-terminal/`。

| 场景 | 结果与证据 |
| --- | --- |
| 未失焦保存 | 实际输入后直接 OK 保存 Menlo-Regular，红色关闭保存 Menlo-Bold，恢复默认清除未提交值；重新打开复核，`font-input-lifecycle-debug.json` |
| 原生下拉与回退列表 | 菜单可保持展开并选择，显示名映射为 AcademyEngravedLetPlain；回退排序/删除保留预期 ID，`debug-font-dropdown.png`、`font-picker-debug.json` |
| 持续输出热更新 | shell 26203 与输出进程 28241 全程保持；字号13→18、行高1→1.3，网格27×166→15×120，中文/emoji/粗斜体正常，`hot-update-debug.json`、`debug-hot-before/after.png` |
| 缺失字体与恢复 | 无效字体+24号保留原15×120及18号外观；恢复有效字体后11×91，期间输出持续，`debug-hot-invalid.png`、`debug-hot-invalid-retained.png`、`debug-hot-recovered.png` |
| 隐藏/恢复 | Debug 工具窗隐藏后恢复，shell PID仍为26203，`debug-hide-restore.png` |
| Release 回退字体实际字形 | 同一缓冲区不重印，仅 PingFangSC-Regular→STSongti-SC-Regular；Menlo18/1.3 不变，中文四种样式均切宋体，Latin 比较区域像素差0、CJK区域27262；`release-fallback-pingfang/songti.png`、`fallback-pixel-comparison.json`，独立审查重新计算一致 |
| Release 已有/新会话 | 已有 shell30898 保持15×120；新 shell31383 使用当前配置也是15×120；关闭提交、隐藏恢复通过，`release-qa-result.json`、`release-new-session.png`、`release-hidden-restored.png` |

ARM64 完整优化构建169.44秒，UUID `CDE2B042-D1EF-3E18-9950-9755093E8F66`，本次没有编译器崩溃。保留3处既有 actor isolation 编译警告（EditorAreaView、EditorTabFlowLayout、TerminalTabDragPayload），不扩大本批修改范围。架构、严格签名、helpers、shader、许可证与双语资源核对通过；未运行 universal/DMG。

隔离 bundle ID 的 QA 与产品包移除签名后的代码 SHA 完全一致，见 `release-code-identity.json`。重新签名导致原始二进制 SHA 不同，不能以此误判为不同源码构建。

## 清理与交付

Debug/Release QA、实际 PTY 和输出任务均已结束；没有 Lithe 或数据库 helper 残留。QA 已取消 LaunchServices 注册并清理 saved state，HTML 报告浏览器及临时 HTTP 服务已关闭，见 `cleanup-final.json`。

实现与验收文档分批本地提交，未 push。文档提交后按既有授权重新打包构建身份、核对同一代码 UUID，再替换安装 `/Applications/Lithe.app` 并删除旧备份；准确安装身份记录于 `install-result.json`。用户未提交的语言方案文档保留原状态。

下一批继续 B4a5b2、B4a6、Refactor、Go/Cargo 与语言/插件计划；[显示设置方案](goland-parity-terminal-display.md) 保留尚未完成的范围。
