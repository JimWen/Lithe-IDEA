# B3b1a Unicode 搜索与 macOS 增量链接验收

日期：2026-09-06。分支：`dev/aiide`，实施基线：`517b4584`。本批交付 Unicode 搜索/替换预览崩溃修复，以及实际验收时发现的 Rust 静态库增量链接修复。Project 保持当前实现；已验收的 B1、B3a、B4a0–B4a3 跳过，不代表 B3 或一期整体完成。

代码按边界提交为 `00a9f9c1`（构建链接）和 `b0dac7e2`（Unicode 搜索）；验收记录另行提交。安装记录保存在本批产物目录的 `install-result.json`，包含实际安装提交、签名检查后的二进制摘要与旧备份清理结果。

## 方案、实现和审查

| 修改 | 原问题与最终行为 | 独立审查 |
| --- | --- | --- |
| B3b1a matcher | lowercase 后的字节位置切原文导致 `İ needle`、`İ`、`K` 中止进程；现复用 regex 在原文匹配，literal `$1` 不展开，preserveCase 使用实际匹配原文 | `workbench_audit` 方案、代码通过 |
| Unicode 索引候选 | lowercase trigram 会漏掉 `ſxſ` / `sxs`；忽略大小写的 ASCII 查询补入非 ASCII 文件，由 matcher 精确过滤，更新/删除/ID 复用同步维护 | 同上；测试索引清理的私有入口与路径规范化问题已修正 |
| macOS 增量链接 | 相同路径下重建 Rust archive 不使 SwiftPM 链接失效；按 SHA-256 发布不可变副本，以链接参数路径变化触发 App 和测试包重链接 | `workbench_audit` 方案、代码及最终 Swift Testing/并发回归通过 |

细节分别见 [B3b 方案](goland-parity-b3b-replacement.md) 和 [链接方案](macos-rust-linking.md)。没有新增依赖，没有修改第三方源码。C ABI 和 JSON 字段保持兼容；共享文档与 23 个 fixture 场景明确 Unicode simple folding，不使用区域相关或多字符 full folding。wholeWords 保留原有 ASCII 字母/数字/`_`/`$` 相邻字符规则。

## 自动检查

使用 Swift 6.2.4，执行以下相关检查；完整命令、输出与逐项耗时归档在 `.artifacts/goland-parity/iteration8-replacement/`。

```sh
./scripts/verify-rust-core-comments.sh
cargo fmt --manifest-path rust/Cargo.toml -p lithe-core -- --check
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh --platform all
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
  --manifest rust/Cargo.toml --package lithe-core
./scripts/verify-rust-core.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
./scripts/verify-core.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./scripts/test-classify-ci-changes.sh
git diff --check
LITHE_ARCH=arm64 LITHE_DIST_ROOT="$PWD/.artifacts/goland-parity/iteration8-package" \
  ./scripts/package-app.sh
```

- Rust **331 项通过**，计时运行 **17.744 秒**。4 项新增回归分别覆盖 23 场景矩阵（46 ms）、索引生命周期（10 ms）、mask/可见性（6 ms）、未保存原文位置（6 ms）。
- 完整 Swift **985 项 / 103 个 suite 通过，34.806 秒**；此结果来自链接修复后重新生成的测试包，不能与修复前的缓存包结果混淆。
- 原生链接集成回归 **7 项通过，23.817 秒**：应用与真实 Swift Testing 包先执行值 1，再仅改变 archive 内容、保留原 mtime，二者均执行值 2；内容不变不重链接。另覆盖含空格路径、幂等、并发发布、损坏缓存、失败清理及 wrapper 参数语义。
- 最慢新增集成项为首次编译/运行微型 SwiftPM 应用与测试包，**19.789 秒**，超过 15 秒提示阈值、低于专用于该编译集成的 90 秒上限。每个子进程 45 秒、整体 240 秒 deadline；本批无新增 scanner 例外。
- Rust verifier 的真实 Swift bridge/符号检查、Core、shared contracts、service boundaries、CI 分类与 diff 检查通过。HTML/JUnit 已生成并查看，归档在 `test-stability/`。
- ARM64 Release 链接修复后的构建日志明确包含 `Linking Lithe`。验收二进制 UUID 为 **`FC152C09-9E42-37B3-86B3-3DA484E47B14`**；Rust archive SHA-256 为 **`965c3218de3bb31018aadaf1c1554ceea73f24778ba52dc40c83ee47f8a91da4`**。

完整测试构建出现 517 条最低系统版本 linker 警告：既有全局 `-force_load` 把 macOS 13 Rust 对象传给最低版本为 11 的 `TestingMacros-tool`。独立审查核对 Lithe 和 LithePackageTests 均为 macOS 13，产品构建与测试通过；该参数作用域问题保留在链接方案，不修改第三方代码压制警告。

主要日志为 `verify-rust-core-link-fixed.log`、`full-swift-tests-link-fixed.log`、`arm64-package-link-fixed.log`。初次测试使用 XCTest 而本机 CLT 缺少 XCTest 的失败记录保留，最终集成改用工具链自带 Swift Testing 并实际执行通过。

## 实际应用点击与截图

使用隔离 QA bundle、临时文本 fixture 与最终 ARM64 Release 二进制，真实鼠标/键盘操作并以 AX、截图和磁盘字节交叉核对。下列截图均已打开检查；路径相对于上述产物目录。

| 操作 | 可观察结果 | 证据 |
| --- | --- | --- |
| Cmd-Shift-R，`needle` → literal `$1`，展开文件预览 | `İ needle KNEEDLE😀` → `İ $1 K$1😀`，2 处匹配，进程保持运行 | `unicode-replacement-release-expanded.png` |
| 同预览切换 query 为 `sxs` | `ſxſ SxS sxs` → `$1 $1 $1`，3 处匹配 | `unicode-replacement-release-folding.png` |
| 勾选区分大小写 | 同一行仅最后的 `sxs` 被替换，1 处匹配 | `unicode-replacement-release-case-sensitive.png` |
| Cmd-Shift-F，`sxs`，完整文件 mask | 定位 `unicode-search.txt:2`，3 处文字高亮；当前计数仍按匹配行显示 1 | `unicode-find-release-full-mask.png` |
| 关闭预览与退出 QA | 没有点击 Apply；原始 UTF-8 字节不变，随后删除本批 fixture；QA 与子进程全部退出并注销 LaunchServices | `unicode-release-shutdown.json` |

首次打包沿用了旧 UUID `B6975446-8CE9-35A5-9031-D5933300D1C3`，实际点击仍崩溃。这一失败证据保留为 `stale-linked-app-crash.log`，失败包未替换安装。完成链接修复后，使用新 UUID 重跑上表场景通过；独立 release 动态库的 4 个崩溃/漏候选探针亦通过，见 `release-unicode-probes.json`。

## 性能与保留事项

索引候选扩展会增加非 ASCII 文件扫描。使用 1,500 个、每个约 4 KB 的临时文件做本机串行对比；每个 query 取 7 次暖缓存样本。ASCII 数据的查询中位数为 0.174–0.274 ms；一半文件含中文时为 10.052–11.607 ms（旧实现为 0.273/0.093 ms），最大 12.370 ms。命中数同时断言，临时数据已清理。该合成样例说明本次正确性修复的成本，不能当作真实大项目延迟保证；详见 `unicode-search-performance.json`。

后续优先继续 B3b1 的明确空范围、所有 scope 的未保存内容、typed 错误和预览预算，再按方案完成原文校验、失败回滚及整体 Undo/Redo。本次没有接通新的 Apply 事务，未验证跨文件写入/撤销；Find 按行计数、ICU 与 Rust 的正则差异、最近项和统一布局仍保留在 B3b–B3d。其余设置、语言、插件、重构、运行入口、Go/Cargo、Structure/TODO 和最终 Git 对照继续按总计划实施。
