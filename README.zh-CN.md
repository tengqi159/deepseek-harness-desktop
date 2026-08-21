# DeepSeek Harness Desktop

<p align="center">
  简体中文 · <a href="README.md">English</a>
</p>

<p align="center"><strong>为 DeepSeek Harness 补上一层克制、可靠的 macOS 桌面体验：研究文件、受限 Mac 上下文与可选远程计算。</strong></p>

> [!IMPORTANT]
> **非官方社区项目。** 本项目不隶属、也未获 DeepSeek 维护、赞助或背书；目前是源码预览版，不发布已经 Apple 公证的公开安装包。

<p align="center">
  <a href="https://github.com/tengqi159/deepseek-harness-desktop/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/tengqi159/deepseek-harness-desktop/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="源码预览版 1.7.1" src="https://img.shields.io/badge/source_preview-1.7.1-f59e0b">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-M%20series-111827?logo=apple">
  <img alt="上游 dsh 0.1.1-rc.2" src="https://img.shields.io/badge/upstream_dsh-0.1.1--rc.2-334155">
</p>

## 1.7.1（build 19）这次解决了什么

这版把兼容锁更新到上游 `@deepseek-ai/dsh@0.1.1-rc.2`。保留上游已经修复的 persistent Bash 提示符问题，同时把视觉能力收敛到一个精确、可验证的模型路线，而不是把所有 DeepSeek 模型都标成多模态。

- **Flash Vision 的图片仍然是图片。** 当前实际 provider/model 精确为 `deepseek-official` / `deepseek-v4-flash-vision-exp` 时，PNG、JPEG 或剪贴板图片会交给上游 composer：界面显示缩略图附件，适配器发送临时 image block，而不是写入一行 `[DeepSeek Harness managed attachment …]` 文本。
- **其他路线不装懂。** `deepseek-v4-flash`、`deepseek-v4-pro`、未知模型、PDF、非图片、混合批次和超限图片仍留在本地受管文件路线。OCR 不会自动冒充识图；它只是用户或工作流明确选择的本地工具兜底。
- **已有设置只做定向迁移。** Harness 的设置优先级高于内置模型目录，因此启动时只补齐精确 Vision 模型的 `inputModalities`，保留其他用户模型配置，并留下一个仅本机可读的迁移前备份。
- **迁移到 rc.2 后仍有保障。** Web Profile、附件客户端、能力菜单和 MCP bridge 都按 rc.2 复核；应用启动前会校验上游 launcher、persistent-shell 修复与 DeepSeek 图片序列化器。

### 真实 Vision 冒烟截图

<p align="center">
  <img src="docs/images/vision-smoke-1.7.1.jpg" alt="DeepSeek Harness 显示图片缩略图附件，并由精确 Flash Vision 路线给出视觉描述" width="838">
</p>

截图只使用合成的应用图标和一句演示提问。它展示的是我们需要的契约：输入框与会话中始终保留缩略图，模型描述的是视觉结构，而不是收到一段受管文件引用文字。

## 1.6.9 稳定了什么

这次不再叠加新概念，重点是把每天都会用到的附件路径做稳。

- **切换会话后，图片不会再借用旧会话的模型状态。** 迟到的能力事件不能再把当前 DeepSeek 会话的图片带到错误的上游通路里，避免误报“当前模型不支持图片”。
- **图片可以拖入，也可以粘贴。** 对文字型或未知模型路线，图片会回到绑定当前会话的受管附件，而不是被上游图片输入框拒绝；普通文字粘贴仍然只是普通文字粘贴。
- **删掉的附件不会复活。** 即使回执延迟、页面刷新，或刚创建空白会话，已删除的 PDF、图片、Markdown 卡片都不会重新盖回你的草稿。
- **附件到达时不再因为本地页面重载而丢状态。** 原生壳会把等价的本地 URL 视为同一页面，尾部斜杠或页面内跳转不会清掉正在进入的附件。
- **顶栏更干净。** 文件库、Appshot、附加应用统一收进一个 **上下文与附件** 菜单；直接把文件拖进或粘贴到聊天框，仍是加入当前对话最快的方式。

## 它在上游 Harness 外补了什么

| 你要做的事 | 桌面客户端会怎样帮你 |
| --- | --- |
| 读论文、检查代码、分析数据 | 从 Finder 拖 PDF、Office、Markdown、源代码、数据或图片到对话里。它们会变成可删除、绑定会话的受管引用，原文件不会被修改。 |
| 从文档中找细节 | 模型可以按需调用受限的本地 Artifact 工具，做 PDF 搜索/选页提取、Office 文本提取和安全文本读取；文件被导入不等于模型已经读过它。 |
| 截取一个窗口 | 用 **Appshot**（`⌘⇧⌥2`）做一次性本地截图：OCR/脱敏后先预览，确认才保存。 |
| 让模型协助另一个 Mac App | 先明确附加一个正在运行的 App。辅助功能/OCR 操作只针对它、它的当前窗口和一张新的快照。 |
| 在 Linux 服务器上跑研究任务 | 选择一个 SSH 主机和工作区后，使用受限的远程计算桥。状态查询可以按任务由模型选择；命令、任务、取消和传输都需要紧接着确认。 |

### 关于图片：说清楚，不装懂

图片可以加入对话，但这**不等于**当前模型一定收到原始像素：

- 当前精确选中的 `deepseek-v4-flash-vision-exp` 才会收到原生图片块，并且必须与实时 Host 路由一致。
- 基础 Flash 与 Pro 路线会把图片保留为本地受管上下文，工作流可按需调用本地提取/OCR 工具。
- 选项未知、正在切换、混合文件或能力记录过期时，统一失败关闭到受管文件路线。

这样文件仍然好用，也不会假装 DeepSeek 看到了根本没有发送给它的图片。

## 它怎样和上游配合

<p align="center">
  <img src="docs/images/architecture.svg" alt="原生桌面层在上游 DeepSeek Harness 外管理本地文件、macOS 权限与可选 SSH 桥接的示意图" width="860">
</p>

原生层负责本地文件边界、macOS 权限、一次性 Appshot、精确 App 附加和可选 SSH 选择；上游 Harness 继续负责会话、模型选择、提供方适配器和原有工具框架。

> 架构图和 Vision 冒烟截图均只使用隔离演示数据；个人文档、聊天、凭据与真实 App 上下文绝不会作为仓库图片发布。

## 重要边界

- **目前仅源码预览版。** 没有发布 Developer ID 签名或 Apple 公证的二进制；请在本机自行构建并审阅权限。
- **Apple Silicon / macOS 14+。** 目前不宣称支持 Intel。
- **Computer Use 是受限能力，不是万能控制。** 必须先附加精确的 App；已知的密码、登录、钥匙串和安全界面会被阻止，但任何启发式都不能识别所有自绘敏感界面。
- **SSH 故意保持很窄。** 使用现有系统 OpenSSH/公钥配置；密码、MFA 提示、交互式 TTY、跳板机、转发和自动接受主机密钥不在范围内。工作区只是路由范围，不是服务器端沙箱。
- **没有视频或音频上传。** 本项目不会把当前钉死的 DeepSeek 文字路线变成通用视觉模型服务。

## 从源码构建

需要 macOS 14+、Apple Silicon、Xcode Command Line Tools（Swift 5.10+）、Node.js 22 和指定的上游运行时。

```bash
npm install -g @deepseek-ai/dsh@0.1.1-rc.2 --registry=https://registry.npmjs.org
git clone https://github.com/tengqi159/deepseek-harness-desktop.git
cd deepseek-harness-desktop
./scripts/build_and_run.sh package
```

默认打包使用本地开发用的 ad-hoc 签名；它不是可作为可信公开下载分发的安装包。桌面端会校验预期的上游 `dsh` 版本和可执行文件摘要，无法识别的运行时会被拒绝。

## 这版源码的验证范围

当前源码树已通过 Release 构建，以及以下可重复的本地回归：

- 原生附件生命周期与会话绑定；
- 真实 `WKWebView` 的拖入/粘贴路线；
- Artifact Bridge（17 项）、Appshot（26 项）、一次性 Computer Use fixture（37 项）；
- Remote Host 选择与隔离 fake-SSH bridge（11 个工具共 29 项，**没有连接真实服务器**）。

这些是本地工程验证，不承诺每台 Mac、每个模型提供方或每种服务器配置都完全相同。

## 文档

[隐私说明](docs/PRIVACY.md) · [安全策略](SECURITY.md) · [分发说明](docs/DISTRIBUTION.md) · [研究文件桥接](integration/ARTIFACT_BRIDGE.md) · [SSH 远程计算](docs/SSH_REMOTE_COMPUTE.md) · [Computer Use 测试](app/APP_BRIDGE_TESTING.md) · [参与贡献](CONTRIBUTING.md)

## 许可证

MIT。上游归属与商标边界见 [NOTICE](NOTICE.md)。
