# GoLand 工作台与可扩展语言能力实施方案

**2026-10-28 范围说明：** 较大的功能迭代继续暂缓。本次仅按用户要求，从截至上游 v0.6.5 的历史中挑选有意义的通用修复，优先轻量 macOS 与 Rust/Go/Python，不新增成套兼容层或配置；见 [集成记录](ai-ide-phase-one.md)。下方优先级和依赖保留为后续参考，不表示已承诺排期。B6a2 等未完成范围仍按各自验收状态跟踪，恢复入口见 [README 当前重点与 TODO](../../README.zh-CN.md#后续-todo)。

状态：B1 命令入口、B3a 搜索正确性、B3b1a Unicode 修复和 B4a0–B4a6 Terminal
已完成。Project 按用户 2026-09-06 要求暂停。B7a1、B7a2a/b/c1 已完成；
Cargo 刷新、双击运行、独立代码审查、GUI 与 ARM64 安装验收已完成（B7a2c2）；其余功能保留在第 6 节状态表，恢复迭代后再复核推进。
2026-09-21 按 GoLand / RustRover / PyCharm 完成一次跨批次体验对齐复核，结论、新增缺口与
优先级调整见 [体验对齐复核](#experience-parity-review-2026-09-21)；该复核未改变任何批次的实现状态。
基线 `c09f2cc4`，目标分支 `dev/aiide`。总体方案复核见
[审查记录](#plan-review)。

<a id="workbench-parity-2026-11-25"></a>

## 2026-11-25 工作台实测（Go、Rust、Python）

主机为 Apple M6、16 GB、macOS 27.0。Lithe 验收包基于 `ab305685` 的 ARM64 Release，最终包包含本轮 SQLite 修复。Go 参照 GoLand 2026.2.3，Rust 参照 RustRover 2026.3.1.1，Python 参照 PyCharm 2026.3.0.2。三语言均在同一组自建源码中检查运行、断点与跨文件跳转。工作台比较使用固定提交的公共项目。

**三种语言最影响日常使用的差距是断点调试。** Lithe 均可运行并跳转定义。三个参照 IDE 均在用户代码断点显示了 21 和 42 两个局部变量，继续运行均输出 42 并以 0 退出。Lithe 三语言各完成一次跨文件重命名，磁盘验证声明和引用同时更新，一次撤销后恢复。Go 的成功路径要求此次会话先打开调用文件并跳到声明，直接操作恢复的标签页曾被新鲜度检查拒绝。

| 操作 | Lithe | GoLand |
| --- | --- | --- |
| Go 编辑、保存、撤销 | 在 `main.go` 粘贴注释、⌘S，磁盘 diff 可见。⌘Z、⌘S 后与原提交一致 | 逐键输入注释并换行，自动续写注释。保存后 diff 可见，两次撤销和保存后恢复。两种输入方式的撤销步数单独记录 |
| 终端 | ⌥F12 建立样本目录的 shell。按键输入算式，工作目录内输出文件值为 42。自动化粘贴超时一次 | ⌥F12，执行 `pwd && expr 21 + 21`，控制台显示项目路径和 42 |
| Git | ⌘9，图中读到样本提交 `Local comparison fixture`、作者及引用 | ⌘9，在 Vue 日志中读到 main 分支和与 HEAD 一致的提交标题 |
| Go 调试 | 对第 8 行执行 ⌘F8 和 ⌃D，界面明确提示当前文件不支持断点和 Debug | 第 8 行 ⌘F8，首次构建提示编译器被终止。重试后 Delve 启动，切回用户帧确认 `main.main (main.go:8)`，恢复后输出 42、退出 0。再次调试时已在用户帧读到 count=21、result=42 |
| SQLite | 启用模块并重启，连接同一库。最初结果为一行 `<unsupported>`，修复后四次均显示一行 42，22、35、32、32 ms | 从样本文件进入连接配置，下载 SQLite JDBC 3.51.1.0，连接成功。在查询控制台 ⌘Enter 执行 `SELECT sum(v) AS parity_sum FROM sample`，四次均为一行 42。控制台显示 500、335、85、331 ms |
| HTTP | 同一 `.http` 文件可读，编辑区、工具菜单及 Actions 搜索均未找到发送请求入口 | 在请求编辑器点击运行。四次本机 GET 均为 200，JSON 值 42。客户端首次 135 ms，热请求 2、2、2 ms |
| 搜索入口 | Keymap 的 Search Everywhere 一行显示 ⇧ ⇧ 和 ⇧⌘O。导航菜单的“全局搜索”及 ⇧⌘O 均打开带 Files / Actions 的搜索框。Hugo、Cargo 可按精确文件名回车进入编辑器，Django 同名文件可按目录选择 | 工具栏“随处搜索”打开“所有”标签，⇧⌘O 可按文件名导航。在“操作”标签搜索“随处搜索”，命令显示 ⇧ ⇧。本轮再次点击工具栏，确认“所有”标签及输入框获得焦点。两端双 Shift 的系统投递记录见下文 |

**双 Shift。** 在自建 Go 样本的源码编辑器中，分别向 Lithe、GoLand 的进程发送两次左 Shift。每次按住 50 ms，松开后间隔 90 ms。macOS 对两次进程投递都记录了 `kTCCServicePostEvent` 拒绝（`authValue=0`），随后两端的焦点仍在编辑器。桌面控制接口也拒绝单独的 Shift。对照操作中，Lithe 的 ⌘⇧O 显示 Files、Actions 并聚焦输入框，GoLand 工具栏入口显示“所有”并聚焦输入框。双 Shift 在真实工作台能否触发仍未测得。21:43 复查时，macOS 将发键权限归到启动本次验收的 iTerm2（`com.googlecode.iterm2`），仍返回 `authValue=0`。实机键盘可直接检验这个手势，无需扩大终端权限。Lithe 的三个手势识别用例在 Debug 配置全部通过，覆盖两次独立点按、夹入大写或其他按键、重置后丢弃第一次点按。逐项报告为 `shift-gesture-debug.html`。首次用 Release 配置运行测试时，测试目标依赖仅在 Debug 中提供的接口，编译阶段退出。原始记录在 `.artifacts/parity-20261125/logs/double-shift-post-access.log` 和 `double-shift-workbench.json`。

### 大仓首次导航

GoLand 从单个项目信任确认到项目树首次可读，再从 ⌘⇧O 输入精确文件名到编辑区出现目标文件。下表记录 UI 自动化端观测墙钟，包含输入及辅助功能树读取，采用正常信任模式下的干净副本。每个首次样本只测一次，后台索引可继续运行。

| 仓库与版本 | 跟踪文件 | 目标文件 | 项目树可读 | 首次导航 | 热导航三次（ms） |
| --- | ---: | --- | ---: | ---: | --- |
| Hugo `7f0b4416` | 2,619 | `hugolib/breaking_changes_test.go` | 1,619 ms | 1,634 ms | 1,320 / 1,301 / 1,280 |
| Cargo `df742db3` | 3,094 | `src/ops/cargo_compile/unit_generator.rs` | 1,229 ms | 1,233 ms | 1,106 / 1,267 / 1,227 |
| Vue core `50aaa3c7` | 704 | `packages/runtime-core/src/renderer.ts` | 1,454 ms | 1,678 ms | 2,266 / 1,959 / 1,886 |

Django `f14af5a8` 有 7,104 个跟踪文件。PyCharm 安全预览将源码目录标为 excluded，Files 搜索完整相对路径结果为空。按路径直接打开则能读到 `django/db/models/sql/compiler.py` 的 `SQLCompiler` 定义。三个同名文件分别位于 MySQL 后端、PostgreSQL 后端和公共 SQL 模块，只有公共 SQL 模块在第 42 行定义该类。三份磁盘文件均与该提交的 Git 对象一致，路径与对象哈希见 `.artifacts/parity-20261125/logs/django-navigation-control.json`。安全预览不计入正常项目导航用时。

**Django 正常信任模式。** PyCharm 在同一提交的干净副本中仅信任该项目，沿用本机 IDE 缓存，项目未配置 Python 解释器。自点击信任至本轮最后一次退出索引模式为 **11.78 s**。主扫描遍历 7,414 个条目，选出 6,032 个送入索引。以下三轮桌面热测均从仓库根目录的 `.gitignore` 出发，计时从快捷键开始，到读出目标编辑器源码结束。

| Django 操作 | Lithe | PyCharm |
| --- | --- | --- |
| 按文件名查找 `compiler.py` | 三个同名结果可按目录区分。三次均打开公共 SQL 模块，桌面观测 16.59 / 16.50 / 16.51 s | 三次按 ⌘⇧O 按目录选中公共 SQL 模块。目标排在第 2 / 3 / 3 位，桌面观测 **1.971 / 1.726 / 2.100 s** |
| 按类名定位 `SQLCompiler` | Classes、Symbols 都显示无匹配。打开目标 Python 文件后再查，Classes 仍无匹配。切到 Text 后可点中类声明，编辑器到 `compiler.py:42:1` | 三次按 ⌘O 输入类名，`django.db.models.sql.compiler` 的精确匹配均排第一。桌面观测 **1.621 / 1.632 / 1.442 s**，核对光标为 `compiler.py:42:7` |

同一 Release Core 的 `workspace.searchEverywhere` 对 Go、Rust、Python 自建样本分别查询函数名，分别返回 2、2、3 条正文结果；Django 的 `SQLCompiler` 返回 33 条正文结果。四次都包含声明所在行，类型和符号结果均为零。原因可定位到 `rust/lithe-core/src/project/search_index.rs` 的 `read_search_data`：这里用 `java_symbols` 填充符号索引，它在 `project/files.rs` 对所有非 `.java` 路径直接返回空集合。这条工作区索引路径与前述三语言从调用跳定义所用的语言服务不同。逐次返回保存在 `.artifacts/parity-20261125/logs/go-rust-python-search-symbol-control.json`。

以上文件导航时间含辅助功能树的读取与界面稳定等待。Lithe 与 PyCharm 的等待开销不同，因此无法据此计算编辑器自身的速度差。索引日志及逐次 UI 记录在 `.artifacts/parity-20261125/logs/` 下的 `pycharm-django-trusted-index.log`、`pycharm-django-trusted-navigation.json` 和 `lithe-django-class-search.json`。

Vue 热测多了一次搜索弹窗焦点确认。早先从安全预览转为信任的副本里，Vue 源目录一度显示为排除项，按文件名没有命中。干净副本首次打开即信任，同一提交和路径可以命中。本表计时只覆盖文件查找。下节另列三语言的语义跳转、重命名和断点结果。

构建采用本机 Swift 6.4、SwiftPM native 后端及 macOS 26.5 SDK。默认后端缺少 Metal 编译器，27.0 SDK 缺少 SwiftUI 宏插件。首次混用后端时，旧构建产物中空的 `Contents/Resources` 使 bundle 查找语法映射失败。移出生成的 bundle 并用 native 后端重打后，打开 Vue 源文件的启动日志无这两条警告。本机原始构建和启动日志在 `.artifacts/parity-20261125/logs/`，GoLand 的四份 HTTP 响应在 `.artifacts/parity-20261125/fixture/.idea/httpRequests/`。

### 三语言编辑器高亮

同一份自建源码分别在 Lithe 和对应的 JetBrains IDE 中打开。每份样本把 `return` 和 `marker` 同时放进可执行代码、双引号字符串和下一条真正的行注释，另有整数字面量 `42`。在本次深色主题下，两端都将代码中的 `return`、普通标识符、整数和整行注释显示为可区分的颜色。差异出现在引号内。

| 语言与字符串 | Lithe | 对照 IDE |
| --- | --- | --- |
| Go · `"return // marker"` | `return` 为字符串色，从 `//` 到结束引号变成注释色 | GoLand 将整个字面量显示为字符串色 |
| Rust · `"return // marker"` | 同样从 `//` 开始变成注释色 | RustRover 保留完整字符串色，并在这份样本中显示局部变量的推断类型 |
| Python · `"return # marker"` | 同样从 `#` 开始变成注释色 | PyCharm 将井号及后续内容显示为字符串色 |

**编辑与撤销。** 在 Lithe 源码编辑器中把字符串内的分隔符改为 `::`，三个样本的 `marker` 都恢复为字符串色。每个样本一次 ⌘Z 即还原源码，移开选区后，尾部再次呈现注释色。与界面结果一致，通用高亮适配器先给字符串着色，随后在同一范围匹配注释并覆盖前景色。该规则也会匹配引号内的分隔符。[通用高亮适配器](../../macos/Sources/Lithe/Views/Editor/SyntaxHighlighting/GenericSyntaxHighlightingAdapter.swift)

本轮覆盖普通双引号字符串、行注释和一次编辑/撤销。多行字符串、转义、IME 和长文件增量绘制仍按 L2 验收范围跟踪。六个原始窗口的并排裁图在 `.artifacts/parity-20261125/logs/highlight-comparison.png`。同目录的 `highlight-observations.json` 保留三份源码、十二张截图的哈希、词元位置及 RGB 采样，可逐张与原图复核。

### 三语言运行、调试与查询结果复验

在 Plugins → More Language Support 启用 Go、Rust、Python，启用 Database，Confirm 后正常退出并重启。Go、Rust 通过项目设置指定本机工具链。验收期间强制结束过一次 Lithe，随后 Go 插件显示上次会话异常并已禁用。通过 Enable、Confirm 和重启恢复，后续在干净会话复核 Go。临时样本各自计算 21 × 2。Lithe 的 Run 控制台从命令行记录到首个 42 的时间分别为 Go 665 ms、Rust 501 ms、Python 58 ms。每项一次，包含对应工具链的启动，Go、Rust 还涉及构建。Rust 记录包含一次 0.20 s 的 Cargo dev 构建。

三种语言的 Run 均成功。对 `main.go`、`main.rs` 和 `main.py` 实际执行 ⌃D 均出现该文件无法调试的通知。本机构建已能定位 Delve、lldb-dap 和带 debugpy 的 Python。插件声明决定有效调试能力，Go 原生插件及内置 Python、Rust 声明均未注册调试模块。组合根同时会把这些语言标为由插件负责，`LanguagePackRegistry` 因而不创建宿主默认调试器的启动配置。此缺口直接影响从断点开始的日常工作流。GoLand 在相同 Go 样本成功命中第 8 行并正常退出。

| 同一语言样本 | Lithe 编辑器 | 对照 IDE |
| --- | --- | --- |
| Go | gopls 启动期间首次 ⌘B 提示找不到定义，就绪后从 `navigation.go` 跳到 `helper.go:3:6`。Shift F6 未唤起重命名。恢复旧标签后右键重命名两次未写盘，界面提示文档或服务器已变化。从调用重新 ⌘B 到声明后再重命名成功，磁盘两处一致，`go test ./...` 编译通过，一次 ⌘Z 两处恢复 | GoLand 从同一调用跳到 `helper.go:3:6`。Shift F6 成功更新声明和引用。撤销时提示 `navigation.go` 已更改，反向重命名后核实磁盘复原。Delve 在 `main.go:8` 显示 `count=21`、`result=42`，继续后输出 42、退出 0 |
| Rust | 从 `src/lib.rs:4` 的调用跳到 `src/helper.rs:1:15`。右键重命名后两份文件更新，`cargo check --offline` 通过，一次 ⌘Z 后两处恢复 | RustRover 附加 Cargo.toml 后识别 lib、bin。⌘B 到同一声明，Shift F6 更新声明和调用，撤销并确认后两份文件复原。LLDB 在 `main.rs:4` 显示两个 i32 局部变量 21、42。Resume Program 后控制台输出 42，退出 0 |
| Python | 从 `navigation.py:3` 跳到 `helper.py:1:5`。右键 Rename Symbol 后，两份文件中的声明、导入、调用均已更新。一次 ⌘Z，两份文件均恢复 | PyCharm 的 ⌘B 到同一声明。Shift F6 内联重命名、保存，两份文件的三处标识符同步，一次 ⌘Z 并确认后磁盘复原。使用已有 Python 3.9.6 的项目虚拟环境，debugpy 在 `main.py:4` 显示两个 int 局部变量 21、42，继续后输出 42、退出 0 |

| Lithe Release Core 随处搜索 | 首次调用（ms） | 五次热查中位数（ms） | 桌面操作结果 |
| --- | ---: | ---: | --- |
| Hugo | 537.67 | 11.10 | ⌘⇧O 命中 `hugolib` 下的目标，回车打开 Go 源码 |
| Cargo | 575.58 | 9.59 | ⌘⇧O 命中 `src/ops/cargo_compile`，回车打开 Rust 源码 |
| Django | 1,443.27 | 111.26 | 输入 `compiler.py`，三个同名命中可按目录区分，打开 `django/db/models/sql/compiler.py` |
| Vue core | 236.42 | 2.58 | 桌面按文件名回车打开 `packages/runtime-core/src/renderer.ts` |

计时逐仓启动新进程调用与本次 Release 同构建的 `workspace.searchEverywhere`，保留系统文件缓存，每次核对完整目标路径。范围包括 Core 的索引及查询和 JSON 边界，不含 UI 去抖、键盘输入及渲染。GoLand 上表为 UI 观测值，两组数据不能计算速度比。原始逐次值在 `.artifacts/parity-20261125/logs/core-search-*.json`。

在安装版 Lithe 上另做三次桌面热导航。每轮从仓库根目录的 `.gitignore` 出发，按 ⌘⇧O，等搜索框得到焦点，按文件名查询，点击完整目录匹配的行，再核对编辑区的源码。Cargo 的目标三次均为 `unit_generator.rs`，Django 三次均为包含 `SQLCompiler` 的 `django/db/models/sql/compiler.py`。自动化端从快捷键到源码可读分别为 Cargo 16.86 / 16.45 / 16.45 s、Django 16.59 / 16.50 / 16.51 s。逐步拆分后，读取搜索框、结果、编辑器三次各占约 5.1–5.3 s。改用截图匹配同名结果的目标行和源码，Django 一次为 15.99 s，三处都在返回的第一帧就已可见。由于两种观测方式均会等待界面稳定，用户实际看到首帧的时刻仍未知。上述数字仅供复查自动化过程。原始分步计时见 `.artifacts/parity-20261125/logs/desktop-navigation-samples.json`。

SQLite 原因已定位到表达式列没有声明类型时仍按声明类型解码。修复在结果映射时读取实际值的类型，保留 NULL。重建 ARM64 包后在 SQL 工作区按 ⌘Enter，四次原查询的 `parity_sum` 均为 42。SQLite 表达式整型、浮点、文本和 NULL 回归 7 ms，sidecar 共 14 项通过。HTML、JUnit 和原始计时位于 `.artifacts/test-stability/db-sidecar.*`。客户端各自显示的查询时间包含哪些开销仍需独立剖析。

Go 的格式化、整理导入和函数调用补全在 Lithe 与 GoLand 写出了相同的文件。Lithe 临时安装副本上，四种编辑各用一次 ⌘Z 均恢复原字节。Rust 的延迟代码动作完成了真实 `codeAction/resolve` 往返，包含原样传回的 data、服务器指定的文档版本、写盘和撤销核验。[逐项安装验收](goland-parity-b6-refactor.md#b6-text-edit-acceptance-2026-11-25)

### Hugo 同仓 Git 与桌面响应

Hugo 的浅克隆加深至 HEAD 可达 1,037 个提交，含 12 个合并提交。两端使用同一目录。⌘9、筛选并选中 `5fa3adb4` 后，两端详情均显示 `markup/goldmark: Adjust the ToC writer setup`。从初次打开的日志直接搜索 `df520e31`（`git log --skip=500 -1`），GoLand 给出 `resources/page: Fix shared reader in Source.ValueAsOpenReadSeekCloser`。Lithe 显示 `No commits match this view`。

在上述仓库清除筛选、保留 `5fa3adb4` 选择后，先隐藏 Git 窗口，再计时从 ⌘9 到日志与同一提交详情均可读。三次热测 Lithe 为 **773 / 791 / 807 ms**，GoLand 为 **2,100 / 1,870 / 1,867 ms**。界面辅助功能树的读取时间计入结果，两端窗口大小和辅助功能实现不同。Hugo 文件导航另测，Lithe 从 ⌘⇧O 到目标结果再到编辑器三次为 2,502 / 2,398 / 2,221 ms，GoLand 的阶段一观测见上表。样本量只支持本机本次操作的观察。

**跨页搜索与合并图复核。** 两端均选中拓扑顺序第 111 个提交 `5379c109`，并在相同的 3,840 × 2,100 像素窗口截图中显示合并线。真实父提交按 Git 记录顺序为 `0732eadd`、`36d24019`，日志中的相邻行按 `36d24019`、`0732eadd` 排列。两端都能分别选中这两个父提交，详情与 `git show` 一致。该提交的原始时间为 16:12（UTC+2），Lithe 显示 16:12，GoLand 在上海时区显示 22:12。

| 操作 | Lithe | GoLand |
| --- | --- | --- |
| 到达合并行 | 滚到首批 100 条底部并点 Load more commits，旧页末尾留在视口内，再向下滚一页到达合并行 | 在 Git 日志的“转到哈希/分支/标记”中输入哈希，直接选中合并行 |
| 翻页与窗口缩放 | 选中合并后向下滚两页、再向上滚两页，滚动条回到原位置，详情持续指向原提交。放大窗口并恢复，选中提交也保留 | 从 `0732eadd` 按 Page Down 到第 123 行 `ec69d0e6`，Page Up 回到原提交。合并详情在放大并恢复窗口后仍可读 |
| 查询第 501 条 | 在未筛选的历史逐页加载至第六页后，搜索同一个 `df520e31` 命中唯一一行，点击可见完整标题与哈希 | 首次查询即可命中 |

两张等尺寸截图里，主线都通过金色节点连接，文档父提交在右侧蓝线上。取合并点上方连续主线节点中心，Lithe 行距约 44 像素，GoLand 约 52 像素。配对截图位于 `.artifacts/parity-20261125/logs/{lithe,goland}-hugo-merge-max.jpg`，Git 校验结果在 `hugo-git-ui-control.json`，第六页的搜索结果在 `lithe-hugo-page-six.jpg`。此次覆盖 Hugo 的双父合并和加载边界。G1 的复杂交叉、多父提交和连续滚动绘制仍按原计划跟踪。

**打开 Hugo 后的进程内存。** 两个 IDE 分别重新启动，打开同一份 `breaking_changes_test.go` 和 Git 日志，选中 `5379c109`，窗口均为 3,840 × 2,100 像素。按各自主进程年龄取样，第 120 秒开始每秒一次，共五次。下表为 macOS `ps` 常驻内存（RSS）的中位数。

| IDE | 主进程 | 主进程及全部子孙进程 | 子进程构成 |
| --- | ---: | ---: | --- |
| Lithe | 349.9 MiB | 1,573.7 MiB | 两个 gopls 进程合计 1,216.1 MiB，另有 Git 进程 |
| GoLand | 1,815.8 MiB | 2,170.0 MiB | 文件监视与 Chromium 辅助进程合计约 354 MiB |

这是系统文件缓存和 IDE 缓存均已预热的一次配对启动。进程树 RSS 求和可能重复计算共享页。两个 IDE 的后台分析进度没有同步。另一次 Lithe 会话五次采样的进程树中位数达到 2,895.8 MiB，其中 gopls 占 2,668.4 MiB，不能把第 120 秒的结果作为长期上限。GoLand 启动时还报告 Hugo 仓库中的空 `internal/warpc/genwebp/go.mod` 缺少 module 声明。原始进程明细在 `.artifacts/parity-20261125/logs/{lithe,goland}-hugo-120s-memory.json`。

### 终端热打开与首条输入

两端在同一自建项目中预热 shell，再隐藏终端。每轮从 ⌥F12 开始立即逐键输入 `sh t` 并回车。脚本计算 21 + 21，把项目路径、结果和毫秒时间写入同一个本地日志。计时覆盖打开面板、分发按键、shell 执行到记录结果。

| 三轮热打开 | 第一次 | 第二次 | 第三次 |
| --- | ---: | ---: | ---: |
| Lithe | 仅收到 `t`，命令失败 | 98 ms | 98 ms |
| GoLand | 105 ms | 110 ms | 95 ms |

Lithe 首次失败时终端显示 `zsh: command not found: t`。另外五轮均在预期目录得到 42。两端成功样本的用时接近，Lithe 在打开面板后立即输入的可靠性需要复核。原始记录见 `.artifacts/parity-20261125/logs/terminal-paired-trials.json` 和同目录的 `terminal-shell-output.tsv`。

复核时新增一次性文本文件，每轮先隐藏已预热的终端，再点击编辑器并确认它持有键盘焦点。四轮交替采用两种输入时序，逐次检查 shell 的结果标记和编辑文件的磁盘内容。

| 起始焦点均在编辑器 | Lithe | GoLand |
| --- | --- | --- |
| ⌥F12 后立即逐键输入 `sh t` | 两轮都把命令写入文本文件，shell 没有结果记录 | 两轮 shell 都得到 42，距快捷键分别为 92、94 ms |
| 读到终端面板后再输入 | 两轮 shell 都得到 42 | 两轮 shell 都得到 42 |

Lithe 的临时文本文件最终多出两行 `sh t`，GoLand 的同一个文件复原后跑完对照仍与原始字节一致。该问题会改写编辑中的文档。证据位于 `.artifacts/parity-20261125/logs/terminal-focus-control.json`、`terminal-focus-reproduce.tsv` 和 `terminal-focus-before-source.txt`。

在独立的诊断构建中，快捷键分发、编辑区和终端挂载共用主线程时间戳，日志只记录事件类型。一次失败中，以识别 ⌥F12 为 0 ms，编辑器分别在 +2、+10、+11、+12、+13 ms 收到按键，命令回调在 +17 ms 执行，终端原生视图在 +46 ms 挂到窗口，+52 ms 请求键盘焦点。另一轮在视图挂到窗口后，编辑器又收到了两个事件。原始时序见 `focus-diagnostic-events.log`。诊断代码只用于该临时构建。

同样从临时文本文件开始，在普通 Release 按 ⌘⇧O 后立即逐键输入 `helper`。GoLand 两轮均在 Files 命中根目录的 `helper.go`，编辑文件保持原始内容。Lithe 一轮正确命中，另一轮搜索框为空，关闭搜索后在编辑文件中读到了完整的 `helper`，磁盘快照见 `search-focus-before-source.txt`。这些小样本可复现焦点交接失序，无法估算日常发生率。

## 功能文档导航

功能文档统一命名为 `goland-parity-<批次号>-<功能块>[-done].md`。
整份文档覆盖的功能已完成实现、审查及相应验收时才加 `-done`；部分完成或暂停的
功能不加。总方案保留职责名称，跨批方案审查摘要并入本文，不单独保留过程文档。
验收摘要并入各功能文档，原始日志、截图和计时报告沿用已有 `.artifacts/` 路径；
摘要中的通过结果均为注明日期的历史记录。

| 批次 / 范围 | 功能文档 | 状态 |
| --- | --- | --- |
| B1 | [菜单、命令与工具窗口](goland-parity-b1-commands-done.md) | 已完成 |
| B2 | [Project](goland-parity-b2-project.md) | 暂停；Commit / PR 范围见本总方案 |
| B3 | [搜索与替换](goland-parity-b3-search.md) | B3a、B3b1a 完成；B3b 当前事务已接入，B3c/B3d 待实施 |
| B3b | [替换事务](goland-parity-b3b-replacement.md) | 显式范围、实际 Apply、文件/occurrence 排除、缓冲区/磁盘事务、租约及共享 Undo/Redo 已接入；历史未提交审查不能代替[当前事务实施记录](goland-parity-b3b-replacement.md#buffer-transaction-integration) |
| B4a | [Terminal 设置与生命周期](goland-parity-b4a-terminal-done.md) | 已完成 |
| B4a4 | [Terminal 启动配置](goland-parity-b4a4-terminal-startup-done.md) | 已完成 |
| B4a5 | [Terminal 显示与输入](goland-parity-b4a5-terminal-display-done.md) | 已完成 |
| B4a6 | [Terminal 虚拟环境](goland-parity-b4a6-terminal-venv-done.md) | 已完成 |
| B6 | [语义编辑事务与重构](goland-parity-b6-refactor.md) | B6a1a 已验收；B6a2 首个文本切片 Rust/Swift 自动验证通过，2026-11-25 [四种编辑及真实 resolve 通过安装验收](goland-parity-b6-refactor.md#b6-text-edit-acceptance-2026-11-25)；复用既有文本事务/Undo，完整资源事务仍待实施，见[当前裁定](goland-parity-b6-refactor.md#b6-current-implementation-rulings) |
| B7a | [Go Tools / Cargo](goland-parity-b7a-go-cargo.md) | 部分完成 |
| B7a2a / B7a2b | [进程清理、工具捕获与插件资源](goland-parity-b7a2b-project-tool-capture-done.md) | 已完成 |
| B7a2c | [项目元数据读取与刷新](goland-parity-b7a2c-project-metadata-refresh.md) | c1/c2 完成，c3 随 B7a3 完成 |
| B7a2c2 | [Cargo 工具窗口](goland-parity-b7a2c2-cargo-tool-window-done.md) | 已完成，含独立审查、修复复核及安装验证 |
| B7a2c3 | [Go 元数据读取隔离](goland-parity-b7a2c3-go-metadata-isolation.md) | 实验和实现均完成，验收归 B7a3 |
| B7a3 | [Go Tools 工具窗口与独立工具任务](goland-parity-b7a3-go-tools-done.md) | 已完成：自动回归、真实编辑/运行/点击和 G/R 深浅色截图通过 |
| B7b | [运行入口 gutter 与右键配置](goland-parity-b7b-run-gutter.md) | 剩余协议/交互方案待重审；保留已有 Go/Rust runnable gutter；前置为 B6a2 符号协议预交付 |
| L0–L2 | [语法引擎、增量协议与三语言高亮](syntax-l0-l2-engine.md) | 2026-09-08 第二版方案复核通过，首轮 9 项闭环；未实施；L0 硬前置 B6b2 |
| L4a | [LSP 直通能力（signature / inlay / semantic tokens / Structure）](syntax-and-completion.md#l4a-split) | 2026-09-21 复核从原 L4 拆出并提到 P0；细案待写、未实施；不依赖 L1/L2 |
| E1 | [编辑器与导航基础能力](#e1-editor-navigation-gaps) | 2026-09-21 复核新识别；批次号待用户确认，方案未写、未实施 |

B4 其他设置、B5 资源插件和 G1 Git 对照范围见本文；语言引擎以
[L0–L8 分批方案](syntax-and-completion.md) 为准。

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
| 2 Project/Commit/Pull/Structure/TODO | Project 假下拉；Commit 命名不一致；PR 全局关闭；Structure/TODO 缺失 | B2、B7、L4a/L4b | 每个工具能打开/关闭、保留状态、真实导航或完成动作；各自菜单验收 |
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
| 复核 参数提示与类型提示 | `signatureHelp` 全库无实现；`.inlayHint` 仅在 `LanguageToolingContracts.swift` 有能力位，无请求方与消费者 | L4a | 三语言函数调用出现参数提示并随光标切换；Rust/Python 类型提示、Go 参数名提示随输入更新且可关闭 |
| 复核 Structure 与面包屑 | 无 `documentSymbol` 消费者，无 Structure 工具窗口与编辑器面包屑 | L4a（LSP）/ L4b（离线回退） | 三语言 Structure 打开、过滤、点击定位；停掉语言服务器仍可用离线结果 |
| 复核 光标符号高亮 | `documentHighlight` 无实现 | L4a | 光标停在标识符上高亮同文件读/写出现点，移开清除，不与查找高亮互相覆盖 |
| 复核 语言动作键位与内联 UI | 语言动作仅在右键菜单注册（`CodeEditorView.swift:4165`）；Rename 走 `NSAlert`（同文件 `:4205`） | B1（键位注册）/ B6（内联 Rename） | JB 默认键位可直接触发跳转/用法/重命名/格式化/code actions；Rename 为编辑器内联，一次 Undo |
| 复核 统一 Problems 面板 | 仅 Java 专属 `JavaProblemsView.swift`，`Views/Diagnostics/` 只有导出 sheet | E1 | 跨语言聚合 LSP 诊断与项目级 lint 输出，可跳转、可过滤、可取消 |
| 复核 保存即格式化 | 仅菜单 `Format Document`；无 `formatOnSave`、无 `onTypeFormatting` | B4（设置项）/ L6（格式化事务） | 按语言开关生效，保存路径与手动格式化共用同一事务与 Undo |
| 复核 编辑器基础操作 | 无多光标/列选择；展开选区已属 L8 `brackets` | E1（多光标）/ L8（展开选区） | 多光标与列选择在 IME、撤销、查找替换下行为正确 |
| 复核 调用/类型层级 | 无 `prepareCallHierarchy` / `prepareTypeHierarchy` 消费者 | E1 | 三语言调用层级可展开上下游并跳转，取消与过期结果不串档 |
| 复核 最近文件与书签 | 无 Recent Files / Recent Locations；无书签；`NavigationHistoryFeatureModel.swift` 仅 109 行做前进后退 | B3（最近文件）/ E1（书签） | Cmd+E 列出最近文件并键盘选择；书签可增删、持久化、跨会话恢复 |
| 复核 测试覆盖率 | 全库无 coverage 实现 | E1 | `go test -cover` / `cargo-llvm-cov` / `coverage.py` 结果在行号槽着色并可汇总 |

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
详细的首批契约和验证见 [goland-parity-b1-commands-done.md](goland-parity-b1-commands-done.md)。

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
- TODO 的可交付版本放 B7/L4a（在线）与 L4b（离线回退），不能先增加无实际内容的占位按钮。

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

Structure 优先 LSP document symbols（L4a），离线使用 L4b 语法结构；提供嵌套树、图标、可见性/继承等 provider 有效筛选、排序、speed search、定位编辑器和状态保持。
TODO 复用工作区遍历与语言注释捕获，支持 TODO/FIXME 自定义 pattern、Project/Current File scope、分组、计数、上下文预览与导航，遵守 ignore；不得扫描二进制或把字符串中偶然的 TODO 当注释任务。

Go Tools 与 Cargo 通过现有 rightSidebar contribution 注册，按 workspace 能力出现、固定位置、可隐藏/恢复；所有执行通过 Execution 模块。
Go 核心 build/test/fmt/vet/mod 与工具链/包信息；Cargo 核心 build/test/check/clippy/fmt/run 与 workspace/member/target 树、features/profile/package 参数。
拓扑读取 `go list` / `cargo metadata`，进程由已有平台 adapter 管理；刷新有取消/超时/失败状态；工具输出进入 Run/Problems，可点击文件行号，终止操作有界清理。

### L0–L8：语言引擎、完整补全与可安装新语言

以 [syntax-and-completion.md](syntax-and-completion.md) 的独立批次为准：离线语法与 LSP 两层、共享增量树、角色映射、语法结构、完整补全 popup/snippet/参数提示、格式化以及插件 worker。
B5 的资源注册与 L7 共用 manifest；B6 的语义编辑事务与 LSP UI 共用；B7 的 Structure、runnable 与 TODO 复用语法/LSP 产物。
最终必须安装一个宿主未内置 grammar 的语言包并获得真实高亮/导航/补全与格式化，不能把重新编译宿主当作插件安装。

2026-09-21 复核后，原 L4 拆为 L4a 与 L4b（[拆分依据](syntax-and-completion.md#l4a-split)）。
L4a 只扩展 `rust/lithe-core/src/lsp/interface/client.rs` 的方法白名单与编辑器装饰，
交付 `signatureHelp`、`inlayHint`、`semanticTokens`、`documentSymbol`→Structure/面包屑、
`documentHighlight`，不依赖 L1/L2 的文档 Tree，因此不排在语法引擎之后。
L4b 保留 locals/outline 与离线 hover/symbols/folding，依赖 L1/L2 不变。
B7 的 Structure/TODO 依赖目标随之由 L4 收窄为 L4a（在线）与 L4b（离线回退）。
L3 的依赖不变，仍硬依赖 L0/L1，不因 L4a 提前而可以脱离 L1 交付。

<a id="e1-editor-navigation-gaps"></a>

### E1：编辑器与导航基础能力（批次号待确认）

2026-09-21 复核新识别、且现有 B1–B7 与 L0–L8 均未覆盖的缺口，暂以 E1 归拢：
统一 Problems 工具窗口、多光标与列选择、调用/类型层级、书签、测试覆盖率。
这些项彼此独立，可各自拆分提交，但都不属于语言引擎范围，不应塞进 L 系列批次。

本节只记录范围与现状证据，**不构成已批准的方案**：批次编号、拆分粒度与排期需用户确认后
再写细案并走既有的方案审查流程。其中多光标与列选择在当前 `NSTextView` 单选区模型下成本最高，
需先评估是否与 L0/L1 的编辑事务、IME 策略和 Undo 合并冲突，不得以破坏既有 IME 与 Undo 行为为代价交付。

### G1：底部 Git 与分支图最终对照

在工作台和语言方案完成后，打开底部 Git，使用相同仓库、筛选条件、窗口尺寸对照 GoLand。复验分支侧栏、日志表头/筛选栏、选中提交与详情、字体/行距、各分隔线及首次打开/再次恢复的布局。
分支图优先保持细直线、紧凑 lane、小节点与清楚的合并连接；减少不必要拐弯、交叉和色彩噪声。必须保留真实 parent/merge 关系，不以隐藏分支换取简洁。
固定线性、分叉合并、交叉、多父节点、过滤、加载边界样例；检查相邻行连接连续、滚动不闪烁、选择与日志对应。若改图布局算法，执行 `scripts/verify-git-graph.sh`；只改渲染也要实际构建、截图及边界检查。调整面板仍复用现有 split 容器，不在业务层追加高频状态更新。
现有 `c09f2cc4` 仅为基线，不能替代本批新证据。仅在实际对照发现差距时修改，再单独审查、commit。

## 6. 顺序、审查和验收记录

基础顺序：B1 → B2/B3 → B4 → B5 → B6 → B7；语言 L0–L8 依赖完整方案审查，可与独立工作台批次交错，但每批仍顺序执行其依赖。

2026-09-08 的交付目标是 B3b、B7a3、B7b。2026-10-06 按当前源码修正依赖：原生编辑器安装门禁已通过，先做 B6a2 保真协议及最小文本适配；已存在的 Search Apply、文本事务与共享 Undo 继续复用，不视为完整 B6b 资源事务已交付。详见 [B6 实施裁定](goland-parity-b6-refactor.md#b6-current-implementation-rulings)。

```
共用前置       B6a1a 已交付 → B6a2（发布含最小纯文本版本适配）
反向请求       B6a1b 保留，按 B6d 实际动作需要接入，不再阻塞所有 B6a2 工作
① 替换事务     复用既有 Search Apply/文本 Undo；补 B3b 预览缺口及 B6b 资源事务/Undo
② Go 执行      B7a3 已完成并安装（211395cc，后续 B6a1a 安装继续包含）
③ 运行入口     B6a2 符号协议预交付 → B7b 方案重审 → B7b1 → B7b2 → B7b3
后续语言引擎   B6b2 → L0 → L1a → L1b → L1c → L2a → L2b → L2c（方案通过、未实施）
④ LSP 直通     L4a 细案 → L4a（不依赖 L1/L2，可与语言引擎并行排期）
```

B6c/B6d 和 L0–L8 保留各自完整计划；不将它们全部列为这三个目标的新增硬前置。
B7b1 的 Rust `experimental/runnables`、B6a2 与 L4a 共改 `client.rs` 的方法白名单，三批串行。
L0 与 L1 共改 dispatcher、Swift bridge、契约和文档事件，默认串行；L0 复用 B6b2 的事务/Undo。
L2c、B7b2 与 L4a 都改 `CodeEditorView.swift`，也需串行；L4a 的行内 hint 复用已有 code vision
装饰通道，不新增第二条绘制路径。L4a 虽不依赖 L1/L2 的交付物，但受上述两处文件交叠约束，
排期时按拥有文件串行，不与 L2c 或 B7b 并发实施。[L0–L2 审查项](syntax-l0-l2-engine.md#l0-l2-plan-review)
已在方案层闭环，实际实现仍按其分批验证门槛推进。
Structure/TODO 在线路径依赖 L4a、离线回退依赖 L4b，语义重构依赖 B6/LSP，资源语言包依赖 B5/L7；不能以依赖尚未实现为理由永久缩减目标。
E1 的五项尚未确定批次编号与排期，不得在未经用户确认前当作已排期工作推进。
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
| B3 | B3a、B3b1a 通过；其余逐批细化 | B3b 范围、预览、Apply、排除与文本事务/Undo 已接入；B3c/B3d 待实施 | B3b1a 历史：Rust 331、Swift 985、原生链接 7 项及 ARM64 包通过；后续事务回归见功能文档 | 输入/键盘、Find 预览与 Unicode 已验收；后续安装版实际替换、排除与撤销见[集成验收](ai-ide-phase-one.md) | 历史未提交审查保留；当前范围以[事务记录](goland-parity-b3b-replacement.md#buffer-transaction-integration)为准 | B3a `010d4d57`；B3b1a `b0dac7e2`；后续集成与原生 Undo 修复见当前记录 |
| B4 | B4a0–B4a6 通过 | Terminal 启动、显示/输入、venv 完成；其他设置待实施 | 1032 项完整测试、42+3 个 shell 场景、边界、ARM64 包通过 | 真实设置、Python prefix、Restart、环境缺失/恢复、迟到确认焦点及清理通过 | B4a0–B4a6 通过 | 启动 `db44d036`；字体 `4f74218a`；输入 `266c0c52`；venv `3724ea20` |
| B5 | 设计基线复核通过，逐批细化 | 未开始 | 未开始 | 未开始 | 未开始 | — |
| B6 | B6a1a 通过；后续依 2026-10-06 修订 | B6a2 首个有序文本编辑切片已实现；其余方法、反向请求、资源事务与重构待实施 | 历史：B6a2 Rust 523、Swift 1574 项通过；本次完整回归见[集成记录](ai-ide-phase-one.md) | B6a1a 已验收；B6a2 首个文本切片的四种语义编辑、撤销及真实 resolve 已于 2026-11-25 完成安装验证 | 首个文本切片静态复核无剩余阻断项；不代表 B6a2 整体完成 | `40c08360`；[当前裁定与验证记录](goland-parity-b6-refactor.md#b6-current-implementation-rulings) |
| B7 | B7a1/B7a2a–b/c1 通过；其余按子方案推进 | Cargo 只读刷新与右栏、双击运行和缺配置生成续跑已实现；Go Tools 与独立任务已完成（见 B7a3）；gutter/Structure/TODO 待实施 | 2026-09-08：Rust 354、Swift 1124、边界/契约/stability 通过 | Cargo 12 种真实对照运行；GUI 切换/刷新恢复/12 文件零写入通过；ARM64 已替换系统安装并复验 | c2 独立代码审查及修复复核通过 | 基线 `3d97c080`，本轮修复与验收记录一同提交；[Cargo 验收摘要](goland-parity-b7a2c2-cargo-tool-window-done.md#cargo-acceptance) |
| B7a3 | 方案与代码复核通过 | Go 元数据隔离、工具窗口、独立任务和 G/R 图标完成 | Swift 1176 全量及最终 27+18 项回归、Rust/边界/契约/stability 通过 | 实际编辑修复、并发停止隔离、零写刷新、Go/Cargo 菜单运行及深浅色图标通过 | 通过 | [Go Tools 验收摘要](goland-parity-b7a3-go-tools-done.md#go-tools-acceptance)；`211395cc` 干净检出 1168 项通过，系统安装与 Go/Cargo 点击复验通过 |
| B7b | 剩余细案待重审（[运行入口 gutter](goland-parity-b7b-run-gutter.md)），前置 B6a2 符号协议预交付 | 已有 Go/Rust runnable gutter 保留；剩余范围待实施 | 原有验证见上游集成记录；本批无新结果 | 本批待复验 | 待实施后审查 | — |
| L0–L8 | 2026-09-08 L0–L2 第二版方案通过（[首轮 9 项闭环](syntax-l0-l2-engine.md#l0-l2-plan-review)），L3–L8 逐批细化 | 未开始 | 历史方案检查：79 处本地链接/锚点、5 个 wire 示例、八槽位、命令语法与 diff 通过；无产品测试 | 11.png 已核对（历史）；本轮无 GUI | 未开始 | 源码基线 `e14309d4`，历史文档验证 HEAD `7e0887a1`；细案与待实现 wire 同步保留 |
| L4a | 2026-09-21 复核确认可独立于 L1/L2 交付；细案未写、未审查 | 未开始 | 未开始 | 未开始 | 未开始 | — |
| E1 | 范围与现状证据已记录，批次号与排期待用户确认；方案未写 | 未开始 | 未开始 | 未开始 | 未开始 | — |
| G1 | 设计基线复核通过 | 已有首轮基线 | 待最终复验 | 待 GoLand 对照 | 未开始 | — |

整体完成需要上表每一项的证据，不能用 B1 或局部测试替代完整目标。

## 7. 参考来源

- [GoLand macOS 默认键位](https://www.jetbrains.com/help/go/reference-keymap-mac-default.html)：核对工具窗、搜索和重构快捷键；实际生效键位仍由用户预设/覆盖决定。
- [GoLand Search Everywhere](https://www.jetbrains.com/help/go/searching-everywhere.html)：最近文件、搜索类别、外部项与转 Find 行为。
- [GoLand Refactoring](https://www.jetbrains.com/help/go/refactoring-source-code.html)：重构入口、预览与冲突处理。
- [Zed Terminal](https://zed.dev/docs/terminal)：shell/cwd/env、字体、光标、复制和 Option-as-Meta；界面基准另见本机截图。
- [Keymap 配置](https://www.jetbrains.com/help/idea/configuring-keyboard-and-mouse-shortcuts.html)：自定义与冲突处理参考。

这些来源用于行为核对；本项目设计、限制、批次与实现责任由上述方案定义。

<a id="plan-review"></a>

## 总体方案审查摘要

2026-09-06，独立 `parity_plan_review` 审查总体、B1 与语言方案；6 项问题修订后
复核通过。此结论只确认设计基线，不能作为所有批次的实现、代码审查或运行验收。
B1 后续完成情况见其功能文档；B6 第二版曾经独立审查不放行，现已更新为第四版，
B6a1a 已交付，其余逐批审查，见 [B6 当前状态](goland-parity-b6-refactor.md)。

| 项目 | 修订后保留的要求 |
| --- | --- |
| R1 焦点与事件消费 | 原生实时窗口资格独立于最近项目；消费前和异步执行前校验上下文，不抢 Settings / modal / IME 的输入 |
| R2 应用级动作承载 | 非创建的 registry lookup；Open 取消不建会话，Clone / Settings 请求由可见 host 承载，不能落到隐形后台模型 |
| R3 独立插件安装 | 正式签名策略保持；本地主动安装 worker / formatter 的授权绑定内容摘要与版本，探测在授权之后，升级重新授权，实际安装验收 |
| R4 新语言完整能力 | Lua 独立安装需同时证明高亮、补全、Structure / 同文件 definition、StyLua 格式化、版本 / 取消 / Undo 与卸载清理；主包不内置 Lua grammar |
| R5 增量与取消 | 区分 accepted / parsed 版本，保留有序编辑与幂等确认；有界 resync / parse waiter，不丢中间 delta，超时 / 取消 / close 释放等待者 |
| R6 最近项后台 I/O | 异步窄 port，真实并发 1 / 最新待办 1，1 秒响应预算；超时 unknown，不可取消 stat 保留 busy，菜单主线程不执行同步 stat |
| RustRover / G1 | Rust 使用真实参考版本；底部 Git 与分支图保留最终对照门槛，不能用已有基线或隐藏拓扑替代验收 |

B1 还须区分可唤醒的 Git / Commit 入口与要求 ready repository 的 Git 写操作，
避免因模块休眠将入口永久置灰。后续各批仍执行本文规定的接口审查、实现、测试、
真实点击与独立代码审查；不因总体方案曾复核通过而自动放行新的细案。

<a id="experience-parity-review-2026-09-21"></a>

## 2026-09-21 体验对齐复核

按用户要求，对照 GoLand / RustRover / PyCharm 对当前实现做一次跨批次体验核查，
产出优先级结论与新增缺口。

**方法与效力边界**：本次复核是**源码静态核查**，基线 `5f9325be`，范围为
`macos/Sources`（568 个 Swift 文件 / 143,396 行）、`rust/lithe-core` 与 `Plugins/mac`。
未构建、未运行产品，未做 GUI 对照，也未打开参考 IDE 重新取证；第 2 节记录的 GoLand
2025.2.4 与 RustRover 2026.2.1 证据仍是历史结论。本节**不是任何批次的实现、代码审查
或运行验收**，只更新范围与优先级判断。

### 1. 已具备、不再列为缺口的能力

避免后续批次重复投入，以下经核查确认已有实质实现：

| 能力 | 证据 |
| --- | --- |
| 调试 | `LitheDebugModule` 约 7,800 行；DAP 覆盖 `setBreakpoints`、`setFunctionBreakpoints`、`setExceptionBreakpoints`、`setDataBreakpoints`、`evaluate`、`setVariable`、`exceptionInfo`、`gotoTargets` |
| LSP 客户端底座 | `rust/lithe-core/src/lsp/interface/client.rs` 已支持 completion、hover、definition/declaration/implementation/typeDefinition、references、codeAction、rename、formatting、codeLens、foldingRange、`workspace/symbol` |
| 符号重命名 | `AppModel+Development.swift:2050` 走 LSP `rename`，非仅文件改名 |
| 代码折叠 | `CodeEditorView.swift` 的 `toggleFold` / `updateFoldRegions` / `collapsedFoldSummaryMaxX` |
| Search Everywhere | `SearchEverywhereView.swift:5` 已分 All / Classes / Files / Symbols / Actions / Text |
| 编辑器装饰 | 诊断、断点、runnable marker、Git 行内变更、code vision 与 blame 均已接入 |
| Run / Test | `RunService.swift`（1,246 行）、`LanguageTestService.swift`、Cargo 与 Go 专属工具窗口 |

### 2. Top 10 优先级结论

排序依据为「日常使用频次 × 体验落差 ÷ 实现成本」。批次列中带「待确认」的项见
[E1](#e1-editor-navigation-gaps)。

| # | 项目 | 关键证据 | 批次 | 成本 |
| --- | --- | --- | --- | --- |
| 1 | 补全交互重做 | `CodeEditorView.swift:4226` 一次性弹最多 200 条 `NSMenu`，无自动触发、无增量过滤、无排序、无文档面板 | L0 + L3 | 高 |
| 2 | Inlay Hints | `.inlayHint` 仅有能力位定义，无请求方与消费者 | L4a | 低 |
| 3 | Signature Help | 全库无实现 | L4a | 低 |
| 4 | 三语言语义高亮 | Go/Rust/Python 均落到 `GenericSyntaxHighlightingAdapter` 的通用正则 | L1 + L2 | 高 |
| 5 | Structure 面板与面包屑 | 无 `documentSymbol` 消费者 | L4a / L4b | 中 |
| 6 | 键位与内联 UI | 语言动作仅在右键菜单注册（`CodeEditorView.swift:4165`）；Rename 走 `NSAlert`（`:4205`） | B1 / B6 | 低 |
| 7 | 重构套件 | 仅 rename；缺 extract / inline / change signature / safe delete | B6 | 中 |
| 8 | Problems 面板与保存即格式化 | 仅 Java 专属 problems view；格式化只有菜单项 | E1（待确认）/ B4 / L6 | 中 |
| 9 | 光标符号高亮、展开选区、多光标 | 三者均无实现 | L4a / L8 / E1（待确认） | 中 |
| 10 | 调用层级、最近文件、书签 | 三者均无实现；`NavigationHistoryFeatureModel.swift` 仅 109 行 | E1（待确认）/ B3 | 中 |

候补项（未进 Top 10，已记入第 3 节映射表或 E1）：测试覆盖率、Live Template 与
Postfix Completion、Python Packages 面板与 Console、`Cargo.toml` 依赖版本内联提示、
Scratch 文件。

### 3. 核心结论：问题在接线层而非能力层

`client.rs` 已覆盖多数常用 LSP 请求，但这些能力在编辑器里**只有右键菜单一个入口**，
补全是平铺 `NSMenu`、Rename 是模态 `NSAlert`。GoLand / RustRover / PyCharm 的体验本质是
「键盘驱动 + 内联 UI + 随输入收窄」，落差主要产生在这一层，而不是缺少后端能力。
因此第 6 项（键位与内联 UI）成本最低但感知增益最高，应优先于多数新增功能。

### 4. 优先级调整：原 L4 拆分为 L4a / L4b

复核最初的判断是「L3/L4 应整体提到 L1/L2 之前」。核对依赖后**此判断不成立并已修正**：
`syntax-and-completion.md` 第 8 节明确 L3 硬依赖 L0/L1 的候选身份与 accepted/parsed
版本保护，且 locals/outline 必须消费 L1 的文档 Tree 与 L2 的 query 资源，两者都不能
脱离语法引擎提前交付。

实际可提前的只有原 L4 中不依赖文档 Tree 的那一半。据此把原 L4 拆为：

- **L4a / P0**：`signatureHelp`、`inlayHint`、`semanticTokens`、`documentSymbol`→Structure、
  `documentHighlight`。只扩展 `client.rs` 方法白名单与编辑器装饰，可独立排期。
- **L4b / P3**：locals/outline 与离线 hover/symbols/folding，依赖 L1/L2 不变。

L0–L3 的内容、依赖与验收门槛**均未改动**。拆分依据与文件交叠约束见
[L4a 拆分说明](syntax-and-completion.md#l4a-split)；L4a 与 B6a2、B7b1 共改 `client.rs`，
与 L2c、B7b2 共改 `CodeEditorView.swift`，按拥有文件串行。

### 5. 待用户确认事项

1. E1 的批次编号、拆分粒度与排期（本节只记录范围与证据，未排期）。
2. L4a 相对于 B6b2 → L0 → L1 主链的插入位置：可在 B6a2 之后立即插入，也可整体后置；
   两种排法都不改变 L0–L3 的依赖。
3. 在 L1/L2 落地前，是否先用 L4a 的 `semanticTokens` 作为三语言着色的过渡方案；
   若采用，需明确它与 L2 投影的切换边界，避免出现第 6.2 节禁止的双重着色路径。
