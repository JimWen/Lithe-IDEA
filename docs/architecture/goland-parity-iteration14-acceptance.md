# 第十四批验收：Go / Cargo 元数据基础

日期：2026-09-06。分支：`dev/aiide`。方案提交 `ca7b43af`，元数据实现
`4039f0f0`，原生链接测试夹具修复 `3411e755`。

本批交付 B7a1：真实工具 stdout 的纯 Rust 解析、可移植拓扑与严格校验。
它尚未接入右侧工具窗口；B7a2 捕获、B7a3 独立工具任务、B7a4 UI 及实际
点击验收仍待完成。Project、已有语言方案文件和已安装应用保持现状。

## 交付与独立审查

- 新命令 `execution.normalizeProjectMetadata` 与版本 1 共享契约；无需新依赖。
- Cargo workspace/default members/member/target、features、声明依赖、default_run；
  example 库与二进制、custom-build、未知 kind 明确区分。
- Go 多 module/package、普通/cgo/test/外部 test/排除源码、imports 与错误诊断。
  module/package 错误禁止执行；健康 package 的目录与 import path 必须对应。
- 稳定 ID 不受源文件名、版本、Cargo opaque ID 和输入顺序影响；显式 root 映射
  支持外部 member/path dependency；原生查询路径不进入 target ID。
- 输入/深度/条目、输出和重复字符串展开均有预算；取消和最后一次解码后再检查期限。
- `workbench_audit`、`terminal_review` 完成方案及代码/测试设计审查，最终 GO。
  `terminal_exit_review` 独立确认测试夹具修复及失败清理，最终 GO。

## 自动与原生验证

| 验证 | 结果与证据 |
| --- | --- |
| 完整 Rust timing | 344 项通过；13 项新增，合计 982 ms；suite 23.072 s，逐项合计 17.46 s；无失败/超时/性能预警 |
| 新增限额测试 | 路径/深度/输出展开 588 ms；重复长诊断 328 ms；其余新增项 3–10 ms |
| C ABI | 两种语言的 fixture 均通过 owned C 字符串边界，匹配 dispatcher；RAII 在失败路径释放返回值 |
| 实际工具输出 | 隔离 Go 双 module 和 Cargo workspace 的真实 stdout，通过新编译的 native dylib 得到正确拓扑；Go 任意 main 文件名、测试源及 Cargo example 库资格均核验 |
| 原生链接测试 | 7 项通过；修正的 wrapper 项 1.481 s。首次编译可执行及 Swift 测试包 18.409 s，超过原有 15 s 预警线，未超过 90 s 硬预算 |
| Rust Core 验证 | comments/layout/fmt、完整 Rust tests、原生链接、macOS ARM64 调试构建、Swift→Rust bridge、链接符号全部通过；应用构建阶段 15.48 s |
| Core 与边界 | `verify-core.sh`、service boundaries、shared contracts、test stability scanner、`git diff --check` 通过 |

执行命令（Swift 验证使用仓库已有 Swift 6.2.4 工具链）：

```sh
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
  --manifest rust/Cargo.toml --package lithe-core \
  --report .artifacts/goland-parity/iteration14-tools/rust-timing/rust-core.json
./scripts/verify-rust-core.sh
./scripts/verify-core.sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
```

首次 `verify-rust-core.sh` 揭示旧 wrapper fixture 漏复制新前置校验器及 SwiftTerm
输入。修复仅补齐真实依赖并断言校验成功，保留所有真实编译/重新链接/参数转发
断言；未增加跳过开关。之后整条脚本复跑通过。

## 证据与范围限制

本地证据位于 `.artifacts/goland-parity/iteration14-tools/`：

- `rust-timing/index.html`、`rust-core.json`、`rust-core.junit.xml`：最终全量时长。
- `link-report/macos-rust-link.html` 与 JSON/JUnit：原生链接及 wrapper 结果。
- `verify-rust-core-final.log`、`verify-core.log`：构建、桥接和边界。
- `real-metadata-normalized.json`：实际 Go/Cargo stdout 经 native C ABI 的结果。
- `report-browser/`：报告实际打开后的可访问性快照；已核对模块健康与预警项。
- `cleanup-and-build.json`：构建产物摘要与相关进程为空的最终核验。

报告已在浏览器打开检查，浏览器与临时 HTTP 服务均关闭，测试临时目录由各自
finally 清理；本批没有启动 Lithe 应用、PTY 或语言服务。

本批没有新 UI，未将既有界面截图算作 Go/Cargo 工具窗口验收，也未替换安装。
隔离无依赖探测未新增项目文件，仍不足以证明一般 Go workspace 零写：官方
modload 在 readonly 下可能写 `go.work.sum`。B7a2 必须先验证读取隔离方案、
真实 process-group 终止和双 EOF，再接自动刷新。完整 UI、格式化与配置执行
继续按[方案](goland-parity-go-cargo.md)验收，整体目标保持未完成。
