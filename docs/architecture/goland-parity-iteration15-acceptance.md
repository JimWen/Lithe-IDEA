# 第十五批验收：项目工具进程清理前置修复

日期：2026-09-06。分支：`dev/aiide`。方案 `d34c109f`，实现 `d6fb2d1f`。

本批完成 B7a2a，为 Go/Cargo 元数据捕获提供可靠的原生进程所有权。B7a2b
双流捕获、B7a2c 只读刷新、独立工具任务和右栏 UI 尚未完成。Project 和用户
已有的三份语言方案文件未修改；本批没有新增可验收的产品界面。

## 实现与审查

- 自然退出、异步停止、同步停止共用一次清理及固定期限；等待者取消或超时
  不取消实际清理、不启动重叠清理。
- 先 waitpid、发布 rootReaped，再等待清理完成后发布旧 running=false 和
  termination callback。停止成功同时需要进程组消失与根回收。
- 失败保留 group 和所有权，后续显式停止可以重试；首次退出通知的清理结果
  独立冻结，不被重试覆盖。回调在锁外，只发送一次。
- 根回收前记录 PID/start-time，枚举前后验证既有成员连续性，发送前重新
  核验身份和组。身份查询暂时失败不丢失既有记录；不能认领复用的同号组。
- 原生清理使用独立 worker、有界等待和单调时钟；查询规模/重试次数有界。
  根回收 latch 仅在 spawn 成功后进入，失败启动没有未配对的等待资源。
- `workbench_audit`、`terminal_exit_review` 分别完成方案、实现及测试设计审查，
  所有阻塞项修正后均为 GO。

macOS 查询身份后发送信号仍有系统调用间隙；本批不声称提供 pidfd 级原子保证。
旧 execution v1 wrapper 提前注销 registry 的行为保持为已知限制，新 capture
必须独立持有资源和 lease；不能仅依赖旧 isRunning 判定完整停止。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| 定向 Swift timing | 28 项通过，suite 5.787 s；无失败、超时或性能预警 |
| 全量 Swift timing | 1047 项通过，113 suites，suite 33.098 s；含构建的 runner 72.270 s |
| 新增测试 | 15 项合计 521 ms；根回收超时测试 503 ms，其余 1–5 ms；无新增性能预警 |
| 既有性能预警 | 12 项超过 1 s 预警线，均未超过 15 s 硬预算；最慢为 Git watcher 集成 2.371 s |
| 原生进程回归 | TERM-resistant 后代保留/关闭管道、正常根退出、超时、显式停止及 root waitpid 全部通过 |
| 受控身份/状态 | 失败→重试、三路清理合并、等待者超时/取消、回调重入、首次结果冻结、编号复用、不完整查询恢复通过 |
| ARM64 构建 | `test-macos.sh` 完成 Lithe 调试应用编译/链接；确认 Mach-O arm64 |
| Core/边界 | `verify-core.sh`、service boundaries、shared contracts、稳定性扫描、`git diff --check` 通过 |

使用仓库已有 Swift 6.2.4 工具链执行：

```sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  --report "$PWD/.artifacts/goland-parity/iteration15-tools/full/macos-swift.json" -- \
  -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./scripts/verify-core.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
git diff --check
```

定向命令在 `--` 后另加
`--filter 'MacManagedProcessCleanupTests|MacProcessGroupOwnershipTests|MacProcessRunnerTests'`。
首次定向运行中，新 fixture 将 FileHandle.nullDevice 用作输出，得到 EBADF；
修正为无输出的真实 `/usr/bin/true` 继承有效 stdout/stderr 后，定向及全量均通过。
未跳过或弱化测试。Rust 代码没有变更，本批未重新运行 Rust suite。

## 证据与后续

证据位于 `.artifacts/goland-parity/iteration15-tools/`：

- `focused-fixed/`、`full/`：逐项 HTML、JSON、JUnit；对应 `.log` 含实际命令及构建记录。
- `focused-report-review.json`、`full-report-review.json`、`dashboard-review.json`：
  浏览器实际打开定向、全量和 `.artifacts/test-stability/index.html` 后的检查记录。
- `verify-core.log`、`build.json`、`cleanup.json`：Core、产物和资源清理证据。
- `go-probe/`：独立 agent 的 40 次隔离 Go 读取调查，最长 473 ms；真实 imports
  和错误诊断可保留，未修改原项目文件。路径特殊字符、telemetry 和 vendor 的
  生产契约仍待 B7a2c 定案，不能据此声称通用自动刷新已完成。

ARM64 调试产物 UUID `A2D9FB61-9E98-3469-9A00-CA03F3E27B1D`，SHA-256
`25dea73abf9b5adc7f26de97a45d8d32b376ba622c242bb32df8aa290c67b96c`。
本批没有替换安装，没有新增 UI 点击验收；实际 Go/Cargo 窗口将在 B7a4 完成。
浏览器、报告 HTTP 服务与本批测试进程已退出。

下一批按[捕获方案](goland-parity-project-tool-capture.md)接入独立 host service，
严格保留旧 Go 插件的 manifest accessor，避免新增 capability 导致旧包加载失败。
B6 Refactor、其他工作台设置和 L0–L7 语言/插件目标继续保留，整体任务未完成。
