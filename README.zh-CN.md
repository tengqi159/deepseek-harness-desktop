# 让 DeepSeek Harness 真正住进你的 Mac

<p align="center">
  简体中文 · <a href="README.md">English</a>
</p>

<p align="center"><strong>把 Mac 里已经存在的论文、代码、截图和一个你选中的 App，带进你正在使用的 Harness 对话。</strong></p>

<p align="center">
  <img src="docs/images/hero-files.png" alt="把研究文件拖入 DeepSeek Harness macOS 桌面伴侣" width="920">
</p>

<p align="center"><sub>基于真实产品界面制作的脱敏演示，不含用户文件、账号或 API key。</sub></p>

<p align="center">
  <a href="https://github.com/tengqi159/deepseek-harness-macos/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/tengqi159/deepseek-harness-macos/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="源码预览版" src="https://img.shields.io/badge/status-source_preview-f59e0b">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">
</p>

上游 Harness 已经能规划任务、编写代码和调用工具。但在 Mac 上，真正的麻烦往往发生在网页界面之外：论文躺在 Finder，结果图开在“预览”，需要帮忙的界面又在另一个 App。这个桌面伴侣就是为了补上这段距离；它保留上游 Harness，只把缺少的原生 Mac 工作流接进来。

> [!NOTE]
> **非官方源码预览版。** 这是社区项目，不隶属于 DeepSeek，也未获得其背书。目前没有经过 Apple 公证的公开下载版，请从源码本机构建，并认真检查自己开启的权限。Harness 对话体验仍由单独安装的上游软件包提供。

## 它解决的是这些日常琐事

### “比较这几篇论文，并告诉我答案对应哪一页。”

把 PDF、Markdown、源代码、Office 文件、图片或混合批次从 Finder 拖进来。它们会成为绑定当前会话、随时可移除的草稿卡片，原文件保持不变。

PDF 与 Office 文件保存在本机受管区域。任务需要时，工具可以提取有边界的文本、带页码搜索 PDF，或渲染指定页面。这和“当前模型原生理解了整份原文件”不是一回事。

只有精确的提供方和模型已经验证支持图片时，纯图片批次才会保留上游原生图片通道。未知或纯文本路由会回退为受管引用，不会假装模型看到了像素。

文件限额与安全规则详见：[研究文件桥接](integration/ARTIFACT_BRIDGE.md)与[隐私说明](docs/PRIVACY.md)。

### “让 Agent 看这一个窗口，但别把整个桌面和旁边的密码也截进去。”

Appshot（`⌘⇧⌥2`）只捕获当时最前方的准确窗口，在本机遮盖疑似秘密，再让你预览。确认前不会保存；是否发送给模型也始终由你明确决定。

Appshot 是一次性、可检查的快照，不是持续共享屏幕。

### “帮我看看这个软件哪里有问题，但重要操作先停下来问我。”

先附加一个确切、正在运行的 Mac App。Harness 可以读取这个 App 当前窗口的辅助功能语义信息，按需做本地 OCR，并执行受限的点击、输入、滚动、选择或等待。

附加关系绑定到确切进程、进程生命周期和最新窗口快照。已知的登录、钥匙串、密码管理器、安全输入框及系统安全界面会被阻止，疑似秘密会被脱敏；但这些防护无法识别每一种自绘敏感界面。

对于发送、发布、购买、删除、安装、修改权限等重要动作，内置安全说明会要求 Agent 停下来，当次向你明确确认。Computer Use 的截图只留在内存中，不会作为图片块发给模型；受限的辅助功能 / OCR **文字**可能进入模型上下文和本机会话记录。

<p align="center">
  <img src="docs/images/app-control.png" alt="为 DeepSeek Harness 附加一个 Mac App 并进行受限操作" width="920">
</p>

<p align="center"><sub>基于真实产品界面制作的脱敏演示，不含用户文件、账号或 API key。</sub></p>

这是基于语义控件和 OCR 的辅助操作，**不等同于 Codex 那种端到端视觉电脑控制**；部分自绘界面可能无法使用。

## 模型和工具不“装懂”

- 已验证的 DeepSeek rc.6 路由按纯文本处理；本地提取或 OCR 不会被包装成“原生视觉”。
- 上游 Kimi 路由只有在所选模型明确声明支持图片时，才可能保留原生图片块。
- 能力未知、加载中、不匹配或过期时，保守回退到受管文件。
- 当前没有视频上传和音频转写。
- “插件健康”展示的是启动发现结果，不保证插件之后永远在线。模型可能自动选择已注册工具，但不保证每次都会调用。

API key 请在 **Harness 设置 → Models** 中配置；它们不会写入本仓库或模型能力表。

## 上游 Harness 与本桌面伴侣的分工

| 使用体验 | 来自哪里 |
| --- | --- |
| 会话、工作区、模型设置、命令、计划、目标、子 Agent、工作流和任务 | 上游 `@deepseek-ai/dsh` |
| 提供方适配（包括受支持的 Kimi 路由）以及 Skill / MCP 框架 | 上游 `@deepseek-ai/dsh` |
| 原生 App 窗口、工具栏、生命周期，以及无需单独浏览器标签 | 本桌面伴侣 |
| Finder 文件拖放、受管研究文件、PDF / Office 助手与可移除草稿卡片 | 本桌面伴侣 |
| Appshot、精确 App 附加、受限 Computer Use、能力路由与插件健康 | 本桌面伴侣 |

桌面伴侣承载并扩展经过验证的上游客户端，不替代、也不重写 Harness。

## 从源码快速开始

当前目标：桌面伴侣 **1.4.1（build 6）**、上游 **`@deepseek-ai/dsh@0.1.0-rc.6`**、macOS **14+**、Apple Silicon。Intel 暂未验证。

需要 Xcode Command Line Tools（Swift 5.10+）、Node.js 22 与 npm。

```bash
npm install -g @deepseek-ai/dsh@0.1.0-rc.6 --registry=https://registry.npmjs.org
dsh --version
git clone https://github.com/tengqi159/deepseek-harness-macos.git
cd deepseek-harness-macos
./scripts/build_and_run.sh package
```

`dsh --version` 必须输出 `0.1.0-rc.6`。桌面伴侣还会校验已验证的可执行文件摘要，来源未知的构建会被拒绝。

打包命令使用 ad-hoc 签名并生成 `outputs/DeepSeek Harness.zip`，不会安装证书或修改钥匙串。

```bash
mkdir -p "$HOME/Applications"
ditto -x -k "outputs/DeepSeek Harness.zip" "$HOME/Applications"
open "$HOME/Applications/DeepSeek Harness.app"
```

首次启动后，请在**设置 → Models** 中配置模型提供方。只保留一份已安装 App，避免 macOS 产生重复权限条目；签名身份变化后，系统也可能要求重新授权。

> [!NOTE]
> App 使用 `~/Library/Application Support/DeepSeek Harness/` 下的独立主目录，不改写全局 npm 软件包。首次设置时，如果 App 专用目标尚不存在，它可能把已有 `~/.dsh` 模型设置与凭据复制到私有主目录，并设置为仅当前用户可读写。

## 权限与数据边界

| 权限 / 数据 | 用来做什么 | 不会做什么 |
| --- | --- | --- |
| 辅助功能 | 读取已附加 App 的语义控件并执行受限操作 | Harness 不能自动授予，也不会因此自动获得所有 App 的控制权 |
| 屏幕录制 | Appshot 与可选的当前窗口 OCR | 不会变成持续远程看屏幕 |
| 模型提供方 API | 对话，以及你或工作流选择发送的内容 | 选择发送提取内容后，不能再把它视为只留在本机 |
| 受管文件 | Application Support 下的本地研究工作流 | 不修改原文件；移除草稿卡片不会删除受管副本 |

Harness 只在随机回环端口中运行，并使用非持久 `WKWebView`。这能减少意外冲突，但不是完整的身份验证或沙箱边界。控制敏感 App 前，请阅读[隐私说明](docs/PRIVACY.md)与[安全策略](SECURITY.md)。

## 当前限制

- 目前只有源码预览版，没有经过 Apple 公证的 `.dmg`、`.zip` 或通用下载版 App。
- 已测试 Apple Silicon + macOS 14 以上；暂不宣称支持 Intel Mac。
- App 只接受经过验证的上游 rc.6 运行时与摘要。
- 主界面仍是 `WKWebView` 中的上游 Web UI，不是完整 SwiftUI 重写。
- 没有通用视频上传、音频转写、自动权限授予、保证插件调用，也不等同于 Codex 视觉电脑控制。

## 构建与测试依据

CI 负责编译和确定性检查。仓库还包含研究文件、Appshot、原生文件拖放、真实 `WKWebView` 拖放生命周期，以及一次性窗口 Computer Use 测试。完整研究文件测试需要 [`uv`](https://docs.astral.sh/uv/)；真实 OCR、权限和窗口操作仍须在已登录的 macOS 会话中本地验收。

```bash
swift build --package-path app -c release
./scripts/test_artifact_bridge.sh
./scripts/test_appshot_qa.sh
./scripts/test_native_file_drop.sh
./scripts/test_webview_file_drop.sh
./scripts/test_app_bridge_e2e.sh
```

## 继续了解

[隐私说明](docs/PRIVACY.md) · [安全策略](SECURITY.md) · [分发说明](docs/DISTRIBUTION.md) · [研究文件桥接](integration/ARTIFACT_BRIDGE.md) · [Computer Use 测试](app/APP_BRIDGE_TESTING.md) · [参与贡献](CONTRIBUTING.md)

## 许可证与致谢

本桌面伴侣源码采用 [MIT License](LICENSE)。上游归属与商标边界见 [NOTICE](NOTICE.md)。欢迎提交范围清晰的 Issue 和 Pull Request；安全问题请按照 [SECURITY.md](SECURITY.md) 私下报告。
