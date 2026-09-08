# B7b：运行入口 gutter 与右键运行配置

状态：基于 `3680935d` 的初稿；2026-09-08 真实 gopls 探针发现候选判定与生命周期缺口，
**方案尚未放行，产品实现未接通；已先落地 §4.1 的共享契约骨架，修订约束见 §3.1。** 对应总方案要求 9
（[入口运行与参数](goland-parity-implementation.md)）中的编辑器侧部分。
参照基线为本机 RustRover **2026.2.1 / 262.9437.161** 与 GoLand **2025.2.4 / GO-252.27397.100**。

本文只覆盖**编辑器 gutter 的运行入口与其右键配置**。右栏工具窗口见
[B7a3 Go Tools](goland-parity-b7a3-go-tools-done.md) 与
[B7a2c2 Cargo](goland-parity-b7a2c2-cargo-tool-window-done.md)。

## 1. 目标

在编辑器左侧行号槽显示运行入口标记，点击可运行，右键可配置参数与环境变量，
交互与 RustRover / GoLand 一致：

1. `func main` / `fn main` / `if __name__ == "__main__"` 行显示 ▶ 标记。
2. 测试函数（`func TestXxx` / `#[test]` / `def test_*`）显示测试运行标记。
3. 左键点击标记 → 弹出菜单：Run '<name>' / Debug '<name>' / Modify Run Configuration…
4. 右键点击标记 → 同一菜单（GoLand 两者行为一致）。
5. Modify Run Configuration 打开配置编辑器，可改**程序参数、环境变量、工作目录、
   工具链/包/target 选择**，保存后再次运行生效并持久化。
6. 标记位置随折叠、软换行、字体大小变化保持正确；不显示在被折叠隐藏的行上。

## 2. 现状核查

每条已在当前 HEAD 核对。

### 2.1 已具备（直接复用）

| # | 事实 | 位置 |
| --- | --- | --- |
| E1 | gutter 已有**独立的图标列** `implementationRange`（宽 20pt，位于 breakpoint 与 fold 之间），并已参与 `hitTarget(at:hasGitChange:)` 命中判定 | `CodeEditorView.swift:486,506,527` |
| E2 | 该列已有完整的绘制样例：`drawImplementationMarker` 处理同行两个标记的 `sharesLine` 分半布局、图标回退绘制 | `CodeEditorView.swift:4623-4658` |
| E3 | 该列已有完整的点击分发样例，含同行多标记时按 x 位置选择 | `CodeEditorView.swift:4999-5008` |
| E4 | gutter 已有右键菜单入口 `menu(for event:)`，breakpoint 列已接 | `CodeEditorView.swift:5013-5019` |
| E5 | 语言能力变化时刷新/清除标记的状态迁移已建模 | `EditorLanguageFeatureTransition`，`CodeEditorView.swift:462-478` |
| E6 | 运行配置解析链路完整：`RunConfigurationResolution`（configurations + diagnostics + defaultConfigurationID + projectToolchain）、`EffectiveRunConfiguration`（configuration + options + source） | `macos/Sources/LitheCoreContracts/Execution/RunConfigurationContracts.swift:90-123` |
| E7 | 配置编辑器已是 capability-driven，已支持分层 override 与工具链模型 | B7a2c2 记录；`RunConfigurationIntegrationTests.swift` |
| E8 | Cargo 双击运行的完整链路（启动 + 打开 Run 工具窗口 + 输出跟随）已验收 | `goland-parity-b7a-go-cargo.md:30` |

### 2.2 缺口

| # | 事实 | 位置 |
| --- | --- | --- |
| G1 | **没有任何「运行候选 → 源码行号」的数据来源。** `LanguageRunExtensionProviding` 只有 `launchPlan(for:)`；`LanguageTestExtensionProviding.discoverTests` 返回的 `LanguageTestExtensionItem` 只有 `id/label/kind/relativeFilePath`，**没有行号** | `GoExecutionCapability.swift:44-66` |
| G2 | 图标列被 `JavaImplementationMarker` 独占：绘制、命中、状态迁移三处都写死该类型 | `CodeEditorView.swift:4623,5001,470` |
| G3 | 检测器产出的是**目录级**配置（`go run .` / `cargo run --bin X`），没有源码位置；`ProjectMetadataTarget` 有 source locations 但那是**文件**级，不是函数行 | `detectors/go.rs`、`detectors/cargo.rs`、`project_metadata/types.rs` |
| G4 | 无 gutter 运行图标资源 | `LitheIcons` 只有 `implementationMarkerImage` |

**G1 + G3 是本批的核心工程量**：产品当前完全没有「哪一行可以运行」这个信息。
gutter 的绘制与交互反而是现成的。方案的重点必须放在这个数据来源上。

## 3. 运行候选的来源：三条路径，按语言分别选定

「哪一行可以运行」有三种可能来源。**本方案明确选定每种语言用哪一条，不做「都试一遍取并集」**
——那会产生不稳定、不可解释的 gutter 图标。

| 路径 | 机制 | 可用性 |
| --- | --- | --- |
| A. LSP `documentSymbol` | 取函数符号的 `selectionRange`，按命名规则匹配 `main` / `TestXxx` | **依赖 B6a2**。当前客户端未声明 `documentSymbol` 能力，gopls 只返回扁平 `SymbolInformation[]`（无 `selectionRange`）——见 [B6 §1.2 N5](goland-parity-b6-refactor.md) |
| B. 语言服务器专有 runnables | rust-analyzer 的 `experimental/runnables` 直接返回可运行项及其 range | rust-analyzer 支持；gopls **不支持**；需要新增非标准请求 |
| C. Tree-sitter `runnables` query | 离线语法层按 query 产出候选 | **依赖 L8**（[syntax-and-completion.md §6.1](syntax-and-completion.md) 明确 `runnables` 槽位属 L8） |

**选定：**

- **Go**：路径 A。gopls 的 `documentSymbol` 在补齐 `hierarchicalDocumentSymbolSupport` 后
  返回带 `selectionRange` 的 `DocumentSymbol[]`（B6 §1.2 N5 已实测）。
  `main` 函数与 `Test*/Benchmark*/Example*` 由宿主按 Go 测试命名规则匹配。
- **Rust**：路径 B 优先，A 兜底。rust-analyzer 的 runnables 比命名匹配准确
  （能正确处理 `#[cfg(test)] mod tests`、`#[bench]`、doc test）。
  仅服务器仍正常工作、专有请求明确不支持时可以退到 A；服务器不可用时两条路径都不可用。
- **Python**：路径 A。`if __name__ == "__main__"` 不是符号，需要额外的语法判定 →
  **Python 的 main guard 入口推迟到 L8**，本批只交付 Python 的 `test_*` 函数标记。
- **路径 C** 在 L8 落地后作为**离线兜底**接入同一个 port，不改 gutter 侧任何代码。

**因此 B7b 的硬前置是 B6a2**（`documentSymbol` 能力协商 + 请求白名单 + 结果解析）。
在 B6a2 交付前不得开始 B7b 的实现；提前实现只能得到基于正则的假入口。

### 3.1 实测发现与修订约束（2026-09-08）

本节优先于下方初稿中的 Go 字符串匹配和仅 revision 校验。当前方案仍需解决这些问题后重审：

- gopls 0.20.0 的符号 detail 保留导入别名（`func(t *tt.T)`）和类型别名（`func(t *T)`），
  因而不能只匹配 `*testing.T`。Go 1.24.4 的 `cmd/go/internal/load/test.go` 还接受裸前缀
  `Test` / `Benchmark`；`TestMain(t *testing.T)` 也是普通测试，只有 `*testing.M` 才是测试主入口。
- gopls 的 `test` CodeLens 默认关闭，开启后仍漏掉别名参数的 `TestAlias`。
  `gopls.packages` 的 TestFiles/Tests/Loc 同样漏此项，并把无 Output 的 Example 列入。
  因此二者均不能单独作为完整、可执行的测试列表。独立无副作用 fixture 中真实
  `go test -list .` 返回 `Test`、`TestAlias`、`Example`，不包含 `ExampleNoOutput`。
- 候选来源必须覆盖别名、Output/Unordered output/空 Output、接收者、类型参数、构建标签和
  外部测试包。自动发现不得运行项目 init/TestMain；`go test -list` 仅用于受控验收 fixture，
  不能直接进入编辑器自动刷新路径。需要确定可靠语法/语义来源，再修改 §5 的 Go capability。
- 异步请求与菜单执行均须携带 workspace、document、provider/session 的身份及 generation，
  加上文档 revision、元数据 generation 和 operationID。关闭、切换工作区、禁用插件、
  LSP 重启、编辑与新请求必须取消或废弃旧结果，不能仅比较两个可能相同的 revision 数字。
- Python main guard 仍属于 L8；本批的 Python 测试入口也必须绑定实际可用的运行提供者，
  不得仅因函数名以 `test_` 开头就展示无法执行的菜单。

证据位于 `.artifacts/plan-implementation/b7b-probe/`：`symbols-and-lenses.json`、
`enabled-test-lenses.json`、`package-tests.json`、`alias-go-test-list.log`。
探针均有截止时间并已退出；这些结果是方案输入，不能计为 gutter 产品验收。

## 4. 契约变更

### 4.1 新增运行候选 port

新建 `macos/Sources/LitheCoreContracts/Execution/RunnableMarkerContracts.swift`：

```
/// A runnable entry point discovered inside one open document.
package struct DocumentRunnable: Equatable, Sendable, Identifiable {
    package let id: String            // 稳定 ID：configurationID + kind + symbolPath
    package let configurationID: String?  // 已有配置时非 nil；nil 表示需临时计划
    package let displayName: String   // 菜单里的 '<name>'
    package let kind: Kind            // application / test / benchmark / example
    package let line: Int             // 一基行号，与产品其他位置一致
    package let symbolRange: LanguageServerRange  // 用于版本校验与折叠判定

    package enum Kind: String, Sendable { case application, test, benchmark, example }
}

package struct DocumentRunnableSet: Equatable, Sendable {
    package let documentID: String
    package let documentRevision: Int   // 产出时的文档版本
    package let runnables: [DocumentRunnable]  // 按 line 升序，稳定去重
}

@MainActor
package protocol DocumentRunnableProviding: AnyObject {
    func runnables(
        documentURL: URL,
        text: String,
        revision: Int,
        completion: @escaping (Result<DocumentRunnableSet, Error>) -> Void
    )
}
```

约束：

- `line` 为**一基**（与产品其他显示位置一致）；`symbolRange` 为 LSP 的零基 UTF-16 坐标。
  两者的换算只在这一处发生，不在 View 里再算一次。
- `documentRevision` 必须回显。**revision 与当前编辑器不一致的结果一律丢弃**，
  不允许把旧版本的行号画到新文本上——这是 gutter 类功能最典型的错位来源。
- 结果按 `line` 升序、按 `id` 去重，保证确定性。
- 同一行多个 runnable（如 Rust 的 `mod tests` 同时有 mod 级与 fn 级）：**只保留最具体的一个**，
  由 provider 决定，不在 View 里裁决。

### 4.2 gutter 图标列泛化（G2）

`implementationRange` 当前被 `JavaImplementationMarker` 独占。改为承载两类标记：

- 保留字段名 `implementationRange` **不变**（改名会波及绘制/命中/测试三处，且无收益）。
- 新增 `runnableMarkers: [DocumentRunnable]`，与 `implementationMarkers` 并列。
- `hitTarget` 返回 `.implementation` 时，**先查 runnable 再查 implementation**：
  IDEA 的实际行为是运行图标优先占据该列。
- 同行既有 runnable 又有 implementation marker 时：runnable 占据整列，
  implementation marker 在**本批不显示**并在验收表标注为已知差异
  （IDEA 会合并成一个复合图标，本批不做）。
- `EditorLanguageFeatureTransition` 增加 `refreshRunnableMarkers` / `clearRunnableMarkers`，
  门控位为 `.documentSymbol`（B6a2 新增）。

### 4.3 临时运行计划

RustRover 双击 lib/test/bench/example 走 `cargo build --lib` / `test --test N` 等
**临时命令行**，而 Lithe 的 `RunConfiguration` 只携带 id/name/kind，由 `RunService`
按 id 反查条目，**没有临时运行通道**（`goland-parity-b7a-go-cargo.md:23`）。

gutter 上的测试入口正是这种情况：`func TestFoo` 不会有持久配置。因此本批必须新增
**临时运行计划通道**：

```
package struct EphemeralRunPlan: Sendable {
    package let displayName: String
    package let languageID: String
    package let workingDirectory: URL
    package let arguments: [String]      // 由语言 capability 投影，View 不拼
    package let environment: [String: String]
}
```

约束：

- 临时计划**不写 `generated.json`**，不进入配置列表，不改变 `defaultConfigurationID`。
- 用户在 Modify Run Configuration 中点保存后，才由已有配置分层机制落为持久配置。
- 临时运行与持久运行共用 `RunService` 的输出通道与 Run 工具窗口。

## 5. 逐文件修改清单

### B7b1：数据来源（依赖 B6a2）

| 动作 | 文件 | 内容 |
| --- | --- | --- |
| 新建 | `macos/Sources/LitheCoreContracts/Execution/RunnableMarkerContracts.swift` | §4.1 全部类型 |
| 新建 | `macos/Sources/LitheExecutionModule/Application/DocumentRunnableFeatureModel.swift` | 请求节流、revision 校验、取消、按文档缓存 |
| 新建 | `Plugins/mac/Official/GoSupport/.../Capabilities/GoRunnableCapability.swift` | 路径 A：documentSymbol → Go 命名规则匹配 |
| 新建 | bundled Rust execution 模块内 `RustRunnableCapability.swift` | 路径 B（`experimental/runnables`）+ A 兜底 |
| 改 | `rust/lithe-core/src/lsp/interface/client.rs` | 若走路径 B：`experimental/runnables` 进白名单与解析（**与 B6a2 的白名单改动在同一文件，须串行实施，不并发**） |

Go 命名规则（写进 capability，附单测）：

- 入口：`package main` 内的顶层 `func main()`，无参数无返回值。
  **「该文件属于哪个 package」不从 documentSymbol 取**——LSP 的 documentSymbol 不返回
  package 子句。正确来源是 B7a1 已交付的 `execution.normalizeProjectMetadata` Go 分支：
  它保留每个 package 的 import path 与其 `GoFiles` 列表，宿主按当前文档路径反查其所属
  package 即可判定是否为 `main`。因此 **B7b 的 Go 入口标记还依赖
  [B7a3](goland-parity-b7a3-go-tools-done.md) 的元数据刷新链路已就绪**；
  元数据不可用时不显示入口标记，不退化为读首行文本猜测。
- 测试：`func Test<X>(t *testing.T)`，`X` 首字母非小写；文件名以 `_test.go` 结尾。
- 基准：`func Benchmark<X>(b *testing.B)`；示例：`func Example<X>()`。
- **不匹配** `TestMain(m *testing.M)`（那是测试入口不是测试用例）。

### B7b2：gutter 渲染与交互

| 动作 | 文件 | 内容 |
| --- | --- | --- |
| 改 | `macos/Sources/Lithe/Views/Editor/CodeEditorView.swift` | `runnableMarkers` 属性；`drawRunnableMarker`（仿 `drawImplementationMarker:4623`）；`hitTarget` 的 `.implementation` 分支优先派发 runnable（`:4999`）；`menu(for:)` 增加图标列分支（`:5013`）；`EditorLanguageFeatureTransition` 增两位（`:462`） |
| 改 | `macos/Sources/Lithe/Theme/LitheIcons.swift` | `runnableMarkerImage(kind:size:)`：application ▶、test ▶（带勾）、benchmark、example |
| 新建 | `macos/Sources/Lithe/Views/Editor/RunnableGutterMenu.swift` | Run / Debug / Modify Run Configuration… 三项菜单构造 |

绘制约束：

- 标记只画在**当前可见且未被折叠隐藏**的行上。折叠状态来自已有的
  `EditorFoldVisibility.hiddenLines(in:regions:collapsedIDs:)`（`CodeEditorView.swift:534` 附近），
  **复用它，不要另算一份**。
- 软换行时标记画在**逻辑行的首个视觉行**，与行号对齐方式保持一致。
- 图标尺寸随编辑器字体缩放，与 `drawImplementationMarker` 的 `markerSize` 取同一策略。
- Debug 标记不单独占位：Debug 是菜单项，不是第二个图标（与 GoLand 一致）。

交互约束：

- 左键与右键**弹同一个菜单**（GoLand 行为）。左键不做「直接运行」——RustRover 的 gutter
  左键也是弹菜单，直接运行的是工具窗口双击。
- 菜单项 `Run '<displayName>'` 的引号与 GoLand 格式一致。
- Modify Run Configuration… 打开已有的 capability-driven 配置编辑器，
  **临时计划打开时预填投影出的参数**，用户保存才落为持久配置（§4.3）。
- 菜单打开期间文档被修改 → 菜单项执行前复核 `documentRevision`，不一致则提示重新触发，
  不按旧行号运行。

### B7b3：配置编辑器补齐

配置编辑器已存在（E7），本批只补 gutter 需要的入口与字段：

| 动作 | 文件 | 内容 |
| --- | --- | --- |
| 改 | 配置编辑器视图 | 确认程序参数 / 环境变量 / 工作目录 / 工具链选择四项对 Go 与 Rust 均可编辑并保存 |
| 改 | 配置分层写入 | 从 gutter 临时计划「另存为」时写入 project/local override，**不写 `generated.json`** |

环境变量编辑必须：支持增/删/改；值不进日志；保存后**实际到达子进程**（验收 7.6 用
打印环境的 fixture 程序核实，不能只看 UI 显示）。

## 6. 验证计划

```bash
export PATH="$PWD/.artifacts/toolchains/swift-6.2.4/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin:$PATH"
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./scripts/verify-rust-core-comments.sh          # 仅当动了 client.rs
./scripts/verify-rust-core.sh                   # 同上
./scripts/verify-shared-contracts.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-module-boundaries.sh
./scripts/test-macos.sh -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
git diff --check
```

`CodeEditorView.swift` 是 5695 行的视图文件，本批要动 5 处。提交前必须：

- 确认 `verify-service-boundaries.sh` 的 UI 边界扫描通过（View 不得引用
  `RunService` 等具体服务，见脚本第 10 行 `ui_service_pattern`）。
- gutter 的纯计算部分（命中判定、折叠过滤、行号换算、同行裁决）抽为可单测的
  值类型/静态函数，放 `macos/Sources/Lithe/Application/Features/`，
  **不要只靠 GUI 验收**。

## 7. 验收矩阵

| # | 项 | 判据 |
| --- | --- | --- |
| 7.1 | Go 入口 | 任意文件名的 `package main` 的 `func main` 行显示 ▶；非 main 包的 `func main` 不显示 |
| 7.2 | Go 测试 | `TestX` / `BenchmarkX` / `ExampleX` 显示标记；`TestMain` 不显示；非 `_test.go` 里的同名函数不显示 |
| 7.3 | Rust | `fn main`、`#[test]`、`#[bench]`、`mod tests` 内的测试正确标记；rust-analyzer 不可用时退到 documentSymbol 且不报错 |
| 7.4 | 点击 | 左键与右键弹同一菜单；Run 真实启动并自动打开底部 Run 工具窗口、输出可见（对齐 E8 已验收的 Cargo 行为） |
| 7.5 | 配置 | Modify Run Configuration 可改参数/环境变量/工作目录/工具链；保存后再次运行生效；重开项目仍在 |
| 7.6 | 参数实到达 | 用打印 `os.Args` 与 `os.Environ()` 的 fixture 程序核实参数与环境变量**实际到达子进程**，不只看 UI |
| 7.7 | 布局正确性 | 折叠隐藏行不画标记；软换行时画在逻辑行首个视觉行；改字体大小后位置仍正确；滚动无残影 |
| 7.8 | 版本一致性 | 编辑文档后旧 runnable 结果被丢弃，不按旧行号绘制；菜单打开期间改文档后执行被拒绝并提示 |
| 7.9 | 能力缺失 | 语言服务器停止时标记被清除（`clearRunnableMarkers`），不留下点了没反应的图标 |
| 7.10 | 多项目 | 两个项目窗口的标记互不串扰；切项目不把 A 的候选画到 B |
| 7.11 | 已知差异 | 同行 runnable + implementation marker 时 implementation 被隐藏，在本表标注为未对齐 |

**7.1–7.4、7.7 必须真实 ARM64 应用点击验收并截图，与 RustRover / GoLand 同尺寸窗口对照。**
B7a2c2 已两次证明：gutter 与点击语义的回归在自动化测试中不可见
（`goland-parity-b7a-go-cargo.md:29`）。

## 8. 依赖与顺序

```
B6a2（documentSymbol 能力 + 白名单 + 解析）
  └─> B7b1（运行候选 port 与语言 capability）
        └─> B7b2（gutter 渲染与交互）
              └─> B7b3（配置编辑器补齐）
```

- **B7b 不能早于 B6a2**。这是硬约束，不是偏好。
- B7b1 若走 Rust 的路径 B，会改 `client.rs` 的方法白名单——**与 B6a2 改同一文件同一函数**。
  两批不得并发实施，必须 B6a2 先落地并提交。
- B7b 与 [B7a3](goland-parity-b7a3-go-tools-done.md) 无源文件交叠，可并行。

## 9. 诚实边界

1. **Python main guard 不在本批**。`if __name__ == "__main__"` 不是 LSP 符号，
   需要 L8 的语法层。本批只交付 Python 的 `test_*` 函数标记，验收表标注 main guard 未完成。
2. **不做复合图标**。同行运行入口与实现标记并存时隐藏后者（§4.2），与 IDEA 有差异。
3. **不承诺 gopls 的 runnables**。gopls 无此扩展，Go 走命名规则匹配 documentSymbol。
   命名规则匹配的固有局限（例如通过 build tag 排除的测试文件）要在验收记录中写明，
   不能声称与 GoLand 的测试发现完全等价——GoLand 用的是自己的 Go 索引。
4. **不用正则扫源码找入口**。在 B6a2 之前没有可靠的行级来源；用正则会在字符串、注释、
   泛型与嵌套函数上产生假阳性，那不是「先做个能用的」，是把错误图标交给用户。
