# Terminal 显示设置与字体更新

状态：B4a5a 依赖前置修正已实现并验收，提交 `68d51977`，见 [本批验收](goland-parity-iteration10-acceptance.md)；B4a5b 产品显示配置待实施。B4a4 启动配置已验收；Project 保持不变。两个显示批次全部验收后才标记 B4a5 完成。

## 字体更新的前置修正

固定 SwiftTerm `1.15.0` / `dd2fb8ac5b861e7bf617c872895e338f38165648` 的 `font`、`lineSpacing` 经 `resetFont → resize → terminal.softReset` 重置 VT 模式，甚至在网格不变时也会重置。其正常窗口缩放 `processSizeChange` 直接调用 emulator resize，没有这个额外 reset。公开 API 无法完整快照并还原内部模式、保存光标和字符集。

核查时上游主分支 `b5338ba35400d7da9e1b50b1f83e18c0d0dba2e0` 仍保留该 reset，且渲染架构已发生较大变化。因此本批保留 1.15.0，编译 `third_party/SwiftTerm` 中实际所需的 SwiftTerm library 源码，用一个可反向验证的窄补丁修正 typography。遵循 [依赖存放规则](repository-layout.md)，不修改 `.build/checkouts`，不引入外部 fork 发布或构建时下载补丁。

来源：[固定版本源码](https://github.com/migueldeicaza/SwiftTerm/blob/dd2fb8ac5b861e7bf617c872895e338f38165648/Sources/SwiftTerm/Apple/AppleTerminalView.swift)、[核查时主分支](https://github.com/migueldeicaza/SwiftTerm/blob/b5338ba35400d7da9e1b50b1f83e18c0d0dba2e0/Sources/SwiftTerm/Apple/AppleTerminalView.swift)。

保留准确 revision、上游文件清单/SHA-256、完整 MIT 许可证和 patch。仅纳入 library 编译源码及 Metal shader；不引入示例、上游测试、CLI、CI、二进制。精简后的 Package.swift 也进入 patch，保持 package/target/product 为 SwiftTerm。许可证及修改说明随 `SwiftTerm_SwiftTerm.bundle` 安装。

新增离线校验脚本：核对文件集合、在临时副本反向应用 patch，再逐文件校验还原后的上游哈希；失败即非零退出，清理临时副本。哈希不是只对最终修改文件自证。根 Package.swift 改用本地 package，重新解析 lockfile；保持仍需的 swift-testing/swift-syntax 版本。离线保证仅针对这份 SwiftTerm 源码，不宣称整个 Lithe 无需网络构建。

补丁契约：

- macOS 提供一次更新 font 与 lineSpacing 的入口，避免连续两次网格 reflow。现有 setter 共用安全路径；不改变公开 `resize(cols:rows:)`、parser、PTY、terminal 协议。
- 字体变化走正常 `processSizeChange`。同网格变化也刷新 attributes、Metal row/shaping/glyph/derived-font 缓存、caret、search/accessibility 几何和显示。保留主字体同名同字号、仅 cascade 改变的场景。
- 保留 view、Terminal、PTY 身份、进程和协议模式。网格变化遵循现有 resize 的 margins、scroll region、selection、同步输出契约；不能要求尺寸相关状态逐位不变。字体 setter 原有清除 selection 行为可保留。
- macOS 在同步输出期间完整暂存 font/lineSpacing，提交后主队列应用最新组合；两种独立 setter 均合并 pending 的另一项，不在 emulator resize 触发的同步结束回调里递归 resize。Metal 绘制入口拒绝未提交帧；CoreGraphics 保存并临时采用原生 `.never` redraw policy 保留屏幕 backing contents，结束时恢复实际原值，不生成位图副本。不能在 CG draw 收到已清空的 context 后直接返回，否则会黑屏；显式离屏 draw 仍完整绘制，不属于屏幕 backing 冻结契约。用事件回归覆盖连续 setter、重复同步、新配置抢先应用以及窗口 resize 结束同步。
- CoreGraphics 在冻结前绘制已标脏的上一提交帧；该绘制可能触发 resize 并结束同步，返回后必须复核同步与保存的 policy。Metal 在同步期间移动到另一窗口时延迟 rebind，提交后以当前 window 绑定，避免提前清空已有 drawable；真实窗口尺寸变化仍遵循上游 resize 结束同步的契约。
- font descriptor 的粗体/斜体转换保持 cascade，先通过原生行为验证；确有丢失才追加对应窄修正。不得以 descriptor 字段存在代替真实字形验证。

先以同步原生测试覆盖同网格和变网格字体更新、应用光标/键盘、origin/insert/wrap、保存光标、主/备用 buffer、颜色、OSC8、bracketed paste。用现有 PTY 事件测试和 GUI 验证 PID、实际输入字节、stty 网格与持续输出。Metal 实际渲染、中文/emoji/粗斜体、fallback-only 更新、隐藏恢复与窗口移动在产品配置批验收，前置修正通过不代表整个 B4a5 已完成。

## 产品配置边界

新增 `TerminalDisplayConfiguration` 纯值模型，与启动配置分开持久化，避免改显示时重写 shell 或环境。`AppSettings` 通过既有 KeyValueStore 保存版本化数据，未知/损坏载荷保留并给出诊断；显式编辑或恢复默认后覆盖。显示错误不会重启或阻止已运行进程。

设置含字体/字号、有序回退、行高、scrollback、光标形状/闪烁、Option Meta、滚动倍率、选择复制策略与链接行为。保留当前默认外观与输入语义，设置值必须有真实消费者。数值需要有限范围及非有限值检查；字体不存在时显示明确诊断，不将无效名称伪装成已应用。缩小 scrollback 会裁剪旧历史，UI 明示。

`TerminalFeatureModel` 持有当前有效显示配置，新普通和 managed session 启动前应用；设置更新通过同一入口 diff 后更新所有保留会话。`TerminalTransport` 接收纯值配置；NSFont/CoreText、SwiftTerm 和原生输入策略由 macOS adapter 实现。SwiftUI 不直接反复写原生 font，设置变化不触发 session/native surface 重建，不引入父 View 拖动高频更新。

光标设置定义为用户默认，允许 TUI 的 DECSCUSR 随后覆盖。复制粘贴继续使用 SwiftTerm 原生 API、bracketed paste 和现有链接解析；copy-on-select 只在实际选择变化后触发，避免旧选择、鼠标报告或链接点击误复制。恢复默认只更新显示和以后启动配置，保留运行中的 shell 快照。

UI 沿用现有 TerminalSettingsView 分组、原生控件和双语资源。产品配置实施前补齐实际字段边界及单一订阅所有者的代码审查，不加入只有 UI 的占位选项。

### 产品批细化契约（独立审查通过，待实现）

| 字段 | 默认与边界 | 生效规则 |
| --- | --- | --- |
| 字体 | 空值沿用现有 Nerd Font 优先序；有效 PostScript ID | 原生字体目录一次枚举，返回纯值 ID/名称；缺字体保留已有 typography 并诊断，新会话使用默认字体 |
| 字号/行高 | 13 pt / 1；分别为有限数 8–48 / 1–2 | 与有序 fallback 一次更新，不重建会话 |
| 回退字体 | 空列表；最多 8 个、唯一、有界且无 NUL | 用 CoreText cascade，验证粗体/斜体和真实字形 |
| 历史行数 | 2000；0–100000 | 0 对应原生不保留 scrollback；减少时明确提示裁剪历史 |
| 光标 | block，闪烁 | 新进程和本字段变化时应用用户默认；其他显示变化不覆盖 TUI DECSCUSR |
| Option as Meta / 滚动倍率 | true / 1；倍率有限数 0.05–10 | 原生 adapter 消费 |
| 选择即复制 / 复制后保留选择 | false / true | 选择即复制保留选区，手动复制遵循选项 |
| 链接 / 修饰键 | 自动识别 / Command | hover 与 click 共用允许模式，关闭必须同时禁用识别和激活 |

配置持久化错误使用独立诊断，保留损坏载荷，默认显示仍可运行；不得写入会话启动错误卡。单一订阅归属于 `AppModel.activateTerminalModule` 的 capability binding：激活后先复核同一 capability 是否已绑定；通过 `observeModuleFeature(.terminal, ...)` 管理取消。订阅 `$terminalDisplayConfiguration.removeDuplicates()` 的发射值，不读取 willSet 时尚未更新的属性，也不 `dropFirst`。未激活/休眠模块不被设置强制唤醒；每个项目 AppModel 在实际激活时收到最新共享设置。

`TerminalFeatureModel` 保存有效配置并同时覆盖普通/managed session 创建入口；transport 做 diff，SwiftUI body 不更新 native font。字体目录经 Settings 所需 port 注入，不在 View body 枚举，也不为显示字体清单激活 Terminal。显示字段错误互不阻塞合法字段。

选择即复制在 native mouseDown/mouseUp 两端比较本地 selection revision；revision 在现有 `selectionChanged` 的 `super` 后递增。只有实际选区变化且非空才复制，排除链接手势、TUI mouse reporting（遵循 Shift capture），覆盖双/三击、Shift 扩选、不同位置同文本。无需新增 published 高速鼠标状态。

当前 SwiftTerm `linkForClick` 与 `updateHoverLink` 固定使用 `explicitAndImplicit`，仅写 `linkReporting = .none` 不能关闭链接。产品批需追加 hover/click 共用 lookup mode 的窄补丁并验证 `.none` 清理旧 hover/拒绝激活；不将原生内部 `always` 模式直接暴露为用户选项。上述链接修正尚未进入本批 typography 补丁。

## 审查与验收

依赖方向已由独立 agent 审查放行，要求来源可反向验证、license 随包、固定依赖图、完整缓存失效和正常 resize 契约。具体方案再审查后实施，完成后独立代码审查。

每批运行 stable-tests 静态门禁、相关 Swift timing harness、完整 macOS 测试、service boundaries、ARM64 完整构建、资源/签名核对与 `git diff --check`。前置依赖批至少执行一次 Metal 实际启用及字体变化后持续绘制的 smoke，排除静默 fallback；完整字体与 Settings 验收仍在产品批。极小/隐藏 surface 保持正常缩放契约，Lithe 已通过 terminalWindowSize 读取实际 clamp 后网格发送 PTY，不拓宽上游 resize 补丁。

GUI 用自有 QA 项目操作，不改用户 Project；保存截图和实际协议/进程证据。关闭测试 app、清理全部自有进程后分批 commit。字体回退、显示设置和 venv 未验收项继续保留在总计划中。
