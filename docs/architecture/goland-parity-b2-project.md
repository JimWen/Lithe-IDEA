# B2 Project 工具窗口实施方案

状态：按用户 2026-09-06 最新要求暂停，Project 当前够用，不实施本文件的改动。基线 `cb892c85`。以下仅保留待办设计，不代表已通过实施审查；Commit、Pull Requests 仍独立评估。

恢复本批前需解决初审问题：删除可只更新 rootNode 而不改变 snapshot ID；重命名回调最后一次 await 后需重新校验工作区代际；隐藏侧栏仍挂载，定位须显式验证可见性；Open Files 需覆盖媒体文件和 URL 原地变更；Expand All 需验证 eager 树的大项目性能。

## 范围与现状

当前 `ProjectSidebarView` 的标题箭头没有交互；展开目录保存在视图局部 State，Workbench 切到 Commit/Find 会销毁该视图。已有文件树、Git 着色、目录标记、重命名/复制副本/Trash、定位请求与滚动容器继续复用。

[GoLand Project 官方说明](https://www.jetbrains.com/help/go/project-tool-window.html)定义标题视图选择、Open Files 范围、手动/自动定位、展开/折叠和名称/类型排序。此处以这些已有能力可承接的操作为首批；不添加没有实际作用的依赖、Scratches、Scopes 编辑、文件大小/时间或预览占位选项。

本批交付：

- 标题下拉选择 Project / Open Files，后者只显示当前项目已打开文件及其目录祖先；不包含项目外文件。无匹配文件时展示明确空状态。
- 标题工具区：Select Opened File、Collapse All、Options。Options 提供 Expand All、Collapse All、Sort By Name/Type、Folders Always on Top、Always Select Opened File、Refresh、Hide。
- 保留现有一次点击打开文件、右键编辑操作。文件按名称或扩展名排序；目录名排序稳定，关闭文件夹优先时所有项目按名称混排。
- 同一项目切工具窗、隐藏/恢复、刷新、原生项目标签合并/拖出时保留展开状态；换项目或重新打开同一路径时清空旧代际状态。目录重命名迁移展开路径，刷新清理已删除目录。
- 视图排序与自动定位偏好持久化；展开状态属于项目会话。本批不声称重启应用后恢复展开状态。

## 所有权与数据流

`ProjectTreeFeatureModel` 放 Application/Features，由每个 AppModel 稳定持有。它拥有投影根、视图模式、展开路径、已索引目录路径和定位目标；不创建文件系统、平台服务、计时器或后台任务。展开变化只由 Project 子视图观察，不向 AppModel 转发每次展开事件。

`ProjectTreeViewOptions` 放 Models/Workspace，包含 sortOrder、foldersOnTop、alwaysSelectOpenedFile；通过 AppSettings 现有 KeyValueStore 持久化，缺失/损坏值回退旧行为：名称排序、目录优先、自动定位关闭。Project/Open Files 的当前视图及展开路径按会话保留，不全局共享。

Project 视图在 snapshot ID、打开文件 URL 集合或选项变化时更新投影；不在 body、Git 状态通知或光标移动时递归排序。模型保留输入身份，重复提交同一输入是空操作。排序和 Open Files 过滤仅作用于已有 FileNode 快照，不重新扫描文件、不改变搜索/运行模块的文件库存。

树路径使用标准化文件 URL，匹配必须在根目录边界内；相同文件名、中文、大小写不同路径保持独立。投影保留 FileNode 的 source-root 与 compact-ancestor 元数据，不改变行 ID。

AppModel 更换 workspaceURL 时重置会话树状态；文件操作的已有 relocateOpenDocuments 回调同时迁移树状态。投影刷新与显示视图切换不销毁完整 Project 展开集合，Open Files 的临时过滤不能把 Project 视图的展开路径当作已删除路径清理。

## 定位与交互

手动定位复用 `revealInProjectTree` 和 `ProjectTreeRevealRequest`。菜单动作执行时核对工作区代际；自动定位仅在 Project 可见且开启偏好时响应活动文件 URL 变化，不能抢 Commit/Find 工具窗或编辑器焦点。隐藏期间不消费定位请求，返回 Project 后定位最新活动文件。未变化的文件不会因光标或 Git 刷新反复滚动。

定位先展开祖先，再等待 SwiftUI 布局轮次滚动到稳定路径 ID；任务在切换工作区/离开视图时取消，恢复后检查取消和请求 ID，旧请求不能覆盖新请求。手动折叠后同一活动文件不会立即被自动展开。

复用现有树行、ScrollViewReader、LitheSplitPaneView。标题独立子视图观察树状态和设置，使用现有 Menu/图标按钮样式；弹出时固定菜单数据，执行时读取实时有效性。窄侧栏把非必要动作放 Options，标题不挤出可点击区域。右键标题提供同一组选项。菜单勾选、图标 help、无工作区/无活动文件的 disabled 状态必须真实。

## 验证与后续

必要行为测试：混合目录/文件排序与同名稳定性；Open Files 过滤与祖先保留；两个视图展开状态互不破坏；刷新删除/重命名迁移；新工作区代际清理；自动定位开关与无效路径；相同快照不重做投影；偏好保存/恢复/损坏回退。使用纯快照和内存 store，不依赖网络或个人文件。

运行验收使用隔离 Go/Rust/Python 文件树：点击所有菜单；深层目录展开后 Project→Commit→Project 及隐藏恢复；切换编辑器文件、关闭文件和空 Open Files；手动定位/自动定位；刷新与目录重命名；窄窗口菜单和滚动；检查没有高频全页重绘。按 stable-tests 运行受影响及完整 macOS 检查、边界检查、diff check，并构建真实 ARM64 包。最后独立代码审查、按修改点 commit。

后续仍需完成：B2a 第二批的树键盘选择/文件复制移动交互与操作回归；B2b Commit 的 changelist/staging 行为和提交流程；B2c Pull Requests 的认证、列表、diff 和 review/checkout。外部提交评论或合并的验收只使用 fixture 或明确授权测试仓库。
