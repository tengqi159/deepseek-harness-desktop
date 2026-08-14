<div align="center">

# HarnessMate

#### DeepSeek Harness 的 Mac 拍档

**DeepSeek Harness 会思考，但它在你的 Mac 上没有手。HarnessMate 给它一双——拿论文、看窗口、操作一个 App，全都听你的。**

简体中文 · [English](README.md)

<img alt="CI" src="https://github.com/tengqi159/harness-mate/actions/workflows/ci.yml/badge.svg">
<img alt="源码预览版" src="https://img.shields.io/badge/status-source_preview-f59e0b">
<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">

<img src="docs/images/hero-files.png" alt="把研究文件拖入 HarnessMate" width="920">

<sub>基于真实产品界面制作的脱敏演示，不含用户文件、账号或 API key。</sub>

</div>

## ✨ 这个项目怎么来的

每次开 Harness，剧情都差不多：Agent 想法一套一套的，但论文躺在 Finder，结果图开在“预览”，它要操作的 App 在隔壁窗口。于是我们复制路径、手动截图、用文字描述界面，折腾得烦了，干脆把中间这层做出来。HarnessMate 不改写上游，它跑着验证过的上游运行时，再把 Mac 原生 Agent 缺的那几样补上：

<table align="center">
<tr>
<td align="center" width="33%"><b>📁 研究文件拖放即用</b><br>PDF、Office、Markdown、代码、数据、图片，拖进来就是卡片。原文件在哪里，还在哪里。</td>
<td align="center" width="33%"><b>🧾 不“装懂”的文件工作台</b><br>提取、带页码搜索、渲染页面、OCR，做了什么就说什么——绝不吹成“模型全看懂了”。</td>
<td align="center" width="33%"><b>📸 Appshot <code>⌘⇧⌥2</code></b><br>只截最前窗口，秘密先打码再给你预览；截图前它还会先把自己藏起来。</td>
</tr>
<tr>
<td align="center" width="33%"><b>🖱️ 受控 Computer Use</b><br>只绑定你选的那一个 App，点到为止；重要操作停下来先问你。</td>
<td align="center" width="33%"><b>🧭 失败即降级的路由</b><br>图片只有模型真能看时才给模型看；拿不准就回退到受管引用，不假装。</td>
<td align="center" width="33%"><b>🔒 验证过的上游</b><br>只认钉版、摘要校验过的运行时，来路不明的直接不启动。</td>
</tr>
</table>

> [!IMPORTANT]
> **非官方源码预览版。** HarnessMate 是独立的社区项目，和 DeepSeek 没有隶属关系，也没拿过任何背书。我们发的是源码，不是公证过的二进制；一份公开下载版要满足哪些条件，都写在[分发说明](docs/DISTRIBUTION.md)里。请从源码本机构建，自己开的权限自己过一遍——你的 Mac 你比我们懂。

## 💬 三件不再烦你的事

### “比较这几篇论文，并告诉我答案对应哪一页。”

把 PDF、Markdown、源代码、Office 文件、图片或混合批次从 Finder 拖进来。它们会成为绑定当前会话、随时可移除的草稿卡片，原文件保持不变。

PDF 和 Office 留在本机受管区域。任务需要时，工具提取有边界的文本、按页码搜 PDF、渲染真正用到的页面。注意这里的措辞：这都不等于“模型读懂了你的文件”。发生了什么，我们就说什么，多一个字都不加。

图片同理。只有精确到提供方和模型都验证过支持图片，纯图片批次才走原生图片通道；拿不准的一律回退成受管引用。不装。

细则与限制：[研究文件桥接](integration/ARTIFACT_BRIDGE.md)和[隐私说明](docs/PRIVACY.md)。

### “让 Agent 看这一个窗口，但别把整个桌面和旁边的密码也截进去。”

Appshot（`⌘⇧⌥2`）一次性截下最前窗口，把文字和像素里的疑似秘密都打上码，再给你预览。确认前不保存；你不点头，任何东西都到不了模型。

一个我们挺得意的小细节：截图前 App 会先把自己藏起来，所以你的图里永远不会出现“截图工具正在截图”。

Appshot 是一次性、可检查的快照，不是持续共享屏幕。

### “帮我看看这个软件哪里有问题，但重要操作先停下来问我。”

附加一个正在运行的 App——你挑的那一个。HarnessMate 读它的辅助功能树，需要时在内存里做 OCR，然后执行受限的点击、输入、滚动、选择或等待。

绑定的是那个进程、那个生命周期、那张最新窗口快照，不是“整个桌面随便点”。登录界面、钥匙串、密码管理器、安全输入框、系统安全界面：拦。疑似秘密：脱敏。自绘界面可能藏过这些防护，没有万无一失，预览请自己再扫一眼。

涉及发送、发布、购买、删除、安装、改权限，内置安全规则会让 Agent 停下来，当次问你。Computer Use 的截图不出内存、不会作为图片块发给模型；受限的辅助功能 / OCR **文字**可能进入模型上下文和本机会话记录。

<p align="center">
  <img src="docs/images/app-control.png" alt="为 HarnessMate 附加一个 Mac App 并进行受限操作" width="920">
</p>

<p align="center"><sub>基于真实产品界面制作的脱敏演示，不含用户文件、账号或 API key。</sub></p>

这是基于语义控件和 OCR 的辅助操作，不是 Codex 式的端到端视觉控制；有些自绘界面不配合。这种事我们宁可把话说无聊，也不想吹过头。

## 🧭 说句实话：模型看到什么，就是什么

不少 Agent 工具会悄悄暗示“模型看过了”，其实没有。我们不做这种事。三条规矩，没有例外：

| # | 铁律 | 具体做法 |
| --- | --- | --- |
| 1 | **只认能力表，不靠感觉** | 路由只看已验证的能力表，别的都不看。DeepSeek rc.6 是纯文本路线，句号——本地提取、OCR 都不会被包装成“原生视觉”；Kimi 只有当所选模型明确声明支持图片时，才保留原生图片块。 |
| 2 | **拿不准，就少做** | 未知、加载中、不匹配、过期，一律回退到受管文件。这里猜错一次，丢掉的信任比省下的事多。 |
| 3 | **没做的，不承诺** | 视频上传、音频转写没做，清单里就不写。插件健康显示的只是启动发现，不是终身保修；模型注册了工具，也不保证一定调用。 |

API key 在 **Harness 设置 → Models** 里配。不进仓库，也不进能力表。

## 🤝 谁干了什么

| 使用体验 | 来自哪里 |
| --- | --- |
| 会话、工作区、模型设置、命令、计划、目标、子 Agent、工作流和任务 | 上游 `@deepseek-ai/dsh` |
| 提供方适配（包括受支持的 Kimi 路由）以及 Skill / MCP 框架 | 上游 `@deepseek-ai/dsh` |
| 原生 App 窗口、工具栏、生命周期，以及无需单独浏览器标签 | HarnessMate |
| Finder 文件拖放、受管研究文件、PDF / Office 助手与可移除草稿卡片 | HarnessMate |
| Appshot、精确 App 附加、受限 Computer Use、能力路由与插件健康 | HarnessMate |

HarnessMate 承载并扩展经过验证的上游客户端。不替代它，也不冒充它。

## 🛠️ 从源码快速开始

当前目标：桌面伴侣 **1.4.1（build 6）**、上游 **`@deepseek-ai/dsh@0.1.0-rc.6`**、macOS **14+**、Apple Silicon。Intel 暂未验证。

需要 Xcode Command Line Tools（Swift 5.10+）、Node.js 22 与 npm。

```bash
npm install -g @deepseek-ai/dsh@0.1.0-rc.6 --registry=https://registry.npmjs.org
dsh --version
git clone https://github.com/tengqi159/harness-mate.git
cd harness-mate
./scripts/build_and_run.sh package
```

为什么钉死版本？上游预览版改插件槽位、改界面是常事，“兼容 rc.6”是我们能兑现的承诺，“你装啥都行”是赌博。所以 `dsh --version` 必须输出 `0.1.0-rc.6`，App 还会校验可执行文件摘要，来路不明的构建直接拒绝。

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

## 🗺️ 为什么还没有 .dmg

没有可下载的二进制——故意的。没签名、没公证的包，到了别人的 Mac 上会被 Gatekeeper 直接拦下；发出去不是发布，是挖坑。完整清单在[分发说明](docs/DISTRIBUTION.md)里，每一项打勾的那天，我们自然就发了。

| 现在（源码预览版） | 路线图下一步 |
| --- | --- |
| 没有经过 Apple 公证的 `.dmg`、`.zip` 或通用下载版 App | Developer ID 签名 + Apple 公证 |
| 已测试 Apple Silicon + macOS 14+；暂不宣称 Intel | 全新 Mac 上的 Gatekeeper 验收 |
| 只接受经过验证的上游 rc.6 运行时与摘要 | 更广的架构验证 |
| 主界面仍是 `WKWebView` 中的上游 Web UI，不是完整 SwiftUI 重写 | |
| 没有通用视频上传、音频转写、自动权限授予、保证插件调用，也不等同于 Codex 视觉电脑控制 | |

## 🧪 质量：用测试说话

CI 负责编译和确定性检查；仓库里还躺着研究文件桥、Appshot、原生文件拖放、真实 `WKWebView` 拖放生命周期、一次性窗口 Computer Use 的固定夹具测试。完整研究文件测试需要 [`uv`](https://docs.astral.sh/uv/)；真实 OCR、权限、窗口操作，还是得靠真人在登录的 Mac 上验收——自动化没法给自己授权辅助功能，说真的，也不该给。

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

如果它帮你省下过一个下午，欢迎开个 issue 说一声——那就是我们全部的推广预算。
