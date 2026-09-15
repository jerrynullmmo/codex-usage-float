# Codex Usage Float · Codex 用量浮窗

[![Build and test](https://github.com/jerrynullmmo/codex-usage-float/actions/workflows/ci.yml/badge.svg)](https://github.com/jerrynullmmo/codex-usage-float/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A native macOS floating usage monitor for Codex: hover to expand, click to pin, and follow locally indexed conversations by their unique window title. Runs locally without model calls or telemetry. Apple Silicon / macOS 14+. The interface and detailed documentation are currently in Chinese.

独立社区项目，与 OpenAI 无官方隶属关系。源码和工具脚本采用 [MIT 许可证](LICENSE)。

一个 macOS 本地小工具：平时是可拖动的浮标，鼠标停留约 0.3 秒展开详情，离开约 0.5 秒收起。点击浮标或详情里的“固定”可以持续观察。窗口不会成为键盘输入窗口，因此悬停与固定不会抢走 Codex 输入框的焦点。

## 安装与启动

需要 **Apple Silicon Mac、macOS 14+、Git 和 Apple Swift 命令行工具**。Intel Mac、Windows、Linux 与普通 ChatGPT 聊天的用量统计暂不支持。源代码无需 API Key，也不需要第三方运行依赖。

### 从源码安装

未安装 Apple 命令行工具时，先运行 `xcode-select --install` 并完成系统安装提示。然后执行：

```sh
git clone https://github.com/jerrynullmmo/codex-usage-float.git
cd codex-usage-float
zsh scripts/test.sh
zsh build.sh
zsh scripts/install.sh
open -g "$HOME/Applications/Codex Usage Float.app"
```

安装脚本会在浮窗仍运行时停止安装并提示退出，保留原有偏好；已有应用会备份到 `~/Library/Application Support/Codex Usage Float/backups/`。不需要 `sudo`，也不修改 Codex 程序。

### 下载构建包

[Releases](https://github.com/jerrynullmmo/codex-usage-float/releases) 提供 Apple Silicon 应用压缩包及 `SHA256SUMS` 校验文件。下载到同一目录后运行 `shasum -a 256 -c SHA256SUMS`，确认压缩包校验通过；解压后将应用放到自己的 `~/Applications/` 目录。

公开构建包使用临时签名，**没有 Apple Developer ID 签名或公证**。macOS 可能要求在“系统设置 → 隐私与安全性”中确认打开；只在确认来源与校验结果后操作。不应关闭系统整体安全保护；也可选择自行从源码构建。

### 首次授权与更新

自动跟随需要给已安装的 **Codex Usage Float** 授予辅助功能权限。先完成安装，再授权，避免授权到 `build/` 中的另一个副本。

临时签名随重新构建而变化。更新后即使开关仍亮着，旧授权也可能不再适用于新版本；请在辅助功能列表移除旧条目，再通过“+”添加 `~/Applications/Codex Usage Float.app` 并开启。浮窗会自动重试，不需要重启 Codex。只想手动选择任务时，可以不授予此权限。

## 使用

- 打开 `~/Applications/Codex Usage Float.app`。默认只在 Codex / ChatGPT 位于前台时显示。
- 拖动小浮标调整位置；松手后记住位置。详情会根据屏幕空间向上或向下展开。
- 默认**自动跟随当前对话**，约每 0.5 秒检查 Codex 前台窗口的页面标题，唯一匹配本地任务后切换用量。标题不存在或有重名时，清空任务数字并提示，绝不按“最近活动”猜测。
- 自动跟随需要在 macOS“系统设置 → 隐私与安全性 → 辅助功能”中允许 **Codex Usage Float**。如果列表没有它，点“+”添加 `~/Applications/Codex Usage Float.app`。允许后会自动重试，无需重启 Codex。
- 点击详情中的任务名称仍可手动选择，但会暂停自动跟随；在设置菜单重新勾选“自动跟随当前对话”即可恢复。固定详情只固定展开状态，不会停止跟随对话。
- 右键浮标或点击详情的“设置”，可更换浮标指标、隐藏详情指标、调整指标顺序、切换强调色，以及关闭“仅前台显示”。
- 屏幕顶部菜单栏中的小图表图标可以隐藏、恢复和退出浮窗。退出只停止本工具，不影响 Codex。
- 本工具不自动开机启动。

## 数字如何理解

Token 是模型处理文字等内容时使用的计量单位，不等于中文字数，也不是人民币金额。

| 列 | 统计范围 |
| --- | --- |
| 全任务 | 所选本地任务日志最新上报的累计值；继承、分叉或恢复的历史以日志口径为准 |
| 本轮 | 从最近一条 `task_started` 记录开始，到最新用量记录的差额；一次用户请求可能触发多次模型调用 |
| 最近调用 | 日志最新上报的 `last_token_usage`，不是整轮用户请求 |

- 输入包含缓存读取，输出包含推理输出，不能再把这些子项加到总数中。
- 缓存命中率 = 缓存读取 / 输入；输入为零或字段缺失时显示“—”。
- **“—”表示数据未知或暂未上报，0 才表示日志明确给出零。** 缓存写入是否完整上报尚未获得独立验证，因此零值不应解释为已确认没有缓存写入。
- 套餐额度来自所选任务日志中的 Codex 额度快照，属于账户额度；不是本任务独占额度，也不能按 Token 简单换算。显示更新时间与重置倒计时；跨过重置时间后显示“待更新”，不会擅自补成 100%。默认浮标显示有效额度窗口中剩余比例最低的一个。
- 每 2 秒读取新增记录；模型尚未上报时保留上次快照和时间。额度快照超过 5 分钟，浮标追加“·旧”；该间隔不是逐字生成时的精确计量频率。
- 只读取所选本地任务，不自动合并子代理、其他任务、远程主机或云端记录。
- 首次打开仅解析日志末尾最多 8 MB，避免加载大型历史对话。若这段记录不含本轮起点及前一累计值，“本轮”显示未知；之后捕获到完整的新轮次会恢复统计。

## 数据与权限

使用 macOS 原生 AppKit 窗口，不修改、注入或重新签名 Codex。只读 `~/.codex/state_*.sqlite` 的任务索引与所选任务日志；不读取登录凭据，不连接网络，不调用模型，不上传内容。自动跟随使用 macOS 辅助功能接口，只读取 Codex 当前窗口的应用页面标题，找到页面后不遍历对话正文，也不读取嵌入浏览器网页。代码不通过该权限点击或输入其他应用，不需要录屏或自动化权限；手动模式不需要辅助功能权限。

当前匹配依据是对话标题，而不是 Codex 官方提供的当前任务 ID 接口。支持可唯一匹配到本机记录的对话；不支持自动读取远程或云端用量。远程对话与本地任务同名时，仅凭标题无法区分，应暂停自动跟随。Codex 更换标题规则、页面地址或窗口结构后可能需要适配。

个人选择与位置保存在 `~/Library/Application Support/Codex Usage Float/settings.json`，不保存对话内容或 Token 历史。删除应用即可卸载；删除这个设置目录可清除偏好。

## 构建与验证

日常开发与自动检查使用合成数据，不需要真实 Codex 账号或会话：

```sh
zsh scripts/test.sh
zsh build.sh
zsh scripts/package.sh
```

构建产物：`build/Codex Usage Float.app`；压缩包与校验文件在 `dist/`。脚本不安装或启动应用，CI 也不申请辅助功能权限。

可用 `CodexUsageFloat --snapshot <任务 ID>` 检查真实快照；`--focus-probe` 只读检查当前窗口匹配。`--ui-test --thread <任务 ID>` 验证悬停延迟、收起、固定、不抢焦点、本地记录加载，以及识别失败后不显示旧任务数据，并将自身界面渲染到 `USAGE_TEST_OUTPUT` 指定的目录。界面测试不点击或输入其他应用。按需加 `--diagnostic-output <路径>` 可将任务匹配状态写入本地诊断文件，正常启动不写此文件。

上述 `CodexUsageFloat` 是应用内部的可执行文件，不会自动加入 PATH。例如：

```sh
"build/Codex Usage Float.app/Contents/MacOS/CodexUsageFloat" --focus-probe
```

诊断输出和界面测试截图可能包含你的任务名称、日志路径和用量，请勿直接公开上传。

## 支持范围与验证

当前实现针对 Codex 桌面宿主（bundle ID `com.openai.codex`）的 `app://-/index.html` 页面。本机验证环境为 Apple Silicon、macOS 26.6.2、Codex 桌面宿主 26.908.40834；“macOS 14+”为构建部署目标，不表示每个系统版本都已完成真人使用验证。普通 ChatGPT 应用可以触发浮窗前台显示，但不提供聊天用量自动跟随。

合成测试覆盖累计值去重、轮次边界、缺失字段、半行写入、文件替换、标题重名与设置迁移。本机额外验证过浮窗交互和实际任务来回切换。仓库自动检查负责构建与合成测试，不能替代真实桌面上的焦点、权限和切换验证。

问题反馈见 [Issues](https://github.com/jerrynullmmo/codex-usage-float/issues)；贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)，隐私问题见 [SECURITY.md](SECURITY.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 实现依据

- [Apple：非激活浮窗的键盘焦点控制](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)
- [OpenAI：任务 Token 用量更新](https://learn.chatgpt.com/docs/app-server)

读取器复用日志提供的累计快照，而不是把每条累计快照相加。聚焦验证涵盖重复事件、轮次边界、半行写入、缺失字段、文件替换和额度过期显示；本地日志格式属于 Codex 实现细节，后续版本变更可能需要适配。
