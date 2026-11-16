<div align="center">

<a href="https://www.drawoffer.com"><img src="docs/images/logo.png" width="112" alt="DrawOffer logo"></a>

<h1>DrawOffer 职绘</h1>

**懂你经历的求职搭档**

改简历、跟进投递、复盘面试、模拟追问，都基于你自己的真实经历，而不是一份通用模板。<br>
本仓库是 DrawOffer 的 **macOS / Windows 原生桌面客户端**。

[官网](https://www.drawoffer.com) · [在线使用](https://www.drawoffer.com/assistant) · [问题反馈](https://github.com/DrawOffer/drawoffer/issues) · [English](README.en.md)

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white)](#-平台支持)
[![Windows](https://img.shields.io/badge/Windows-10%201809%2B-0078D4?style=flat-square&logo=windows&logoColor=white)](#-平台支持)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-F05138?style=flat-square&logo=swift&logoColor=white)](apps/mac)
[![WinUI 3](https://img.shields.io/badge/WinUI%203-native-512BD4?style=flat-square&logo=dotnet&logoColor=white)](apps/windows)
[![Website](https://img.shields.io/badge/website-drawoffer.com-F4743B?style=flat-square)](https://www.drawoffer.com)
[![GitHub stars](https://img.shields.io/github/stars/DrawOffer/drawoffer?style=flat-square&color=ffcb47)](https://github.com/DrawOffer/drawoffer/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/DrawOffer/drawoffer?style=flat-square)](https://github.com/DrawOffer/drawoffer/commits/master)

<img src="docs/images/hero.png" alt="DrawOffer 职绘：懂你经历的求职搭档" width="100%">

</div>

<details>
<summary><b>目录</b></summary>

- [👋 DrawOffer 是什么](#-drawoffer-是什么)
- [✨ 功能亮点](#-功能亮点)
- [🖥 平台支持](#-平台支持)
- [📦 下载](#-下载)
- [🗺 路线图](#-路线图)
- [❓ 常见问题](#-常见问题)
- [🧩 生态](#-生态)
- [🛠 开发](#-开发)
- [🤝 反馈与贡献](#-反馈与贡献)

</details>

## 👋 DrawOffer 是什么

大多数简历工具只管“这一份简历”，模拟面试工具只管“这一场面试”。可求职是一段持续几个月的过程：投了哪些岗位、哪轮面试被问住了、哪段经历最能打，这些信息散落在各处，每用一次 AI 都要从零讲一遍自己。

DrawOffer 把简历、岗位、面试和复盘串成一张属于你的**求职长期记忆**。AI 改简历时知道你投的是什么岗位，出面试题时知道你上次在哪里卡住，复盘时能对照你全部的经历给建议。

<div align="center">
<img src="docs/images/memory-map.png" alt="简历、岗位、模拟面试与真实面试串成一张求职记忆" width="100%">
</div>

桌面客户端用系统原生控件实现了网页版的主要功能，和网页版、微信小程序共用同一个账号与数据。

## ✨ 功能亮点

### 🧠 求职知识图谱：每一场面试都记得

每次模拟面试和真实面试被问到的知识点，都会记进你的知识图谱，并和简历亮点、目标岗位连在一起。哪些还不牢、哪些刚练稳，一眼就能看到；点开任意一个岗位或公司，只看它牵出的考点，直接“聊一聊”或“再练一场”。

<table>
<tr>
<td width="50%"><img src="docs/images/knowledge-graph.png" alt="完整的求职知识图谱"></td>
<td width="50%"><img src="docs/images/knowledge-graph-focus.png" alt="聚焦某个岗位的知识点"></td>
</tr>
<tr>
<td align="center"><sub>全部知识点：来自简历、练习和真实面试</sub></td>
<td align="center"><sub>聚焦一个岗位：只看它要考的内容</sub></td>
</tr>
</table>

### 🏠 首页：上一场练了什么，下一步做什么

<img src="docs/images/home.png" alt="DrawOffer 工作区首页" width="100%">

- 最近一场面试问到了哪些点、哪些已经练到熟练，按时间排开
- 面试日程、模拟面试次数、简历、收藏岗位、资料库一屏看全，点击直达

### 📝 简历模板与编辑器

<img src="docs/images/templates.png" alt="按岗位分类的简历模板库" width="100%">

- 60+ 套中文简历模板，按岗位方向和风格筛选
- 所见即所得的简历纸面，与网页版和 PDF 导出使用同一个渲染器，排版一致
- 导入已有简历（Markdown / Word / PDF），一键换模板、导出 PDF、生成分享链接

### 💼 看到合适的岗位，顺手收下

<img src="docs/images/story-collect-jobs.png" alt="在招聘网站看到岗位就存下来" width="100%">

- 在招聘网站看到就存下来，岗位要求自动整理好
- AI 告诉你哪个岗位和你的经历最对得上；投递看板记录每个岗位走到了哪一步
- 面试日程按日历排开，笔试、面试不撞车

### 🎙 AI 模拟面试与复盘

- 按目标岗位和你的个人经历出题，项目追问、专业基础、自我介绍都会练到
- 文字或语音作答；语音会记录停顿和口头禅，结束后生成复盘报告
- macOS 26 起，语音作答可以在本机离线转写，不经过云端识别

### 📚 资料库与 AI 对话

- 上传面经、笔记、项目文档，AI 出题和改简历时都会参考
- 直接问：“这段项目经历怎么写更好？”“明天字节一面该怎么准备？”

## 🖥 平台支持

| 功能 | macOS | Windows |
| --- | :---: | :---: |
| 首页与知识图谱 | ✅ | ✅ |
| 简历模板 | ✅ | ✅ |
| 简历编辑 | ✅ | 只读预览 |
| 投递看板与面试日程 | ✅ | ✅ |
| AI 模拟面试（文字 / 语音） | ✅ | ✅ |
| 本机语音识别 | ✅ macOS 26+ | — |
| 资料库 | ✅ | ✅ |
| AI 对话 | ✅ | ✅ |

最低系统要求：**macOS 14 Sonoma** / **Windows 10 1809**。

## 📦 下载

安装包正在准备中，发布后会出现在 [Releases](https://github.com/DrawOffer/drawoffer/releases)。现在可以先在 [www.drawoffer.com](https://www.drawoffer.com) 使用网页版，账号与数据和客户端互通。

> [!TIP]
> 点击右上角 **Watch → Custom → Releases**，客户端发布时第一时间收到通知。

## 🗺 路线图

- [x] macOS 原生客户端：首页、简历、模板、投递看板、面试日程、模拟面试、资料库、AI 对话
- [x] macOS 26 本机语音识别
- [ ] 发布 macOS 与 Windows 安装包
- [ ] Windows 简历编辑
- [ ] macOS 14–25 本机语音识别（SenseVoice）

## ❓ 常见问题

<details>
<summary><b>DrawOffer 是什么？</b></summary>

DrawOffer（职绘）是一款面向应届生和求职者的 AI 求职助手，覆盖写简历、管理投递、准备面试和面试复盘。它把你的求职过程记成长期记忆，AI 的每条建议都基于你自己的经历。
</details>

<details>
<summary><b>和普通的 AI 简历工具有什么不同？</b></summary>

普通工具每次只看当前这一份简历。DrawOffer 会记住你投过的岗位、练过和面过的题、简历里的亮点，并把它们连成知识图谱，所以改简历和出题都更贴近你的实际情况，也能告诉你哪些知识点还不牢。
</details>

<details>
<summary><b>桌面客户端和网页版有什么区别？</b></summary>

主要功能相同，数据互通。客户端使用系统原生界面；macOS 版从 macOS 26 起支持本机语音转写。Windows 版部分功能仍在补齐。
</details>

<details>
<summary><b>我的简历和面试录音安全吗？</b></summary>

客户端通过 HTTPS 访问 DrawOffer 服务，登录凭据保存在系统钥匙串（macOS Keychain / Windows Credential Locker）。使用本机语音识别时，转写在你的电脑上完成。
</details>

<details>
<summary><b>怎么收费？</b></summary>

AI 功能按积分计费，套餐与价格以官网为准。
</details>

## 🧩 生态

| 项目 | 说明 |
| --- | --- |
| [DrawOffer 网页版](https://www.drawoffer.com) | 完整功能的在线版本 |
| [drawoffer-mcp](https://github.com/DrawOffer/drawoffer-mcp) | 让 Claude、Cursor 等 AI 工具读写你的 DrawOffer 求职数据 |
| [drawoffer-skills](https://github.com/DrawOffer/drawoffer-skills) | 简历与求职 Agent Skills |
| [drawoffer-prompts](https://github.com/DrawOffer/drawoffer-prompts) | 简历诊断、JD 匹配、STAR 改写等求职提示词 |
| [drawoffer-chinese-resume-templates](https://github.com/DrawOffer/drawoffer-chinese-resume-templates) | 中文简历模板库 |

## 🛠 开发

本仓库只包含桌面客户端。后端与 Web 端位于私有仓库，以子模块 `upstream/` 引用：你可以阅读和学习客户端源码，但需要团队权限才能完整构建。

```text
apps/mac       macOS 客户端（Swift Package：Core / Render / App 三层）
apps/windows   Windows 客户端（WinUI 3，.NET）
apps/native    两端共用：简历纸面渲染器、共享素材、检查脚本
apps/desktop   早期 Electron 壳（已被原生客户端取代）
```

```bash
git clone --recurse-submodules https://github.com/DrawOffer/drawoffer.git
cd drawoffer/apps/mac && swift build      # macOS
apps/windows/scripts/typecheck.sh         # Windows 类型检查
```

客户端跟随 Web 端迭代，同步流程见 [CLAUDE.md](CLAUDE.md) 与 [SYNC.md](SYNC.md)。

## 🤝 反馈与贡献

- 🐛 遇到问题或有建议：[提交 Issue](https://github.com/DrawOffer/drawoffer/issues)
- 🌐 了解更多：[www.drawoffer.com](https://www.drawoffer.com)

如果 DrawOffer 对你的求职有帮助，欢迎点一个 ⭐ Star，让更多同学看到。

<a href="https://star-history.com/#DrawOffer/drawoffer&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=DrawOffer/drawoffer&type=Date&theme=dark">
    <img src="https://api.star-history.com/svg?repos=DrawOffer/drawoffer&type=Date" alt="Star History Chart" width="100%">
  </picture>
</a>

---

<div align="center">

© DrawOffer · All rights reserved

</div>
