# GoLand 工作台与可扩展语言能力实施方案

状态：B1 菜单、工具窗口命令和基础 View 已实现并验收，跳过重复实现。用户 2026-09-06 明确 Project 当前够用，B2 的 Project 部分暂停。B3a 搜索正确性与 B4a0–B4a3 终端设置/重启修复已验收，见 [输入与终端验收](goland-parity-iteration7-acceptance.md)。B3b1a Unicode 搜索崩溃与 Rust 增量链接也已通过独立审查、完整测试和 ARM64 实际验收，见 [Unicode 与链接验收](goland-parity-iteration8-acceptance.md)。B4a4 Terminal 启动配置亦已完成，见 [Terminal 设置验收](goland-parity-iteration9-acceptance.md)。其余批次仍待实施。现状审计与独立方案复核见 [审查记录](goland-parity-plan-review.md)。基线提交 `c09f2cc4`，目标分支 `dev/aiide`。

## 1. 目标与完成规则

本方案保留用户提出的十项工作台要求，以及 Tree-sitter / 插件语言扩展两项要求。上述方案完成后，还须按用户补充要求复验底部 Git 与分支图（G1）。Rust 专属行为以用户已打开的 RustRover 为参考。
“对齐”同时包括入口、布局、鼠标、键盘、持久化、真实操作结果和失败恢复；截图相似或单元测试通过不等于功能完成。
每批顺序为：现状证据 → 技术方案 → 独立 agent review → 修正审查问题 → 实现 → 自动检查与真实应用验收 → 独立代码审查 → commit。
审查不需要用户重复批准已经授权的工作。未通过的批次继续修正，不能用禁用占位按钮替代实现。

继续复用现有 Rust Core、SwiftUI/AppKit、SwiftTerm、LSP runtime、模块和插件体系，保持 macOS 产品范围和上游合并能力。
不恢复已移除的 Windows 产品、Java 工具链、Maven/Spring、Linux.do 集成。
语言方案详见 [syntax-and-completion.md](syntax-and-completion.md)，它定义离线语法层与完整 LSP 的协作，而非用 Tree-sitter 代替类型分析。

## 2. 证据基线

- 本机 GoLand **2025.2.4 / GO-252.27397.100**；本机 Zed **1.18.1 / 20260904.150309**。优先以用户正在使用的版本作视觉参考；官方在线帮助只补充行为契约，版本差异需显式记录。
- 本机 RustRover **2026.2.1 / 262.9437.161** 已实际打开 Cargo、`main` gutter 菜单、Modify Run Configuration 和 Rust 设置。证据为 `rustrover-cargo.png`、`rustrover-run-gutter.png`、`rustrover-run-config.png`、`rustrover-rust-settings-expanded.png`；未运行其示例程序，配置对话框均取消。补全与重构仍需后续实际操作核对。
- 代码审计覆盖 Commands、Workbench、Project/Commit/PR、Search、Settings、Keymap、Terminal、LSP edits、RunService、Go/Cargo detectors、PluginManifest 和右侧模块注册。
- 最近项目菜单实测：展开后 0.19 秒有 16 个可见菜单项，0.73 秒时全部消失；期间仅只读 AX 采样。故障已复现，Commands 过宽观察仍是需要 A/B 验证的原因候选。
- Zed Terminal 设置实际打开：Environment 下 Shell、Working Directory、Environment Variables、Detect Virtual Environment；Font 下 Font Size、Font Family、Font Fallbacks。
- 用户 `11.png` 是 Zed 扩展分类页，包含 TOML、Dockerfile/Compose、SQL、Make、LOG、CSV；这些格式进入语言验收矩阵。
- 本地截图、AX 快照与菜单生命周期采样位于 `.artifacts/goland-parity/iteration5-planning/`，包含 `recent-lifetime-baseline.json`、`zed-terminal.png`、`goland-menus.jsonl`。产物不进入产品资源或源码提交。

## 3. 要求到批次的映射

| 用户要求 | 当前缺口 | 完成批次 | 必需证明 |
| --- | --- | --- | --- |
| 1 左栏提示与快捷键 | 多数 help 只有标题，部分动作未注册命令 | B1、B4 | 鼠标提示显示实际生效键位；改键后提示、菜单和执行同步 |
| 2 Project/Commit/Pull/Structure/TODO | Project 假下拉；Commit 命名不一致；PR 全局关闭；Structure/TODO 缺失 | B2、B7、L4 | 每个工具能打开/关闭、保留状态、真实导航或完成动作；各自菜单验收 |
| 3 最近项目菜单 | 实测自动消失 | B1 | 后台状态更新时稳定展开，鼠标和键盘可选，同名/失效/多项目正确 |
| 4 View 菜单 | Tool Windows 在 Window 内，View 缺少已有能力入口 | B1、B4 | 可执行工具窗、编辑器显示与布局操作；菜单状态随真实设置同步 |
| 5 双 Shift / Find / Replace | 空搜索最近项缺失；scope 与未保存文本不一致；查找/替换分离 | B3 | 键盘、IME、最近项、搜索域、预览和替换/撤销完整工作 |
| 6 Appearance/Keymap/Editor/Plugins | 固定主题枚举；导入和 chord/context 缺失；Editor 设置少；Plugins 不在 Settings | B4、B5 | 每个核心设置有实际渲染/操作效应；预设和导入 fixture；主题安装/切换/卸载 |
| 7 Terminal 设置 | 仅 shell，改设置会重启当前终端；字体/回滚固定 | B4 | Zed 核心项生效，新会话参数不终止正在执行的会话 |
| 8 Refactor | 无 prepareRename、选区未传 code actions、跨文件版本/undo 不足 | B6 | Go 重构矩阵逐项执行，预览/取消/应用/冲突/undo，项目仍可构建 |
| 9 入口运行与参数 | detector 有缺口，无行级 gutter | B7 | Go/Rust/Python 入口位置正确，Run/Debug/Edit；args/env/cwd 实际传入且可持久化 |
| 10 Go Tools / Cargo 右栏 | 承载已有，贡献和工具树缺失 | B7 | 项目识别、目标树、常用工具执行、错误导航、取消/刷新 |
| 语言 1 Tree-sitter 编辑/高亮/补全/推荐 | Java 专属语法路径、正则兜底、补全菜单 | L0–L6 | 增量与全量一致、可见区高亮、完整补全/提示交互、LSP 语义能力 |
| 语言 2 插件语言与常规格式 | manifest 缺语法资源；任意新 grammar 不能仅加 JSON | B5、L2、L7 | 安装宿主未内置语言的插件，真实高亮/格式化/补全，禁用/升级/卸载正确 |
| 补充 底部 Git / 分支图 | c09f2cc4 有首轮样式，尚需完成后的 GoLand 复验 | G1 | 相同仓库与窗口尺寸下打开/选中/筛选/滚动/缩放对照；线条简洁且拓扑不断裂 |

“Pull”暂按 GoLand 左侧 **Pull Requests** 工具窗口理解，已向用户发出澄清；Git Pull 保留独立操作，不将两个概念混为一个按钮。

## 4. 公共设计

### 4.1 一个命令标识贯穿所有入口

`LitheCommandCatalog` 定义稳定 action ID、名称、可用条件、默认绑定；菜单、工具栏、Search Actions、Keymap 与插件 action 都复用它。
tooltip 从 `KeyboardShortcutFeatureModel.displayText(for:)` 取得实际生效绑定，未绑定则只显示名称，不虚构快捷键。
用户覆盖优先于预设；升级新增默认键位时不得夺取已绑定的键。快捷键上下文区分编辑器、终端、工具窗口、弹窗和菜单 tracking。

### 4.2 生命周期与状态投影

Commands 观察稳定、可等值比较的命令状态，不订阅整个 AppModel 的终端输出、Git 刷新和光标脉冲。
投影只包含菜单可见性、enabled/check/title、快捷键、最近项目等字段。AppKit menu tracking 状态在 macOS 层管理；展开期间缓存新投影，结束后提交一次。
项目焦点与命令所属项目明确绑定；保存、搜索、运行、Git 动作不能因全局广播落到另一个项目。
源对象 `objectWillChange` 发生在写入前，投影采样须在变更完成后合并；“删掉观察”导致菜单永不更新不是修复。
详细的首批契约和验证见 [goland-parity-b1-commands.md](goland-parity-b1-commands.md)。

### 4.3 统一编辑事务

查找替换、格式化、rename、code action 和 snippet 均通过编辑事务层接入原生 undo。
事务持有 workspace/session/document/version 身份以及预期旧文本；应用前重新校验、预计算全部 edits，拒绝重叠 edits 和过期结果。
跨文件事务覆盖已打开且未保存的缓冲区；关闭文件写失败回滚已写部分，不能以单文件 undo 冒充整体撤销。
资源操作（create/rename/delete）显式建模并处理覆盖/缺失/大小写文件系统/项目边界，不把 rename 文件当文本替换。

### 4.4 设置与资源插件

设置持有 typed defaults + user overrides + project overrides；UI 是同一模型的编辑器，值要由使用该能力的 renderer/service 消费。
资源插件为 theme/keymap/language/snippet 提供声明式 payload，复用插件安装、校验、启停、回滚与卸载。
与语言方案共用 manifest 版本策略：兼容当前 v1；新增资源能力使用显式新版本和宿主最低版本，旧宿主不能静默忽略后声称安装成功。
纯主题/键位包不需要执行原生代码。可执行语言包默认沿用正式同 Team 签名；本机临时签名无 Team 的独立安装另走语言方案 6.3 的显式本地执行授权：安装前显示能力与来源，用户确认后把信任绑定到包/可执行内容摘要及版本，升级/替换需重新确认。不能把无 Team 当可信，也不能用 mock 校验替代真实安装。所有资源限制大小、路径和层级，防止跨包读写。

## 5. 分批实现

### B1：菜单稳定性、工具栏命令和基础 View

范围：要求 1、3，以及 4 中已有真实能力。修复最近项目菜单；统一 Project、Commit、Find、Git、Terminal、Run、Debug、Problems 的动作与提示；View → Tool Windows 接入相同动作。
已有显示能力（编辑器布局、Markdown 视图等）按上下文可用；没有实现的 Structure/TODO/软换行开关在后续能力落地时接入。
在 `ProjectWindowScene` / Commands 之间建立稳定聚焦上下文，原生 tracking 生命周期留在 macOS 层。
先验证原始菜单故障，再实现投影并以相同后台刷新场景复验；最近项目排序、重复名路径说明和不存在项目错误处理不能退化。
目标提交：菜单生命周期、命令/tooltip、View 菜单可分别审查提交；每项不得破坏已有自定义 keymap。

### B2：Project / Commit / Pull Requests 工具窗口

- Project：按用户最新要求暂停，当前实现保持；原下拉、定位、排序与展开状态方案仅保留备查，恢复前重新审查。
- Commit 统一目的地名称和图标，匹配 GoLand 当前 staging 设置；补齐 changelist/default list、文件包含/排除、amend、提交消息、diff 和失败状态。staging 与 changelist 的映射必须显式，不能用重命名 Changes 掩盖行为差异。
- Pull Requests 接入现有 GitHub 模块，先修凭据存储、签名策略与认证/网络错误，再开放入口；列表、筛选、详情、文件 diff、讨论/review、checkout 与已有 merge 操作逐项验收。账户缺失显示登录入口，不能显示空白“成功”。
- 外部发表评论、review、merge 等验收使用协议 fixture 和明确授权的测试仓库；用户这次要求实现功能不等于授权向其真实仓库发送消息。
- TODO 的可交付版本放 B7/L4，不能先增加无实际内容的占位按钮。

### B3：Search Everywhere 与统一 Find/Replace

复用现有 Rust search 与 SearchFeatureModel；保留 All/Classes/Files/Symbols/Actions/Text，空 query 展示最近文件/动作，双 Shift 再次触发切换搜索域，Tab 与 Shift+Tab 切换类别。
Include non-project items 接入明确可索引的依赖/外部根，而非空开关；`/` 命令与 Find Actions 共用 action catalog。没有匹配时能转 Find in Files。
Find/Replace 共用 query、case/word/regex、mask、Project/Directory/Open Files、结果列表和代码预览；所有 scope 纳入当前未保存缓冲区。
替换提供单项/选中项/全部、替换预览、排除项、原文校验、统一 undo；支持捕获组与保留大小写的明确规则。
弹窗按窗口约束适配，复用 `LitheSplitPaneView`，焦点稳定，输入中不反复抢主编辑器焦点。索引/查询有取消和 generation，旧结果不能覆盖新 query。
验收：双 Shift 不与输入法组合、连续 Shift、终端交互冲突；键盘选择/预览/Esc；未保存文本；非法/零长度 regex；中文/emoji；大项目取消；跨文件替换失败回滚与 undo。

### B4：Settings 核心、键位预设和 Terminal

Settings 导航整理为 Appearance & Behavior、Keymap、Editor、Plugins、Terminal、Languages & Frameworks 等稳定类别；搜索结果直达真实设置项，提供恢复默认及修改状态。

| 类别 | 这一目标内必须实现的核心项 | 生效边界 |
| --- | --- | --- |
| Appearance | 内置与安装主题、跟随系统/明暗、UI 字体/字号、紧凑度 | 全工作台、菜单/弹窗、工具窗与设置实时更新 |
| Editor | 字体族/字号/行距、Tab/Spaces/缩进宽度、软换行、行号、空白显示、当前行、括号与引号配对、自动缩进、保存时格式化开关、tab 布局 | 渲染、光标命中、输入、undo 与新/现有文档均验证 |
| Keymap | GoLand/IDEA、VS Code、Visual Studio、Eclipse 预设；搜索动作/按键；录制、冲突、恢复、导入、导出 | tooltip/菜单/编辑器/终端/弹窗使用同一 effective keymap |
| Plugins | 搜索已装/可装、详情、版本、启停、安装、卸载、升级/回滚、错误 | 复用 plugin runtime；B5 添加资源插件 |
| Terminal | shell 程序和参数、login 开关、cwd 策略、自定义 env、venv 检测、字体/字号/回退/行距、scrollback、光标/闪烁、Option as Meta、复制选择、复制后保留选区、滚动/链接行为 | 启动项仅新会话使用；显示项按 transport 能力实时更新 |

Keymap 导入格式：IDEA `keymap XML`、VS Code `keybindings.json`/JSONC、Visual Studio `.vssettings`、Eclipse exported preferences/key configuration。
定义 action 映射、OS modifier 转换、两段及多段 chord、上下文 predicate 的受限 AST；不执行导入文件表达式，不静默丢掉 when/chord。
导入预览列出已映射/冲突/未知 action/未知条件，用户可取消；应用为可撤销的独立预设，不改源文件。常见编辑/导航/搜索/运行/工具窗快捷键以四种真实格式 fixture 验证。
未映射的外部 IDE 专属动作保留在导入报告中；完整目标的核心映射项必须可执行后才验收。

Terminal 使用现有 PTY/SwiftTerm，而非替换终端引擎。cwd 优先级明确为当前文件目录、当前项目、首项目、home 或指定目录；失效路径有错误提示和可选回退。
env 支持增删覆盖但不泄漏到日志；配置更改不重启活动 shell。验证 long-running command 在修改 shell/env 后仍存活，新建会话拿到新配置。
venv 使用运行时发现和显式启动计划，不能把任意项目文本直接拼接为 shell command。display 配置保留重启后的值及明暗主题一致性。

### B5：主题和声明式插件资源

将闭合 `AppTheme` 枚举迁移为稳定 theme ID + registry；保留 Lithe/Codex/Linear 已保存值迁移。
theme token 包括 UI、编辑器 syntax/semantic、Git 图/选中、终端 ANSI、diff、弹窗和禁用状态；未知 token 诊断、缺省回退、颜色格式和可读性检查。
提供明暗内置基准主题，并支持安装 Theme 插件、预览、切换、重载、禁用/卸载回退；预览取消必须恢复之前主题。
导入常见 JetBrains theme JSON / editor color scheme 与 VS Code theme 数据，通过明确 token adapter 转换；非数据的 JetBrains JVM UI 插件不能直接加载到 Swift 宿主。
“可选主题对齐”以可安装的真实主题资源与已验证的 token 映射完成，不放假市场列表。主题、keymap、snippet、语言资源使用同一安装生命周期。
验收包括纯数据主题包，无可执行文件仍可安装；损坏包、路径穿越、超大资源、同 ID 冲突、升级失败回滚、卸载当前主题。

### B6：Refactor 与语义编辑事务

先补通用 LSP prepareRename、真实 selection range、document symbols 和 workspace edit 的 documentChanges/resource operations/version。
Refactor This 菜单与编辑器右键、快捷键共用动作；rename 预填符号名，支持 inline 输入、预览/取消/提交，不能以全文字符串替换实现符号重命名。

| GoLand Go 重构基线 | 实现/验收要求 |
| --- | --- |
| Rename（符号、文件、包） | 符号引用与 import 同步；冲突、字符串/注释选项、跨文件 undo |
| Move / Copy / Safe Delete | 资源操作与引用更新；重名/引用存在时有预览和冲突处理 |
| Extract Variable / Constant / Function / Method / Interface | 传入真实选区；自由变量/返回值/作用域正确，预览可编辑命名 |
| Inline Variable / Constant / Function | 引用/副作用与求值顺序正确；不支持的语义场景明确拒绝 |
| Change Signature | 参数增删/顺序/名称、调用点更新、默认值与冲突预览 |

逐项查询当前 gopls capability/code action；缺失项由 Go language-support 插件的语义工具补足，必要时使用 Go AST/types API，不能把不可用菜单算作完成。
Rust/Python 使用各自 provider 可适用的语义重构，操作入口、预览、事务及错误体验统一；Go 特有的 interface/package 语义不强加到其他语言。
每个 Go 条目有多文件 fixture：操作前后 build/test、取消零改动、版本冲突拒绝、一次 undo 恢复；没有明确证据的条目持续标记未完成。

### B7：入口 gutter、Structure/TODO 与 Go/Cargo 右栏

Rust 的具体交互以正在运行的 RustRover 2026.2.1 为参照：Cargo workspace/package/target 层级、刷新与执行、feature/target/toolchain、运行配置参数/env/cwd、`main`/test/example 的 gutter 菜单。Rust 设置与补全提示分别归 B4 和语言批次，使用同一 RustRover 参考样例；公共工具栏仍保持统一 GoLand 风格。

RunService 与现有 capability-driven 配置编辑器继续复用；语言 provider 提供 stable runnable ID、workspace/package/target、source range、Run/Debug/test 能力和启动计划。
Go 覆盖任意文件名的 package main/main、tests/examples/benchmarks、build tags/module/workspace；Cargo 通过 metadata 覆盖 workspace/member、显式与自动 bin、example/test/bench；Python main guard/module/script 与解释器范围明确。
gutter 根据真实行坐标与折叠/换行布局绘制；鼠标点击和右键提供 Run、Debug、Edit Configuration；args/env/cwd/工具链选择保存到已有 project/local override，不在 View 拼进程参数。
配置编辑器只保存用户确认的变更，临时运行与持久化配置分开；切项目或 detector 返回过期版本不能更新另一窗口的图标/目标。

Structure 优先 LSP document symbols，离线使用 L4 语法结构；提供嵌套树、图标、可见性/继承等 provider 有效筛选、排序、speed search、定位编辑器和状态保持。
TODO 复用工作区遍历与语言注释捕获，支持 TODO/FIXME 自定义 pattern、Project/Current File scope、分组、计数、上下文预览与导航，遵守 ignore；不得扫描二进制或把字符串中偶然的 TODO 当注释任务。

Go Tools 与 Cargo 通过现有 rightSidebar contribution 注册，按 workspace 能力出现、固定位置、可隐藏/恢复；所有执行通过 Execution 模块。
Go 核心 build/test/fmt/vet/mod 与工具链/包信息；Cargo 核心 build/test/check/clippy/fmt/run 与 workspace/member/target 树、features/profile/package 参数。
拓扑读取 `go list` / `cargo metadata`，进程由已有平台 adapter 管理；刷新有取消/超时/失败状态；工具输出进入 Run/Problems，可点击文件行号，终止操作有界清理。

### L0–L7：语言引擎、完整补全与可安装新语言

以 [syntax-and-completion.md](syntax-and-completion.md) 的独立批次为准：离线语法与 LSP 两层、共享增量树、角色映射、语法结构、完整补全 popup/snippet/参数提示、格式化以及插件 worker。
B5 的资源注册与 L7 共用 manifest；B6 的语义编辑事务与 LSP UI 共用；B7 的 Structure、runnable 与 TODO 复用语法/LSP 产物。
最终必须安装一个宿主未内置 grammar 的语言包并获得真实高亮/导航/补全与格式化，不能把重新编译宿主当作插件安装。

### G1：底部 Git 与分支图最终对照

在工作台和语言方案完成后，打开底部 Git，使用相同仓库、筛选条件、窗口尺寸对照 GoLand。复验分支侧栏、日志表头/筛选栏、选中提交与详情、字体/行距、各分隔线及首次打开/再次恢复的布局。
分支图优先保持细直线、紧凑 lane、小节点与清楚的合并连接；减少不必要拐弯、交叉和色彩噪声。必须保留真实 parent/merge 关系，不以隐藏分支换取简洁。
固定线性、分叉合并、交叉、多父节点、过滤、加载边界样例；检查相邻行连接连续、滚动不闪烁、选择与日志对应。若改图布局算法，执行 `scripts/verify-git-graph.sh`；只改渲染也要实际构建、截图及边界检查。调整面板仍复用现有 split 容器，不在业务层追加高频状态更新。
现有 `c09f2cc4` 仅为基线，不能替代本批新证据。仅在实际对照发现差距时修改，再单独审查、commit。

## 6. 顺序、审查和验收记录

基础顺序：B1 → B2/B3 → B4 → B5 → B6 → B7；语言 L0–L7 依赖完整方案审查，可与独立工作台批次交错，但每批仍顺序执行其依赖。
Structure/TODO 依赖 L4，语义重构依赖 B6/LSP，资源语言包依赖 B5/L7；不能以依赖尚未实现为理由永久缩减目标。
源文件交叠时不得并发修改；多个 agent 可审查独立方案，实施阶段按拥有文件划分。

每批提交前：

1. reviewer 给出阻塞问题、修复结果和是否允许进入实施/交付；发现新契约问题则更新对应方案再审查。
2. Swift 检查运行 `scripts/test-macos.sh`、`scripts/verify-service-boundaries.sh`、`git diff --check`；Rust/协议按改动运行 comments gate、Rust Core/shared contracts；新增或修改测试必须走 stable-tests scanner 和 timing harness。
3. 实际 ARM64 应用运行；用隔离项目覆盖当前用户 Go 项目规模、Rust workspace、Python 项目及常规格式；保护用户未保存内容与凭据。
4. 鼠标/键盘/IME/窄窗口/多项目/关闭恢复/取消/错误按该批逐项验收，截图附操作结果和版本；记录性能基线，不能只写“通过”。
5. 清理本批启动的 Lithe/worker/helpers，再按用户已授权范围安装构建包；分批 commit，不自动 push。

| 批次 | 方案审查 | 实现 | 自动检查 | 运行验收 | 代码审查 | commit |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | 方案复核通过 | B1a/B1b/B1c 完成，跳过 | 976 项测试、边界、ARM64 包通过 | 最近项稳定并可选；工具窗、改键及提示、主题、标签、设置入口通过 | 通过 | `8b8f21be`、`cb892c85` |
| B2 | 设计基线复核通过，逐批细化 | Project 按用户要求暂停；其他待实施 | — | — | — | — |
| B3 | B3a、B3b1a 通过；其余逐批细化 | B3a、Unicode matcher/候选修复完成；scope/事务与 B3c/B3d 待实施 | Rust 331、Swift 985、原生链接 7 项及 ARM64 包通过 | 输入/键盘和 Find 预览已验收；新包 Unicode 查找与替换预览通过 | B3a、B3b1a 通过 | B3a `010d4d57`；B3b1a `b0dac7e2`，构建依赖 `00a9f9c1` |
| B4 | B4a0–B4a4 通过；其余逐批细化 | 停止/连接隔离与完整启动配置完成；显示、venv 及其他核心设置待实施 | 997 项完整测试、边界、ARM64 包通过 | 活动 PID/输出、argv/env/cwd、Restart 快照、失败 Retry、Restore Defaults、中文及退出清理通过 | B4a0–B4a4 通过 | B4a0 `59c4ce74`；停止/连接 `517b4584`；启动设置 `db44d036` |
| B5 | 设计基线复核通过，逐批细化 | 未开始 | 未开始 | 未开始 | 未开始 | — |
| B6 | 设计基线复核通过，逐批细化 | 未开始 | 未开始 | 未开始 | 未开始 | — |
| B7 | 设计基线复核通过，逐批细化 | 未开始 | 未开始 | 未开始 | 未开始 | — |
| L0–L7 | 设计基线复核通过，逐批细化 | 未开始 | 未开始 | 11.png 已核对 | 未开始 | — |
| G1 | 设计基线复核通过 | 已有首轮基线 | 待最终复验 | 待 GoLand 对照 | 未开始 | — |

整体完成需要上表每一项的证据，不能用 B1 或局部测试替代完整目标。

## 7. 参考来源

- [GoLand macOS 默认键位](https://www.jetbrains.com/help/go/reference-keymap-mac-default.html)：核对工具窗、搜索和重构快捷键；实际生效键位仍由用户预设/覆盖决定。
- [GoLand Search Everywhere](https://www.jetbrains.com/help/go/searching-everywhere.html)：最近文件、搜索类别、外部项与转 Find 行为。
- [GoLand Refactoring](https://www.jetbrains.com/help/go/refactoring-source-code.html)：重构入口、预览与冲突处理。
- [Zed Terminal](https://zed.dev/docs/terminal)：shell/cwd/env、字体、光标、复制和 Option-as-Meta；界面基准另见本机截图。
- [Keymap 配置](https://www.jetbrains.com/help/idea/configuring-keyboard-and-mouse-shortcuts.html)：自定义与冲突处理参考。

这些来源用于行为核对；本项目设计、限制、批次与实现责任由上述方案定义。
