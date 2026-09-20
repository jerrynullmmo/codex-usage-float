# Windows 用量浮窗

这是 AI Desktop Usage Float 的 Windows 客户端。与 Mac 版共用计量约定和软件接入格式，浮窗使用 Windows 的“不激活窗口”标志，悬停展开时保留原软件的键盘焦点。

## 运行

Windows 10/11 x64。解压后运行 `AIUsageFloat.exe`，不需要安装 Python，不需要管理员权限。程序未做商业代码签名，系统可能提示来源未知；请先核对发布页来源和 SHA-256。无需关闭系统防护。

默认自动跟随，只在已接入的软件位于前台时显示。鼠标停留 0.3 秒展开，移开 0.5 秒收起；点击固定，拖动移动，右键设置。可以手动选择本机任务、查看子代理明细、更换浮标显示内容及强调色。手动模式暂停自动跟随并持续显示浮窗。系统托盘提供设置入口，即使浮窗隐藏也可从托盘恢复。退出通过右键菜单，不影响被监控的软件。不自动开机启动。

当前内置读取 Codex 与 OpenCode；其他软件可通过本地 JSON 计量接入。已安装某款软件不等于有足够的计量记录；WorkBuddy、Cursor、Claude 等专用读取仍以根目录兼容表为准。首次没有可确认的对话时不会按“最近活动”猜测。

Codex 自动识别只读窗口标题与应用文档标题，不遍历对话正文；OpenCode 只使用精确窗口标题。软件暴露的是通用标题或存在同名任务时，需手动选择。系统权限不同、软件未暴露辅助功能信息时也可能无法自动跟随。

## 数据与隐私

只读 `%USERPROFILE%\.codex\state_*.sqlite`、对应任务日志、`%USERPROFILE%\.local\share\opencode\opencode.db`。不读取凭据、不发网络请求、不调用模型。输入包含缓存、输出包含推理，子项不能再次相加。

默认递归汇总全部子代理，所有成员“本轮”使用主任务的请求起点。日志缺失或无法确认轮次时显示未知；最近调用只指主任务。分叉继承的记录按软件原有口径展示，不应当成分叉之后新发生的消耗。

偏好位于 `%APPDATA%\AI Usage Float\settings.json`；接入文件位于同目录的 `adapters\`。接入程序用 `processNames` 填写软件进程名，例如 `ExampleDesktop.exe`；Mac 的软件标识填 `bundleIDs`。同一文件可以同时描述两个系统，见 `ADAPTERS.md`。本程序不执行接入代码，接入程序自身的权限由其作者负责。

退出并删除程序即可卸载；若要清除个人偏好，可自行删除设置目录。

## 从源码构建

需 64 位 Python 3.13.7（安装时包含 Tkinter）、PyInstaller 6.14.0 和 Windows 自带的 .NET Framework 4.x 编译器。已有 Python 时建议在项目虚拟环境安装构建依赖：

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r windows/requirements-build.txt
powershell -NoProfile -File windows/build.ps1
```

构建先运行合成计量测试，再编译只读标题探测器，最后打包独立程序。不会安装、启动目标软件或产生模型费用。产物在 `dist/`，附项目许可证及运行时许可声明。应用仅支持 x64；其他架构尚未验收。

命令行诊断：从源码运行 `python windows/usage_float.py --list` 或 `--snapshot <任务编号> --source codex --output <文件路径>`。诊断包含个人任务名称及计量，切勿提交到公开仓库。界面自测 `AIUsageFloat.exe --ui-test <输出路径>` 必须在已登录的交互桌面运行；SSH 会话中的空桌面不能证明真实悬停与焦点行为。


费用估算：详情显示任务、本轮、最近调用的官方 API 参考金额（美元）。设置菜单“API 费用明细与价目”提供未知原因、官方来源、自定义价格入口；浮标可切换显示费用。内置 OpenAI、Anthropic、Google、DeepSeek 价目与 Mac 共用 `prices.json`，模型/缓存/子任务按各调用计算。`+ ?` 表示部分已知金额，不能作为完整账单。采用 Standard/全球文本参考价、Claude 5 分钟写入、DeepSeek 峰价；不含其他服务费，不等于套餐扣费。详见主 README 的口径说明。

顶部“全部累计 / 当前对话”分别查看本机已接入软件的全历史累计与当前任务；全历史包括归档和子代理，每个来源下的会话只加一次。首次扫描有进度提示，之后约每 30 秒更新。说明文字默认收起，可点击展开，窗口高度随之调整。范围、分叉历史重叠与费用估算限制见主 README。
