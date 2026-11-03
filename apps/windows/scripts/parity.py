#!/usr/bin/env python3
"""Mac ↔ Windows 界面代码对照：按文件对比较界面文案、颜色值与尺寸数字。

用法：python3 apps/windows/scripts/parity.py <mac.swift>... -- <windows.cs>...
输出 Mac 里有、Windows 里没有的项（以及反向），供逐项核对。只是文本层面的比较：
数字与颜色同时出现在两边不代表用在同一处，缺失项需要人工判断是否为有意差异。
"""
import re
import sys

CJK = re.compile(r'"([^"\\]*[\u4e00-\u9fff][^"\\]*)"')
HEX = re.compile(r'0x([0-9A-Fa-f]{6})u?\b')
NUMBER = re.compile(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])')
# 插值写法统一：Swift "\(x)" 与 C# "{x}" 都换成占位符
INTERP = re.compile(r'\\\([^)]*\)|\{[^}]*\}')


def scan(paths):
    text = "\n".join(open(p, encoding="utf-8").read() for p in paths)
    # 去掉整行注释（含文档注释），避免说明文字里的数字干扰；行尾注释保留，以免误伤 "ms-appx:///" 一类字符串
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
    strings = {INTERP.sub("…", s) for s in CJK.findall(code)}
    colors = {h.upper() for h in HEX.findall(code)}
    numbers = {n for n in NUMBER.findall(code) if float(n) >= 2}
    return strings, colors, numbers


def main():
    if "--" not in sys.argv:
        print(__doc__)
        return 2
    split = sys.argv.index("--")
    mac, win = scan(sys.argv[1:split]), scan(sys.argv[split + 1:])
    failed = False
    for label, a, b in zip(("文案", "颜色", "数字"), mac, win):
        missing, extra = sorted(a - b), sorted(b - a)
        print(f"== {label}：Mac {len(a)} 项，Windows {len(b)} 项")
        if missing:
            failed = True
            print("  Windows 缺少：" + "  |  ".join(missing))
        if extra:
            print("  Windows 多出：" + "  |  ".join(extra))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
