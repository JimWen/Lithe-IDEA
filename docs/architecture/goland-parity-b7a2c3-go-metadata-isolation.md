# B7a2c3：Go 元数据读取隔离

状态：基于 `feb1114e`。这是 [B7 Go/Cargo 方案](goland-parity-b7a-go-cargo.md) 中
B7a2 明确要求先证明、否则不得接自动刷新的那一项的验证记录与结论。本文件保留隔离实验；生产实现、代码复核与真实验收已在 [B7a3](goland-parity-b7a3-go-tools-done.md#go-tools-acceptance) 完成。

B7a2 原文：「以上 Go flags 只是候选读取策略，尚未证明 workspace 零写：Go modload 即使
readonly 仍可能写 go.work.sum。B7a2 实施前必须以官方源码及缺 sum/有缓存依赖 fixture
验证隔离 sum/work 文件的方案，或使用已证明不触发写入的元数据命令组合；未通过前不得接
自动刷新。」

## 1. 验证结论：候选策略确实会写用户工作区

环境：本机 go1.24.4 darwin/arm64。fixture 为临时目录中的 go.work workspace，
两个 module，其中 `a` require 一个已在 module cache 但**工作区内没有任何 sum 文件**的
外部依赖（`github.com/pkg/errors v0.9.1`）。命令一律用 `env -i` 从空环境启动，
只带 `HOME`/`PATH`，并设置 `GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPROXY=off GOSUMDB=off`。

| 命令 | 位置 | 对用户工作区的写入 |
| --- | --- | --- |
| `go env -json GOWORK GOMOD` | workspace 根 | 无 |
| `go work edit -json` | workspace 根 | 无 |
| `go list -m -json` | workspace 根 | 无 |
| `go list -e -json ./...` | module `a` | **创建 `go.work.sum`** |
| `go list -e -json ./...`（`GOWORK=off`，单 module 无 go.work） | 单 module | 无 |

也就是说：**定位命令是安全的，逐 module 的包列举在 workspace 模式下不安全**。
`-mod=readonly` 只约束 `go.mod` 的修改，不阻止 `go.work.sum` 的写入。
这一条与 B7a2 的担心完全一致，候选策略按原样实施会修改用户工作区。

单 module 模式（`GOWORK=off`）缺 sum 时不写文件，而是把失败作为**包级 `Error`** 返回：

```
"Err": "missing go.sum entry for module providing package github.com/pkg/errors
        (imported by example.com/single); to add:\n\tgo get example.com/single"
```

这正是 B7a1 要求的「`-e` 返回的包级失败需可见，不能降格为空树」，可以直接作为
project-level diagnostics 呈现，不需要宿主执行 `go mod tidy` 或 `go get`。

## 2. 隔离方案：三种做法只有一种成立

目标是让 `go.work.sum` 落在宿主管理的临时位置，而不是用户工作区，同时保持解析语义不变。

| 做法 | 结果 |
| --- | --- |
| 用 `go work edit -json` 的输出重建 go.work | **不可用**：该命令只输出 `Go`/`Use`/`Replace`，**不输出 `toolchain` 与 `godebug`**。重建的副本会静默丢掉这两条指令，解析语义与用户真实 workspace 不同 |
| 隔离目录里放 go.work 副本 + 指向各 module 的符号链接 | **不可用**：Go 不跟随符号链接匹配当前目录，报 `directory prefix . does not contain modules listed in go.work` |
| 逐字节复制 go.work，**只**把 `use` 块内的路径重写为解析后的绝对路径 | **可用**：包列举成功且依赖解析正确，`toolchain`/`godebug`/`replace` 全部保留，`go.work.sum` 写在隔离目录 |

第三种做法连续三次刷新后，用户工作区全部文件的 SHA-1 与刷新前**逐字节一致**。

### 2.1 实施约束

- `use` 路径必须重写为**符号链接解析后的真实路径**。用未解析的路径（如 `/tmp/...`
  而实际是 `/private/tmp/...`）时 Go 会拒绝当前目录，报同样的
  `directory prefix .` 错误。宿主必须用与 capture 的 cwd 相同的解析方式。
- 只重写 `use` 块内的路径行，**其余行逐字节保留**。不得用 `go work edit -json` 重建，
  也不得"顺手规范化"格式：任何未被识别的指令都必须原样带过去，否则就是静默改变语义。
- 隔离目录由宿主创建在系统临时目录下，经检查不落在源码树内（与 B7a2c2 的
  Cargo 准备同一条约束），刷新结束后连同 `go.work.sum` 一起删除。
- 单 module 项目（无 go.work）走 `GOWORK=off`，不需要隔离目录，也不得凭空造一个
  go.work——那会改变 module 解析。
- go.work 在刷新期间被用户修改时，隔离副本已经冻结：与 Cargo 一样，这一轮的输入身份
  在准备时冻结，`validate()` 复核 go.work 的文件身份，不一致则整轮失败并要求重新刷新。

### 2.2 环境构造

沿用 B7a2c2 为 Cargo 建立的做法：从空字典按白名单构造，而不是继承宿主环境。
Go 侧至少需要 `HOME`、`PATH`、`GOMODCACHE`、`GOPATH`、`GOCACHE`，并显式设置
`GOTOOLCHAIN=local`、`GOFLAGS=-mod=readonly`、`GOPROXY=off`、`GOSUMDB=off`、
`GOWORK=<隔离副本或 off>`。

B7a2 点名要审查的几个会改变下载或外部命令行为的变量，处理方式明确为**不继承**：
`GOFLAGS`（用宿主自己的值覆盖，不叠加用户的）、`GOPRIVATE`/`GONOSUMDB`/`GONOSUMCHECK`、
`GOCACHEPROG`（会让 go 启动一个外部程序）、`GOAUTH`（会触发凭据获取）、`GOINSECURE`。
本机实测该用户的 `GOPROXY` 与 `GONOSUMDB` 都有非默认值，直接继承会改变读取行为，
这不是假设风险。

`-modfile`、`-test`、`-compiled` 明确禁用，与 B7a2 原文一致。

## 3. 命令序列

1. `go env -json GOWORK GOMOD`（定位，零写）
2. `GOWORK` 非空时：`go work edit -json` 取 `Use` 列表用于确定要遍历哪些 module；
   同时**另行**逐字节复制 go.work 并重写 `use` 路径生成隔离副本（不用该 JSON 重建）
3. `go list -m -json`（workspace 根或单 module，零写）
4. 逐 module `go list -e -json ./...`，`GOWORK` 指向隔离副本（或 `off`）

go.work 根不执行 `./...`（B7a2 原文要求），只在每个 use module 目录内执行。

## 4. 验收

1. **零写**：缺 sum / 有缓存依赖 / 缺缓存依赖 / go.work 含 replace+toolchain+godebug
   四种 fixture，刷新前后用户工作区全部文件 SHA-256 逐字节一致；连续多次刷新同样一致。
2. **隔离副本忠实**：含 `toolchain`、`godebug`、`replace`、注释、非常规空白的 go.work
   复制后除 `use` 路径外逐字节相同；解析结果与直接使用原 go.work 相同（除 sum 文件位置）。
3. **失败可见**：缺 sum 的包级 `Error` 出现在 diagnostics 中，不降格为空树，
   宿主不执行 `go mod tidy`/`go get`/`go work sync`。
4. **身份冻结**：刷新期间修改 go.work 或 module 的 go.mod，该轮整体失败并提示重新刷新。
5. **清理**：取消、超时、失败、项目关闭后隔离目录与其中的 `go.work.sum` 均被删除。
6. **环境**：实测 child 收到的 env 精确等于白名单加显式设置，用户的 `GOPROXY`/`GONOSUMDB`
   等不出现在其中。

上述结论来自 go1.24.4；换 Go 版本必须重跑第 1 节的表格，不能沿用本文结论。
本文只解除了 B7a2 的读取阻塞，Go Tools 工具窗口本身仍未实施。
