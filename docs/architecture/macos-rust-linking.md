# macOS Rust 静态库的增量链接

状态：方案和代码均经 `workbench_audit` 独立审查通过；7 项原生链接回归、985 项完整 Swift 测试、ARM64 包及真实点击验收已通过，见 [验收记录](goland-parity-iteration8-acceptance.md)。触发批次为 [B3b1a Unicode 搜索修复](goland-parity-b3b-replacement.md)，不改变 C ABI 或第三方依赖。

## 已复现的问题

2026-09-06 更新 Rust matcher 后，release 动态库的 Unicode 回归通过，但 `package-app.sh` 生成的 App 在点击替换预览时仍因旧 matcher 中止。包内 Mach-O UUID 与修复前相同；完整日志在 `.artifacts/goland-parity/iteration8-replacement/`。这个失败包没有替换安装。

SwiftPM 的 `.build/release.yaml` 中，Lithe executable 与 LithePackageTests 的链接命令都包含 `-force_load <profile>/liblithe_core.a`，但 inputs 没有该 archive。只在相同路径重建库不会改变 SwiftPM 的命令签名，也未必触发 relink。直接新编译的桥接验证程序不能证明缓存的 App 已采用新库。

## 方案与边界

`prepare-rust-core-link.sh` 接收已构建的 `liblithe_core.a`，计算 SHA-256，在同一 Cargo profile 的 `lithe-link/<digest>/liblithe_core.a` 原子发布不可变副本。优先使用 macOS clone copy，不可用时退回普通 copy；不使用指向可变 archive 的 symlink。复制后再校验摘要，拒绝复制期间内容变化；既有摘要文件校验不符时失败，不能覆盖。临时目录在成功和失败时均清理。

相同内容复用同一路径和文件时间；准备已摘要化的路径也是幂等操作，不生成嵌套缓存。`build-rust-core.sh` 返回这个路径，现有 build/package/preview/verify 消费者继续传同样的 `-force_load` 参数，内容变化通过路径变化触发链接命令失效。

`test-macos.sh` 仅规范化调用者显式提供的 Rust force-load archive，保留其他 linker 参数。无 Rust 的单元测试方式不新增 Cargo 依赖；同一次调用提供多个 Rust archive 明确拒绝，避免混合版本。`--skip-build` 保留对既有测试包的执行含义，不构建、准备新库或声称验证了当前 Rust 源码。

摘要缓存位于已有 Cargo target 内，不进入产品包或 Git。构建过程中不清理历史摘要，以免删除另一个链接任务正在使用的库；与对应 Cargo target 一起清理。后续如需要独立回收，应先设计链接租约，不能只按 mtime 删除。

## 验证和提交

添加隔离的原生构建回归：小型 SwiftPM executable + Swift Testing test target 调用同一 C archive 函数，使用工具链自带的 Testing，支持仅安装 Command Line Tools 的机器。第一次返回 1；只重建 archive 为 2、保留旧 mtime，Swift 源码与测试源码保持不变；应用与测试包都必须返回 2。测试预期从测试进程环境传入。相同内容再次运行，摘要路径与时间不变且不重新链接。

另验证路径含空格、重复准备、损坏缓存拒绝、失败后旧副本不变及临时资源清理；测试 wrapper 保留第三方链接参数、拒绝重复 Rust 库，`--skip-build` 不触发 prepare。子进程使用现有有界 process-tree runner，整个 fixture 有 deadline，失败仍清理；输出 HTML/JUnit 计时报告。

回归接入 Rust verifier 和 CI 变更分类；运行 Swift 全量测试、ARM64 打包，再实际点击原始 Unicode 崩溃场景。验收必须记录 App 的新 UUID、源库摘要和画面，不能只凭 cargo test 或独立 dylib 探针放行。构建修复和 matcher 修复按各自文件边界提交。

本次完整测试构建还暴露了既有全局 `-force_load` 的副作用：`TestingMacros-tool` 的最低 macOS 版本为 11，继承了最低版本为 13 的 Rust archive，因此产生 517 条 linker 版本警告。产品 Lithe 和 LithePackageTests 均以 macOS 13 为最低版本，实际测试通过。独立审查确认该警告不阻塞本次交付；后续将链接参数限定到真实 Rust 消费目标时单独处理，不修改第三方代码或全局部署版本来压制诊断。
