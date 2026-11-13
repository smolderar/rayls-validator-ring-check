"""Extra numbers from step1-data.csv used in the post (read-only, offline).
Run: python extra-stats.py step1-data.csv   (Python 3, standard library only). All times UTC."""
import csv, sys, datetime as dt
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1] if len(sys.argv) > 1 else "step1-data.csv", encoding="utf-8-sig")))
for r in rows:
    r["block"] = int(r["block"]); r["nonce"] = int(r["nonce"]); r["epoch"] = int(r["epoch"])
    r["t"] = dt.datetime.strptime(r["time_utc"], "%Y-%m-%d %H:%M:%S"); r["w"] = r["window"].split()[0]
ORACLE = "0x339d413ccefd986b1b3647a9cfa9cbbe70a30749"
NEWEST = "0xbbd0b35294fff3981a7aeb2adb14f23f93bf9662"
FORK = dt.datetime(2026, 10, 10, 14, 22, 7)

def pairs(rs):
    """next nonce from the same wallet, same epoch, different block (same metric as check-affinity.ps1)"""
    g = defaultdict(list); out = []
    for r in rs: g[r["from"]].append(r)
    for l in g.values():
        l.sort(key=lambda r: r["nonce"])
        for a, b in zip(l, l[1:]):
            if b["nonce"] == a["nonce"] + 1 and a["epoch"] == b["epoch"] and a["block"] != b["block"]:
                out.append((a, b))
    return out

def pct(a, b): return f"{a} of {b} = {100.0 * a / b:.1f} %" if b else "n/a"

print("1. Same-validator share in 3-hour bins around the fork block (bin = time of the second transaction)")
bins = defaultdict(lambda: [0, 0])
for w in ("BEFORE", "AFTER"):
    for a, b in pairs([r for r in rows if r["w"] == w]):
        h = int((b["t"] - FORK).total_seconds() // 10800)
        bins[h][0] += 1; bins[h][1] += a["miner"] == b["miner"]
for h in sorted(bins):
    if -4 <= h <= 3: print(f"   {h * 3:+3d} h to {h * 3 + 3:+3d} h: {pct(bins[h][1], bins[h][0])}")

print("2. Other wallets (not the price-feed wallet), pairs at most 1,000 blocks apart")
for w in ("BEFORE", "AFTER", "RECENT"):
    p = [(a, b) for a, b in pairs([r for r in rows if r["w"] == w and r["from"] != ORACLE]) if b["block"] - a["block"] <= 1000]
    print(f"   {w:6s} {pct(sum(a['miner'] == b['miner'] for a, b in p), len(p))}  ({len(set(a['from'] for a, b in p))} wallets)")

print("3. Newest validator 0xbbd0b352, last 24 hours")
o = sorted([r for r in rows if r["w"] == "RECENT" and r["from"] == ORACLE], key=lambda r: r["nonce"])
nb = [r for r in o if r["miner"] == NEWEST]
win = []; c0 = c1 = nb[0]
for x in nb[1:] + [None]:
    if x is not None and (x["t"] - c1["t"]).total_seconds() <= 2400: c1 = x
    else:
        win.append((c0["block"], c1["block"]))
        if x is not None: c0 = c1 = x
inside = lambda blk: any(lo <= blk <= hi for lo, hi in win)
p = pairs([r for r in rows if r["w"] == "RECENT"])
pin = [(a, b) for a, b in p if inside(a["block"]) or inside(b["block"])]
pout = [(a, b) for a, b in p if not (inside(a["block"]) or inside(b["block"]))]
print(f"   same-validator share outside its windows: {pct(sum(a['miner'] == b['miner'] for a, b in pout), len(pout))}")
print(f"   same-validator share touching its windows: {pct(sum(a['miner'] == b['miner'] for a, b in pin), len(pin))}")

def bursts(rs):
    out = []; cur = [rs[0]]
    for a, b in zip(rs, rs[1:]):
        if (b["t"] - a["t"]).total_seconds() <= 60: cur.append(b)
        else: out.append(cur); cur = [b]
    out.append(cur); return [b for b in out if len(b) >= 2]
bs = bursts(o)
def span(b): return (b[-1]["t"] - b[0]["t"]).total_seconds()
bi = [b for b in bs if inside(b[0]["block"])]; bo = [b for b in bs if not inside(b[0]["block"])]
for name, g in (("on its turns", bi), ("on other turns", bo)):
    s = [span(b) for b in g]
    print(f"   price-feed bursts {name}: {len(g)} bursts, first to last update {sum(s) / len(s):.2f} s on average, {max(s):.0f} s at most")
gaps = sorted((c["t"] - a["t"]).total_seconds() for b in bi for a, c in zip(b, b[1:]) if a["miner"] != c["miner"])
print(f"   gaps where a burst switched validator: {len(gaps)}, from {min(gaps):.0f} s to {max(gaps):.0f} s (block timestamps)")
