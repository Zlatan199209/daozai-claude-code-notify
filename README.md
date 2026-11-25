# 岛仔 × Claude Code 通知钩子

[岛仔（Daozai）](https://github.com/Renly1994/xiaotang-daozai) 的补丁版，加一个 Claude Code 钩子脚本：
Claude Code 一轮回答结束后，灵动岛弹出横幅，并在小岛右侧留下一个可点击的图标；点它切回会话所在的终端窗口。

| 横幅出现时 | 横幅消失后，图标保留 |
|---|---|
| ![横幅](docs/banner.png) | ![图标保留](docs/persist.png) |

> 补丁基于官方 v0.6.66。**「点图标切回窗口」这一步还没完成验证**，详见[状态与限制](#状态与限制)。

## 快速开始

1. 到 [Releases](../../releases) 下载 `daozai-claude-code-notify-<版本>.zip` 并解压。里面有三个文件：`daozai.exe`、`notify.ps1`、`SETUP-for-Claude-Code.md`。
2. 核对哈希：压缩包里附有 `SHA256SUMS.txt`，Release 页上也有一份。
3. 对你的 Claude Code 说：**「按 SETUP-for-Claude-Code.md 帮我设置」**。它会逐步安装并验证，中途需要你配合看屏幕、点按钮。

要求 Windows 10 / 11 x64，已安装 Claude Code。不需要管理员权限，不需要编译。

## 它是怎么工作的

分两半：

- **岛仔补丁**，改的是岛仔。通知的文字末尾如果带着 `daozai-focus:<窗口句柄>:<名称>`，岛仔就在右侧留一个橙色图标；点它，把那个窗口带到前台。窗口到了前台或被关闭，图标消失。协议是通用的，任何会发 Windows 通知的程序都能用。
- **钩子脚本**，改的是 Claude Code 这边。在 `Stop`、`Notification`、`SessionStart` 三个事件上运行 `notify.ps1`。`SessionStart` 记下会话所在的窗口；`Stop` 和 `Notification` 发出带上述标记的系统通知，只进通知中心，不弹 Windows 横幅，响一声。

```
Claude Code 回答结束 ──Stop 钩子──▶ notify.ps1 ──带标记的静默通知──▶ 岛仔读取通知中心
                                                                          │
                                                      右侧留下橙色图标 ◀────┘
用户点图标 ──▶ 岛仔把记下的终端窗口带到前台 ──▶ 图标消失
```

## 仓库内容

| 路径 | 说明 |
|---|---|
| `SETUP-for-Claude-Code.md` | 给 Claude Code 看的安装指南，附钩子脚本全文 |
| `notify.ps1` | 钩子脚本 |
| `patch/external-shortcut.patch` | 岛仔补丁相对 v0.6.66 的源码改动 |
| `patch/patched-build.yml` | 在 GitHub Actions 上编译补丁版的 workflow |
| `docs/` | 上面的两张截图 |

编好的 `daozai.exe` 不放进代码仓库，见 [Releases](../../releases)。

## 状态与限制

**已验证**，在编写者的机器上，Windows 10：

- 补丁在全量测试下通过，1294 个测试。
- 通知到达后横幅与图标同时出现，横幅消失后图标保留。
- 钩子在真实的 Claude Code 会话里触发，会话启动时正确登记了窗口。

**未验证，或属于已知限制**：

- **点图标切回窗口**：编写本页时还没完成验证，测试被锁屏打断。指南第 5.3 节会让使用者确认，请把结果反馈到 [Issues](../../issues)。
- Windows 11、Windows 的「通知访问权限」弹窗、Windows Terminal 以外的终端，都没在别的机器上试过。
- 不要用岛仔内置的「检查更新」，更新会把补丁覆盖掉。
- 在 Windows 通知中心里展开这条通知，会多一行 `daozai-focus:…` 的标记。
- 补丁版和官方版一样没有数字签名。
- 锁屏、全屏程序在前台、或岛仔用「极简刘海」外观时，小岛本来就不显示。
- Claude Code 用 `--dangerously-skip-permissions` 启动时没有权限确认框，所以只有「一轮回答结束」和「回答完约 60 秒没输入」两种提醒。

## 让自己的程序也用这个图标

任何能发 Windows 通知的程序都可以。在通知文字的最后加一个内容为 `daozai-focus:<窗口句柄>:<名称>` 的文本元素：

```powershell
$hwnd = (Get-Process -Name notepad).MainWindowHandle.ToInt64()   # 想切回去的窗口
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'   # 借用系统自带的身份
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>我的程序</text><text>任务完成了</text><text>daozai-focus:' + $hwnd + ':记事本</text></binding></visual></toast>')
$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
$toast.SuppressPopup = $true    # 只进通知中心，不弹 Windows 横幅；想弹就删掉这行
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
```

岛仔识别后会把这个标记从显示内容里剔掉。脚本里含中文的话，文件要存成带 BOM 的 UTF-8。

## 从源码编译

补丁的源码在 [fork 的 `patch/external-shortcut` 分支](https://github.com/Zlatan199209/xiaotang-daozai/tree/patch/external-shortcut)。推送到该分支后，[这个 workflow](patch/patched-build.yml) 会在 GitHub Actions 的 windows-latest 上编译、跑全量测试并上传 `daozai.exe`。自己在本机编译需要 Rust stable 和 MSVC；想改代码，fork 那个分支即可。

## 回滚

- 恢复官方岛仔：退出岛仔，用安装前备份的官方 `daozai.exe` 覆盖回去，见指南第 7 节。
- 去掉 Claude Code 这边的接入：恢复 `settings.json` 的备份，删除 `notify.ps1`。

## 许可与致谢

岛仔补丁部分基于 [Renly1994/xiaotang-daozai](https://github.com/Renly1994/xiaotang-daozai)，沿用 MIT 许可，向原作者致谢。钩子脚本和文档由本仓库提供。本补丁不是岛仔官方发布的版本，官方不为它提供支持。
