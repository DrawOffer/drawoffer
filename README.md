# DrawOffer 职绘 · AI 求职助手桌面客户端

DrawOffer（职绘）是面向应届生和求职者的 AI 求职助手：把简历、投递岗位、面试安排和复盘统一记成“长期记忆”，在此基础上用 AI 修改简历、模拟面试和复盘。本仓库是 DrawOffer 的 **macOS 与 Windows 原生桌面客户端**。

- 官网与在线版：<https://www.drawoffer.com>
- 平台：macOS 14 及以上（SwiftUI），Windows 10（1809）及以上（WinUI 3）

## 功能

| 功能 | 说明 | macOS | Windows |
| --- | --- | --- | --- |
| 简历编辑 | 原生编辑器，文字格式、版式与模板切换，所见即所得纸面（与网页和 PDF 导出同一渲染器） | ✓ | 只读预览 |
| 简历模板 | 按岗位分类的模板库，游客可浏览精选示例 | ✓ | ✓ |
| 岗位看板 | 记录投递岗位、推进阶段和岗位详情 | ✓ | ✓ |
| 面试排期 | 日历式安排笔试、面试 | ✓ | ✓ |
| AI 模拟面试 | 按岗位和个人经历出题，支持文字和语音作答，结束后生成复盘报告 | ✓ | ✓ |
| 本机语音识别 | macOS 26 起语音作答使用系统离线识别在本机转写 | ✓ | — |
| 资料库 | 上传面经、笔记等求职资料，供 AI 出题和改简历时参考 | ✓ | ✓ |
| AI 对话 | 基于你的求职记录回答问题、给修改建议 | ✓ | ✓ |

## 常见问题

**DrawOffer 是什么？** 一款 AI 求职助手，帮助求职者写简历、管理投递、准备和复盘面试。网页版、微信小程序和桌面客户端共用同一个账号与数据。

**桌面客户端和网页版有什么区别？** 主要功能与网页版相同，界面使用系统原生控件；macOS 26 起语音作答可在本机完成转写，不经过云端识别服务。Windows 版仍在补齐中。

**怎么收费？** AI 功能按积分计费，套餐与价格以官网为准。

## 仓库结构

```text
apps/mac       macOS 客户端（Swift Package：Core / Render / App 三层）
apps/windows   Windows 客户端（WinUI 3，.NET）
apps/native    两端共用：简历纸面渲染器、共享素材、检查脚本
apps/desktop   早期 Electron 壳（已被原生客户端取代）
upstream/      后端与 Web 主仓库（私有子模块，仅团队成员可拉取）
```

客户端的界面与功能跟随 Web 端，同步方式见 [CLAUDE.md](CLAUDE.md) 与 [SYNC.md](SYNC.md)。

## 构建（团队成员）

```bash
git clone --recurse-submodules https://github.com/ql-link/drawoffer.git
cd drawoffer/apps/mac && swift build      # macOS
apps/windows/scripts/typecheck.sh         # Windows 类型检查
```

`upstream/` 是私有仓库，没有权限时仍可阅读客户端源码，但无法构建简历纸面渲染器。

## English

DrawOffer is an AI job-search assistant for students and job seekers: resume editor and templates, job application tracker, interview scheduling, AI mock interviews with voice answers, and interview reviews, all built on a long-term memory of your job search. This repository contains the native macOS (SwiftUI) and Windows (WinUI 3) desktop clients. Try it online at <https://www.drawoffer.com>.

© DrawOffer. All rights reserved.
