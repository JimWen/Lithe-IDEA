# 一期限定裁剪范围与上游合并策略

日期：2026-09-05（初始裁剪验收）；2026-09-21（上游集成）；2026-09-22（原生编辑器复验）。初始裁剪结果见第 7–9 节；本次已合入至 v0.5.0。安装版实机操作暴露的跨文件 Undo 崩溃已有文档级修复，2026-10-06 完整自动测试通过；最终安装版实机验收尚未完成，详见第 10–12 节。

## 1. 本轮范围

基于当前 Lithe，仅处理以下四项。此前关于数据库、数据库 MCP、背景图片、Markdown 等能力的裁剪建议全部撤回。

| 对象 | 处理范围 | 目标 |
| --- | --- | --- |
| JDK、JDTLS、Java Debug/Test | 从默认安装包移除；协调依赖这些资源的启动和可用性检查 | 减少默认下载与安装体积 |
| Maven、Spring 专用功能 | 彻底清理专用入口、自动工作流、实现、模型、配置、依赖和测试 | 降低维护复杂度，保护通用运行功能 |
| Windows | 删除产品代码、专属插件、构建与 CI 链路，以及失效的当前产品说明 | 收敛为 macOS 产品 |
| Linux.do 社区集成 | 移除插件、界面、注册、专用授权回调和服务；按依赖关系清理专用代码 | 收敛产品范围 |

其他已有功能保持当前行为和默认配置，包括数据库及其 helper/MCP、AI、Git/GitHub、终端、编辑器、搜索、运行/调试基础设施、测试基础设施、本地历史、插件管理、全部其他语言支持、配置文本高亮、Markdown、主题与背景图片。

Go/Rust/Python 的能力增强、工具自动安装、AI 对话与 Agent、快捷键重设计、日志扩展、性能重构均为后续独立迭代，不属于本轮。长期目标仍是自己的 AI IDE，本轮只做限定裁剪。

## 2. Java 包体与启动边界

裁剪前，[打包脚本](../../scripts/package-app.sh)无条件准备并复制 JDTLS 和完整 JDK Home；[JDK 准备脚本](../../scripts/prepare-jdk.sh)没有创建最小运行时。JDTLS 资源还包含 Lombok、Java Debug 与 Java Test 扩展。

脚本默认 universal，会包含两套 JDK 与双架构可执行文件；现有[正式发布流程](../../.github/workflows/release-macos.yml)已经分别发布 arm64/x86_64。因此不能把单架构正式包偏大归因于同时包含两套 JDK。

此前核对的发布资产如下；这些是公开发行资产，不是本工作树新构建的结果：

| 对象 | 字节数 | MiB |
| --- | ---: | ---: |
| Lithe-0.4.2-arm64.dmg | 302,539,667 | 288.5 |
| Lithe-0.4.2-x86_64.dmg | 298,525,782 | 284.7 |
| 锁定 JDK 的 macOS arm64 tar.gz | 200,073,404 | 190.8 |
| 锁定 JDK 的 macOS x86_64 tar.gz | 194,316,575 | 185.3 |

来源：[Lithe v0.4.2 元数据](https://api.github.com/repos/1lck/Lithe-IDEA/releases/tags/v0.4.2)、[Temurin 锁定版本元数据](https://api.github.com/repos/adoptium/temurin21-binaries/releases/tags/jdk-21.0.12.1%2B1)。MiB = 1,048,576 字节。压缩格式不同，不能直接相减计算裁剪后的 DMG 大小。

实施要求：

- 默认打包与对应 CI 不再下载、缓存或复制 Java 工具资源。
- 没有包内 JDK/JDTLS 时，普通项目打开不能触发 Java 环境错误、自动预热或重复恢复尝试。
- Java 专用能力与资源可用性保持一致，避免显示无法执行的运行/调试入口。
- 保留通用文件识别、基础文本编辑、高亮和低成本解析能力，不因删除运行时扩大删除范围。
- 如保留上游 Java 准备脚本供兼容检查使用，将其与默认构建路径分离；本轮不新增 Java 按需下载安装功能。
- 数据库 sidecar、数据库 MCP、官方 Go 插件、SwiftTerm、Markdown、图标、字体、主题和背景资源继续按当前规则打包。

体积验收分别记录 DMG、应用安装目录、各资源目录与 helper 的前后变化。此前“100 MiB 主包”仅是探索性预算，本轮不设未测量的硬性体积承诺。

## 3. Maven/Spring 彻底清理

Maven 工具窗口、Spring 专用入口、项目检测与索引、自动分析/预热、运行配置和执行工作流全部移除，同时清理专用模型、契约、实现、资源、依赖、文档和测试。完成标准是没有可恢复的 Maven/Spring 产品能力，也没有为未来恢复而保留的专用实现。

Run/Test/Debug 的通用能力和其他语言的配置保持现状。共用代码先明确消费者，再提取或保留通用职责，解除对 Maven/Spring 类型和逻辑的依赖，禁止仅按目录或类名删除。

已识别的耦合点：

- [ProjectRuntimeService](../../macos/Sources/Lithe/Services/Java/ProjectRuntimeService.swift)位于 Java 目录，但同时实现通用 Run 和语言工具 runtime port。
- [RunExecutableResolver](../../macos/Sources/Lithe/Services/Java/RunExecutableResolver.swift)承担通用可执行文件解析职责。
- [运行配置编辑器](../../macos/Sources/Lithe/Views/Run/JavaRunConfigurationEditorView.swift)包含按 capability 展示的通用配置界面。
- [MacServiceContainer](../../macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift)统一组装 Run、Test、Debug 和语言服务，已解除 Maven 服务依赖。
- [内置模块目录](../../macos/Sources/LitheModuleAPI/Catalog/BuiltInModuleCatalog.swift)中的 Execution 和 Language Intelligence 同时承载通用能力，不能为了退出 Maven 而整体关闭这些模块。

以完整删除 Maven/Spring 为验收要求，不采用隐藏 UI、禁用模块或保留死代码的替代方案。上游合并成本通过集中补丁、保留通用文件结构和针对性回归控制；仅保留其他功能实际使用的通用代码。

## 4. Windows 与 Linux.do 的删除边界

Windows 删除集合包括 windows/、Plugins/win/、专属构建/打包/依赖脚本、Windows CI 与发布工作流。同步调整 CI 变更分类、共享验证脚本中直接读取 Windows 文件的检查，以及当前 README/架构中的产品入口。

保留 Rust Core、macOS 消费的 shared contracts/fixtures、通用 CI 工具和历史发布记录。共享协议可能仍包含平台字段或历史 Windows 样例，不为清除关键词而修改数据格式。停止 Windows 发布不涉及本轮删除远端历史资产或 Git 历史。

Linux.do 删除集合包括官方插件包、工作台贡献、专用 WebView/视图、feature model、服务、授权回调路由中的专用分支和相关专属测试。清理 Rust 社区代码或依赖前检查所有消费者，避免影响 GitHub、AI、数据库网络访问、通用凭据存储或其他 WebKit 功能。

需检查已有安装的状态：持久化的 Linux.do 可见状态、模块开关或旧插件不能在升级后恢复已移除的产品入口。保留通用插件管理和现有其他插件的加载、禁用、休眠行为。

## 5. 持续合并上游的约束

1. 保持上游主要目录结构、文件名、Swift target、通用 Rust C ABI、JSON 命令和模块 ID 的稳定；Maven/Spring 专用契约随功能移除，同步修改所有剩余消费者；本轮不做大规模重命名、格式化或架构重写。
2. 把四类改动组织为可独立评审的补丁单元：Java 默认打包、Maven/Spring 产品行为、Windows、Linux.do。提交时避免与其他功能迭代混成一个提交；提交和推送分别以用户明确授权为准。
3. 产品差异尽量集中在现有打包、组合和注册边界。只有多个消费者确实需要时才增加集中配置，避免到处散落条件编译或构建第二套功能开关系统。
4. 保留有用的上游通用实现与测试。对共享大文件，只修改移除功能实际依赖的代码段。
5. 上游合并后重新检查 Java 资源是否被加入默认包、Windows 工作流是否复活、Linux.do 是否被重新注册，以及 Maven/Spring 的自动工作流是否恢复。
6. 以功能契约和产物检查保护裁剪边界；检查某个词是否出现不能替代行为验证，也不能据此删除普通 XML、配置解析或通用运行能力。
7. 定期合并上游时，优先解决上述集中差异，再验证保留能力；避免长期积累大批上游变更后一次合并。

## 6. 实施与验收顺序

| 顺序 | 工作 | 验收条件 |
| --- | --- | --- |
| 1 | 建立当前单架构构建与保留功能基线 | 保存包体构成、默认资源与关键操作结果 |
| 2 | 退出 Java 默认资源并彻底删除 Maven/Spring | 没有 Java 资源仍能正常打开项目；通用 Run/Test/Debug 保持可用 |
| 3 | 删除 Windows 产品链路和 Linux.do 集成 | macOS 构建/CI 无失效路径；社区入口和专用进程不再出现 |
| 4 | 回归保留功能与升级状态 | 数据库/MCP、AI、Git/GitHub、终端、其他语言、编辑器、配置高亮、Markdown、主题和背景保持现有行为 |
| 5 | 记录差异与上游合并检查项 | 明确实际删除、通用职责保留情况、体积变化和未执行的验证 |

工程验证沿用 develop-lithe 与 write-stable-tests。修改测试时先运行稳定性静态检查，再运行带逐用例计时的相关测试；Swift、Rust、服务边界、共享契约与打包检查按实际改动范围执行。所有测试启动的应用和子进程在结束后清理。

## 7. 实施结果与编译器问题

已删除 Maven/Spring 的专用实现、UI、契约、索引器、运行检测器、配置项、依赖、资源和测试；通用运行/调试基础设施与 Java 文本解析保留。Java 运行元数据使用 `extensions.java`。旧 Maven provider 返回 `unsupportedProvider` 诊断，不阻塞其他语言配置。

Windows 产品、插件和专属构建/发布工作流已删除。Linux.do 的插件、工作台、授权和 Rust 社区实现已删除；旧插件安装记录保留在磁盘，但在扫描和加载前跳过，且不可重新安装。

默认打包、预览与发布缓存不再准备或复制 Java 工具链资源。Go 插件、数据库 helper/MCP、SwiftTerm、Markdown 和其他资源继续沿用上游流程。Git 图样例改为无框架 Java 项目，保留原分支、合并、Rebase 和标签覆盖。

macOS 完整编译遇到的崩溃属于 Swift 6.2.4 调试类型重建：`EditorTabFlowPlanner.rows()` 的局部函数捕获可变 `CGFloat`，触发 `Failed to reconstruct type` 断言。独立最小复现同样退出 134；加入 `-Xfrontend -disable-round-trip-debug-types` 后通过。现有构建脚本已有同类规避，本次补到 `Package.swift` 的应用目标，使直接 SwiftPM 入口也得到保护。布局行为和 Swift 语言模式未修改。

已完成真实 Rust Core 链接的 930 项 Swift 测试、326 项 Rust 测试、Swift/C ABI 桥接与符号校验、Core/Git Graph、官方 Go 插件加载、服务边界、共享契约、CI 分类器、下载缓存测试和 actionlint。Swift 与 Rust 的逐项计时报告位于 `.artifacts/test-stability/index.html`，全部通过，无测试超时或剩余测试进程。arm64 与 x86_64 Release 均编译成功，默认 universal 应用和 DMG 验收通过。

## 8. 产物与替换安装

安装沿用当前源码的版本 `0.1.0`、构建号 `3`，未修改版本元数据。2026-09-05 将已完成的 arm64 Release 主程序按现有打包脚本组装资源、数据库助手和 Go 插件，并替换 `/Applications/Lithe.app`。应用标识仍为 `app.lithe.desktop`；未修改应用外的设置和项目数据。安装时保留的旧版应用备份已按用户要求删除，安装记录在 `.artifacts/arm64-install/installation.json`。

安装前后均验证应用及两个数据库助手、Go 插件的 arm64 架构，并通过 `codesign --verify --deep --strict`。确认 SwiftTerm Metal shader 等必要资源存在，默认包没有 JDK、JDTLS 和 Linux.do 插件。安装后的主程序 SHA-256 与待安装产物一致；构建 UUID 与刚完成的 Release 主程序一致。

以下应用大小为普通文件逻辑字节数之和，不是文件系统分配空间；DMG 为实际文件长度。

| 产物 | 字节数 | MiB |
| --- | ---: | ---: |
| 替换前本机 arm64 应用（0.4.2） | 501,469,707 | 478.2 |
| 本次 arm64 应用（0.1.0） | 84,572,801 | 80.7 |
| 本次 arm64 DMG | 32,690,572 | 31.2 |
| 本次 universal 应用 | 160,692,973 | 153.2 |
| 本次 universal DMG | 55,943,131 | 53.4 |

本机应用文件总量减少约 83.1%。其中 Resources 从 419,752,183 字节降至 11,036,201 字节；替换前 LanguageServers 占 408,624,634 字节。两个数据库助手合计从 9,545,344 字节变为 9,578,288 字节，仍随包保留。与第 2 节公开的 arm64 DMG 相比，本次压缩包约小 89.2%；该比较涉及不同版本与构建环境，不能将全部差额归因于某一项删除。

可保留产物为 `.artifacts/arm64-install/Lithe-arm64.app` 和 `.artifacts/arm64-install/Lithe-0.1.0-arm64.dmg`。默认 universal 验证使用临时目录并在成功后清理，测量记录保存在 `.artifacts/package-verification-final.log`。本次没有执行逐功能手工 UI 验收，也没有启动并留下 GUI 应用实例。

## 9. 最终验证记录

使用本机独立解包的官方 Swift 6.2.4 工具链运行以下命令；没有替换系统工具链。完整测试命令如下，Swift 用真实 Rust Core 静态库强制链接：

```sh
export PATH="$PWD/.artifacts/toolchains/swift-6.2.4/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin:$PATH"
scripts/build-rust-core.sh --debug --target aarch64-apple-darwin
.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- \
  -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs \
  --manifest rust/Cargo.toml --package lithe-core \
  --report .artifacts/test-stability/rust-core.json
scripts/verify-core.sh
scripts/verify-git-graph.sh
scripts/verify-official-plugins.sh
scripts/verify-macos-package.sh
git diff --check
```

Swift 最终运行覆盖 96 个 suite、930 个用例，测试阶段耗时 35.438 秒。Rust 逐用例报告覆盖 326 个用例，全部通过。HTML、JSON、JUnit 报告位于 `.artifacts/test-stability/`，已检查结果与逐项耗时。本轮修改过的测试中耗时最高的五项如下：

| 测试 | 耗时 |
| --- | ---: |
| `workspaceWatcherProjectsTypedJavaChangesWithoutReloadingForSourceEdits` | 370 ms |
| `configurationWriteRejectsLitheSymlinkOutsideProject` | 210 ms |
| `startingASingleProcessServiceCreatesItsOwnSession` | 195 ms |
| `generationPublishesNoEntryResultAndKeepsCurrentFileAvailable` | 150 ms |
| `unchangedLocalOptionsDoNotRewriteTheConfigurationFile` | 123 ms |

没有因本机平台限制而未运行的保留产品测试套件。Windows 已退出产品范围；不再执行 Windows 构建和测试。本任务启动的测试运行器、验证器和数据库助手均已退出。安装完成后检测到 `/Applications/Lithe.app` 被外部启动；本任务未发起该启动，保留正在使用的安装版实例。

## 10. v0.4.5–v0.5.0 上游集成与验收

2026-09-21：以本分支既有实现为 base，按版本顺序完成上游集成。第 7–9 节保留的是 2026-09-05 的历史验收；本节记录新的合并和验证，不将两次结果混用。后续合并原则已写入 [AGENTS.md](../../AGENTS.md#upstream-integration-principles) 和 [CLAUDE.md](../../CLAUDE.md)，提交 `9a30b884`。

### 合并历史与取舍

| 上游版本 | 原始上游提交 | 本地合并提交 |
| --- | --- | --- |
| 0.4.5 | `03e40473` | `72b71b8c` |
| 0.4.6 | `588daa33` | `5d1a26ad` |
| 0.4.7 | `931b0e1a` | `8fc0148e` |
| 0.4.8 | `5fa0db9c` | `73906227` |
| 0.4.9 | `78da9bad` | `3c1d7119` |
| 0.4.10 | `78622012` | `75ad8ded` |
| 0.5.0 | `a7eec237` | `e1a0e392` |

以上上游提交均作为原始历史保留，并是最终分支的祖先；没有将它们压成一个重新署名的提交。原始作者、提交消息和 SHA 保留，适配与验收修复另行提交。逐路径取舍和父提交证据保存在 `.artifacts/upstream-045-050/`，最终祖先记录为 `final/ancestry.json`。

持续排除 Windows 产品、Java 框架和工具链增量，以及 Linux.do 恢复。按用户决定继续使用 AppKit/NSTextView，暂缓 Monaco 及其前端、minimap、主题和专属协议迁移。保留 Go/Rust/Python、官方 Go 插件、原生窗口归属，以及项目替换的真实 Apply、文档修改租约、过期结果检查、共享撤销与补偿事务。

本轮保留 Git 图与执行日志、精确本地排除、Run 勾选/固定/批量启动、工作区 LSP 开关持久化、原生编辑与输入法修正、搜索替换预览、外部修改保存保护、HTML/SVG 预览和通用构建验证改进。Git 命令仍由真实执行事件和项目 journal 统一拥有，避免重复日志或 Clear 后晚到回填。Run 的 `project`/`infrastructure` 分类保留在共享 JSON 契约和 Compose 检测中；macOS 没有新增 Infrastructure 分组或基于分类的 Run All/default 规则。

### 验收中修复的问题

- `c4bd52af`：修复配置加载期间勾选恢复的时序和批量启动输出归属；`a5b912ed` 进一步移除 Run 视图抢选首个勾选配置及切换 Console 的行为。
- `33f83f7f`：兼容旧 SDK Foundation 对 `about:blank#fragment` 的解析，保留 HTML 页内锚点。
- `b4fbabb8`：修复签名安装包中 HTML 相对 CSS/图片不能加载的问题。平台适配器通过文档目录限定的本地 scheme 提供资源，离开该目录的路径和符号链接不能越界；停止的请求不再晚到回调。预览仍直接使用当前缓冲区，不先执行磁盘 HTML 或生成临时 HTML。
- `3bd13936`：Swift 桥接 DTO 保留 Run category，防止 Rust 生成的 Compose 分类在 Mac store 重写时丢失。
- `5f9325be`：预览订阅、资源处理器与 WKWebView 按文档身份共同管理，避免切换标签后旧预览滞留；分栏尺寸仍由外层原有容器保留。最终提交与安装结果见下方验收记录。

- `1ae1a9cb`：实际 HTML 输入 emoji 触发 `identifier(at:in:)` 对代理项的强制解包崩溃；改为安全判断单个 UTF-16 code unit，补充真实 NSTextView 插入、光标和共享撤销回归。最终提交与验证结果随安装记录归档。

### 工程验证与实际操作

使用官方 Swift 6.2.4，应用维持 Swift 5 语言模式、测试维持 Swift 6；完整 Swift 测试强制链接真实 Rust Core，并显式启用 Run 配置、Git execution 和 LSP sync 的集成测试开关。最终完整 Swift 1517 项、Rust Core 513 项通过；Git host 6、项目元数据 18、Git C ABI 12、console/LSP bridge 10、Git 性能 debug 20/release 2、Rust 注释扫描器 8 项专项记录通过。合并报告共 2106 条通过记录，部分专项与完整 Swift 覆盖重叠，不作为不重复用例数；没有跳过项或超出硬时间预算的用例。已打开 HTML 汇总检查；45 条记录达到慢测试警戒线，但未超过硬预算。

Rust 格式/注释/文档、服务边界、共享契约、测试稳定性、Core、Git Graph、官方 Go 插件、CI 分类器/actionlint、更新清单和实际包体检查通过。测试等待和清理边界保持有界，没有为通过验证整体放宽预算。最终日志、逐项 JSON/HTML/JUnit 报告在 `.artifacts/upstream-045-050/final/` 和 `.artifacts/test-stability/`；主汇总为 `final/timing/index.html`。

完整 Swift 验证命令如下（PATH 使用第 9 节记录的 Swift 6.2.4）。新增的 emoji/组合 emoji 输入回归共 2 个参数场景，计时 23 ms；HTML 导航/资源和 Run category 回归也在完整报告中，专项探针证据另存于对应 prepared 目录。

```sh
LITHE_RUN_RUN_CONFIGURATION_INTEGRATION=1 \
LITHE_RUN_GIT_EXECUTION_INTEGRATION=1 \
LITHE_RUN_LSP_SYNC_BRIDGE_INTEGRATION=1 \
.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  --suite-timeout-seconds 900 \
  --report .artifacts/test-stability/macos-upstream-final-unicode-caret.json \
  -- -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
```

各轮系统安装版完成以下实际操作，原始截图、AX 状态和断言记录在 `final/ui/results.json`：

- 原生 SVG 编辑即时预览、保存、撤销和分隔条边界；CRLF/中文/emoji 的精确保存；同大小同 mtime 外部修改重载，以及脏缓冲区冲突时保存不覆盖外部写入。
- Search Everywhere 普通文件与 slash 命令查询；两个原生终端执行独立命令；本地 Git 图、成功与失败 remote 的 Fetch 日志、精确暂存两个文件、中文/emoji 多行提交消息和实际本地提交。
- 项目替换预览 6 个文件 11 处匹配，只选择 README 的 3 处并保留大小写；Apply、保存后逐字节核对，共享撤销再保存恢复原始内容。
- Go/Rust 勾选批量运行得到各自预期输出；重开后 Rust 勾选和 Go 固定保留；重新扫描后的四个 Compose 配置 category 保留；运行勾选 Rust 时保留 Go 的详情页，随后手动选择 Rust 可见成功输出。

- HTML 在安装版 `5f9325be` 中按 index → other → anchors → index 来回切换，当前文档与 CSS/SVG 预览一致；原生 emoji 输入随后暴露的崩溃由 `1ae1a9cb` 修复，两个真实 NSTextView 输入/撤销回归通过。
- 工作区 Go 语言服务在设置中显示 Running，关闭开关后停止；本次结束时已删除仅属于验收项目的临时禁用偏好，恢复默认启用。

**尚未完成的实机复验**：安装最终 `1ae1a9cb` 后，桌面已锁定，前台为 `loginwindow`，无法再执行原生 emoji 输入、未保存 HTML 预览及 Go LSP 重启状态检查。已请求解锁；这些项目不计入 UI 通过项。最终自动化测试包含这次输入崩溃的两个参数回归（23 ms），但不将自动化结果等同于安装版的最后一次手工/界面操作。

### 安装、清理与范围限制

最终 ARM64 Release 构建成功（182.77 秒），已原子替换 `/Applications/Lithe.app`。产品提交 `1ae1a9cb5a44f3324e2c6ed1a59b88104d24f41a`，版本维持 `0.1.0`；主程序 SHA-256 为 `e52746edba0534b89a4008fd81cd40a1326a4ca64f647753fd4d75971497d66f`，UUID 为 `BE24A893-32BF-367F-8657-D70E540A6069`。安装前后签名、架构、必需资源与主程序校验值一致；包内没有 JDK/JDTLS 或 Linux.do 插件。记录为 `final/installed-verified/installation.json`，产物为 `final/package-verified/Lithe-arm64.app`。

构建标记保留真实的 `dirty=true`：构建期间另有四份架构文档正在编辑；已检查未提交差异全部限定在这些文档，产品源码与上述提交一致。本次不覆盖或提交这些并行文档修改。后续仅补充本验收记录，不为文档文字再次重建应用。

本轮测试启动的 Lithe、数据库助手与语言服务已退出，自动保存恢复默认，输入法恢复为任务前的选择；清理记录为 `final/cleanup.json`。未推送、打 tag 或发布远端 release。

本轮验证针对 macOS ARM64 和当前 Swift 6.2.4 工具链，没有新增 x86_64、Windows 或未来 Xcode 版本的实机通过声明。Python/Debug、其他 LSP 语义操作、跨窗口归属和异常时序使用对应自动化覆盖；没有将它们全部表述为本轮逐项手工实测。Compose 只验证检测、命名与持久化，没有启动 Docker 服务。HTML 显式绝对 `file:` 资源仍受 WebKit 自身权限约束；相对文档资源已有签名应用探针与安装版验证。

## 11. 原生 Git 装订线与项目切换设置窗口复修

2026-09-22：用户反馈的装订线问题指绿色 Git 竖线，Go 与 Rust 均适用。初次提交 `4f0a71b1` 中无关的装订线收窄调整已撤回，恢复既有列宽；其中设置窗口修复继续保留。用户截图对应的 Rust 子仓库尚无首次提交，文件为 staged-added；原生编辑器曾把整份新文件 diff 的所有新增行都绘成分段绿条。

在同一个隔离示例仓库中实际打开 GoLand 2025.2.4 与 RustRover 2026.2.1，确认两者均采用以下效果：尚未首次提交的新文件以文件名颜色表示新增，不绘制逐行 Git 标记；建立首次提交后插入连续两行，则只在两行旁绘制一段连续绿条。截图与 Git 状态记录位于 `.artifacts/ui-gutter-settings-0922/reference-comparison.json` 及同目录四张 `goland-*` / `rustrover-*` 截图。

修复限定在现有原生编辑器和 Git feature：

- `GitFeatureModel.loadLineChanges` 对 added 文件清空行标记和 hunk 缓存，跳过装订线 diff 读取；Changes 中的完整文件 diff、暂存与提交工作流保持原有路径。
- 相邻、同类型、同 hunk 的新增/修改行绘为连续色条，覆盖逻辑行的全部软换行片段；未修改行与隐藏行不连接，删除标记保持首个显示行上的短标记。
- `ProjectSettingsWindow` 不再因隐藏设置视图在切换项目时重建而主动显示。显式设置请求、延迟绑定窗口、关闭后重开仍可用。`4f0a71b1` 安装版已完成关闭设置窗口前后各 8 个切换检查记录，以及显式重开设置的实机检查；其中相邻记录存在同一项目，不能将其表述为 16 次不同项目间的切换。证据为 `ui/results.json`；该历史结果不替代下一安装版的最终复验。

已执行 Swift 6.2.4 真实 Rust Core 链接的失败回归与修复验证。新增文件覆盖 `??`、`A `、`AM`、已跟踪 staged/unstaged、完整 diff 与旧 hunk 操作失效；AppKit 像素回归覆盖连续新增、软换行、清除标记及删除锚点。定向 182 项测试通过，报告为 `.artifacts/test-stability/git-gutter-affected-final.html` 和对应 JUnit；测试稳定性静态检查、服务边界和 whitespace 检查通过。

历史锁屏运行的完整 1523 项测试中 1522 项通过，唯一失败为既有 `nativeRollbackUsesWrittenIdentityAndPreservesExternalWriter`。当时独立探针确认普通临时文件可读，使用 `.completeFileProtectionUnlessOpen` 写入并关闭的临时文件读取报 EPERM，与失败路径一致；记录为 `.artifacts/ui-gutter-settings-0922/file-protection-locked.log`。没有为让测试通过而修改文件保护行为。历史报告为 `.artifacts/test-stability/git-gutter-final-full.html`：14 个既有性能警告，无硬预算超限；本轮新增 Git 策略测试各 1 ms、绘图回归 64 ms，两个设置窗口回归 242 / 131 ms。

解锁后已重新执行真实 Rust Core 链接的完整 Swift 测试：1523 项、183 个 suite 全部通过，无跳过或硬预算超限，14 个性能警告；测试用时 46.400 秒，进程用时 52.232 秒，文件回滚的两个参数场景均通过。证据为 `.artifacts/test-stability/git-gutter-unlocked-full.{json,html,junit.xml}` 和 `.artifacts/ui-gutter-settings-0922/marker-unlocked-full.log`。这解决了历史锁屏失败，不代表随后发现的 Undo 问题已修复。

在 `69a56d67` 安装版中，已实际确认用户原始 Rust `simple/httpie` 文件以及隔离 Go/Rust 新文件均不再绘制整文件绿条；首次提交后原生输入两行注释并保存，均显示对应的连续绿条。Go 原生 Undo 加保存后标记清除、磁盘内容恢复为 HEAD。截图为 `ui/unlocked-original-httpie.png`、`ui/unlocked-new-main-{go,rs}.png`、`ui/unlocked-modified-main-{go,rs}.png` 和 `ui/unlocked-restored-main-go.png`。

随后在同一 `69a56d67` 安装版补完设置窗口的独立实机复验：两个隔离项目实际交替切换 8 次，显式打开设置并用原生红色按钮关闭，再交替切换 8 次；每次记录不同的前后项目标题，并持续 1.2 秒检查设置窗口未显示，最后显式重开成功。记录为 `ui/results.json` 的 `69a` 条目，截图为 `ui/69a-settings-*`。该项通过不等于尚在修复的 Undo 已通过。

同一实机操作中，切回 Rust 后 Cmd+Z 导致崩溃；另一次启用 Zombie 的安装版复现明确记录 `NSConcreteTextStorage _undoRedoTextOperation:` 向已释放对象发送消息。根因为项目共享撤销栈中的原生 TextKit 目标比历史记录更早释放。证据为 `crash-undo-rust.ips`、`zombie-ui.stderr.log`、`crash-undo-rust-zombie.ips`；修复方案在本地 `native-undo-design.md`。新增自动回归的 red2 分组/释放前提无效，red3/red4 在释放前提失败，不能冒充已重现崩溃的自动测试；实机 Zombie 证据独立成立。

2026-09-22 当时剩余验收为稳定文档 Undo 修复和自动回归；2026-10-06 已完成这两项（见第 12 节）。当前仍需重新构建替换系统安装，验证跨文件 Undo/Redo、软换行标记、最终版本的多项目交替切换与设置窗口显式开关，以及尚未结束的 emoji、未保存 HTML 预览和 Go LSP 跨重启检查。上述项目完成前，不声明最终安装版整体实机验收通过，也不进入后续 P0/P1 功能实施。

ARM64 Release 构建已成功（198.01 秒），产品提交 `69a56d679f43c6fb139989aa7aaffa79eda40410`，并已原子替换 `/Applications/Lithe.app`。签名、架构、必需资源与程序校验值核验一致，主程序 SHA-256 为 `b297731f5e5cf124cbc3e424444bf6a0ab68e526ba515eb2d3c8f8a837e1df89`，安装凭据为 `.artifacts/ui-gutter-settings-0922/installed-final/installation.json`。版本仍为 `0.1.0`；`dirty=true` 仅对应前述四份并行修改的架构文档。本段为安装后的文字补记，不重建产品。

安装后未在锁屏状态下留下新的 Lithe 实例。解锁后已关闭 GoLand 中本次创建的 `git-gutter-comparison` 对照项目，原先已运行的 GoLand 及用户项目保持不动，实际 Window 菜单记录为 `goland-menu-cleanup.jsonl`。Zombie 复现结束后 Lithe、数据库 helper 和语言服务均无残留，输入法恢复原选择；清理记录为 `.artifacts/ui-gutter-settings-0922/cleanup-after-zombie.json`。这些清理记录不替代后续修复验收结束时的再次清理。


## 12. 原生 Undo 生命周期修复（2026-10-06，安装验收待完成）

共享撤销历史改为由 `WorkspaceTextEditUndoController` 保存文档级增量，目标不再依赖临时
`NSTextStorage`、编辑视图或 Coordinator。已接入的原生编辑器停止向 AppKit 登记文本
Undo；键盘、菜单和右键操作使用同一项目历史。跨标签重建保留顺序、选区和 dirty 状态，
关闭文档只移除该文档的原生记录，外部重载通过 generation 拒绝旧范围。项目替换仍走
原有磁盘事务及补偿路径。

连续输入、同向删除可合并；移动光标、保存、切换编辑器、粘贴、换行、替换和 IME 提交
形成相应边界。嵌套输入事件只登记一次 IME 提交，Replace Next 的整次操作包含最终选区。
历史回放按 UTF-8 字节比较同步缓冲区，保留规范等价 Unicode 的不同编码，并刷新搜索、
折叠和软换行状态。

原生回放在 MainActor 同步执行，拒绝现有 mutation lease，但不额外获取多文件事务租约：
这样保存进行中仍可 Undo，保存任务只确认它捕获的旧字节，不覆盖当前缓冲区。独立审查
核对了保存任务所有权；该选择是对本地初始设计的明确修订，磁盘事务的 lease 不变。

独立审查发现并经失败回归确认了直接 `keyDown` 撤销误登记、嵌套 IME 重复记录、Unicode
同步漏更新、Find 匹配过期和 Replace Next 最终选区丢失，修复后复审没有剩余源码阻断项。
定向 20 项测试通过，报告为 `.artifacts/test-stability/native-undo-review-green.{json,html,junit.xml}`。
生命周期回归使用有期限的 deinit 信号，实际释放视图、Coordinator 和 TextKit 存储后才
执行 Undo/Redo，不通过清栈或保活旧视图规避问题。首次完整运行发现只等待视图释放仍早于
存储释放，已改为独立等待三个对象。最终 Swift 6.2.4、真实 Rust Core 链接的完整重跑
通过：1539 项、184 个 suite，44.822 秒；1528 条独立计时记录均通过，无跳过、硬预算
超限。报告为 `.artifacts/test-stability/native-undo-final-full4.{json,html,junit.xml}`。默认
`groupsByEvent = true` 的自动闭组顺序回归通过。测试稳定性、服务边界及 whitespace
检查通过。

本次尚未完成安装版实机验收。GoLand/RustRover 已尝试实际打开隔离文件，桌面控制接口
出现窗口不可用和超时；这些尝试不算体验对比通过。第 11 节剩余 UI 项和后续规划继续
保持未完成。原始日志与当前验收记录位于 `.artifacts/ui-native-undo-1006/`。
