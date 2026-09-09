# 项目工具链配置与入口运行配置

状态：已完成并通过真实打包界面验收。

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

Go 与 Rust 的项目设置页分别显示 Go SDK (GOROOT) / Rust toolchain，检测菜单沿用平台发现优先级；Go Finder 启动环境会优先使用 GOROOT/GOPATH 并展示版本管理器和缓存中的可执行文件。

原生插件恢复状态由 `MacPluginRuntimeRecoveryCoordinator` 管理；插件管理器在模块已注册的情况下重新启用插件时也会清除隔离标记，避免异常退出后的 Go 插件停留在“上次会话异常”状态。

入口菜单通过文档 URL 解析到对应的生成配置：Go 入口使用项目目录名，Rust `src/main.rs` 使用 Cargo 包目录名，Run、Debug 与 Modify Run Configuration 都先选中该配置再执行。

## 验收记录

完整预览包通过 `scripts/preview.sh` 构建并打开，并覆盖到 `/Applications/Lithe.app` 做独立重启验收。安装包启动后 Go Support、Go Tools 和环境通知均正常；Go SDK 菜单实际列出 `.g/go`、版本管理器和 GOPATH toolchain，Rust 页面实际列出 Cargo。Go `main` 与 Rust `main.rs` 的右键菜单均实际显示 Run、Debug、Modify Run Configuration，且 Rust 菜单标题与 `scrap_url` 配置一致。系统安装包中 Go 运行窗口实际输出 `$ go run .` 与程序输出，未再出现缺失 execution capability。配置编辑器实际提供并持久化工作目录、程序参数和环境变量到 `.lithe/run/local.json`。

验证命令：`swift test --filter 'ProjectRuntimeTests|GoTreePresentationTests|CargoTreePresentationTests'`（19 项通过）、Go/Rust 树测试（15 项通过）、`scripts/verify-official-plugins.sh`、`scripts/verify-service-boundaries.sh`、`verify-test-stability.sh` 与 `git diff --check` 均通过。
