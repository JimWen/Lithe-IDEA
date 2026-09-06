# 第十六批验收：项目工具捕获与插件资源

日期：2026-09-06。分支：`dev/aiide`。实现分为两个提交：

- `daf43b7f`：独立 native 捕获、管道与进程所有权。
- `0003c624`：Go/Rust 模块资源、插件兼容与 CI 接线。

本批完成 B7a2b。B7a2c 只读元数据刷新、B7a3 独立任务、B7a4 右侧 Go Tools /
Cargo 窗口仍待实施。Project 及用户已有的三份语言方案文件保持原状；本批没有
新增产品 UI，也没有替换安装应用。

## 行为与审查

- 新增版本化 project-tools host service / capability，保留旧 execution v1 协议
  和结构布局。每次 capture 独立持有 operation ID、完整环境、双流字节预算及期限。
- 原生串行队列读取独立 stdout/stderr，四次小块读取后让出队列；不按输出块向
  MainActor 排 Task。精确达到上限仍可成功，多一个字节即失败。
- 成功必须同时确认 spawn 返回、宿主 writer 关闭、根回收、进程组清理、双真实
  EOF 和双 reader cancel-handler 关闭。取消读端不算 EOF，非零退出仍保留完整两流。
- 全应用共用两个并发槽；超时、取消和迟到启动均继续执行真实清理。清理失败有界
  返回，但 owner/槽/模块 lease 保留；显式停止可重试进程清理，旧失败事件不能结束
  新一轮清理。capture 只返回一次。
- 创建管道途中失败也先把已分配 FD 交给 owner，不能抛错后把未确认的关闭当成功。
  writer 只调用一次 Foundation close；失败后不再访问 wrapper 或原 fd。
- 监控 registry 使用独立 UUID token，根 reap 时注销；后代清理所有权由 coordinator
  与资源继续持有，不用已释放的 PID 表示资源存活。
- `LitheLanguageExtensionSupport` 共享模块资源和 activation 门禁。停用先关闭门禁，
  再向所有会话发 stop，最后集中等待；旧 capability / 预创建 session 不可再启动。
  capture 尚未返回时 lease 继续保留，即使 native stop 已成功。
- 旧 scope 中还有 active capture 时禁止新 owner；已退役且确认停止的资源仅注销
  自己的 registration。Go/Rust await 后核对资源身份，防迟到清理影响新 activation。
- 仅 Go/Rust 提供新 capability，Python/Node 保持原声明。宿主插件兼容版本及 Go
  包更新为 0.3.1；旧 Go v1 与新 v2 manifest accessor 分别冻结，schema/API 仍为 1。

`terminal_review`、`terminal_exit_review`、`workbench_audit` 分别参与方案、实现、
插件兼容、测试与跨模块审查。全部阻塞项修复后均给出 GO。审查与测试发现的问题
包括关闭证据丢失、旧清理事件干扰重试、顺序停止、迟到启动、重激活旧引用和
FileHandle 异常；均保留回归测试，未跳过或弱化测试。

## 验证

| 检查 | 结果 |
| --- | --- |
| 定向 Swift timing | 65 项、9 suites 全部通过，suite 1.404 s，无性能预警 |
| 全量 Swift timing | 1090 项、119 suites 通过，suite 33.897 s；含编译 runner 87.089 s |
| 新增测试 | 43 项合计 1249 ms，无性能预警；三种后代清理合计 858 ms，超时清理 308 ms |
| 既有性能预警 | HTML/JUnit 共 12 项，均低于 15 s 硬预算；最慢 Git watcher 集成 2103 ms |
| Native 集成 | 大于管道容量的双流、中文末段、非零退出、精确上限、TERM-resistant 后代分别保留 stdout/stderr/关闭双流、无效 executable/cwd、部分 pipe 准备失败全部通过 |
| 生命周期 | 六种 root/双 EOF 顺序、独立 reader/writer 关闭门槛、迟到启动/期限、失败重试、共享两槽、停用/重激活门禁与 lease 保留通过 |
| 动态插件 | 真实新版 Bundle 的 Run/LSP/capture/停用通过；保留的真实 0.3.0 Bundle 在新 verifier 中 Run/LSP/停用通过 |
| 版本拒绝 | 真实新 Go manifest 对 host 0.3.0 的 catalog 检查拒绝；生产 startup 对不兼容包在 principal class 加载前拒绝，加载次数为零 |
| ARM64 | `build-macos.sh --configuration debug --triple arm64-apple-macosx` 完整通过 |
| 其他 | Core、service/module boundaries、shared contracts、CI 分类回归、测试稳定性扫描及 diff 检查全部通过 |

动态插件验证真实加载已编译 Bundle，Run/LSP/capture 的宿主是无进程内存 fixture，
用于验证 ABI、生命周期和延迟符号绑定；实际 native 捕获另由集成测试验证。
没有实际启动旧版 App。旧版拒绝结论来自版本契约与生产拒绝路径的组合证据。

首次定向运行在“真实 FileHandle 关闭后模拟抛错，再次关闭”测试中触发
`NSFileHandleOperationException`；修复为首次尝试后不再访问失效 wrapper，随后
定向、全量和完整构建通过。新增的一处测试 gate `Task.sleep` 注释仅用于 2 秒
失败期限；事件顺序由显式 open/cancel 驱动，不用睡眠同步。

主要命令使用已有 Swift 6.2.4 工具链：

```sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  --report "$PWD/.artifacts/goland-parity/iteration16-capture/full/macos-swift.json" -- \
  -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./scripts/verify-official-plugins.sh --legacy-go-0.3.0 \
  .artifacts/goland-parity/iteration16-capture/compat/old-installed/dev.lithe.plugin.go-support
./scripts/build-macos.sh --configuration debug --triple arm64-apple-macosx
./scripts/verify-core.sh
./scripts/verify-module-boundaries.sh
./scripts/test-classify-ci-changes.sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
git diff --check
```

定向 filter 为
`(MacProjectTool|ProjectToolModuleLifecycle|LanguageProjectToolResource|GoProjectTools|GoSupportModule|LanguageExtensionProcessLifecycle|PluginPackageStoreTests)`。
Rust 源码未改；本批没有重新运行 Rust unit suite。

## 证据与后续

证据目录 `.artifacts/goland-parity/iteration16-capture/` 包含 `focused/`、`full/`
的 HTML/JSON/JUnit，`compat/verify.log`、`arm64-build.log`、`core-verification.log`、
`report-browser/` 的真实浏览器报告快照以及 `build.json`、`cleanup.json`。
定向和全量 HTML 均已在浏览器实际打开；默认 dashboard 的 Swift lane 已更新并
实际查看，其余历史 lane 不视为本批重跑。报告服务与浏览器已关闭，测试进程已退出。

ARM64 产物 UUID `C895B10B-3F67-346A-A263-BAC64A488472`，SHA-256
`3f460c8a03b3b4f4c9c96caf26f025966e57d903cff20dae0e1869f520f21b95`。
旧 Go Bundle 从本轮开始时已安装应用只读保留，未重编；二进制 SHA-256
`3179cf768343bf0f422943d6d64a5588190194eee031f8a18b8538a2c02e9745`。
新版 Go Bundle SHA-256
`2a1659f807e3aba9f32331562844c9852016386e79fb079f89c10ed4a8f33bbc`。

下一步继续审查 B7a2c 的 Go workspace sum、特殊路径、vendor、telemetry 与 Cargo
实体工具链只读策略，再接元数据刷新和工具窗口。B6 Refactor、其他设置与 L0–L7
语言/插件任务仍保留；本批后台验证不替代后续实际 UI 点击和截图验收。
