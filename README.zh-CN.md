# DeepSeek Harness Desktop

<p align="center">
  简体中文 · <a href="README.md">English</a>
</p>

<p align="center"><strong>DeepSeek Harness 的桌面客户端，跑在 Apple Silicon（M 系列）Mac 上。</strong></p>

<p align="center">
  <img src="docs/images/hero-files.png" alt="把研究文件拖入 DeepSeek Harness Desktop" width="920">
</p>

<p align="center"><sub>基于真实产品界面制作的脱敏演示，不含用户文件、账号或 API key。</sub></p>

<p align="center">
  <a href="https://github.com/tengqi159/deepseek-harness-desktop/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/tengqi159/deepseek-harness-desktop/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="源码预览版" src="https://img.shields.io/badge/status-source_preview-f59e0b">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-M%20series-111827?logo=apple">
</p>

## 这是什么

DeepSeek Harness Desktop 把上游 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 运行时（`@deepseek-ai/dsh`）装进一个原生 Mac 应用。对话、模型、插件都还是上游的；桌面客户端只补 Mac 上干活缺的那几样：

<p align="center">
  <img src="docs/images/architecture.svg" alt="DeepSeek Harness Desktop 在你的 Mac 与上游 Harness 之间的位置" width="860">
</p>

- 论文、PDF、Office、代码、图片，从 Finder 直接拖进对话，原文件不动。
- Appshot（`⌘⇧⌥2`）：截最前窗口，秘密先打码再预览，确认才保存。
- Computer Use：附加一个 App，用辅助功能 + 本地 OCR 操作；登录、钥匙串、密码框一律拦住。
- Linux 研究服务器的 SSH 远程计算，只走公钥。
- 图片只在提供方/模型确认支持时才发给模型，拿不准就回退，不装懂。

<p align="center">
  <img src="docs/images/app-control.png" alt="为 DeepSeek Harness Desktop 附加一个 Mac App 并进行受限操作" width="920">
</p>

<p align="center"><sub>附加一个 App，客户端只在它内部操作。基于真实产品界面制作的脱敏演示，不含用户文件、账号或 API key。</sub></p>

> [!NOTE]
> 非官方社区项目，目前只有源码预览版，还没有公证过的二进制——见[分发说明](docs/DISTRIBUTION.md)。

## 快速开始

需要 macOS 14+、Apple Silicon（M 系列）、Xcode Command Line Tools（Swift 5.10+）和 Node.js 22。

```bash
npm install -g @deepseek-ai/dsh@0.1.0-rc.6 --registry=https://registry.npmjs.org
git clone https://github.com/tengqi159/deepseek-harness-desktop.git
cd deepseek-harness-desktop
./scripts/build_and_run.sh package
```

客户端钉死 `dsh` 0.1.0-rc.6 并校验摘要，来路不明的构建拒绝启动。首次启动后在 **设置 → Models** 里配置模型提供方。

## 权限

辅助功能和屏幕录制只为上面几个功能服务，由 macOS 授予（不是 App 自己），随时可撤销。详见[隐私说明](docs/PRIVACY.md)。

## 当前限制

- 源码预览版：暂无签名/公证的 `.dmg`、`.zip`。公开二进制卡在 Developer ID 签名和公证上（[分发说明](docs/DISTRIBUTION.md)）。
- 已测 Apple Silicon + macOS 14+；不宣称支持 Intel。
- 主界面仍是 `WKWebView` 里的上游 Web UI。
- 没有视频/音频上传。Computer Use 是语义/OCR 辅助操作，不是 Codex 式视觉控制。

## 文档

[隐私说明](docs/PRIVACY.md) · [安全策略](SECURITY.md) · [分发说明](docs/DISTRIBUTION.md) · [研究文件桥接](integration/ARTIFACT_BRIDGE.md) · [SSH 远程计算](docs/SSH_REMOTE_COMPUTE.md) · [Computer Use 测试](app/APP_BRIDGE_TESTING.md) · [参与贡献](CONTRIBUTING.md)

## 许可证

MIT。上游归属与商标边界见 [NOTICE](NOTICE.md)。
