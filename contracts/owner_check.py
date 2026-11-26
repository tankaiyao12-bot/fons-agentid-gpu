#!/usr/bin/env python3
"""合约里的 owner 专用函数 ↔ README「权限披露」必须对得上。

README 说「owner 能做什么、不能做什么」。加了个 onlyOwner 函数却忘了写进
README，等于偷偷扩大了 owner 的权力 —— 对非托管产品这是最严重的一类漂移。
这个检查让它编译不过去。
"""
import re, sys, pathlib

src = pathlib.Path("contracts/src/AgentAccount.sol").read_text()
readme = pathlib.Path("README.md").read_text()

# 带 onlyOwner 修饰符的函数名
fns = set(re.findall(r"function\s+(\w+)\s*\([^)]*\)[^{]*?onlyOwner", src, re.S))
missing = sorted(f for f in fns if f"`{f}`" not in readme)

print(f"  onlyOwner 函数 {len(fns)} 个：{', '.join(sorted(fns))}")
if missing:
    for m in missing:
        print(f"::error::`{m}` 是 onlyOwner 函数，但 README 的权限披露里没有它")
    sys.exit(1)
print("  ✓ 每一个都在 README 里写明了")
