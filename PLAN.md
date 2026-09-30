# UsageNow macOS 开发实施文档

## 1. 项目目标

开发一个仅在本机使用的原生 macOS 菜单栏应用 `UsageNow`，复用当前 Mac 已登录的 Codex 和 Cursor 账户，展示实时额度用量。

界面包含两个双层圆环：

| 服务 | 内圈 | 外圈 | 重置时间 |
|---|---|---|---|
| Codex | 5 小时已用额度 | 周已用额度 | 显示两者 |
| Cursor | Other Models 已用额度 | Cursor Models 已用额度 | 不显示 |

百分比表示“已经使用多少”，越接近 100%，圆环越满。

## 2. 技术约束

- Swift 6、SwiftUI、AppKit。
- 最低系统版本 macOS 13。
- Apple Silicon 构建。
- 使用 Swift Package Manager，不依赖完整 Xcode 工程。
- 不引入第三方 Swift 包。
- 应用不启用 App Sandbox，以便读取 Cursor 本地数据库和启动 Codex 子进程。
- 不提供账户登录、Token 输入、历史图表、通知、开机启动或自动更新。
- 不得读取或解析 `~/.codex/auth.json`。
- 不得保存、输出或记录 Cursor Token。
- 最终产物为 `dist/UsageNow.app`，使用本地临时签名。

## 3. 项目结构

```text
UsageNow/
├── Package.swift
├── README.md
├── .gitignore
├── Sources/
│   └── UsageNow/
│       ├── App/
│       │   ├── UsageNowApp.swift
│       │   └── AppDelegate.swift
│       ├── Models/
│       │   └── UsageModels.swift
│       ├── State/
│       │   └── UsageStore.swift
│       ├── Providers/
│       │   ├── UsageProvider.swift
│       │   ├── CodexUsageProvider.swift
│       │   └── CursorUsageProvider.swift
│       ├── Services/
│       │   ├── CodexAppServerClient.swift
│       │   ├── CursorTokenReader.swift
│       │   └── HTTPTransport.swift
│       ├── Views/
│       │   ├── MenuBarContentView.swift
│       │   ├── ProviderCardView.swift
│       │   ├── DoubleRingView.swift
│       │   └── StatusFooterView.swift
│       ├── Utilities/
│       │   ├── ResetTimeFormatter.swift
│       │   └── PercentageFormatter.swift
│       └── Resources/
│           └── AppIcon.icns
├── Tests/
│   └── UsageNowTests/
│       ├── CodexResponseTests.swift
│       ├── CursorResponseTests.swift
│       ├── UsageStoreTests.swift
│       └── FormattingTests.swift
└── scripts/
    └── build-app.sh
```

`Package.swift` 要求：

- `platforms: [.macOS(.v13)]`
- 一个名为 `UsageNow` 的 executable target。
- 一个名为 `UsageNowTests` 的 test target。
- 将 `Resources` 作为 SwiftPM resources 处理。

## 4. 应用生命周期和菜单栏

不要直接依赖 `MenuBarExtra` 判断面板开关状态。使用 AppKit 实现：

- `NSStatusItem` 创建菜单栏图标。
- `NSPopover` 承载 `NSHostingController<MenuBarContentView>`。
- `NSPopoverDelegate` 通知 `UsageStore` 面板打开或关闭。
- 菜单栏图标使用 SF Symbol `chart.donut`。
- `AppDelegate` 持有 `NSStatusItem`、`NSPopover` 和共享 `UsageStore`。
- 点击菜单栏图标切换 Popover。
- Popover 失去焦点时自动关闭。
- 退出应用前停止定时器并终止 Codex App Server 子进程。

`Info.plist` 至少包含：

```xml
<key>CFBundleIdentifier</key>
<string>com.local.usagenow</string>
<key>CFBundleName</key>
<string>UsageNow</string>
<key>CFBundleExecutable</key>
<string>UsageNow</string>
<key>CFBundlePackageType</key>
<string>APPL</string>
<key>LSUIElement</key>
<true/>
<key>LSMinimumSystemVersion</key>
<string>13.0</string>
<key>NSHighResolutionCapable</key>
<true/>
```

## 5. 数据模型与内部接口

定义以下核心类型，名称可以保持一致：

```swift
protocol UsageProvider: Sendable {
    var provider: UsageProviderKind { get }
    func fetch() async throws -> UsageSnapshot
}

enum UsageProviderKind: String, Sendable {
    case codex
    case cursor
}

struct UsageMetric: Sendable, Equatable {
    let title: String
    let percentUsed: Double
    let resetAt: Date?
}

struct UsageSnapshot: Sendable, Equatable {
    let provider: UsageProviderKind
    let innerMetric: UsageMetric
    let outerMetric: UsageMetric
    let fetchedAt: Date
}

enum ProviderState: Equatable {
    case idle
    case loading
    case available(UsageSnapshot)
    case stale(snapshot: UsageSnapshot, message: String)
    case unavailable(message: String)
}
```

显示规则：

- 绘图进度使用 `min(max(percentUsed, 0), 100) / 100`。
- 文本保留真实百分比。
- 百分比显示为四舍五入后的整数。
- 超过 100% 时显示真实值，例如 `112%`，圆环保持填满。
- 无数据时显示 `—`，不得错误显示成 `0%`。
- 最后更新时间使用本地时区。

## 6. Codex 数据接入

### 6.1 二进制查找

按以下顺序查找 Codex 二进制：

1. `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`
2. `/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`
3. `/Applications/ChatGPT.app/Contents/Resources/codex`
4. `/Applications/Codex.app/Contents/Resources/codex`
5. `/opt/homebrew/bin/codex`
6. `/usr/local/bin/codex`
7. 当前进程 `PATH` 中名为 `codex` 的可执行文件

必须通过 `Process` 直接启动二进制，不通过 shell 拼接命令。

找不到时显示：

> 未找到 Codex。请确认 ChatGPT 或 Codex CLI 已安装。

### 6.2 App Server 通信

启动命令：

```text
codex app-server --stdio
```

使用 stdin/stdout 的逐行 JSON-RPC 协议。stderr 单独读取，仅用于内部诊断，不得显示认证信息。

初始化顺序：

```json
{
  "id": 1,
  "method": "initialize",
  "params": {
    "clientInfo": {
      "name": "UsageNow",
      "title": "UsageNow",
      "version": "1.0.0"
    }
  }
}
```

收到成功响应后发送：

```json
{
  "method": "initialized",
  "params": {}
}
```

读取额度：

```json
{
  "id": 2,
  "method": "account/rateLimits/read",
  "params": null
}
```

同时处理通知：

```text
account/rateLimits/updated
```

官方 App Server 提供 `usedPercent`、`windowDurationMins` 和 `resetsAt` 等字段。[Codex App Server 文档](https://learn.chatgpt.com/docs/app-server)

### 6.3 JSON-RPC 客户端

`CodexAppServerClient` 使用 `actor` 实现，负责：

- 管理唯一长驻 `Process`。
- 管理递增请求 ID。
- 缓存未完成请求的 continuation。
- 从 stdout 累积字节并按换行拆分完整 JSON。
- 区分响应、通知和 JSON-RPC 错误。
- 为初始化和请求设置 15 秒超时。
- 提供 `AsyncStream` 或回调传出额度更新通知。
- 防止启动多个 App Server。
- 进程退出后解除所有等待中的 continuation。
- 应用退出时发送 terminate，超时后再调用 `Process.terminate()`。

任何日志都不得包含原始 stdout JSON、授权头或账户数据。

### 6.4 额度映射

优先读取：

```text
rateLimitsByLimitId["codex"]
```

不存在时读取：

```text
rateLimits
```

根据窗口长度匹配，而不是依赖 `primary`、`secondary` 顺序：

- `windowDurationMins == 300` → 内圈，标题 `5 小时`
- `windowDurationMins == 10080` → 外圈，标题 `本周`

字段映射：

- `usedPercent` → `percentUsed`
- `resetsAt` → Unix 秒级时间戳
- 缺少指定窗口时，仅将该指标标记为不可用，不能用另一个窗口替代

Codex 重置时间显示格式：

- 24 小时以内：`2 小时 13 分后（21:30）`
- 1–7 天：`3 天后（周日 14:00）`
- 已过期：`正在重置`
- 缺失：`重置时间不可用`

官方说明 Codex 存在五小时用量窗口，并可能同时受周额度限制。[Codex 定价与用量文档](https://learn.chatgpt.com/docs/pricing)

### 6.5 异常恢复

App Server 意外退出时：

- 保留最后成功快照。
- 状态变为 `stale`。
- 按 5、15、30、60、120、300 秒退避重启。
- 用户点击手动刷新时立即尝试重启，不等待退避结束。
- 成功后清空退避计数。

## 7. Cursor 数据接入

### 7.1 Token 读取

数据库路径：

```text
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
```

使用 `/usr/bin/sqlite3`，通过 `Process` 运行只读查询：

```sql
SELECT value
FROM ItemTable
WHERE key = 'cursorAuth/accessToken'
LIMIT 1;
```

要求：

- 使用 `-readonly`。
- 数据库路径作为独立参数传入，不拼接 shell 命令。
- stdout 只保存在内存中。
- 不得打印 Token。
- 每次刷新重新读取 Token，确保 Cursor 重新登录后能自动恢复。
- 如果值是 JSON 编码字符串，先尝试 `JSONDecoder` 解码；失败时将原始文本视为 Token。
- 查询完成后立即释放不再需要的 Token 数据。

数据库或 Token 不存在时显示：

> 未检测到 Cursor 登录信息，请先登录 Cursor。

### 7.2 用量请求

请求：

```http
POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
Authorization: Bearer <Cursor access token>
Content-Type: application/json
Connect-Protocol-Version: 1
```

请求体：

```json
{}
```

使用 `URLSession` 和 15 秒超时。禁止把 Token 放入错误消息或日志。

只解码需要的字段：

```swift
struct CursorUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
}

struct CursorPlanUsage: Decodable {
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
}
```

字段映射：

- `apiPercentUsed` → 内圈 `Other Models`
- `autoPercentUsed` → 外圈 `Cursor Models`

即使响应包含账期结束时间，界面也不得显示 Cursor 重置时间。

Cursor 官方将额度分为 Cursor Models 与 Other Models 两个池。[Cursor 用量与限制](https://prod.cursor.com/help/models-and-usage/usage-limits)

### 7.3 HTTP 错误

- `401/403`：显示“Cursor 登录已失效，请重新登录 Cursor”。
- `404`：显示“Cursor 用量接口不可用”。
- `429`：保留旧数据并显示“请求过于频繁”。
- `5xx` 或网络错误：保留旧数据并标记过期。
- JSON 字段缺失或结构改变：显示“Cursor 数据接口已变化”。
- 不自动调用 refresh token 接口。
- 不向用户要求手动复制 Token。

Cursor 接口属于当前客户端使用的内部接口，因此必须把所有路径、请求头和 DTO 限制在 `CursorUsageProvider` 内，避免影响其他模块。

## 8. 状态管理和刷新策略

`UsageStore` 使用 `@MainActor final class ObservableObject`。

公开状态：

```swift
@Published private(set) var codexState: ProviderState
@Published private(set) var cursorState: ProviderState
@Published private(set) var isRefreshing: Bool
@Published private(set) var lastRefreshCompletedAt: Date?
```

刷新规则：

- 应用启动后立即刷新。
- Popover 每次打开时立即刷新。
- Popover 打开期间每 60 秒刷新。
- Popover 关闭期间每 300 秒刷新。
- 手动刷新忽略当前周期并立即执行。
- 刷新进行中时禁用刷新按钮。
- 不允许同一 Provider 重叠请求。
- Codex 与 Cursor 使用 `async let` 并行刷新。
- 一个 Provider 失败不影响另一个。
- Codex 推送通知可立即更新 Codex 状态，但不能改变 Cursor 刷新周期。
- 切换前后台周期时取消旧定时任务，避免多重计时器。
- 应用退出时取消全部 Task。

状态降级规则：

- 从未成功过且请求失败 → `unavailable`
- 已有成功数据后请求失败 → `stale(snapshot:message:)`
- stale 状态继续显示旧圆环，并显示黄色“数据可能已过期”
- 下一次成功后自动回到 `available`

为便于测试，应注入：

- `UsageProvider`
- 时间/睡眠抽象
- `HTTPTransport`
- Cursor Token Reader

## 9. 界面规范

Popover 推荐尺寸：`460 × 340`。

布局：

```text
┌──────────────────────────────────────────────┐
│ UsageNow                         刷新按钮      │
│                                              │
│ ┌──────────────────┐ ┌──────────────────┐    │
│ │      Codex       │ │      Cursor      │    │
│ │   双层同心圆环    │ │   双层同心圆环    │    │
│ │ 5 小时  42%      │ │ Other Models 21%│    │
│ │ 本周    67%      │ │ Cursor Models 8%│    │
│ │ 5小时重置时间     │ │                  │    │
│ │ 周重置时间        │ │                  │    │
│ └──────────────────┘ └──────────────────┘    │
│ 最后更新：21:18       状态信息        退出     │
└──────────────────────────────────────────────┘
```

圆环规范：

- 外圈直径约 132 pt，线宽 12 pt。
- 内圈直径约 98 pt，线宽 10 pt。
- 起点位于 12 点钟方向。
- 使用灰色轨道和圆角端点。
- 更新时使用约 0.3 秒平滑动画。
- 系统开启“减少动态效果”时禁用动画。
- 0–89% 使用服务对应颜色。
- 90% 及以上使用警示红色。
- 中央显示服务名称，不将两个百分比挤在圆环中心。
- 圆环下方必须同时提供文字和百分比，颜色不能是唯一的信息表达方式。

颜色建议：

- Codex 内圈：青绿色
- Codex 外圈：蓝色
- Cursor 内圈：橙色
- Cursor 外圈：紫色
- stale：黄色
- unavailable：红色或次要灰色

无障碍要求：

- 每个圆环提供 VoiceOver 标签，例如“Codex 五小时额度，已使用 42%”。
- 所有按钮提供 accessibility label。
- 支持浅色和深色模式。
- 使用系统字体和语义颜色。

## 10. 构建与打包

`scripts/build-app.sh` 执行以下流程：

1. `swift build -c release`
2. 清理并重新创建 `dist/UsageNow.app`
3. 创建：
   - `Contents/MacOS`
   - `Contents/Resources`
4. 复制 Release 可执行文件。
5. 复制 `Info.plist` 和 `AppIcon.icns`。
6. 执行本地签名：

```bash
codesign --force --deep --sign - dist/UsageNow.app
```

7. 使用以下命令验证：

```bash
codesign --verify --deep --strict dist/UsageNow.app
```

构建脚本应使用脚本自身位置解析项目根目录，不能依赖用户当前工作目录。

README 必须包含：

- 功能截图位置或界面说明。
- 系统要求。
- 构建命令。
- 安装方式：将 `UsageNow.app` 拖入 `/Applications`。
- 数据来源和隐私说明。
- Cursor 内部接口可能随客户端升级变化的说明。
- 常见问题：找不到 Codex、Cursor 未登录、数据过期。

## 11. 日志与隐私

默认只记录必要的生命周期信息：

- Provider 启动或停止。
- 请求成功或失败的错误类别。
- App Server 是否重启。
- 不记录完整响应。

严禁记录：

- Cursor access token 或 refresh token。
- `Authorization` 请求头。
- Codex/Cursor 账户 ID。
- App Server 原始响应。
- Cursor SQLite 查询结果。
- 任何认证文件内容。

应用不得创建包含认证信息的缓存文件。快照只保留在进程内存中，退出后清除。

## 12. 测试要求

### 单元测试

Codex：

- 能解析 `account/rateLimits/read`。
- 能解析 `account/rateLimits/updated`。
- `primary` 和 `secondary` 交换顺序后仍正确映射。
- `rateLimitsByLimitId["codex"]` 优先于顶层数据。
- 顶层回退生效。
- 缺失 300 分钟窗口时不会错误使用周额度。
- `resetsAt` 按 Unix 秒解析。
- 子进程退出后等待中的请求能正常失败。

Cursor：

- `apiPercentUsed` 映射到内圈。
- `autoPercentUsed` 映射到外圈。
- 小数、0%、100% 和超过 100% 正确处理。
- 缺失 `planUsage` 时返回明确错误。
- 401、403、404、429 和 5xx 映射为正确状态。
- Token Reader 能处理普通字符串和 JSON 编码字符串。
- 测试输出不包含 fixture Token。

状态管理：

- 初次失败进入 unavailable。
- 成功后再失败进入 stale 并保留旧数据。
- 前台使用 60 秒周期。
- 后台使用 300 秒周期。
- 切换周期不会产生重复计时器。
- 并发点击刷新不会产生重叠请求。
- 一个 Provider 失败时另一个仍然更新。

格式化：

- 倒计时、本地时间和已过期状态正确。
- 负数绘图为 0，但文本保留后端值。
- 超过 100% 绘图饱和，文本保留真实值。

### 人工验收

- 菜单栏出现 UsageNow 图标。
- Dock 中不出现应用图标。
- 点击图标可稳定打开和关闭面板。
- Codex 内圈是 5 小时额度，外圈是周额度。
- Cursor 内圈是 Other Models，外圈是 Cursor Models。
- 仅 Codex 显示重置时间。
- 数值与 Codex、Cursor 当前账户页面一致。
- 面板打开期间最多约 60 秒反映变化。
- 后台最多约 5 分钟反映变化。
- 手动刷新立即触发。
- Cursor 退出登录、断网、Codex 进程退出时应用不崩溃。
- 恢复登录或网络后无需重启应用即可恢复。
- 退出 UsageNow 后没有残留 `codex app-server` 进程。

## 13. 完成标准

Cursor 执行开发后必须交付：

- 完整 Swift 源码。
- 全部单元测试。
- 可重复执行的打包脚本。
- `dist/UsageNow.app`。
- README。
- `swift test` 全部通过。
- Release 构建成功。
- 不存在真实 Token、账户数据或本机认证文件内容。
- 运行后两个双层圆环、Codex 重置时间和刷新策略均符合本文档。
