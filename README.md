# UsageNow

UsageNow 是一款仅在本机运行的 macOS 菜单栏应用，用于查看当前 Mac 上已登录的 **Codex** 与 **Cursor** 账户的实时额度用量。

## 界面说明

Popover 约 `460×340`，包含两个服务卡片，各有一张双层同心圆环：

| 服务 | 内圈 | 外圈 | 重置时间 |
|------|------|------|----------|
| Codex | 5 小时剩余额度 | 周剩余额度 | 显示 |
| Cursor | Other Models | Cursor Models | 不显示 |

菜单栏显示 Codex 与 Cursor 的两个双环剩余额度缩略图。**鼠标悬停**图标可查看详细剩余额度卡片；**左键点击**打开完整面板；**右键点击**退出。应用不会在 Dock 中显示图标。

可将 `docs/screenshot.png` 放入仓库以展示截图（可选）；本地运行后点击菜单栏图标即可查看实际界面。

## 系统要求

- macOS 13 或更高
- Apple Silicon（arm64）
- 已安装 Xcode（含 Swift 6 与 XCTest）。若 `swift test` 找不到 XCTest，请执行：  
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- 本机已登录 Cursor；Codex 通过 ChatGPT / Codex CLI 的 `codex app-server` 读取额度

## 构建

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

产物：`dist/UsageNow.app`（本地 ad-hoc 签名）。

调试构建：

```bash
swift build
swift test   # 需要 Xcode 自带的 XCTest
```

## 安装

将 `dist/UsageNow.app` 拖入 `/Applications`，从菜单栏打开即可。

## 数据来源与隐私

- **Codex**：启动本机 `codex app-server --stdio`，通过 JSON-RPC 读取 `account/rateLimits/read`；不读取 `~/.codex/auth.json`。
- **Cursor**：只读查询本机 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 中的 access token（仅内存使用，不记录、不缓存到文件），再请求 Cursor 内部用量接口。

应用不启用 App Sandbox，以便访问上述本地数据并启动 Codex 子进程。默认日志仅包含生命周期与错误类别，**不会**记录 Token、Authorization 头或完整 API 响应。

## Cursor 接口说明

Cursor 用量接口为客户端内部 API，字段或路径可能随 Cursor 升级变化。若出现「Cursor 数据接口已变化」，需随新版本调整 `CursorUsageProvider`。

## 常见问题

| 现象 | 处理 |
|------|------|
| 未找到 Codex | 安装或更新 ChatGPT / Codex CLI，然后重新构建并启动 UsageNow；应用会检查新版 ChatGPT 应用包中的 Codex CLI 路径 |
| 未检测到 Cursor 登录 | 在 Cursor 中登录账户后点击刷新 |
| 数据可能已过期 | 检查网络或稍后刷新；Codex 会自动退避重连 App Server |
| 退出后仍有 `codex app-server` | 请报告问题；正常退出应终止子进程 |

## 许可证

本地个人使用项目；未附带第三方 Swift 依赖。
