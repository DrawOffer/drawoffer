# Local parity checks only: pairs same-named elements between a Web box dump (web-snap.mjs {"boxes":true})
# and a Mac AX tree (snap.sh shot), after moving Mac window coordinates into the Web viewport, and prints the
# differences above a tolerance. usage: python3 compare.py web.box mac.ax [tolerance=6]
import re, sys
web_path, mac_path = sys.argv[1], sys.argv[2]
tol = float(sys.argv[3]) if len(sys.argv) > 3 else 6
box = re.compile(r"@(-?\d+),(-?\d+) (\d+)x(\d+)")
norm = lambda s: re.sub(r"[\s·　,，|:：]+", "", s.split(" | ")[0])

def parse(path, mac):
    rows = []
    for line in open(path, encoding="utf-8"):
        m = box.search(line)
        if not m: continue
        head = line[:m.start()].strip()
        name = head.split(" ", 1)[1] if " " in head else head
        if mac and name.endswith("，去练"): name = name[:-3]
        rows.append((norm(name), name, *map(int, m.groups()), line[m.end():].strip()))
    return rows

web, mac = parse(web_path, False), parse(mac_path, True)
# Mac window origin includes the title bar: align on the sidebar brand link, or for dialogs
# (no sidebar in the Web dump) on the first name both sides share.
names = [w[0] for w in web if w[0] == "DrawOffer首页"] or [w[0] for w in web if any(m[0] == w[0] for m in mac)]
anchor = lambda rows: next(r for r in rows if r[0] == names[0])
dx = anchor(web)[2] - anchor(mac)[2]; dy = anchor(web)[3] - anchor(mac)[3]
print("anchor", names[0])
used, missing = set(), []
print(f"offset dx={dx} dy={dy}")
for w in web:
    same = lambda a, b: a == b or (min(len(a), len(b)) >= 4 and (a.startswith(b) or b.startswith(a)))
    cand = [(i, m) for i, m in enumerate(mac) if i not in used and same(m[0], w[0])]
    if not cand: missing.append(w[1]); continue
    i, m = min(cand, key=lambda c: abs(c[1][2] + dx - w[2]) + abs(c[1][3] + dy - w[3]))
    used.add(i)
    d = (m[2] + dx - w[2], m[3] + dy - w[3], m[4] - w[4], m[5] - w[5])
    if max(abs(d[0]), abs(d[1])) > tol:
        print(f"POS  {w[1][:30]:<30} web@{w[2]},{w[3]} {w[4]}x{w[5]}  mac@{m[2]+dx},{m[3]+dy} {m[4]}x{m[5]}  {w[6]}")
print("ONLY WEB:", " / ".join(missing))
print("ONLY MAC:", " / ".join(m[1] for i, m in enumerate(mac) if i not in used and m[1] and not m[1].startswith("this button")))
