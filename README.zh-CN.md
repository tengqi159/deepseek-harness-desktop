<div align="center">

# DeepSeek Harness for macOS

#### 补上上游没做的原生层

**上游 DeepSeek Harness 会规划、会写代码、会调工具；这个桌面伴侣让它真正接手你 Mac 上的活——把研究文件拖进来、安全截取一个窗口、只附加一个 App 做 Computer Use。**

简体中文 · [English](README.md)

<img alt="CI" src="https://github.com/tengqi159/deepseek-harness-macos/actions/workflows/ci.yml/badge.svg">
<img alt="源码预览版" src="https://img.shields.io/badge/status-source_preview-f59e0b">
<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">

<img src="docs/images/hero-files.png" alt="把研究文件拖入 DeepSeek Harness macOS 桌面伴侣" width="920">

<sub>基于真实产品界面制作的脱敏演示，不含用户文件、账号或 API key。</sub>

</div>

## ✨ 为什么会有这个项目

上游 Harness 已经是一个很强的 Agent 运行时：规划、编码、工具调用、子 Agent、工作流都不缺。但在 Mac 上，它止步于浏览器标签页——而你的真实工作都在 Finder、“预览”和其他 App 里：论文躺在 Finder，结果图开在“预览”，需要帮忙的界面又在另一个 App。

这个桌面伴侣补上的就是这一段原生层。它不 fork、也不重写上游，而是在承载经过验证的上游运行时之上，加进 Mac 原生 Agent 真正需要的东西：

<table align="center">
<tr>
<td align="center" width="33%"><b>📁 研究文件拖放即用</b><br>PDF、Office、Markdown、代码、数据、图片和混合批次变成可移除的受管卡片，原文件保持不动。</td>
<td align="center" width="33%"><b>🧾 不“装懂”的本地工作台</b><br>有边界的文本提取、带页码 PDF 搜索、指定页渲染、可选 OCR。模型看到了什么，永不夸大。</td>
<td align="center" width="33%"><b>📸 Appshot <code>⌘⇧⌥2</code></b><br>一次性截取最前窗口，文字与像素双重脱敏，先预览后保存。是快照，不是共享屏幕。</td>
</tr>
<tr>
<td align="center" width="33%"><b>🖱️ 受控 Computer Use</b><br>只附加一个确切 App；辅助功能 + 内存级 OCR 驱动受限操作，绑定进程生命周期与最新窗口快照。</td>
<td align="center" width="33%"><b>🧭 失败即降级的路由</b><br>仅验证过的提供方/模型组合保留原生图片通道；拿不准就回退到受管引用，不假装。</td>
<td align="center" width="33%"><b>🔒 验证过的上游</b><br>只接受钉版、摘要校验的运行时，来源未知的构建直接拒绝。</td>
</tr>
</table>

> [!IMPORTANT]
> **非官方源码预览版。** 这是独立的社区项目，不隶属于 DeepSeek，也未获得其背书。我们发布的是源码，而不是 Apple 公证过的二进制——哪些条件挡在公开下载前面、发布前要逐项验证什么，都写在[分发说明](docs/DISTRIBUTION.md)里。请从源码本机构建，并认真检查自己开启的权限。

## 💬 它解决的是这些日常琐事

### “比较这几篇论文，并告诉我答案对应哪一页。”

把 PDF、Markdown、源代码、Office 文件、图片或混合批次从 Finder 拖进来。它们会成为绑定当前会话、随时可移除的草稿卡片，原文件保持不变。

PDF 与 Office 文件保存在本机受管区域。任务需要时，工具可以提取有边界的文本、带页码搜索 PDF，或渲染指定页面。这和“当前模型原生理解了整份原文件”不是一回事——而且我们把这件事明明白白写出来。

只有精确的提供方和模型已经验证支持图片时，纯图片批次才会保留上游原生图片通道。未知或纯文本路由会回退为受管引用，不会假装模型看到了像素。

文件限额与安全规则详见：[研究文件桥接](integration/ARTIFACT_BRIDGE.md)与[隐私说明](docs/PRIVACY.md)。

### “让 Agent 看这一个窗口，但别把整个桌面和旁边的密码也截进去。”

Appshot（`⌘⇧⌥2`）只捕获当时最前方的准确窗口，在本机同时遮盖文字和像素里的疑似秘密，再让你预览。确认前不会保存；是否发送给模型也始终由你明确决定。

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

## 🧭 三条铁律：模型和工具不“装懂”

内容到模型之前，只有三条铁律：

| # | 铁律 | 具体做法 |
| --- | --- | --- |
| 1 | **能力至上** | 路由只看已验证的能力表，不看别的。DeepSeek rc.6 按纯文本处理：本地提取或 OCR 绝不包装成“原生视觉”；Kimi 路由仅当所选模型明确声明支持图片时，才保留原生图片块。 |
| 2 | **失败即降级** | 能力未知、加载中、不匹配或过期，一律回退到受管文件——拿不准就少做，而不是装懂。 |
| 3 | **不承诺没做的** | 视频上传、音频转写尚未上线。插件健康展示的只是启动发现，不保证永久在线，也不保证模型必然调用已注册工具。 |

API key 请在 **Harness 设置 → Models** 中配置；它们不会写入本仓库或模型能力表。

## 🤝 这个桌面伴侣贡献了什么

| 使用体验 | 来自哪里 |
| --- | --- |
| 会话、工作区、模型设置、命令、计划、目标、子 Agent、工作流和任务 | 上游 `@deepseek-ai/dsh` |
| 提供方适配（包括受支持的 Kimi 路由）以及 Skill / MCP 框架 | 上游 `@deepseek-ai/dsh` |
| 原生 App 窗口、工具栏、生命周期，以及无需单独浏览器标签 | 本桌面伴侣 |
| Finder 文件拖放、受管研究文件、PDF / Office 助手与可移除草稿卡片 | 本桌面伴侣 |
| Appshot、精确 App 附加、受限 Computer Use、能力路由与插件健康 | 本桌面伴侣 |

桌面伴侣承载并扩展经过验证的上游客户端，不替代、也不重写 Harness。

## 🛠️ 从源码快速开始

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

## 🔐 权限与数据边界

| 权限 / 数据 | 用来做什么 | 不会做什么 |
| --- | --- | --- |
| 辅助功能 | 读取已附加 App 的语义控件并执行受限操作 | Harness 不能自动授予，也不会因此自动获得所有 App 的控制权 |
| 屏幕录制 | Appshot 与可选的当前窗口 OCR | 不会变成持续远程看屏幕 |
| 模型提供方 API | 对话，以及你或工作流选择发送的内容 | 选择发送提取内容后，不能再把它视为只留在本机 |
| 受管文件 | Application Support 下的本地研究工作流 | 不修改原文件；移除草稿卡片不会删除受管副本 |

Harness 只在随机回环端口中运行，并使用非持久 `WKWebView`。这能减少意外冲突，但不是完整的身份验证或沙箱边界。控制敏感 App 前，请阅读[隐私说明](docs/PRIVACY.md)与[安全策略](SECURITY.md)。

## 🗺️ 状态与路线图

“只有源码预览版”是刻意做出的选择，不是疏忽：在它配得上公开二进制之前，我们不会发布。

| 现在（源码预览版） | 路线图下一步 |
| --- | --- |
| 没有经过 Apple 公证的 `.dmg`、`.zip` 或通用下载版 App | Developer ID 签名 + Apple 公证 |
| 已测试 Apple Silicon + macOS 14+；暂不宣称 Intel | 全新 Mac 上的 Gatekeeper 验收 |
| 只接受经过验证的上游 rc.6 运行时与摘要 | 更广的架构验证 |
| 主界面仍是 `WKWebView` 中的上游 Web UI，不是完整 SwiftUI 重写 | |
| 没有通用视频上传、音频转写、自动权限授予、保证插件调用，也不等同于 Codex 视觉电脑控制 | |

公开二进制必须通过的完整清单，见[分发说明](docs/DISTRIBUTION.md)。

## 🧪 构建与测试依据

CI 负责编译和确定性检查。仓库还包含研究文件、Appshot、原生文件拖放、真实 `WKWebView` 拖放生命周期，以及一次性窗口 Computer Use 测试。完整研究文件测试需要 [`uv`](https://docs.astral.sh/uv/)；真实 OCR、权限和窗口操作仍须在已登录的 macOS 会话中本地验收。

```bash
swift build --package-path app -c release
./scripts/test_artifact_bridge.sh
./scripts/test_appshot_qa.sh
./scripts/test_native_file_drop.sh
./scripts/test_webview_file_drop.sh
./scripts/test_app_bridge_e2e.sh
```

## 📚 继续了解

<div align="center">

<a href="docs/PRIVACY.md">🔒 隐私说明</a> ·
<a href="SECURITY.md">🛡️ 安全策略</a> ·
<a href="docs/DISTRIBUTION.md">📦 分发说明</a> ·
<a href="integration/ARTIFACT_BRIDGE.md">🧾 研究文件桥接</a> ·
<a href="app/APP_BRIDGE_TESTING.md">🖱️ Computer Use 测试</a> ·
<a href="CONTRIBUTING.md">🤝 参与贡献</a>

</div>

## ⚖️ 许可证与致谢

本桌面伴侣源码采用 [MIT License](LICENSE)。上游归属与商标边界见 [NOTICE](NOTICE.md)。欢迎提交范围清晰的 Issue 和 Pull Request；安全问题请按照 [SECURITY.md](SECURITY.md) 私下报告。
