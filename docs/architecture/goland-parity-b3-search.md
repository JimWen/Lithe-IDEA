# B3 搜索与替换分批方案

状态：B3a 已验收，见 [输入与生命周期验收](#b3a-acceptance)；B3b1a Unicode 搜索/替换崩溃修复也已通过独立审查、完整测试及 ARM64 点击验收，见 [Unicode 验收](goland-parity-b3b-replacement.md#b3b1a-acceptance)。B3b 范围与事务的最新实现见 [缓冲区事务记录](goland-parity-b3b-replacement.md#buffer-transaction-integration)，B3c/B3d 仍待实施。基线 `cb892c85`；Project 按用户最新要求暂停。已验收的 B1 提示/快捷键、最近项目菜单、基础 View 入口跳过，不重复实现。

## 优先级与现状

先修影响操作正确性的搜索生命周期和输入问题，再合并 Find/Replace 体验与补齐最近项。当前已有 All/Classes/Files/Symbols/Actions/Text、项目/目录/Open Files、匹配选项、结果预览、Find 工具窗口和替换预览，继续复用。

- P1：Search Everywhere 使用全应用 key monitor，只判断弹窗标志；另一项目或设置窗口的按键可能被旧弹窗截获。左右键被拿来切类别，不能正常编辑查询；组合输入的方向/回车/Esc 也被拦截。
- P1：Search Everywhere 与替换预览没有各自的请求代际；旧请求可覆盖新选项或替换文本，clear/reset 后仍能重新填入结果。替换预览完成后，AppModel 只比较 query，旧任务还会重新全选文件。
- P1：替换应用没有完整的原文校验、跨文件事务与 undo，必须在 B3b 作为独立数据安全批次解决，不能把修复预览竞争等同于解决替换事务。
- P2：项目/目录搜索未纳入未保存缓冲区；搜索弹窗空查询最近项缺失；Find/Replace 是两个互不一致的界面。后续逐批完成。

## B3a：请求生命周期与键盘输入

SearchFeatureModel 分别持有 project search、Search Everywhere、replacement preview 代际；开始、清空、reset 都使前次请求失效。只有本代请求可改结果和 loading；旧任务不得清掉新任务的 loading。异步返回同时检查调用方工作区身份、任务取消和输入有效性。同步 SearchOperations 在有明确所有者的 GCD worker 执行，避免占用 Swift cooperative executor；当前同步端口无法中止已开始的 Rust 调用，取消后丢弃结果，不声称物理停止搜索。

AppModel 持有独立 SearchRequestLifecycle，在首个 await 之前为每类请求分配 token，并捕获工作区身份与请求输入，激活返回后重新验证；clear/dismiss 即使尚无 feature 也使 token 失效，关闭标志直接变化也必须失效，防止同输入重开和两个激活等待倒序恢复。Search Everywhere 包含会话身份和弹窗可见性，替换预览包含 query/replacement/options/文件集合/缓冲区快照。预览函数返回是否被当前请求采纳；只有成功采纳并仍有效时才设置选择。清空替换输入即使尚无结果也必须使加载请求失效；关闭预览窗口同样清空失效。布局仍复用现有界面。

apply 单独持有 busy，旧 isLoadingProjectReplacement 兼容为 preview/apply 聚合；apply 期间不能启动另一 apply 或 preview。clear/reset 只结束 preview loading，不能提前结束仍在执行的 apply busy；由 apply 的 defer 唯一结束。回归包括 recordHistory 挂起期间清空/关闭预览，实际写事务仍留 B3b。

输入监听使用绑定 NSView 的可拆卸 helper，由其所属窗口决定事件归属。仅在弹窗仍可见、所属窗口为 key、事件来自该窗口且无 attached sheet 时处理按键；Find 本身是 sheet，判断其自身而非 parent 的 attachedSheet。NSTextInputClient 正在 marked text 时全部交还输入法。无修饰上下键移动结果，Return/Enter 执行，Esc 关闭，Tab/Shift+Tab 切类别；左右键、Shift+方向键和带 Command/Option/Control 的编辑操作保留原生行为。Find in Files 的上下键监听复用同一归属/IME 判定，不另造全局监听。移除视图或关闭窗口立即注销 monitor，更新回调避免捕获过期 query/selection。

本批不改变 Project，不加入依赖索引占位，也不声称 B3 全部完成。最近文件/动作、再次双 Shift 切换范围和统一替换界面仍在后续批次。

验证使用可控同步端口与有界事件信号，覆盖同 query 不同 options/replacement 的倒序返回、clear/reset 后旧返回、取消与上下文失效；确认旧请求不能改 loading 和选择。额外覆盖首次模块激活挂起时 dismiss 后同输入重开，以及激活等待倒序返回。键盘行为使用原生窗口/输入客户端测试，检查左右键、修饰键、IME、所属 sheet、嵌套 sheet、非所属窗口和拆卸。所有 gate 的超时均可断言，所有任务保留并等待结束。运行隔离测试应用实际点击双 Shift、输入、移动光标、切类别、Find 预览与 Escape，截图核验；不触碰用户已打开项目内容。[GoLand 官方搜索说明](https://www.jetbrains.com/help/go/searching-everywhere.html)确认双 Shift 打开和 Tab 切类别；具体样式以本机版本为准。

## 后续批次与依赖

1. B3b：统一搜索/替换请求模型和 scope，补齐所有 scope 的未保存文本；明确错误、结果限制、匹配位置和 regex 引擎。替换编辑事务先实现原文/版本校验、全部预计算、失败回滚和统一 undo，再接单项/选中/全部及排除预览。具体代码审计、动态库复现、事务边界和分批验收见 [B3b 细化方案](goland-parity-b3b-replacement.md)；B3b1a matcher/候选修复已验收，scope、事务和原生 undo 已接通，最新验证范围见细化方案的事务记录。
2. B3c：Search Everywhere 最近文件/动作、`/` action 过滤、再次双 Shift 的真实可索引范围、空结果转 Find；按 GoLand 核对分组、图标、行高、焦点和小窗口适配。不存在的依赖索引不伪造可用。
3. B3d：统一 Find/Replace 弹窗与底部 Find 工具窗口，复用 LitheSplitPaneView，键盘/IME、预览/导航、替换取消/undo、中文 emoji/零长度 regex 与大项目验收。

每批独立方案审查后实施，按 stable-tests 运行行为测试与完整 macOS 检查，完成边界/diff 检查、真实构建与点击截图、独立代码审查后 commit。B4 设置、B6 重构、B7 运行与工具集成、语言方案 L0–L7 和最终 Git G1 保留在总计划，不随本批完成而勾选。

<a id="b3a-acceptance"></a>

## B3a 已完成验收

2026-09-06，代码 `010d4d57`，`search_review` 独立方案与代码审查通过。
交付请求代际/工作区校验、preview/apply busy 分离、所属窗口键盘路由与 IME 保护。
与 Terminal 基础修复一起完成 Swift 985 项 / 103 suites（32.133 秒）、服务边界、
稳定性门禁、diff 检查和 ARM64 Release 构建。

真实点击验证双 Shift、查询内光标编辑（`abcd` → `abcXd`）、Tab 切换 Classes、
Esc 关闭；Find 查询 `package` 返回 9 个文件并可用 Down 切换预览。
IME、其他窗口、嵌套 sheet 和请求倒序使用原生/受控回归验证，未声称人工输入法验收。
证据在 `.artifacts/goland-parity/iteration7-search/`：`search-release-caret.png`、
`search-release-category.png`、`find-release-results.png`、`find-release-keyboard-next.png`
及 `test-stability/`。QA、子进程与 LaunchServices 登记已清理。
跨文件 Apply、scope 与整体 Undo 仍按 B3b–B3d 交付。
