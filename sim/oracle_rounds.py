# Morrow Finance: pulls every Chainlink round of a feed across a historical window and writes the path as relative
# price multipliers (WAD) with elapsed seconds, for crash replay on a fork.
# @author adiii.eth

import os
import subprocess
import sys

from eth_abi import encode

RPC = os.environ.get("BASE_RPC_URL", "https://mainnet.base.org")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")
WAD = 10**18


def cast(*args):
    out = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return out.stdout.strip()


def parse(raw):
    return [int(line.split()[0]) for line in raw.splitlines()]


def batch_rounds(feed, ids):
    import json
    import urllib.request

    reqs = []
    for k, rid in enumerate(ids):
        data = "0x9a6fc8f5" + rid.to_bytes(32, "big").hex()
        reqs.append({"jsonrpc": "2.0", "id": k, "method": "eth_call", "params": [{"to": feed, "data": data}, "latest"]})
    import time

    body = json.dumps(reqs).encode()
    headers = {"content-type": "application/json", "user-agent": "curl/8.5.0"}
    for attempt in range(8):
        res = json.loads(urllib.request.urlopen(urllib.request.Request(RPC, data=body, headers=headers), timeout=60).read())
        if isinstance(res, list):
            break
        time.sleep(1.5 * (attempt + 1))
    else:
        raise RuntimeError(f"rpc refused batch: {str(res)[:200]}")
    out = {}
    for r in res:
        raw = bytes.fromhex(r.get("result", "0x")[2:])
        if len(raw) < 160:
            continue
        answer = int.from_bytes(raw[32:64], "big", signed=True)
        updated = int.from_bytes(raw[96:128], "big")
        out[ids[r["id"]]] = (updated, answer)
    return out


def rounds(feed, start_block, end_block):
    rid, answer, _, updated, _ = parse(
        cast("call", feed, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--block", str(start_block))
    )
    last = parse(cast("call", feed, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--block", str(end_block)))[0]
    import json
    import time

    cache_path = os.path.join(HERE, "..", "cache", f"rounds_{feed[:10]}_{start_block}.json")
    got = {}
    if os.path.exists(cache_path):
        got = {int(k): tuple(v) for k, v in json.load(open(cache_path)).items()}
    ids = list(range(rid + 1, last + 1))
    deadline = time.time() + float(os.environ.get("ROUND_BUDGET_S", "500"))
    pending = [k for k in ids if k not in got]
    while pending and time.time() < deadline:
        chunk = pending[:4]
        res = batch_rounds(feed, chunk)
        got.update({k: v for k, v in res.items() if v[0] > 0})
        pending = [k for k in pending if k not in got]
        time.sleep(0.35)
        if len(got) % 40 == 0:
            json.dump({str(k): v for k, v in got.items()}, open(cache_path, "w"))
    json.dump({str(k): v for k, v in got.items()}, open(cache_path, "w"))
    if pending:
        raise TimeoutError(f"{len(pending)} of {len(ids)} rounds still to fetch; rerun to resume")
    return [(updated, answer)] + [got[k] for k in ids]


ANSWER_UPDATED = "0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f"
AGGREGATORS = {
    "0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F": "0x852aE0B1Af1aAeDB0fC4428B4B24420780976ca8",
    "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70": "0x57d2d46Fc7ff2A7142d479F2f59e1E3F95447077",
}


def rounds_from_logs(feed, start_block, end_block):
    import json
    import time
    import urllib.request

    _, answer, _, updated, _ = parse(
        cast("call", feed, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--block", str(start_block))
    )
    agg = AGGREGATORS[feed]
    path = [(updated, answer)]
    headers = {"content-type": "application/json", "user-agent": "curl/8.5.0"}
    b = start_block + 1
    while b <= end_block:
        to = min(b + 1999, end_block)
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getLogs", "params": [{
            "address": agg, "fromBlock": hex(b), "toBlock": hex(to), "topics": [ANSWER_UPDATED]}]}).encode()
        for attempt in range(10):
            res = json.loads(urllib.request.urlopen(urllib.request.Request(RPC, data=body, headers=headers), timeout=60).read())
            if "result" in res:
                break
            time.sleep(1.0 + attempt)
        else:
            raise RuntimeError(str(res)[:200])
        for log in res["result"]:
            current = int(log["topics"][1], 16)
            if current >= 2**255:
                current -= 2**256
            path.append((int(log["data"], 16), current))
        b = to + 1
        time.sleep(0.2)
    return sorted(path)


def write(name, path):
    t0, p0 = path[0]
    elapsed = [t - t0 for t, _ in path]
    ratio = [p * WAD // p0 for _, p in path]
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, f"crash_{name}.hex"), "w") as f:
        f.write("0x" + encode(["uint256[]", "uint256[]"], [elapsed, ratio]).hex())
    low = min(ratio) / WAD - 1
    print(f"{name}: {len(path)} rounds over {elapsed[-1] / 3600:.1f} h, trough {low * 100:.2f}%, end {ratio[-1] / WAD - 1:+.2%}")


if __name__ == "__main__":
    windows = {
        "oct25": (36_657_109, 36_730_909),
        "apr25": (28_566_109, 28_609_309),
        "feb25": (26_935_309, 26_967_709),
    }
    feeds = {"btc": "0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F", "eth": "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70"}
    only = sys.argv[1:] or list(windows)
    for w in only:
        for asset, feed in feeds.items():
            write(f"{w}_{asset}", rounds_from_logs(feed, *windows[w]))
