# 接入更多桌面软件

接入程序负责从目标软件的官方接口、插件事件或可靠本地记录取得用量，再写成一个 JSON 文件。浮窗只读取这个文件，不执行其中的命令。这样新增 WorkBuddy、Cursor 或其他软件时，可以独立开发转换程序，不必每次重写界面。本项目当前提供通用接口，**尚未提供这些软件的专用转换程序**。

内置 Codex、OpenCode 读取器属于直接读取本地记录的实现。其他软件也可以增加薄读取器，实现 `SnapshotReader.poll()`，再在 `UsageSources` 中注册；通常先用 JSON 接入验证数据最省事。

## 从真实数据开始

1. 先确认来源能提供实际计量和稳定任务编号。只有文字长度、窗口标题或模型名称不足以计算 Token。不要读取密码、Cookie 或登录令牌来猜测私有接口。
2. 分别确认累计数、单次调用数、输入是否含缓存、输出是否含推理，以及父任务是否已经包含子代理。若父任务已经包含子代理，必须先取得各自独立用量再汇总；不能把包含关系重复相加。
3. 用一次主任务调用、一次子代理调用、一次重复事件、一次任务切换核对。记录缺失就保留未知，不补成零。
4. 只有真实软件读数与切换通过，才把兼容表标为已验证。软件无法提供当前任务编号时，先支持手动选择。

当前调研入口：[OpenCode 官方服务接口](https://opencode.ai/docs/server/)、[OpenCode 计量归一化源码](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/session.ts)、[Cursor 团队管理接口](https://cursor.com/docs/account/teams/admin-api)、[WorkBuddy 第三方应用](https://open.workbuddy.cn/docs/third-party-app)。团队接口需要相应权限，不等于个人账号通用接口；WorkBuddy 的消息历史接口也不等于已确认存在 Token 明细。

Claude Desktop 本机办公任务记录中的助手消息可能多次重复，而且片段用量不等于结束报告。其正确去重和子代理覆盖范围尚待验证，不能直接用片段求和。

## 文件格式 v1

在浮窗设置中选择“打开软件接入目录”，把接入文件原子替换写入其中。Mac 默认目录是 `~/Library/Application Support/Codex Usage Float/adapters/`；Windows 是 `%APPDATA%\AI Usage Float\adapters\`。文件名必须以 `.json` 结尾；每个文件最多 1 MB、1000 个任务，最多加载 32 个文件。接入程序先写同目录临时文件再重命名，避免浮窗读到半个文件。

```json
{
  "schemaVersion": 1,
  "id": "example-desktop",
  "name": "Example Desktop",
  "bundleIDs": ["org.example.desktop"],
  "processNames": ["ExampleDesktop.exe"],
  "updatedAt": "2026-09-15T00:00:00Z",
  "activeSessionID": "task-1",
  "childrenComplete": true,
  "sessions": [
    {
      "id": "task-1",
      "title": "示例任务",
      "total": {"input": 1000, "output": 100, "cached": 600, "written": 0},
      "last": {"input": 1000, "output": 100, "cached": 600, "written": 0},
      "round": {"input": 1000, "output": 100, "cached": 600, "written": 0},
      "roundStartedAt": "2026-09-15T00:00:00Z",
      "updatedAt": "2026-09-15T00:00:00Z",
      "running": false
    }
  ]
}
```

`id` 只允许小写字母、数字、连字符，同一目录不能重复。`bundleIDs` 是 macOS 软件标识，不是显示名称；必须填实际软件标识；Windows 通过可选 `processNames` 指定进程名，例如 `ExampleDesktop.exe`。Windows 专用接入也要保留 `bundleIDs: []`，至少提供一类标识。不要占用 Codex/OpenCode 的标识，它们由内置读取器处理。时间使用带时区的 ISO 8601。同一文件可以供两个系统使用，但用量与当前任务必须来自运行该文件的那台电脑，不能把另一台电脑的活动任务当成本机任务。

| 字段 | 约定 |
| --- | --- |
| `total` | 本任务自己已发生的累计值，不含任何子代理；重复写同一快照不增加用量 |
| `input` | 包含缓存读取与写入的输入总数 |
| `output` | 包含推理的输出总数；`reasoning` 是其中的子项 |
| `cached` / `written` | 输入中的缓存读取 / 写入子项；没有提供就省略或设为 null |
| `parentID` | 子代理所属任务编号；可多层嵌套，所有成员必须在同一文件内 |
| `childrenComplete` | 仅在确认已包含所有后代时为 true；否则完整合计显示未知，可查看已取得明细 |
| `round` / `roundStartedAt` | 本轮增量与起点；每个子代理必须按主任务起点提供增量。不同起点不相加，未活动的成员应提供已确认的零增量 |
| `activeSessionID` | 软件当前真正展示的任务编号；切换时立即更新，无法确认时省略或置 null |
| `updatedAt` | 接入程序最近成功确认状态的时间；超过 15 秒不再自动沿用当前任务，手动模式保留数字并显示过期提示 |

负数、重复任务编号、格式错误的文件会拒绝加载。循环父子关系按任务编号去重，不会无限递归。缺失的字段显示“—”；单项为零才写 0。接入失败时不能用心跳更新时间掩盖旧状态。正常工作时建议每 2～5 秒写一次。

可选账户套餐快照（最多两个窗口）独立写在顶层 `quota`，绝不对子代理相加：

```json
{
  "plan": "example-plan",
  "updatedAt": "2026-09-15T00:00:00Z",
  "windows": [{"used": 40, "minutes": 300, "resets": 1789434000}]
}
```

`used` 是已使用百分比（0～100），`minutes` 是额度窗口时长，`resets` 是秒级 Unix 时间，可省略。积分余额、美元或人民币金额不能直接塞进百分比；没有这种额度信息就不提供 `quota`。

## 验证接入

运行 `python3 examples/bridge-demo.py` 会在标准输出产生一份明确标为合成示例的新鲜快照，不写入用户配置，也不调用任何软件或模型。可以保存到临时目录，用构建后的程序验证：

```sh
python3 examples/bridge-demo.py > /tmp/usage-bridge-example.json
"build/Codex Usage Float.app/Contents/MacOS/CodexUsageFloat" --bridge-check /tmp/usage-bridge-example.json
```

真实接入安装后，可手动选择其任务核对用量，再验证 A→B→A 切换及停止接入程序后的清空行为。合成文件使用不存在的 `org.example.desktop`，不会绑定到任何已安装软件。不要把示例中的模拟数字改名伪装成真实应用读数。


## 可选的逐次调用与费用（v0.4）

`schemaVersion` 仍为 1，旧接入文件继续提供 Token；未提供下列字段时，费用显示未知。每个 session 可增加 `callsComplete: true` 和 `calls`。每项调用必须有本任务内唯一的 `id`、准确的 `model`、ISO 8601 `createdAt`、同现有口径的 `tokens`，以及可选的原厂 `provider`（例如 `anthropic`）。调用的输入包含读写缓存，输出包含推理；只能提供本任务自己的调用，不能复制子任务调用。最多 5,000 项，文件仍受 1 MB 限制。

```json
{
  "callsComplete": true,
  "calls": [{
    "id": "request-1", "provider": "anthropic", "model": "claude-sonnet-5",
    "createdAt": "2026-09-20T10:00:00Z",
    "tokens": {"input": 100000, "output": 1000, "cached": 60000, "written": 10000, "reasoning": 0}
  }]
}
```

完整性声明之外，调用合计还必须与 session 的累计计量吻合。若缺记录，保留已知部分并显示 `+ ?`。费用本轮按主任务的 `roundStartedAt` 筛选所有后代调用；最近调用只展示主任务，且需与 `last` 计量相符。未知模型禁止擅自改写成相近型号。

价目契约：`pricing.json` 的 `schemaVersion: 1`、`currency: "USD"`、`verifiedAt` 和 `models`。每行包含 `provider`、精确 `model`、明确的 `aliases`、官方 `source` URL、`note`，以及 `rates: [普通输入, 缓存读取, 缓存写入, 输出]`，单位均为 USD/百万 Token。无此计费项用 `null`；若缓存写入沿用普通输入价，填写相同单价。分档模型同时提供正整数 `threshold` 与 `longRates`，单次输入严格大于阈值才用长上下文价。未知或无效价目不能隐式退回 OpenAI 的价格。自定义文件替换内置目录，并明确标注为自定义；建议从内置文件复制编辑，保留核对日期和真实来源。

Mac 自定义文件：`~/Library/Application Support/Codex Usage Float/pricing.json`；Windows：`%APPDATA%/AI Usage Float/pricing.json`。改完重启浮窗。价目只用于离线参考，程序不验证中转服务实际使用的模型，也不把内置价格视作历史发票。
