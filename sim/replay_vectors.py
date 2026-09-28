# Morrow Finance: builds replay vectors for real Midnight liquidation days: tx hashes, block env and the Chainlink
# feed rounds in force just before each transaction.
# @author adiii.eth

import json
import os
import subprocess
import sys

from eth_abi import encode

RPC = os.environ.get("BASE_RPC_URL", "https://mainnet.base.org")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")
FEEDS = {
    "eth": "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70",
    "usdc": "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B",
    "btc": "0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F",
}


def cast(*args):
    out = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return out.stdout.strip()


def round_at(feed, block):
    raw = cast("call", feed, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--block", str(block))
    vals = [line.split()[0] for line in raw.splitlines()]
    return [int(v) for v in vals]


def liquidation_effects(name, market_id, first_block, last_block, log_path):
    from eth_abi import decode as abi_decode

    raw = open(log_path).read().strip()
    logs = []
    for chunk in raw.split("\n["):
        chunk = chunk if chunk.startswith("[") else "[" + chunk
        logs += json.loads(chunk)
    rows = []
    for log in logs:
        block = int(log["blockNumber"], 16)
        if log["topics"][1] != market_id or not first_block <= block <= last_block:
            continue
        caller, seized, repaid, post, recv, payer, bad, lf, cfc = abi_decode(
            ["address", "uint256", "uint256", "bool", "address", "address", "uint256", "uint256", "uint256"],
            bytes.fromhex(log["data"][2:]),
        )
        collateral = "0x" + log["topics"][2][-40:]
        borrower = "0x" + log["topics"][3][-40:]
        rows.append((block, int(log["logIndex"], 16), collateral, borrower, seized, repaid, post, bad))
    rows.sort()
    encoded = encode(
        ["uint256[]", "address[]", "address[]", "uint256[]", "uint256[]", "bool[]", "uint256[]"],
        [[r[0] for r in rows], [r[2] for r in rows], [r[3] for r in rows], [r[4] for r in rows],
         [r[5] for r in rows], [r[6] for r in rows], [r[7] for r in rows]],
    )
    with open(os.path.join(OUT, f"replay_{name}_effects.hex"), "w") as f:
        f.write("0x" + encoded.hex())
    print(f"{name}: {len(rows)} liquidation effects, bad debt total {sum(r[7] for r in rows)}")


def build(name, market_id, first_block, last_block, decoded_path):
    rows = json.load(open(decoded_path))
    txs = sorted(
        {(r["block"], r["tx"]) for r in rows if r["id"] == market_id and first_block <= r["block"] <= last_block}
    )
    hashes, blocks, stamps, rounds = [], [], [], {k: [] for k in FEEDS}
    senders, targets, inputs, values = [], [], [], []
    for block, tx in txs:
        info = json.loads(cast("tx", tx, "--json"))
        senders.append(info["from"])
        targets.append(info["to"])
        inputs.append(bytes.fromhex(info["input"][2:]))
        values.append(int(info["value"], 16) if str(info["value"]).startswith("0x") else int(info["value"]))
        hashes.append(bytes.fromhex(tx[2:]))
        blocks.append(block)
        stamps.append(int(cast("block", str(block), "-f", "timestamp")))
        for key, feed in FEEDS.items():
            rounds[key].append(round_at(feed, block))
    encoded = encode(
        ["bytes32[]", "uint256[]", "uint256[]", "uint256[5][]", "uint256[5][]", "uint256[5][]"],
        [hashes, blocks, stamps, rounds["eth"], rounds["usdc"], rounds["btc"]],
    )
    calls = encode(["address[]", "address[]", "bytes[]", "uint256[]"], [senders, targets, inputs, values])
    with open(os.path.join(OUT, f"replay_{name}_calls.hex"), "w") as f:
        f.write("0x" + calls.hex())
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, f"replay_{name}.hex"), "w") as f:
        f.write("0x" + encoded.hex())
    print(f"{name}: {len(hashes)} txs, blocks {blocks[0]}..{blocks[-1]}")


if __name__ == "__main__":
    decoded = sys.argv[1]
    if len(sys.argv) > 2:
        log_path = sys.argv[2]
        liquidation_effects("jul16_we86", "0x10a033a31e0143f28ea28af165b8c931764f5679843754dea86a0c6320655eb2", 48_640_000, 48_730_000, log_path)
        liquidation_effects("jul16_cb915", "0xa28cffd5ae5f8b59335d974ef541aaf4c3d3beee5d12e28079eebfd1c5e2669f", 48_640_000, 48_730_000, log_path)
        sys.exit(0)
    build("jul16_we86", "0x10a033a31e0143f28ea28af165b8c931764f5679843754dea86a0c6320655eb2", 48_640_000, 48_730_000, decoded)
    build("jul16_cb915", "0xa28cffd5ae5f8b59335d974ef541aaf4c3d3beee5d12e28079eebfd1c5e2669f", 48_640_000, 48_730_000, decoded)
