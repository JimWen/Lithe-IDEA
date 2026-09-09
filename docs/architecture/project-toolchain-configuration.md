# 项目工具链配置与入口运行配置

状态：实施与真实界面验收中。

## 验收范围

- Go/Rust main 入口的 Run、Debug、Modify Run Configuration 必须绑定被点击的入口。
- 新项目完成目录快照后，缺少 `.lithe/runtime.json` 中对应工具链选择时弹出右下角通知。
- Go SDK 列表优先展示 `go env` 发现的 GOROOT，包含已安装版本；Rust 展示工具链目录。
- 工具链选择通过项目文件持久化，影响后续 Run、Debug 与语言工具进程。
- 对照用户提供的 101–105.png，以及 GoLand/RustRover 实际设置和入口菜单，验证字段、交互和布局。

## 当前实现

ProjectRuntimeService 通过注入的 FileStorage 读写 `.lithe/runtime.json`，结构为 `executables` 映射。生产环境以项目文件为准，未注入文件端口的兼容调用仍使用 KeyValueStore。持久化成功后才更新内存选择。

AppModel 在 workspace rebuild 完成且工作区代数仍匹配时触发项目环境提示。Go 和 Rust 使用对应设置动作。

macOS 工具发现支持 GOROOT、PATH、Homebrew、Go 版本管理器目录和 GOPATH 下的工具链缓存。

## 待完成的验收

真实打包界面已暴露 Finder 环境下缺少 Go 候选的问题。仍需完整验证 go env 主动发现、SDK 版本展示、右键目标配置绑定、新项目首次 Debug、设置布局对齐及完整包点击流程。现有单元测试通过不能代替这些验收。
