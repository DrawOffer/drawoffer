# DrawOffer 桌面客户端

本仓库是 DrawOffer（职绘）的桌面客户端：`apps/mac`（SwiftUI）、`apps/windows`（WinUI 3）、`apps/desktop`（Electron 壳，已被原生客户端取代，仅保留）以及两端共用的 `apps/native`（简历纸面渲染器、共享素材与检查脚本）。`AGENTS.md` 链接到本文件，只改这一份。

后端（FastAPI）和 Web 端在私有主仓库 `ql-link/LinkCV`，以只读子模块挂在 `upstream/`。**客户端永远跟随 Web：Web 先做完，客户端再按同步清单对齐。**

## 1. 通用原则

- 默认中文沟通与提交说明；代码、命令和技术标识保留原文。
- 先核实代码再下结论；示例和测试只用虚构数据，不写真实简历、账号、密钥或内网地址。**本仓库公开**，提交前确认没有凭据、内网 IP、个人邮箱。
- 不在 `upstream/` 里改代码。需要新接口或改接口时，到主仓库按它的流程提 PR，合入后再同步过来。

## 2. 去哪里理解后端和 Web

先 `git submodule update --init upstream`。`apps/web` 是指向 `upstream/apps/web` 的软链接，渲染器构建脚本依赖它。

| 想知道 | 看哪里 |
| --- | --- |
| 接口、鉴权、错误码 | `upstream/docs/api/http-contracts.md`（桌面端见“桌面 Bearer 会话”），路由在 `upstream/apps/backend/src/drawoffer/modules/*/routes.py` |
| 某接口桌面端能否调用 | 路由上的 `client_access(desktop=True)`；403 说明还没对桌面开放 |
| 字段与类型 | `upstream/apps/web/src/api/`（Web 客户端类型，Mac `DrawOfferCore/Models.swift` 与之对齐） |
| 某个页面怎么做的 | `upstream/apps/web/src/features/<模块>/`、`upstream/apps/web/src/v3/` |
| 颜色、字号、圆角、间距 | `upstream/apps/web/src/design-system/tokens.css` → Mac `apps/mac/Sources/DrawOfferApp/DesignSystem/Tokens.swift`、Windows 对应资源 |
| 简历纸面 | `upstream/apps/web/src/features/preview/print/`，由 `apps/native/scripts/build_renderer.mjs` 打成离线 `paper.html` / `editor.html` |
| 后端模块事实 | `upstream/docs/README.md` 索引 |

## 3. 同步 Web 改动

1. `scripts/sync-upstream.sh` 生成 `.sync/pending.md`：上次同步以来合入的 PR，以及样式 Token、页面组件、接口类型、纸面渲染、后端路由、契约文档的改动文件。
2. 逐个 PR 看 diff（`git -C upstream log -p <base>..<target> -- <路径>`），判断 Mac、Windows 各要改什么；Web 专属或后台管理的改动写明不同步原因。
3. 改完运行 `scripts/sync-upstream.sh --apply "一句话说明"`，子模块移到目标提交并记入 `SYNC.md`，与客户端改动一起提交。
4. Token 只改数值时直接照 `tokens.css` 改 `Tokens.swift` 与 Windows 资源，再用 `apps/windows/scripts/parity.py` 核对两端文案、颜色与尺寸。

## 4. 客户端规则

- 界面以 Figma 为准：Mac 稿与 Windows 稿各有独立文件；窗口单层、内容铺满、系统控件，弹窗居中无遮罩（Windows 加原生浅遮罩）。
- Mac 构建与打包：`cd apps/mac && swift build`，`scripts/bundle.sh` 打包（会先构建渲染器）；本地语音识别依赖见 `scripts/fetch-sherpa.sh`。
- Windows 只做类型检查：`apps/windows/scripts/typecheck.sh`。
- 新依赖说明必要性并更新对应 lockfile。

## 5. Git

- 默认分支 `master`；功能分支 `feat/`、`fix/`、`chore/` 前缀，PR 合入 `master`，不直接推送或改写 `master`。
- 只在用户要求时提交、推送、建 PR；合并需要用户授权。
