# 一期限定裁剪范围与上游合并策略

日期：2026-09-05。状态：限定裁剪、完整构建与安装包验收已完成；arm64 版本已替换本机安装。

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
