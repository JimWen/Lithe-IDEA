# 第十七批验收：项目元数据 Swift 消费边界

2026-09-06，分支 `dev/aiide`。本批完成 B7a2c1，代码分为：

- `8b8e7fe9`：Core 保留旧 features，同时输出无损 featureEntries。
- `0b5dfcaa`：Swift typed consumer、完整捕获校验、Core deadline 参数和真实链接 CI。

这是 [B7 方案](goland-parity-go-cargo.md) 的数据边界交付。Cargo/Go 原生读取、刷新
工作流、独立任务、右栏、gutter 及 UI 对照仍待接入；Project 不改。用户已有三份语言
方案工作区修改未纳入本批。未替换安装或启动 Lithe 应用。

## 实现与审阅

新的 package 级 port 接 Cargo 单次 capture 或 Go module/package 多次 capture。
先核验成功状态、cause、exit code、双 EOF、cleanup，再按 Data 字节数检查共同预算，
最后严格 UTF-8 解码、拼流并调用真实 Core。Go 至少有一次实际 package capture；
没有执行查询不能伪装成空树。失败保留 stage 与原结果，不使用 partial stdout。
完整发现清单的覆盖率仍由后续刷新工作流负责。

Swift 逐字段保留 portable root/ID、nullable defaults、目标/来源、声明依赖、
required features、imports 与包级诊断。Core 错误保留 code/message/details，
Core 无 details 时保持 nil。operation ID 最多 128 UTF-8 bytes，取消也先检查
NUL/长度，避免 C 字符串截断后误取消其他操作。Core timeout 只覆盖 Scope 注册后的
命令；Swift 编解码和刷新整体 deadline 仍归后续工作流。

独立 review 发现 Swift 字典会合并两种规范等价的 Unicode feature 名。为兼容
macOS 13 的 Foundation，Core 增量提供有序 `featureEntries`；它与旧 features
借用同一 map，两个输出视图共同计入 32 MiB。Swift 直接使用数组，feature 身份及
变更比较按原始 UTF-8，未采用依赖较新 Foundation 的 custom-key 解码策略。

两名独立 reviewer（`terminal_exit_review`、`workbench_audit`）完成方案与最终代码
审阅，结论均 GO；Go 读取策略另由 `terminal_review` 核对。c2/c3 只获得策略证据，
其实体工具链、临时目录与工作流接线仍须分别细化审阅。

CI 的 Swift-only lane 跳过要求真实 Core 的 suite；Rust lane 构建 archive 后使用
force_load 运行同一计时 harness 并上传报告。classifier 新增 8 个回归场景，覆盖
三个模型文件、两个 bridge/adapter、测试与两个 Package 链接图文件。测试没有在
Core 不可用时直接 return。

## 验证结果

| 验证 | 结果 |
| --- | --- |
| Rust focused metadata | 15 项通过 |
| Rust 全量 timing | 346 项通过；runner 19.806 s |
| 新 Swift suite / 真实 C ABI | 18 项通过；0.623 s；最长 301 ms |
| Swift 全量 timing | 1108 项、120 suites 通过；35.395 s；runner 39.443 s |
| 新 Swift suite 在全量中 | 18 项，累计 612 ms，最长 303 ms，无性能预警 |
| Rust Core 集成验证 | 注释/布局/fmt、Rust 全量、7 项链接验证、Swift bridge/符号与真实 suite 通过 |
| ARM64 完整调试构建 | build-macos 通过，14.35 s |
| Core/service/module/shared/stability/classifier | 全部通过，git diff --check 通过 |

全量 Swift 有 12 项既有性能预警，最长 2310 ms；无硬预算失败。Rust 新增的双视图
32 MiB 输出边界测试耗时 1630 ms，超过 1000 ms 预警线，低于 15000 ms 硬限制。
该测试使用低于 16 MiB 的有效输入，验证重复输出会触发整体输出上限；不因预警
缩小测试数据而失去真实边界覆盖。

最初 focused run 有一条测试错误地要求 permission_denied.details 非 nil；按既有
Core 契约修正测试后，最终 focused/full 全部通过。原失败报告保留在 focused-initial，
不混入最终汇总。新增测试还覆盖 Unicode 双名称/activation 变更、旧响应缺新数组、
nil 与空 defaults、Go errors、失败流/未确认清理、非法 UTF-8、16 MiB 恰好/+1、
Go 分隔符预算、root/ID/deadline 上限与默认 bridge 编码兼容。

本机实际打开了 Rust、Go 探测、focused、full 和默认 HTML 仪表盘。最终默认仪表盘
仅汇总本批当前 Rust 与 Swift 全量：1454 项、13 项性能预警、0 失败/硬预算超限。
报告浏览器和本地 HTTP 服务已关闭；最后进程检查无 Lithe/测试应用残留。

## 工具读取策略实验

Cargo 21 场景，493.18 ms；Go 48 次调用（37 次读取、11 次 fixture 生成/版本检查），
最慢 108.9 ms。Cargo 正控确认继承 CARGO_LOG_PROFILE 会写源码目录 trace；普通
no-deps 不验证 lock、active features 或 vendor 健康。rustup which 加禁止自动安装
可解析已安装实体工具链。Go vendor 的相对 replace 不能随私有 work 搬迁，验证了
原 work/vendor 配 sum-only overlay 的候选路径。

这些是隔离策略实验，不能算生产 collector、任意版本 Go/Cargo 或 GUI 已验收。
Go runtime 证据限定 1.24.4 darwin/arm64，telemetry 内部开关仍需版本化适配。
详细方案见 [项目元数据读取](goland-parity-project-metadata-refresh.md)。

## 可复查产物

目录：`.artifacts/goland-parity/iteration17-metadata/`。

- `rust/`、`focused/`、`full/`：JSON、HTML、JUnit、逐项 timing 与日志。
- `reports/index.html`：当前两条全量 lane 的汇总；默认仪表盘为 `.artifacts/test-stability/index.html`。
- `rust-core-verification.log`、`arm64-build.log`、`core-verification.log`：实际命令输出。
- `cargo-policy/`、`go-policy/`：探测脚本、原始结果、独立 review 与清理证据。
- `report-browser/`：实际浏览记录；`build.json`、`cleanup.json`：构建与最终清理信息。

ARM64 debug UUID：`E0CB3A14-21E5-3F65-9BEF-FCC8CB672D28`；二进制 SHA-256：
`d6cb3a419a3175b4a604b0b87729e432a4fbfcbc3271e95e0e9922c8b8fa6029`。
未新增界面，因此未把报告浏览冒充右栏的运行、点击或截图验收。

复现主要检查：Swift 6.2.4 环境下运行 `scripts/verify-rust-core.sh`；全量 Swift 使用
`test-stability-macos.sh -- -Xlinker -force_load -Xlinker <ARM64 liblithe_core.a>`；
Rust 使用 `run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core`；
构建为 `scripts/build-macos.sh --configuration debug --triple arm64-apple-macosx`。
