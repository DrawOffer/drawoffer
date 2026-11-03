#!/usr/bin/env bash
# 在 macOS / Linux 上对 WinUI 界面工程做 C# 编译检查（Windows 上照常用 Visual Studio 或 dotnet build）。
# XAML 编译器只能在 Windows 运行，工程里没有 .xaml 文件，csproj 在非 Windows 主机上跳过两遍标记编译；
# 也不复制 paper.html 等内容文件（由 npm run build:native-renderer 生成）。产物不可运行，只用于发现类型与 API 错误。
set -euo pipefail
cd "$(dirname "$0")/.."
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
"$DOTNET" build src/DrawOffer.App/DrawOffer.App.csproj -r win-x64 -p:EnableWindowsTargeting=true \
  -nologo -clp:NoSummary "$@"
