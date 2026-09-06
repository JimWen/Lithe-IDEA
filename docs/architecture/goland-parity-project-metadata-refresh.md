# B7a2c：项目元数据读取

状态：c1 已完成（`8b8e7fe9`、`0b5dfcaa`），独立方案/代码审查 GO；Rust 346、
Swift 1108、真实 C ABI 和 ARM64 构建通过。读取策略已完成 Go/Cargo 隔离探测；
c2/c3/接线须分别细化再审，不能据此视为整个刷新实现获批。
本批承接已提交的 Rust normalizer 和插件 capture；Go Tools/Cargo 右栏、工具任务、
运行配置和 GUI 对照仍按 [B7 总方案](goland-parity-go-cargo.md) 交付。
Project 不改；已有三份语言方案的工作区修改保持原样。

## 1. 先接完整数据边界（c1）

在 `LitheCoreContracts/Execution` 增加 package 级 Swift 类型和同步 Sendable
`ProjectMetadataNormalizing` port；不改变公开插件 v1 ABI，不在 View 解原始 JSON。
响应逐字段对应 [metadata v1](../../shared/contracts/project-tools-metadata.md)：
workspace、member、target、source、feature、声明依赖、diagnostics 和 nullable defaults。
保留 kind/rawKinds/crateTypes、requiredFeatures、Go imports、Incomplete；不把缺 defaults
解成空列表，不把 Cargo 声明依赖当作已解析的依赖图。

独立审查发现 Swift String 字典会合并规范等价的 Unicode feature 名；旧 macOS 13
Foundation 还会在 custom key strategy 前建字典。因此 Core v1 保留原 `features`，
增量提供 `featureEntries:[{name,enables}]`，两者借用同一份有序 BTreeMap 序列化、共同
计入 32 MiB 输出预算，不复制整份 map。Swift 直接读数组，feature 的 ID 和 equality
按原始 UTF-8，Go 返回空数组；缺新字段时明确失败，不回退字典。命令/C ABI/版本号/
旧字段与 stable IDs 保持兼容。共享 fixture 和 Rust/真实 Swift FFI 同时验证双 Unicode
名称、对应值、顺序、原旧字段及输出上限。

输入使用互斥枚举：Cargo 的一个 capture result，或 Go 的 module result 与按真实
module 依次捕获的 package results。Swift adapter 在复制/拼接前检查全部结果均为
succeeded、exitCode=0、双流真实 EOF、cleanupConfirmed，stdout 必须严格 UTF-8；
有失败即整体失败，保留原 capture 结果，不用 partial stdout 或 stderr 补树。
Go 对象流之间插入换行，分隔符也计入共享 16 MiB 原文预算；检查完成后才分配拼接。
Go 要求 1…128 次 package capture；真实没有 package 可以由成功调用的空 stdout
表达，不能用未调用的空数组当成功。c3 工作流须冻结预期 stage 清单，逐项核验归属、
唯一性和覆盖率；c1 不能证明传入结果已覆盖所有发现的 module。编码前还检查 roots
数目 1…128、root ID 最多 64 UTF-8 bytes、路径及 workspaceDirectory 最多 8 KiB，
以限制宿主 JSONEncoder 的分配；root 语义仍交 Core 校验，adapter 不扩充授权。
失败区分 captureRejected（stage/原结果）、invalidInput、core(code/message/details)。
响应 version 必须为 1、language 必须匹配输入枚举。

`Core/Rust/RustProjectMetadataOperations` 调用现有同步 JSON bridge，保留 Core 的
code/message/details。返回值携带调用方 operation ID（1…128 UTF-8 bytes、无 NUL）；
该 ID 是本次 normalize stage 的全局唯一 ID，不能跨项目复用固定字符串或与仍在
运行的 stage 冲突。工作流仍须检查自身的 workspace/provider generation；Core 的
cancel=false 不保证稍后进入的命令已取消。添加可选 bridge timeout 参数，默认 nil 保持旧调用
行为；本 port 必须显式给剩余 timeout，范围 1…30000 ms。Core 从请求 envelope
解码、Scope 注册后计算期限，不能抢占 Swift 的 UTF-8/JSON 编码与响应解码；这部分须由后续工作流
的外层单调时钟覆盖。c1 不创建 Task/进程、不声明已完成异步取消或刷新：后续工作流
在 worker 调用，并在完成后再次检查期限和 generation；取消复用
`RustCoreBridge.cancel`，不能因丢弃结果遗漏 native cleanup。Core 的 timeout=0 表示
没有期限，因此 port 必须拒绝 0；测试核验实际生产 request encoder 的字段透传和
nil 默认省略，不用 1 ms 大输入制造依赖机器速度的超时测试。

验证使用现有共享 fixture 经真实 C ABI，覆盖 Cargo 外部 member/path dependency/
required features/defaults、Go 多流/imports/包级错误、非法 UTF-8、失败 capture/
缺 EOF/未确认 cleanup、总预算、未映射 root 和损坏记录。失败不得返回部分快照。
该 suite 明确要求实际 Core 链接。CI 的 Swift-only lane 跳过它，Rust lane 在构建
archive 后以 force_load 运行同一个 timing harness 并上传报告；classifier 覆盖
类型/feature/adapter/bridge/test 及 Package 链接图变化，不用 unavailable 时 return
伪造通过。旧 Core 缺新数组时沿用 bridge 的 invalid response 失败。
不为本批无变化界面制造 GUI 验收；真实点击在接入右栏时完成。

## 2. Cargo 读取与实体工具链（c2）

命令为实体 Cargo 的 `metadata --format-version 1 --no-deps --frozen --color never
--manifest-path <真实绝对路径>`，cwd 保留实际项目目录。正常配置文件、相对路径与
命名 registry 交 Cargo 自己解释，不复制源码，不手工扫描 manifest 生成目标树。

复用现有工具链候选顺序与用户显式选择，新增窄 native resolver：被动检查文件身份，
实体 Cargo 配合已核验的 compiler；rustup proxy 使用已安装 rustup 的 `which cargo`
和 `which rustc`，设置公开 `RUSTUP_AUTO_INSTALL=0`、真实 cwd，保留官方 override
优先级。两次解析亦通过语言插件 capture。输出只去掉协议行终止符，保留路径空格；
验证实体可执行文件及配对，缺 pin 不下载，未知脚本 shim 提示选择实体工具链。
不通过 proxy 执行版本探测，不改变旧 Run resolver。

环境从空字典构造。保留必要 HOME、CARGO_HOME、locale、受控 TMPDIR 和明确的
`CARGO_REGISTRIES_*_INDEX`，PATH 使用实体工具链与平台标准目录；设置实体 RUSTC、
空 RUSTC_WRAPPER/RUSTC_WORKSPACE_WRAPPER、CARGO_CACHE_RUSTC_INFO=0、
CARGO_NET_OFFLINE=true、RUSTUP_AUTO_INSTALL=0。不继承任意 CARGO*/RUST*/DYLD*、
Run env 或 credential/helper 变量。实际探测发现 CARGO_LOG_PROFILE=1 即使配合
no-deps/frozen 也会在源码目录写 trace，必须以完整白名单阻断。

no-deps 只返回声明。缺/坏 Cargo.lock、缺缓存/vendor 可成功；features/filter-platform
不在该分支求值，未来 MSRV 也不证明能构建。界面不能据此显示“依赖就绪”，不能
偷偷退回 with-deps（会执行 rustc/wrapper）。保留 Cargo config，空 CARGO_HOME 会
破坏私有 registry 的名称解析。完整依赖图与 vendor 健康是后续显式动作。

## 3. Go 读取与 workspace 隔离（c3）

普通 module 设置 GOWORK=off；workspace 保留真实 module 源目录，逐 member 执行
普通 go list，不能用 -find（丢 imports）、-test、-compiled、-modfile 或伪造 work
绕过依赖错误。缓存模式显式 `-mod=readonly`，只读 go.mod/go.sum，私有 work/sum 承接允许的
work sum 更新。原文只投影 use 与本地 replace 路径 token，保留其余字节、未知指令、
Toolchain/Godebug、注释及 CRLF。不能从 work edit JSON 重建文本；不能依赖 -replace
flag 对 @/尾空白的解析。具体 lexer/字符串投影须先独立审查和回读语义核验再实现。

vendor 路径单独处理。移动 go.work 后，即使 symlink 整个 vendor，Go 对相对 replace
的比较仍会失效。已验证的候选是原 GOWORK/vendor 加宿主生成的 sum-only `-overlay`：
拒绝原 sum 写入，保留真实 vendor 校验与错误；不接受用户任意 overlay。键为原
GOWORK 完整路径加 `.sum`，单 module 保护 go.sum；缺原文件时私有副本为空文件。
这是拒绝写入，并非重定向写入副本。选定 vendor 后显式 `-mod=vendor`，错误不得
自动降级到缓存模式。本轮实测与源码审查仅覆盖 Go 1.24.4 darwin/arm64。
选择 vendor 需遵守对应 Go 版本的默认规则及 modules.txt workspace marker，不能只
看目录存在或把 Go 工具链版本与 workfile 的 go directive 阈值混为一谈。

使用实体已安装 Go SDK，从空字典构造环境白名单，显式 GOTOOLCHAIN=local、
GOENV=off、GOFLAGS=、GOPROXY=off、GOSUMDB=off、GOVCS=*:off、GOPRIVATE=、
GONOPROXY=none、GONOSUMDB=none、GOAUTH=off、GOCACHEPROG=。配置明确的
GOOS/GOARCH/CGO_ENABLED/tags，缓存和临时目录不得落在源树内。首次 Go 执行前就须
解决 telemetry helper：内部 GO_TELEMETRY_CHILD 不是稳定公共 API，版本兼容 profile
及测试证据另行审查，不能泛化为所有 Go 版本支持。未知组合显示真实 unavailable。

## 4. 刷新与资源边界（c2/c3 接线前再审）

语言 Go/Rust module 独占进程 capture；Execution graph 拥有刷新工作流、快照和私有
临时目录 lease。这是对原方案“Execution 只拥有 UI/任务状态”的补充，不重复认领
进程。语言停用关闭旧 capability 门禁；Execution 停止阻止后续 stage，并等待自身
工作流及临时目录回收。清理失败保留 owner/lease；所有读该目录的 capture 确认结束
后才能删除，迟到 native cleanup 仍需被接收。不能在 capture 返回失败时直接 defer
删除目录。与现有 graph.stop/module-resource 的接线必须独立审查。

整个 refresh 使用一个 operation ID 和 workspace/provider incarnation，子命令各有
唯一 stage ID，共享 30 s 总期限及 16 MiB 原文预算；至多 128 个发现的 member，
已有 capture 的全局两个槽继续生效，不新建无界任务队列。每次启动 capture 就按剩余
stdout 预算限流，stderr 另设整体保留预算，不先收齐 128×16 MiB 再拒绝。deadline 覆盖解析及 native
准备；仅放弃等待不算清理。先核验授权的真实 workspace/member/path dependency/
source roots，再冻结映射；不把 `/` 加成 root 逃避核验，不从错误文本猜路径授权。

manifest/config/工具链选择变更和 workspace/provider 切换产生新 generation；多命令
读取前后核验相关输入，旧结果不得覆盖新项目。文件系统不是原子快照，不承诺所有
源码在刷新期间静止，也不在每次刷新前哈希整个项目。

## 5. 证据与交付门槛

隔离探测位于 `.artifacts/goland-parity/iteration17-metadata/{cargo-policy,go-policy}`。
Cargo 21 场景，493.18 ms；Go 48 次调用（37 次读取、11 次 fixture 生成/版本检查），
最慢 108.9 ms，涵盖缓存/缺 sum/vendor/相对 replace/特殊路径。读取检查均符合预期；
Cargo 两项故意开启副作用的正控单独记录，不能算零写。这些是策略实验，不冒充
已提交的生产回归测试或右栏验收。
每批方案与代码独立 review，focused/full timing、边界、ARM64 构建、相关 Core 验证
通过后分批 commit。c2/c3 还须真实 capture 前后目录/内容/mtime 零改动、取消/插件
停用/超时/迟到清理检查；B7a4 实际运行、点击、截图并退出测试应用。

官方依据：

- [Cargo metadata](https://doc.rust-lang.org/cargo/commands/cargo-metadata.html)
- [Cargo feature 名称](https://doc.rust-lang.org/cargo/reference/features.html)
- [Foundation 系统版本说明](https://forums.swift.org/t/any-updates-on-the-new-foundation/68532/11)
- [Cargo no-deps 实现](https://github.com/rust-lang/cargo/blob/f2d3ce0bd7f24a49f8f72d9000448f8838c4e850/src/cargo/ops/cargo_output_metadata.rs)
- [Cargo 启动环境处理](https://github.com/rust-lang/cargo/blob/f2d3ce0bd7f24a49f8f72d9000448f8838c4e850/src/bin/cargo/main.rs)
- [Cargo 配置](https://doc.rust-lang.org/cargo/reference/config.html)
- [rustup 环境开关](https://rust-lang.github.io/rustup/environment-variables.html)
- [rustup override 顺序](https://rust-lang.github.io/rustup/overrides.html)
- [Go toolchain 选择](https://go.dev/doc/toolchain)
- [Go telemetry](https://go.dev/doc/telemetry)

逐项证据见[第十七批验收](goland-parity-iteration17-acceptance.md)。
