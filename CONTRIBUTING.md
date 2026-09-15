# 参与贡献

欢迎提交问题和小范围改进。本项目是独立社区工具，与 OpenAI 无隶属关系。

## 本地开发

需要 Apple Silicon Mac、macOS 14+ 和 Xcode Command Line Tools。克隆仓库后运行：

```sh
zsh scripts/test.sh
zsh build.sh
```

测试使用临时目录中的合成记录，不需要登录 Codex，也不会读取你的真实对话。AppKit 界面和真实窗口跟随需要在 Mac 桌面会话中另外验证。提交前说明修改解决的问题、验证方式，以及没有验证的环境。

## 代码结构

| 文件 | 职责 |
| --- | --- |
| `Sources/UsageCore.swift` | 只读任务索引、增量解析用量、计算各项指标、保存显示偏好 |
| `Sources/FamilyUsage.swift` | 按主任务时间边界汇总 Codex 后代，保留明细和缺失状态 |
| `Sources/OpenCodeUsage.swift` | 只读 OpenCode 任务/消息计量，归一化缓存与推理口径 |
| `Sources/UsageSources.swift` | 内置来源选择与本地 JSON 接入；校验当前任务及新鲜度 |
| `Sources/ActiveConversation.swift` | 按应用选择当前任务识别方式；无法确认时清空 |
| `Sources/FloatingUI.swift` | 不抢焦点的浮窗、悬停交互、菜单、异步状态更新 |
| `Sources/main.swift` | 应用入口与按需诊断命令 |
| `Tests/main.swift` | 用合成数据验证计量、轮次与标题匹配边界 |

保持改动与当前需求相称。优先复用原生系统能力；新增依赖时解释用途、许可和替换方式。

## 用量与隐私边界

- 累计快照不能相加；缓存读取属于输入，推理属于输出。
- 缺失数据保持未知，不补成 0；切换任务后迟到的旧结果不得回填。
- 无法唯一识别当前对话时，不使用最近活动的任务代替。
- 不提交真实对话日志、数据库、诊断输出、任务标题截图、凭据或用户设置。复现问题请构造匿名的最小样例。
- 涉及自动跟随的改动应测试任务 A → B → A、同名任务、未识别页面、权限缺失和任务切换时的异步结果。

提交内容使用仓库的 MIT 许可证。不要提交你无权公开的代码或素材。

新增软件请先读 [接入说明](docs/ADAPTERS.md)。每个接入必须分别说明计量读取、子代理完整性和真实切换验收；合成测试不能代替软件实测。

Windows 客户端位于 `windows/`。用 `python3 -m unittest discover -s windows -p test_usage.py` 运行不依赖真实账号的计量测试；在 Windows 运行 `windows/build.ps1` 构建独立程序。跨语言计量实现必须遵守同一字段口径，修改算法时同时更新对应测试；界面检查须区分程序化检查和真实软件切换。
