# AI Desktop Usage Float · AI 桌面用量浮窗

[![Build and test](https://github.com/jerrynullmmo/codex-usage-float/actions/workflows/ci.yml/badge.svg)](https://github.com/jerrynullmmo/codex-usage-float/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A native macOS floating usage monitor for AI desktops. Built-in Codex and OpenCode readers, recursive subagent accounting, and a local JSON bridge for additional applications. Hover to expand and click to pin. Automatic conversation following depends on the data source; see the compatibility table below. Runs locally without model calls or telemetry. macOS 14+ / Apple Silicon and Windows 10/11 x64. The interface and detailed documentation are currently in Chinese.

独立社区项目，与 OpenAI 或其他软件厂商无官方隶属关系。仓库、应用文件名和设置路径保留 `Codex Usage Float`，便于旧版本升级。源码和工具脚本采用 [MIT 许可证](LICENSE)。

一个 Mac 与 Windows 本地工具：平时是可拖动的浮标，鼠标停留约 0.3 秒展开详情，离开约 0.5 秒收起。点击浮标或详情里的“固定”可以持续观察。窗口不会成为键盘输入窗口，因此悬停与固定不会抢走 Codex 输入框的焦点。

## 全部累计与当前对话

顶部可切换 **全部累计 / 当前对话**，默认打开全部累计。全部累计显示本机已接入软件的所有会话记录，包括归档任务和子代理；总 Token 是输入加输出，缓存和推理已含在其中。当前对话仍保留任务合计、本轮、主任务最近调用与套餐快照。说明文字默认收起，点击“展开说明 / 收起说明”即可切换，选择会保留。

全部累计按“软件来源 + 会话编号”去重，每个会话只读取自己的用量，不再把父任务的子代理合计加一遍。它没有最近 40 条的菜单限制；首次后台扫描历史并显示进度，以后约每 30 秒检查变动。本地 `all-usage-cache.json` 只保存统计摘要和文件变更标记，不保存对话正文；删除该缓存可重新扫描，不会删除原始记录。

范围是**这台电脑上已接入且仍可读取的记录**，不是账号全设备账单。不含未同步电脑、已删除日志，也不代表尚未接通的软件已支持。通用接入只能统计接入文件导出的历史。不同软件记录同一次调用、或分叉复制原对话历史时，原始记录可能重叠：当前按各自会话口径累计，不能将此视为去重后的实际消费账单。缺失记录或模型价格时显示已知部分并附 `+ ?`；未知单项显示 `—`，不会用零补齐。套餐百分比属于账户快照，不对多个对话求和。

## 官方 API 费用估算

详情增加“API 估算 USD”一行，分别显示任务合计、本轮、主任务最近调用；设置菜单可查看缺失原因、涉及模型、价目来源，并将费用放到紧凑浮标中。子代理先按各自调用的模型计算，再合并金额。模型切换不会把旧调用重新归到最新模型。

内置价目于 **2026-09-20** 核对，包含 OpenAI、Anthropic、Google、DeepSeek 的 50 个模型条目及显式别名。模型目录见 [prices.json](windows/prices.json)，每条价格均保留官方来源。**价格支持与软件接入是两回事**：费用引擎能计算 Claude 等模型，不代表 Claude Desktop 已能读取用量。其他模型可在设置中复制并编辑本地 `pricing.json`，重启生效；使用自定义文件时明确显示“自定义价目”。

金额是按这份价目重新估算已有 Token 的参考值，**不是历史实际账单、套餐扣费或余额**。采用 Standard/全球文本参考口径，不跟随实际 Fast、Batch、区域费率、企业折扣；Claude 缓存写入按 5 分钟参考价，DeepSeek 按官方峰时参考价；Google 不包含缓存按时存储费。工具服务、搜索、媒体生成、托管运行、税费等非 Token 费用未纳入。推理 Token 已包含在输出中，不再另加一次。

输入拆分为普通输入、缓存读取、缓存写入三类，各自只计一次。长上下文模型按每次调用的输入长度选档，不能按任务累计 Token 选档。记录缺少模型、价格或计费字段时，`—` 表示无法估算，`$金额 + ?` 表示已核实部分，不能视作完整合计；小于 $0.0001 的正金额显示 `<$0.0001`。

Codex 费用按每次累计增量与最近调用明细交叉核对，历史在后台每次最多回溯 8 MB，回溯完成才提供该任务金额。OpenCode 按独立消息计算。通用接入程序需提供逐次调用及完整性声明，见 [接入格式](docs/ADAPTERS.md)。不会请求模型或上传对话来计算费用。

## 软件兼容现状

目标是持续接入各类 AI 桌面软件，包括 WorkBuddy、Cursor、Claude Desktop 等；软件名称是例子，不是封闭名单。**可扩展不等于所有软件已经接通。** 每款软件必须解决两件事：找到当前对话，以及取得它实际产生的用量。软件未公开数据时，浮窗不能凭空补齐。

| 软件 / 接入方式 | 当前用量读取 | 子代理 | 自动跟随 |
| --- | --- | --- | --- |
| Codex Desktop | Mac、Windows 本机记录均已读取核对；套餐为带时间的账户快照 | 默认递归汇总；可查看各任务明细 | Mac 已验证标题切换；Windows 已实现精确标题/文档标题匹配，真实切换待验收 |
| OpenCode Desktop | 已用 Mac 上 1.18.29 的 5 个任务核对输入、输出、缓存；无套餐接口 | 已实现父子关系汇总并通过合成测试；本机暂无真实子任务样本 | 仅接受唯一的精确窗口标题；尚未完成真实切换验收，通用窗口标题需手动选择 |
| 其他软件的本地 JSON 接入 | 接入程序提供原软件真实计量；无需修改浮窗即可增加软件 | 按父任务编号递归；要求明确声明记录完整 | 接入程序提供当前任务编号；15 秒未更新即停止沿用旧任务 |
| Claude Desktop / Cowork | 待接入：本机有执行记录，但流式片段与结束报告计量不同，尚未解决完整计量 | 待核实报告是否包含全部代理 | 待接入 |
| WorkBuddy、Cursor、其他软件 | 待接入：Windows 有 WorkBuddy 数据库但暂无任务；Cursor 有部分非零 Token 记录，完整性未确认；尚无专用转换程序 | 随对应数据源验证 | 随对应数据源验证 |

给软件增加一个接入程序，就是把它自己的记录转换成浮窗认识的格式。[接入说明](docs/ADAPTERS.md) 提供格式、真实软件开发步骤和可运行的合成示例。示例只用于验证接口，不会读取 WorkBuddy、Cursor 或 Claude 的真实用量，也不会让它们自动变成已支持。提供 macOS 原生版本与 Windows 独立程序；Linux 尚不支持。不同软件、不同系统的读取与自动切换分别验收，不以某一平台通过代表所有平台通过。

## Windows 安装与启动

在 [Releases](https://github.com/jerrynullmmo/codex-usage-float/releases) 下载 `ai-usage-float-<版本>-windows-x64.zip`，核对校验值后解压并运行 `AIUsageFloat.exe`。无需 Python 或管理员权限；程序未做商业代码签名，不应关闭系统整体防护。

Windows 系统托盘提供设置和退出入口。初版已在 Windows 11 已登录桌面通过程序化悬停、展开、收起、不抢焦点等检查，并读到本机 Codex 实际计量；没有把 Windows 的真实 Codex/OpenCode A→B→A 切换、手动点击拖动全部标为已验收。构建、使用及许可说明见 [Windows README](windows/README.md)。

## macOS 安装与启动

需要 **Apple Silicon Mac、macOS 14+、Git 和 Apple Swift 命令行工具**。Intel Mac、Linux 与普通 ChatGPT 聊天的用量统计暂不支持。macOS 原生客户端无需 API Key 或第三方运行依赖。Windows 独立包自带 Python/Tk 运行时及对应许可声明。

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

## macOS 使用

- 打开 `~/Applications/Codex Usage Float.app`。默认只在已接入的软件位于前台时显示。
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
| 任务合计 | 默认主任务与全部后代子代理各自的累计值之和；只按任务编号计一次，包含已关闭或归档的子代理 |
| 本轮 | 统一以主任务最新请求为起点，汇总主任务和子代理在此后的用量；子代理中途续问不会重置这个起点 |
| 主任务最近 | 主任务最近一次模型调用，单独保留；不把不同代理的最后调用拼成一次调用 |

- 输入包含缓存项，输出包含推理输出，不能再把这些子项加到总数中。OpenCode 原始记录将这些项分开，本工具先统一口径再展示。
- 缓存命中率 = 缓存读取 / 输入；输入为零或字段缺失时显示“—”。
- **“—”表示数据未知或暂未上报，0 才表示日志明确给出零。** 缓存写入是否完整上报尚未获得独立验证，因此零值不应解释为已确认没有缓存写入。
- 套餐额度来自所选任务日志中的 Codex 额度快照，属于账户额度；不是本任务独占额度，也不能按 Token 简单换算。显示更新时间与重置倒计时；跨过重置时间后显示“待更新”，不会擅自补成 100%。默认浮标显示有效额度窗口中剩余比例最低的一个。
- 每 2 秒读取新增记录；模型尚未上报时保留上次快照和时间。额度快照超过 5 分钟，浮标追加“·旧”；该间隔不是逐字生成时的精确计量频率。
- 设置中的“汇总全部子代理”默认开启；关闭后只看主任务。“查看各任务用量”列出每个成员的累计和本轮值。缺少某个子代理记录时，完整合计显示“—”，可在明细查看已取得的数字。无关任务不合并，远程记录未接入时不会冒充已汇总。
- 分叉/复制任务中的继承历史按软件本地记录口径显示，不能把新分叉中的全部累计视为分叉后新发生的用量。
- Codex Token 视图首次打开解析日志末尾最多 8 MB；费用另行分段回溯完整计量历史。若这段记录不含本轮起点及前一累计值，“本轮”显示未知；之后捕获到完整的新轮次会恢复统计。

## macOS 数据与权限

使用 macOS 原生 AppKit 窗口，不修改、注入或重新签名 Codex。只读 `~/.codex/state_*.sqlite` 的任务索引、父子关系与对应日志，以及 `~/.local/share/opencode/opencode.db` 中的任务和消息计量字段；通过接入目录读取用户主动配置的 JSON 用量快照；不读取登录凭据，不连接网络，不调用模型，不上传内容。自动跟随使用 macOS 辅助功能接口，只读取 Codex 当前窗口的应用页面标题或 OpenCode 的窗口标题，找到页面后不遍历对话正文，也不读取嵌入浏览器网页。其他软件的通用接入使用接入程序明确提供的当前任务编号，不需要辅助功能权限。代码不通过该权限点击或输入其他应用，不需要录屏或自动化权限；手动模式不需要辅助功能权限。

当前匹配依据是对话标题，而不是 Codex 官方提供的当前任务 ID 接口。支持可唯一匹配到本机记录的对话；不支持自动读取远程或云端用量。远程对话与本地任务同名时，仅凭标题无法区分，应暂停自动跟随。Codex 更换标题规则、页面地址或窗口结构后可能需要适配。

个人选择与位置保存在 `~/Library/Application Support/Codex Usage Float/settings.json`，本工具不保存对话内容或 Token 历史；`adapters/` 是用户自行接入的用量快照。删除应用即可卸载；删除这个设置目录可清除偏好和接入文件。接入程序本身的权限与网络行为由其作者负责。

## macOS 构建与验证

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

Codex 的 Mac 标题读取针对桌面宿主（bundle ID `com.openai.codex`）的 `app://-/index.html` 页面。早期实际标题切换在 26.908.40834 上验证；0.3.0 的计量和浮窗检查在 Apple Silicon、macOS 26.6.2 上完成。Windows 独立包在 Windows 11（系统构建 26200）的已登录桌面完成程序化界面检查。部署目标不代表所有系统和软件版本都经过真人使用验收；普通 ChatGPT 聊天仍未接入。

合成测试覆盖累计值去重、轮次边界、子代理递归、缺失字段、半行写入、文件替换、标题重名、接入数据过期、跨任务旧结果拒绝与设置迁移。本机额外验证过浮窗交互和实际任务来回切换。仓库自动检查负责构建与合成测试，不能替代真实桌面上的焦点、权限和切换验证。

问题反馈见 [Issues](https://github.com/jerrynullmmo/codex-usage-float/issues)；贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)，隐私问题见 [SECURITY.md](SECURITY.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 实现依据

- [Apple：非激活浮窗的键盘焦点控制](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)
- [OpenAI：任务 Token 用量更新](https://learn.chatgpt.com/docs/app-server)

读取器复用日志提供的累计快照，而不是把每条累计快照相加。聚焦验证涵盖重复事件、轮次边界、半行写入、缺失字段、文件替换和额度过期显示；本地日志格式属于 Codex 实现细节，后续版本变更可能需要适配。
