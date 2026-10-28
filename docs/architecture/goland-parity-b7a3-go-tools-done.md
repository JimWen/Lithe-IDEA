# B7a3：Go 元数据隔离读取、Go Tools 工具窗口与独立工具任务

状态：**B7a3a–d 已完成实现、代码审查、自动回归及 ARM64 真实编辑/运行/点击/截图验收。** 原始方案基于 `3680935d`，本轮修复基于
`7e0887a1`。第 2 / 5 节保留实施前核查与执行清单；当前结果以 §6.5 为准。本文是
[B7a Go/Cargo 方案](goland-parity-b7a-go-cargo.md)
中 B7a2c3、B7a3 两项的实施细案，并把 B7a2c2 已交付的 Cargo 链路作为 Go 侧的实现模板。
第 2 节的位置与行号属于历史基线，不代表当前 HEAD 仍有这些缺口。

阅读顺序：第 2 节（现状）→ 第 3 节（分批）→ 第 4 节（契约变更，唯一需要改共享契约的地方）
→ 第 5 节（逐文件修改清单）→ 第 6/7 节（验证与验收）。

## 1. 目标与不在范围

目标（对应总方案要求 10 与要求 9 的 Go 部分）：

1. Go 项目元数据以**证明零写用户工作区**的方式读取（B7a2c3 的结论落地为代码）。
2. 右栏出现 Go Tools 工具窗口：module / package / target 树、刷新、取消、错误可见。
3. Go 常用工具（build / test / vet / fmt 检查 / mod）作为**独立任务**执行，不占用也不打断
   用户已有的 Run；输出可点击定位。
4. Go 运行入口检测器补齐：任意文件名的 `package main`，不只 `main.go` 与 `cmd/<name>`。

不在本文范围：

- 运行入口 gutter 与右键配置 → [B7b 运行入口](goland-parity-b7b-run-gutter.md)。
- Structure / TODO 工具窗口 → 在线路径依赖 L4a、离线回退依赖 L4b，另批。
- Go 语义重构 → [B6](goland-parity-b6-refactor.md)。
- 实际格式化写回（`gofmt -w` 类）→ 依赖 B6b1 的编辑事务；本批只做**格式检查**并明确标注
  「检查，非格式化」，不得把检查结果标成格式化已交付。
- Cargo 命令和元数据语义保持 B7a2c2 的已验收契约；按用户要求统一 G/R 工具图标，并修复
  对照验收发现的 Cargo 父菜单覆盖目标菜单问题。

## 2. 现状核查

每条都在当前 HEAD 核对过，行号为实测值。

### 2.1 已具备的基础设施（直接复用，不重造）

| # | 事实 | 位置 |
| --- | --- | --- |
| E1 | `execution.normalizeProjectMetadata` 已支持 Go：多 module、package、source、imports、diagnostics、稳定 ID、外部 root 映射 | `rust/lithe-core/src/execution/project_metadata/go.rs` |
| E2 | Go 插件已注册 `.languageProjectTools(goLanguageID)` 能力 | `Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule/Module/GoExecutionModule.swift:64` |
| E3 | 平台 capture（进程组、双 EOF、stdout/stderr 分离、预算、超时）已完成 | `macos/Sources/Lithe/Platform/MacOS/ProjectTools/MacProjectToolCapture.swift` 等 6 个文件 |
| E4 | 单轮刷新所有权模型（期限、取消、迟到清理、lease、provider generation）已完成 | `macos/Sources/LitheExecutionModule/Application/CargoProjectFeatureModel.swift:13-244`、`Services/CargoProjectWork.swift` |
| E5 | 文件身份冻结（resolvedURL + dev + inode + size + mtime）已有实现 | `MacCargoMetadataPreparer.swift:228-250` 的 `CargoFileIdentity` |
| E6 | 环境白名单构造（从空字典按白名单构造，不继承宿主环境）已有实现 | `MacCargoMetadataPreparer.swift:25` 的 `CargoMetadataEnvironment.make(from:)` |
| E7 | 工具发现已覆盖 Go：`~/go/bin`、`GOBIN`、`GOPATH` 兜底 | `MacRuntimeToolDiscovery`（B7a2c2 记录 `goland-parity-b7a-go-cargo.md:17`） |
| E8 | 工具窗口注册、树形呈现、右键菜单、双击运行的完整参考实现 | `CargoProjectView.swift`（409 行）、`CargoTreePresentation.swift`（155 行）、`AppModel+CargoProject.swift`（215 行） |

### 2.2 缺口

| # | 事实 | 位置 |
| --- | --- | --- |
| G1 | `CargoMetadataNativeSession` 的分阶段协议是 **`resolutionCommands`（固定列表）→ `metadataCommand(resolutionOutputs:)`（**单个**最终命令）→ `normalizationInput(metadata:)`**。Go 需要「先定位 → 再按定位结果决定要跑几个 `go list`」，命令**条数依赖前一阶段输出**，当前形状表达不了 | `macos/Sources/LitheCoreContracts/Execution/CargoMetadataNativeContracts.swift:66-76` |
| G2 | 没有任何 Go 元数据准备器。`macos/Sources/Lithe/Platform/MacOS/Execution/` 下只有 `MacCargoMetadataPreparer.swift`、`MacCargoProjectComposition.swift` | 该目录 |
| G3 | 没有 `GoProjectFeatureModel`、没有 Go 工具窗口视图、没有 `AppModel+GoProject.swift` | `macos/Sources/LitheExecutionModule/Application/`、`macos/Sources/Lithe/Views/Execution/` |
| G4 | `detectors/go.rs` 只认字面量 `main.go`（`has_main_package` 只 `ctx.read("main.go")`），且必须与 `go.mod` 同目录或位于 `cmd/<name>/`；任意文件名的 `package main` 不被发现 | `rust/lithe-core/src/execution/detectors/go.rs:44-47` |
| G5 | `RunService.run()` 先 stop 再 run，是**替换语义**；没有任何独立工具任务通道 | `goland-parity-b7a-go-cargo.md:43` 的既有结论，实现未变 |
| G6 | 无 Go Tools 工具窗口图标资源 | `macos/Resources/IDEAIcons/toolwindows/` 只有 `toolWindowCargo.svg` / `_dark.svg` |

### 2.3 B7a2c3 已完成的实验结论（本批直接实施，不重做实验）

来自 [Go 元数据读取隔离](goland-parity-b7a2c3-go-metadata-isolation.md)，go1.24.4 实测：

- `go env -json GOWORK GOMOD`、`go work edit -json`、`go list -m -json` 对用户工作区**零写**。
- workspace 模式下逐 module 的 `go list -e -json ./...` **会创建 `go.work.sum`**；`-mod=readonly` 不阻止它。
- 三种隔离做法只有一种成立：**逐字节复制 go.work，只重写 `use` 块内路径为符号链接解析后的绝对路径**。
  用 `go work edit -json` 重建会丢 `toolchain` / `godebug`；符号链接方案被 Go 拒绝。
- 单 module（无 go.work）走 `GOWORK=off` 即可零写，缺 sum 时以包级 `Error` 返回，可直接作为诊断。

**这些结论绑定 go1.24.4。实现方在实施时必须先用本机 Go 版本重跑
`goland-parity-b7a2c3-go-metadata-isolation.md` 第 1 节的表格；版本不同而结论不同时，
停止实施并回报，不得沿用本文结论。**

## 3. 分批与依赖

| 子批 | 交付 | 依赖 | 不属于本批 |
| --- | --- | --- | --- |
| B7a3a | 分阶段 capture 契约泛化（G1）；`MacGoMetadataPreparer` 与隔离 go.work 副本 | 无 | 任何 UI |
| B7a3b | `GoProjectFeatureModel` + Go Tools 工具窗口（只读树、刷新、取消、错误） | B7a3a | 工具执行 |
| B7a3c | 独立工具任务服务 + Go 工具动作（build/test/vet/fmt 检查/mod） | B7a3b | 实际格式化写回 |
| B7a3d | `detectors/go.rs` 补齐任意文件名 `package main` | 无 | gutter |

B7a3d 与 a/b/c 无源文件交叠（纯 Rust detector），可并行实施并单独提交。
B7a3a 是 a3b/a3c 的硬前置。B7a3c 的「格式检查」在没有 B6b1 编辑事务前**只做检查**。

## 4. 契约变更

本批只有一处需要改动共享契约面，务必先做这一处再写实现。

### 4.1 分阶段 capture 协议泛化（G1）

现状（`CargoMetadataNativeContracts.swift:66-76`）：

```
protocol CargoMetadataNativeSession {
    var resolutionCommands: [CargoMetadataCommand] { get }
    func metadataCommand(resolutionOutputs: [Data]) throws -> CargoMetadataCommand
    func normalizationInput(metadata: Data) throws -> CargoMetadataNativeInput
    func validate() throws
}
```

Go 的命令序列是（B7a2c3 §3）：

1. `go env -json GOWORK GOMOD`（定位）
2. `GOWORK` 非空时 `go work edit -json`（取 `Use` 列表）
3. `go list -m -json`
4. **逐 module** `go list -e -json ./...`，条数 = 步骤 2 的 `Use` 条目数

步骤 4 的命令**条数与工作目录都由步骤 2 的输出决定**，`metadataCommand` 的「单个最终命令」
形状表达不了。

**决定：新增语言无关的分阶段协议，Cargo 适配到它，不为 Go 另造一套。**

新建 `macos/Sources/LitheCoreContracts/Execution/ProjectMetadataNativeContracts.swift`：

```
/// One capture round produced by the preparer. `commands` runs in order; the
/// session decides after each round whether more rounds are needed.
package struct ProjectMetadataCaptureStage: Sendable {
    package let id: String                       // 稳定阶段标识，进诊断与日志
    package let commands: [ProjectMetadataCommand]
}

package enum ProjectMetadataStageOutcome: Sendable {
    case more(ProjectMetadataCaptureStage)       // 还需要下一轮
    case done(ProjectMetadataNormalizationSource) // 收集完毕，可进归一化
}

package protocol ProjectMetadataNativeSession: Sendable {
    /// 第一轮命令。不依赖任何输出，可在 prepare 时确定。
    var initialStage: ProjectMetadataCaptureStage { get }

    /// 交付上一轮 stage 的 stdout（与 `commands` 同序、同长度），
    /// 返回下一轮或最终归一化输入。
    func advance(stage: ProjectMetadataCaptureStage,
                 outputs: [Data]) throws -> ProjectMetadataStageOutcome

    func normalizationInput(_ source: ProjectMetadataNormalizationSource)
        throws -> ProjectMetadataNativeInput

    /// 提交前复核准备期冻结的全部文件身份。
    func validate() throws
}
```

约束（实现方必须逐条落实，审查按此核对）：

- **阶段数有上限**：全局最多 4 轮，单轮最多 512 条命令。超限抛出稳定失败，不得无界循环。
  Go 的 4 轮正好落在上限内；上限是防御性的，不是 Go 的需求。
- `outputs` 与 `stage.commands` **同序同长度**，实现方不得按内容猜测归属。
- 每轮开始前重新检查 owner 的 deadline / cancellation（沿用
  `CargoProjectFeatureModel.checkCurrent(_:)` 与 `remainingMilliseconds(_:)` 的既有做法）。
- stdout / stderr 预算是**整轮累计**，不是每命令重置。沿用现有 16 MiB / 1 MiB。
- `ProjectMetadataNormalizationSource` 是 `enum { case cargo(Data); case go(modules: Data, packages: [Data]) }`，
  与 `ProjectMetadataNormalizing.normalize(_:workspaceDirectory:...)` 现有入参对齐。

Cargo 适配（**行为必须逐字节不变**）：`MacCargoMetadataSession` 的
`resolutionCommands` → `initialStage`；`metadataCommand(resolutionOutputs:)` → 在
`advance` 中返回 `.more(第二轮=单条 metadata 命令)`，第二轮 `advance` 返回 `.done(.cargo(data))`。
`normalizationInput` / `validate` 原样保留。**旧协议在本批删除**，不保留双份。

### 4.2 不需要改动的契约

- `shared/contracts/project-tools-metadata.md`：`execution.normalizeProjectMetadata` 的
  请求/响应形状不变，Go 分支 B7a1 已交付。本批**不改该契约**。
- `shared/contracts/rust-core-api.md`：无新增 operation。
- 插件 ABI：`LanguageProjectToolsProviding` / `LanguageProjectToolSession` 不变，
  Go 侧已注册（E2）。本批**不动插件 v1 ABI**。

若实现过程中发现必须改上述任一项，停止并回报——那意味着本方案的分层判断错了。

## 5. 逐文件修改清单

### B7a3a：契约泛化与 Go 准备器

| 动作 | 文件 | 内容 |
| --- | --- | --- |
| 新建 | `macos/Sources/LitheCoreContracts/Execution/ProjectMetadataNativeContracts.swift` | §4.1 的 5 个类型/协议 |
| 改 | `macos/Sources/LitheCoreContracts/Execution/CargoMetadataNativeContracts.swift` | 删除 `CargoMetadataNativeSession`；`CargoMetadataCommand` 更名并上移为 `ProjectMetadataCommand`（字段不变：executablePath / arguments / workingDirectory / environment）；`CargoMetadataPreparationRequest` 保留 |
| 改 | `macos/Sources/Lithe/Platform/MacOS/Execution/MacCargoMetadataPreparer.swift` | `MacCargoMetadataSession` 改实现新协议（§4.1 末段），`normalizationInput` / `validate` / `CargoFileIdentity` 不动 |
| 新建 | `macos/Sources/Lithe/Platform/MacOS/Execution/MacGoMetadataPreparer.swift` | 见下 |
| 新建 | `macos/Sources/Lithe/Platform/MacOS/Execution/MacGoWorkspaceIsolation.swift` | go.work 逐字节复制 + `use` 路径重写；隔离目录创建与删除 |
| 改 | `macos/Sources/LitheExecutionModule/Application/CargoProjectFeatureModel.swift` | `run(_:)` 的两段式 capture 改为 §4.1 的循环；其余所有权逻辑不动 |

`MacGoMetadataPreparer` 必须实现的点：

1. **工具解析**：只接受 `request` 里已解析的 go 可执行文件候选，经
   `CargoFileIdentity.nativeExecutable`（本批更名为 `ProjectToolFileIdentity`）冻结身份；
   拒绝脚本 shim（沿用 Cargo 侧同一判定）。尊重项目设置里的显式 Go 选择。
2. **环境**：从空字典按白名单构造。白名单：`HOME`、`PATH`、`GOMODCACHE`、`GOPATH`、`GOCACHE`。
   显式设置：`GOTOOLCHAIN=local`、`GOFLAGS=-mod=readonly`、`GOPROXY=off`、`GOSUMDB=off`、
   `GOWORK=<隔离副本绝对路径 | off>`。
   **明确不继承**：`GOFLAGS`（用宿主值覆盖而非叠加）、`GOPRIVATE`、`GONOSUMDB`、`GONOSUMCHECK`、
   `GONOPROXY`、`GOCACHEPROG`、`GOAUTH`、`GOINSECURE`。
   实现上复用 `CargoMetadataEnvironment.make(from:)` 的构造方式，Go 用自己的白名单常量。
3. **禁用参数**：`-modfile`、`-test`、`-compiled` 一律不出现在 argv 中。
4. **身份冻结**：`go.mod`、`go.work`（存在时）、每个 use module 的 `go.mod`，以及 go 可执行文件，
   全部在 prepare 时记录 (resolvedURL, dev, inode, size, mtime)，在 `validate()` 复核。
   任一不符 → 整轮失败，提示重新刷新。
5. **阶段划分**（对应 §4.1）：
   - stage `locate`：`go env -json GOWORK GOMOD`（cwd = 工作区根）
   - `GOWORK` 为空 → stage `modules`：`go list -m -json`（`GOWORK=off`）
   - `GOWORK` 非空 → stage `work`：`go work edit -json`；同时**另行**生成隔离副本
   - stage `packages`：逐 use module 目录 `go list -e -json ./...`
   - `.done(.go(modules:packages:))`
6. **go.work 根不执行 `./...`**（B7a2 原文要求），只在各 use module 目录内执行。

`MacGoWorkspaceIsolation` 必须实现的点：

1. 隔离目录建在系统临时目录下，创建后校验其真实路径**不在工作区内**（与 Cargo 同一约束）。
2. 逐字节读取原 go.work，**只**重写 `use` 块内的路径行为「符号链接解析后的绝对路径」。
   其余行（含 `toolchain`、`godebug`、`replace`、注释、非常规空白、未识别指令）**原样输出**。
   不得调用 `go work edit`，不得规范化格式。
3. 路径解析方式必须与 capture 的 cwd 解析方式一致（都用 `resolvingSymlinksInPath()`），
   否则 Go 报 `directory prefix . does not contain modules listed in go.work`。
4. 取消、超时、失败、项目关闭、正常完成五条路径都删除隔离目录及其中的 `go.work.sum`。
   删除失败要记录为可见诊断，不用 `try?` 吞掉。

### B7a3b：Go Tools 工具窗口

以 Cargo 对应文件为模板逐一对应新建。**不要抽取 Cargo/Go 公共基类**——两者的树语义
（Cargo：workspace→member→targets；Go：module→package→files/tests）不同，
过早抽象会把 B7a2c2 已验收的 Cargo 行为置于回归风险中。

| 动作 | 文件 | 模板 |
| --- | --- | --- |
| 新建 | `macos/Sources/LitheExecutionModule/Application/GoProjectFeatureModel.swift` | `CargoProjectFeatureModel.swift` |
| 新建 | `macos/Sources/Lithe/Application/Features/GoTreePresentation.swift` | `CargoTreePresentation.swift` |
| 新建 | `macos/Sources/Lithe/Models/AppModel/AppModel+GoProject.swift` | `AppModel+CargoProject.swift` |
| 新建 | `macos/Sources/Lithe/Views/Execution/GoProjectView.swift` | `CargoProjectView.swift` |
| 新建 | `macos/Sources/Lithe/Platform/MacOS/Execution/MacGoProjectComposition.swift` | `MacCargoProjectComposition.swift`（`.languageProjectTools("go")`） |
| 新建 | `macos/Resources/IDEAIcons/toolwindows/toolWindowGo.svg` + `_dark.svg` | 见下 |
| 改 | `WorkbenchModuleUIComposition` | 注册 Go Tools 侧条与 renderer |
| 改 | Go plugin manifest + bundled catalog | 声明 contribution，与 `ModuleFactory.contributions` 一致 |

树形（GoLand `Go Modules` 工具窗口对照）：

```
<module path>                      ← 每个 module 一个顶层节点
  └─ <package import path>         ← 该 module 下的 package
       └─ Targets                  ← 可折叠分组，仅在有可运行项时出现
            └─ <main / test 名>
```

单 module 时保留 module 顶层节点（与 RustRover 的反编译结论一致：**顶层从不隐藏**，
Cargo 侧是把根包的 targets 提升，不是删掉顶层）。Go 不做「根包提升」——Go 没有
「根包」概念，module 根目录的 package 就是一个普通 package 节点。

图标：**不得从 GoLand 或任何 JetBrains 产品拷贝资源**。Cargo 图标能用是因为 intellij-rust 是
MIT 且已归档 `LICENSE-MIT.txt` 与 NOTICE。Go Tools 图标须新绘或取自明确兼容许可的来源，
并同样归档许可与 NOTICE。若实施时找不到合规来源，使用现有 `LitheIDEAIcon` 体系里的
通用工具图标并在验收表标注「图标未对齐」，**不要留空按钮，也不要拷贝**。

节点交互（对齐 Cargo 已验收形态）：单击选中；双击可运行 target → 启动运行并打开底部 Run
工具窗口；右键 → Go to Source / Open go.mod / Refresh。
**注意 B7a2c2 的教训**：target 行必须是**纯行 + `onTapGesture(count: 2)`**，
不能包成 `Button` + `simultaneousGesture`——在 `List` 内双击手势会被容器吞掉，
且这个失败**自动化测试看不见**（`goland-parity-b7a-go-cargo.md:28`）。

性能：`goManifestURLs`（go.mod 候选）必须沿用 Cargo 的两项优化，否则重蹈
「每次渲染重扫全量工作区文件表、主线程 4–205 ms」的覆辙：
(a) 先按文件名过滤再 `standardizedFileURL`；(b) 按「工作区 + 已应用扫描 id」记忆化，
缓存放 `GoTreePresentation`，**不放 `AppModel`**（有 1800 行上限）。
另在 `loadProjectServices` 末尾加 `prewarmGoProject()`。

### B7a3c：独立工具任务

| 动作 | 文件 | 内容 |
| --- | --- | --- |
| 新建 | `macos/Sources/LitheExecutionModule/Application/ProjectToolTaskFeatureModel.swift` | 独立 task ID、workspace/provider generation、输出缓冲、状态机、停止/重跑 |
| 新建 | `macos/Sources/LitheCoreContracts/Execution/ProjectToolTaskContracts.swift` | 任务 DTO、状态枚举、诊断来源标识 |
| 改 | `RunView` / 输出视图 | 在现有 Run 左侧列表加入工具任务，复用详情、工具栏、ANSI 与位置链接投影 |
| 改 | Go 能力 | 新增 `GoToolActionCapability`：build / test / vet / fmt 检查 / mod 的 argv 投影 |

硬约束：

- **不改变已有普通 Run 的替换语义**（G5）。工具任务是**新通道**，多个任务互不 stop；
  显式 Stop 只停选中任务。
- **不写 `generated.json`**。无持久配置也能执行临时计划。
- argv 投影在 Rust Core / 语言 capability 内完成，**View 不拼 shell**，不经过 shell。
- lease 在进程**实际停止后**才释放（沿用 `CargoProjectCapture.isOwned` 的判据）。
- 独立 build diagnostics source，**不得覆盖 LSP diagnostics**。
- `go vet` / `go build` 的 `file:line:col:` 输出投影为可点击定位，定位根为 module 目录。
- fmt 只跑 `gofmt -l`（列出需要格式化的文件），**不跑 `-w`**。UI 文案必须是
  「Check Formatting」，不是「Format」。

### B7a3d：检测器补齐

`rust/lithe-core/src/execution/detectors/go.rs` 现在只 `ctx.read("main.go")`（`:45`）。
按 Cargo 侧同样的思路补齐：

- 扫描目录内**所有** `*.go`（排除 `*_test.go`），任一文件的包子句为 `package main` 即认定入口。
  包子句判定要跳过行注释与块注释，不能像现在这样只做 `line.trim() == "package main"`
  ——那会漏掉 `package main // comment`，也会把注释里的同名行误判。
- 保留现有 `go.mod` 同目录与 `cmd/<name>/` 两条既有规则，新规则与其取**并集**并去重。
- 生成的命令保持 `go run .`（目录级），不要改成 `go run <file>`——后者在多文件 main 包下会失败。
- `Confidence::Heuristic` 保持不变：Go 确实没有声明式入口清单。

新增测试放同文件 `#[cfg(test)]`：任意文件名 main、`package main` 带尾注释、注释内的
`package main` 不误判、`_test.go` 内的 main 不计、多文件 main 包只产出一个配置。

## 6. 验证计划

按 `.agents/skills/develop-lithe/SKILL.md` 的验证矩阵，本批实际涉及 Rust Core、
共享契约消费方、Services/Views 边界与 Swift 应用，因此全部要跑：

```bash
export PATH="$PWD/.artifacts/toolchains/swift-6.2.4/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin:$PATH"
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./scripts/verify-rust-core-comments.sh
./scripts/verify-rust-core.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-module-boundaries.sh
./scripts/test-macos.sh -Xlinker -force_load \
  -Xlinker "$PWD/rust/target/macos/aarch64-apple-darwin/debug/liblithe_core.a"
git diff --check
```

本机无 Xcode，`/usr/bin/swift` 是 CLT 6.0.3，不满足 `Package.swift` 的 tools version 6.2，
必须先按上面把仓库内解包的 swift.org 6.2.4 置于 PATH。
不传 `-force_load` 时 `RustCoreBridge().isAvailable` 为 false，约 50 项测试会以
「Rust Core is unavailable」失败，那是调用方式问题不是回归。

分批门槛：

- B7a3d 纯 Rust：`verify-rust-core-comments` + `verify-rust-core` 即可单独提交。
- B7a3a：加 `verify-shared-contracts` + 完整 Swift 套件。**Cargo 回归是本子批的核心风险**，
  必须证明 `CargoTreePresentationTests` 与 Cargo 相关测试全部保持通过，且 Cargo 的
  两轮命令序列逐字节不变。
- B7a3b / B7a3c：全套 + **真实 ARM64 GUI 点击验收**（见 §7.5）。

### 6.1 实施记录（2026-09-08，B7a3d 与 B7a3a）

- **实施前重测（§2.3 门槛）**：本机 Go 为 go1.24.4 darwin/arm64，与实验绑定版本一致；
  §1 表格五行与 §2 隔离方案全部复现（隔离副本三轮刷新后用户工作区 SHA-256 逐字节一致，
  `go.work.sum` 落在隔离目录）。脚本与日志在
  `.artifacts/goland-parity/go-isolation-recheck.sh` 与同目录 `*-2026-09-08.log`。
- **B7a3d**：`detectors/go.rs` 按第 5 节实施；包子句判定为「跳过注释后的首个有效行」，
  比原任何行匹配更严（真子句之前的注释行被跳过，之后的 `package main` 不再误判）。
  三条规则按并集去重为每目录一条。`cargo fmt`、verify-test-stability、
  verify-rust-core-comments、verify-rust-core 通过；Rust 计时 harness 359/359，
  含五个新检测器场景。
- **B7a3a**：§4.1 契约与 §5 清单全部落地；`CargoFileIdentity` 更名为
  `ProjectToolFileIdentity` 并去掉 private 供 Go 侧共用。隔离副本在 prepare 时即创建
  （go.work 存在性 prepare 可查），`advance` 阶段冻结 use module 的 go.mod；会话可变
  状态由 NSLock 保护，调用所有权仍归串行 worker。五条清理路径中的模型接线（取消/超时/
  失败/项目关闭/完成时删除隔离目录）随 B7a3b 的 `GoProjectFeatureModel` 交付，本批
  仅有 `cleanupIsolation()` 与 deinit 兜底。
- **对方案的更正**：`ProjectMetadataContracts.swift` 中已有同名枚举
  `ProjectMetadataCaptureStage`（capture 拒绝归因），与 §4.1 新 struct 撞名。保留
  §4.1 的命名，把既有枚举更名为 `ProjectMetadataCaptureOrigin`（两处使用，纯 Swift
  内部错误类型，不触及 §4.2 的任何受保护契约）。
- **验证**：新增 `ProjectMetadataPreparationTests` 7 项（Go workspace/single 阶段序列、
  外部 go.work 拒绝、身份变更失败、隔离副本逐字节重写、Cargo 两轮序列逐字节不变）；
  verify-test-stability、verify-shared-contracts、verify-service-boundaries、
  verify-module-boundaries、verify-rust-core-comments、verify-rust-core 通过；完整
  Swift 套件 `test-macos.sh`（含 Rust force_load）1131 项全部通过。测试直接断言
  §7.7 要求的「Cargo 命令序列逐字节不变」；§7 的 GUI 与真实进程验收项仍未执行，
  不据此宣布 B7a3a「已验收」，独立代码审查待做。

## 7. 验收矩阵

| # | 项 | 判据 |
| --- | --- | --- |
| 7.1 | 零写 | 缺 sum / 有缓存依赖 / 缺缓存依赖 / go.work 含 replace+toolchain+godebug 四种 fixture，刷新前后用户工作区**全部文件** SHA-256 逐字节一致；连续 3 次刷新同样一致 |
| 7.2 | 隔离副本忠实 | 含 `toolchain`、`godebug`、`replace`、注释、非常规空白的 go.work，复制后除 `use` 路径外逐字节相同；解析结果与直接用原 go.work 相同 |
| 7.3 | 失败可见 | 缺 sum 的包级 `Error` 出现在 diagnostics，不降格为空树；宿主**不执行** `go mod tidy` / `go get` / `go work sync` |
| 7.4 | 身份冻结 | 刷新期间修改 go.work 或某 module 的 go.mod → 该轮整体失败并提示重新刷新，不产出半份结果 |
| 7.5 | 清理 | 取消 / 超时 / 失败 / 项目关闭四条路径后，隔离目录与 `go.work.sum` 均被删除；无遗留进程（`pgrep` 核实） |
| 7.6 | 环境 | 实测 child 收到的 env **精确等于**白名单加显式设置；用户本机的 `GOPROXY` / `GONOSUMDB` 非默认值不出现在其中 |
| 7.7 | Cargo 不回归 | 契约泛化后 Cargo 的三层树、双击运行、Run 窗口自动打开、tooltip 全部与 B7a2c2 验收结果一致（同一 fixture 重跑） |
| 7.8 | 树与交互 | 单 module / go.work 多 module / 同名包 / build tags 四种项目：树层级正确、刷新保持选择与展开、双击真实运行并打开 Run 窗口、右键三项可用 |
| 7.9 | 独立任务 | 同时跑 2 个工具任务互不 stop；用户已有 long-running Run 存活；显式 Stop 只停选中任务；输出 `file:line` 可点击定位 |
| 7.10 | 检测器 | 任意文件名 main、带尾注释的包子句、注释内假阳性、`_test.go`、多文件 main 包五种情况正确 |
| 7.11 | 诚实标注 | fmt 入口文案为「Check Formatting」；未对齐项（图标、实际格式化写回）在本文验收表明确标未完成 |

**7.8 与 7.9 必须做真实 ARM64 应用点击验收并截图。** B7a2c2 的第四/第五迭代已经证明：
树层级回归与双击失灵在自动化测试中完全不可见，只有真实点击能暴露
（`goland-parity-b7a-go-cargo.md:29`）。自动化通过不等于本批完成。

验收用隔离的临时 Go fixture，不要在用户真实项目上跑写入相关验证。截图与日志放
`.artifacts/goland-parity/`，不进产品资源或提交。

## 8. 风险与诚实边界

1. **Go 版本绑定**。§2.3 的零写结论只对 go1.24.4 成立。换版本必须重跑实验表格。
   本文不承诺「所有 Go 版本零写」。
2. **契约泛化会碰已验收的 Cargo 代码**。这是本批最大的回归风险源。缓解手段是
   §7.7 的同 fixture 重跑，以及要求 Cargo 的命令序列逐字节不变。若实现方判断风险不可控，
   可退化为「Go 用独立协议、Cargo 不动」——但那样会留下两套分阶段协议，
   需要在审查中明确记录这个取舍，不能默默选择。
3. **不承诺 Go Tools 的完整 GoLand 对齐**。GoLand 的 Go 工具主要在 Tools 菜单，
   本产品按用户要求放右栏，这是**位置差异**，不得声称为 GoLand 原生布局
   （`goland-parity-b7a-go-cargo.md:34`）。
4. **格式化只做检查**。实际写回依赖 B6b1 的编辑事务，本批不交付，验收表保持未完成。
5. **图标合规优先于视觉对齐**。宁可标注未对齐，不拷贝来源不明的资源。

### 6.2 独立评审记录（2026-09-08，codex 对 B7a3d/B7a3a 两个提交）

11 条 CORE 全部修复；3 条 MINOR 一并处理。要点：

- **缓存路径可能落进工作区**（GOMODCACHE/GOCACHE/GOPATH 解析后位于工作区内时拒绝刷新，
  不做静默重定向）。
- **`GOENV=off`** 加入固定旗标：`go env -w` 持久化过的配置（代理绕过、缓存程序）不得
  绕过环境白名单。
- **相对 `replace` 目标随重定位改写为绝对路径**：Go 按 go.work 所在目录解析相对 replace，
  只保留字节不动会静默改变依赖解析。这是对「逐字节保留其余行」的**有意修正**，replace
  的版本形式与绝对路径不动；未知指令仍逐字节带过。
- **`use .`、裸目录名等全部合法 use 路径**都改写（不再只认 `./` 前缀）；`//` 仅在 token
  起始处视为注释；带空白/引号的解析结果自动加引号；引号内转义解码。
- **CRLF 文件**按 `\n` 标量切分（Swift 字符会把 `\r\n` 合并导致整文件单行、改写失效）。
- **use module 的 go.mod 在 prepare 时即冻结**（从 go.work 文本解析 use 清单）；
  `go work edit -json` 的模块集合必须与冻结集合一致，否则整轮失败。
- **清理 API 通过新协议 `ProjectMetadataSessionCleaning` 暴露**，私有会话类型也可被
  owner 以存在类型调用；deinit 仅作兜底。
- **隔离副本创建改为事务式**：先校验源再建目录、创建后复核真实路径不在工作区内、
  失败路径删除并汇报；`cleanup()` 只把确认不存在的情形当成功。
- **包子句注释删除保留词法空白**（`package/* c */main` 不再粘连）、接受显式分号
  （`package main;`），新增两个检测器测试。
- **测试失败路径清理**：五个检测器测试改用 Drop 守卫；顺带修复 `temporary_root`
  纳秒时间戳在并行下的碰撞（追加进程内序列号），该 flake 在全量套件下偶发。
- MINOR：补充 rustup 分支的 Cargo 序列测试；`ProjectToolFileIdentity` 的失败文案改为
  中性（Go 刷新不再提示 "Refresh Cargo"）；检测器测试按仓库惯例放在集中测试模块而非
  方案所写的「同文件 `#[cfg(test)]`」，在此记录偏差。

### 6.3 B7a3b 实施记录（2026-09-08）

- **交付物**：`GoProjectFeatureModel`（staged 循环 + 五路径会话资源清理 +
  `.go(modules:packages:)` 归集）、`GoTreePresentation`（module→package→Targets
  三层，顶层从不隐藏）、`AppModel+GoProject`（识别/附加/刷新/取消/事件失效，与
  Cargo 同型）、`GoProjectView`、`MacGoProjectComposition`、`toolWindowGo.svg`
  与 `_dark`（初版为原创双箭头，验收后按用户要求改成原创圆形 G；不含第三方素材）、workbench 注册、
  `toggle-go` / `refresh-go` / `cancel-go-refresh` 命令、bundled catalog 与 Go
  插件清单的 `language.go.projecttools` contribution、`startGoTarget` 与
  `.goTarget` 生成意图、`loadProjectServices` 末尾 `prewarmGoProject()`。
- **复用而非复制**：`CargoProjectWork.swift` 的通用工作类型（Worker/Scheduling/
  Capture/RefreshOperation 等）更名为 `ProjectTool*` 后由两个 feature 共用；这
  是组合而非基类抽取，符合本批「不抽公共基类」的约束。`ProjectMetadataCapture
  Stage`/`Failure` 等既有契约不变。
- **双击语义**：application 入口经 `goMainConfigurationID` 投影到检测器生成的
  `go.main`/`go.command` 配置（与 B7a3d 的 id 规则一致，含 cmd/<name> 判定），
  缺配置时沿用「生成后续跑」流；test 入口在 B7a3c 中启动独立 package 测试任务。
- **测试**：`GoTreePresentationTests` 4 项（单 module 顶层保留、入口按
  runnable/testable、id 投影镜像检测器、reconcile 剪枝与选择清理）。


### 6.4 B7a3c 历史实现与修复过程（2026-09-08）

本节保留中间测试与失败结论；最新验收结果见 §6.5，旧报告路径可能已被最终测试覆盖。

- `ProjectToolTaskFeatureModel` 持有独立 ID、workspace/provider generation、准备任务、
  原生会话、Execution lease 与停止期限。最多 4 个活跃任务、保留 32 个完成任务，
  每任务最多 4 MiB 输出；原生输出先在有界缓冲中累积，再按 40 ms 合并发布。
- `GoToolActionCapability` 通过现有 execution capability 的可选子协议提供参数数组，
  不改已安装插件的 v1 manifest / entrypoint 协议。旧插件仍可 Run，工具任务入口提示升级。
  build/test/vet 使用 `./...`，mod 支持 tidy/download/verify；格式检查使用所选 Go 同目录
  的 `gofmt -l .`。不调用 shell，也不读写 Run 配置。
- 原生准备器校验工作目录包含关系及目录/工具身份，设置变化或工作区切换使迟到准备失效。
  停止失败保持 `cleanupRequired` 和 lease；真实退出后才释放。插件补齐 capability 退休、
  延迟创建会话及旧 termination 回调的 generation 防护。
- Go module/package 右键接入工具动作；test target 双击启动独立测试。Run 输出加入任务列表项，
  不受配置缺失门槛限制；普通 Run 的替换语义保留。工具输出以捕获目录解析位置链接，
  `go-tool` 来源与 LSP 诊断分离。停止、重跑、清空作用于选中任务。
- 已通过针对性计时 37 项（含准备身份、并发停止隔离、准备取消、实际退出前持有 lease、
  历史/输出预算）；产物 `.artifacts/test-stability/macos-project-tool-tasks.{json,html,junit.xml}`。
  最慢新增测试为历史上限测试约 5 ms；真实 GUI、全量回归与安装验收仍在进行，不能据此标记完成。
- 原生复查修正：旧 `MacStreamingProcess.stop()` 会提前清空引用，仅修复 Go 包装器不足以
  保证 lease。插件执行宿主改为 `MacOwnedLanguageExecution`，复用现有进程组/管道驱动；
  root reap、进程组清理和双路读端/写端关闭都确认后才结束。启动离开主线程，失败仍保留
  原生所有权；输出支持分块 UTF-8，不因进程先退出而丢尾部输出。新增原生状态机与真实
  `/bin/sleep` 关闭测试，首轮 29 项通过；补充流读取失败不能被根进程 exit 0 掩盖后，
  全量 Swift **1167 项 / 128 suites 通过（36.583 s）**，计时产物
  `.artifacts/test-stability/macos-plan-full.{json,html,junit.xml}`。ARM64 GUI 与安装仍待验收。
- 元数据复查继续修复：隔离目录移到全部 `use` 清单/manifest 校验之后分配；源 symlink、
  `use` 目录改指向、新建 go.work 和 workspace 改指向都会使刷新失效。明确检查隐式 macOS
  Go 缓存目录，防止打开 `~/go` 或缓存目录时被默认缓存写入；go.work 限制为 1 MiB。
  `regularFile` 使用真实文件类型，拒绝 FIFO/socket/device，避免工具头读取阻塞 worker。
  首轮新增元数据/任务/Cargo 树回归 40 项通过，随后全量 1171 项通过（35.840 s）；
  FIFO 准入回归补齐后，最新全量 **1172 项 / 128 suites 通过（35.429 s）**，
  报告仍为 `macos-plan-full.{json,html,junit.xml}`。源码/任务标题更新后的包尚未进行 GUI 验收。
- ARM64 包曾成功生成并通过 codesign/lipo 检查，但窗口接口对 Lithe、访达和 GoLand
  均返回 `cgWindowNotFound`；未能执行有效的点击或截图，不能计为 GUI 通过。已关闭该测试
  实例并确认无 Lithe 进程残留。待桌面恢复后继续验收，之后才提交和替换系统安装。
- 桌面解锁后完成第一轮真实点击：多模块树与选择/展开保持正常；连续 3 次刷新后，13 个
  fixture 文件 SHA-256 不变且无新增文件。双击普通 main 与两个独立测试成功；Stop 一个测试后，
  另一个测试及普通 Run 的进程仍存活。证据在 `.artifacts/goland-parity/b7a3-gui/`。
- 第一轮 GUI 未放行：父级 DisclosureGroup 菜单覆盖子节点、模板图标显示实心方块、右侧面板
  遮住 Run 控件、Go 错误输出未生成链接。现已修复并按用户要求让 Go 任务复用 Cargo Run 的
  列表/详情/工具栏样式，Go 与 Rust 工具图标统一为原创 G/R 轮廓。4 项输出链接回归已补齐，
  最新完整 Swift **1176 项 / 129 suites 通过（34.640 s）**；修复后 ARM64 包正在重建，
  必须重做真实编辑/运行/点击/截图才可提交与替换安装。


<a id="go-tools-acceptance"></a>
### 6.5 当前验收与代码复核（2026-09-08）

- **复用结论**：保留已有 Go 元数据与检测器，复用 Cargo 分阶段捕获、现有 Run 列表和原生
  进程驱动。修复生命周期、隔离准备和 GUI 缺口，没有整体回退 GLM 实现。
- **自动验证**：最终完整 Swift 1176 项 / 129 suites，35.203 s；最后 Cargo 菜单修复后
  27 项 / 5 suites，0.043 s；无配置任务行按钮修复后 18 项 / 3 suites，0.032 s。
  Rust verifier、shared contracts、service/module boundaries、test stability 与 diff 检查通过。
  报告位于 `.artifacts/test-stability/macos-plan-full.*`、`macos-cargo-go-final.*`、
  `macos-go-row-final.*`；完整 Rust 日志为 `.artifacts/plan-implementation/go-tools-verify-rust-core.log`。
- **实际编辑闭环**：Go Build 报错，点击 `check.go:3:28` 打开源文件；在编辑器内把
  `missingValue` 改成 `42`，保存后点击重跑，构建成功。Check Formatting 只输出待格式化
  文件名，文件 SHA-256 不变；Vet、Tidy、Download、Verify 全部真实执行成功。
- **树与隔离**：多模块、同名包、任意文件名 main、build-tag 排除项和单模块均正确。
  多模块连续三次 Refresh 后 13 文件 SHA-256 不变、无新增文件，选择与展开保持。
  两个独立测试与普通 `go run .` 并发；停止一个测试后，另一个测试和普通 Run 进程仍存活。
- **界面**：Go 任务使用 Cargo Run 的列表/详情/输出布局；无 generated.json 的单模块
  Build/Test 成功，切到“当前运行”后可返回任务；终态空输出显示“工具未产生输出”。
  Cargo 目标菜单含 Run / Go to Source，成员菜单含 Open Cargo.toml / Refresh，菜单 Run 成功。
  右栏隐藏恢复、缩小窗口后 Run 控件仍可见。继续使用现有 split 容器，没有新增高频父视图
  拖动状态或自定义 DragGesture；尺寸由可用空间限定。
- **图标**：Go / Rust 工具窗口统一为原创圆形 G / R，模板渲染可读，深色与浅色实机截图均已核对，结束恢复原深色设置；
  源文件为独立路径绘制，NOTICE 同步记录，未拷贝 RustRover 资源。
- **证据**：`.artifacts/goland-parity/b7a3-gui/01-go-tree-refresh.png` 至
  `12-cargo-light.png`、`metadata-after-three-refreshes.json`、
  `stop-isolation-processes.txt`、`after-go-tool-actions.json`。中间失败截图不能作为最终通过证据。
- **清理与范围**：每轮 Cmd-Q 后核实本批应用和子进程退出；预先存在的 RustRover 与用户
  无关 Go 进程保留。gopls 未配置提示仍存在，本批验收的是 Go 工具任务，未声称 LSP 已验收。
  实际格式化写回、gutter、语义编辑事务和 L0–L2 仍按各自计划推进。
- **测试例外**：Go 旧 termination 回调回归通过 AsyncStream 控制顺序；唯一新增
  `swift-real-sleep` 注解只提供 2 秒本地失败期限，不用真实休眠同步状态。
- **最后复验通过**：无配置工具行的 Run/Stop 改为独立准入，新建任务后从列表点击 Run
  生成新的成功任务，再从列表停止长测试，终态为已取消。单模块仍无 generated.json。
  原创 G/R 在深浅色下均可读，应用和测试子进程退出干净。
- **提交与系统安装**：实现提交 `211395cc`，从该提交的干净独立检出打包，完整 Swift
  1168 项 / 128 suites 通过（35.011 s），报告 `macos-go-committed.*`。该检出未包含
  原工作区尚未完成的 Search 改动，因此测试数与上方工作区结果不同。
  `/Applications/Lithe.app` 已替换，构建标记为 `211395cc` / dirty=false；签名与包内
  二进制 SHA-256 一致。安装版 Go Test、Cargo Run 实际点击通过，退出后无本批进程残留。
  证据为 `.artifacts/goland-parity/b7a3-gui/installation.json`、
  `13-installed-go-test.png` 和 `14-installed-cargo-run.png`。
