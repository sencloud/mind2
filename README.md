# Mind

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B.svg)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-%5E3.11.1-0175C2.svg)](https://dart.dev/)
[![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20Android-lightgrey.svg)](#支持平台)

Mind 是一个用 Flutter 构建的个人「第二大脑」应用。它把对话、研究、知识库、写作和项目开发放在同一个本地工作台里。

如果你只是想运行应用，不需要先理解整个代码库。安装 Flutter，配置本地 `.env`，拉取依赖，然后启动 Windows 或 Android 目标即可。

如果你想从源码构建、修改或打包 Mind，请继续阅读。

## Mind 能做什么

Mind 面向需要长期收集资料、研究主题、写作笔记，并把 AI 融入日常工作流的人。

当前应用包含：

* 带持久化历史的对话会话。
* 名为 `我的大脑` 的本地知识库目录。
* 主题研究：检索论文、代码、网页和本地参考资料。
* 知识库：管理笔记、文档、媒体、书籍和论文。
* 写作工具：支持文档、书籍和论文草稿。
* 桌面集成：Zotero、Playwright 辅助浏览和项目开发。
* 项目 Agent：可以在应用界面中查看、理解并修改软件工程。

## 支持平台

Windows 是主要目标平台。它使用完整的桌面界面，并支持 Zotero、Playwright、项目开发和自定义窗口控制。

Android 使用移动端界面，包含对话、知识库、研究、知识体系、写作和设置等核心页面。

仓库里的 `scripts/publish.ps1` 也包含 macOS 和 Linux 的发布逻辑，但当前提交的 Flutter 平台目录主要是 Windows 和 Android。

## 快速开始

先安装 Flutter，并确认目标平台可用：

```shell
flutter doctor
```

拉取依赖：

```shell
flutter pub get
```

在项目根目录创建本地 `.env`。这个文件只放在本机，不提交到仓库：

```text
DEEPSEEK_API_KEY=你的 DeepSeek API Key
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-v4-flash
```

运行 Windows 版本。推荐使用脚本，因为它会读取 `.env` 并把配置注入 Flutter：

```shell
powershell -ExecutionPolicy Bypass -File .\scripts\run.ps1
```

运行 Android 版本：

```shell
powershell -ExecutionPolicy Bypass -File .\scripts\run.ps1 -Device android
```

## 从源码构建

构建 Windows Release。推荐使用发布脚本，因为它会读取 `.env`，并把 DeepSeek 配置通过 `--dart-define` 注入构建：

```shell
powershell -ExecutionPolicy Bypass -File .\scripts\publish.ps1 -Platform windows
```

发布脚本会把 Release 产物复制到 `dist/`，并在需要时补充 Windows 运行时 DLL。

如果你手动调用 Flutter 构建，需要自己传入 `--dart-define`：

```shell
flutter build windows --release --dart-define=DEEPSEEK_API_KEY=你的Key
```

创建 zip 发布包：

```shell
powershell -ExecutionPolicy Bypass -File .\scripts\publish.ps1 -Platform windows -Clean -Zip
```

使用 Inno Setup 构建 Windows 安装包：

```shell
powershell -ExecutionPolicy Bypass -File .\scripts\installer.ps1 -Clean -DesktopShortcut
```

## 配置

Mind 会把用户数据保存在源码目录之外。Windows 上默认知识库路径是：

```text
D:\我的大脑
```

你可以在应用设置中修改知识库路径。

部分桌面功能依赖本机工具或服务：

* DeepSeek 默认配置来自本地 `.env`，通过 `scripts/run.ps1` 或 `scripts/publish.ps1` 注入应用。
* `.env` 已被 `.gitignore` 忽略，不要把真实 API Key 写进源码、README 或提交记录。
* Zotero 集成需要本机 Zotero 桌面端在配置端口上可访问。
* Playwright 辅助研究需要通过应用设置安装 Playwright 和 Chromium。
* 项目语义检索需要在设置中配置 Embedding 服务。
* AI 功能使用 OpenAI 兼容的 Chat Completions API。

## 仓库结构

```text
lib/main.dart                 应用入口和服务装配
lib/ui/                       桌面端和移动端页面
lib/services/                 应用服务、研究源、存储和外部集成
lib/services/agent/           Agent 循环、工具、记忆和模型客户端
assets/icon/                  应用图标资源
android/                      Android 平台工程
windows/                      Windows 平台工程
scripts/publish.ps1           发布打包脚本
scripts/installer.ps1         Windows 安装包脚本
scripts/run.ps1               本地运行脚本，负责读取 .env
tool/make_ico.dart            图标生成辅助工具
```

## 开发说明

生成文件和本地构建产物会被忽略。需要时可以通过 `flutter pub get`、`flutter build` 或上面的脚本重新生成。

应用仍在快速演进。改动应尽量小，提交前运行 `flutter analyze`，并优先使用符合现有服务和页面结构的简单 Flutter/Dart 代码。
