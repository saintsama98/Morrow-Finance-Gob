# Morrow Finance: encodes live Midnight Base market parameters (from the Midnight API books snapshot) into test vectors,
# grouped as eligible, above-ceiling and mismatched-oracle markets.
# @author adiii.eth

import json
import os
import sys

from eth_abi import encode

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
ZERO = "0x0000000000000000000000000000000000000000"
CBBTC = "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf"
CBBTC_ORACLE = "0x663becd10dae6c4a3dcd89f1d76c1174199639b9"
MARKET = "(uint256,address,address,(address,uint256,uint256,address)[],uint256,uint256,address,address)"


def as_tuple(book):
    return (
        int(book["chainId"]),
        book["midnight"],
        book["loanToken"],
        [(c["token"], int(c["lltv"]), int(c["liquidationCursor"]), c["oracle"]) for c in book["collaterals"]],
        int(book["maturity"]),
        int(book["rcfThreshold"]),
        book["enterGate"],
        book["liquidatorGate"],
    )


def main(path):
    books = json.load(open(path))
    eligible, above, mismatched = [], [], []
    for b in books:
        if b["loanToken"].lower() != USDC or b["enterGate"] != ZERO or b["liquidatorGate"] != ZERO:
            continue
        cols = b["collaterals"]
        lltvs = [int(c["lltv"]) for c in cols]
        has_usdc = any(c["token"].lower() == USDC for c in cols)
        if max(lltvs) > 915 * 10**15 and not has_usdc:
            above.append(b)
        elif not has_usdc and max(lltvs) <= 915 * 10**15:
            if any(c["token"].lower() == CBBTC and c["oracle"].lower() != CBBTC_ORACLE for c in cols):
                mismatched.append(b)
            eligible.append(b)
    for name, group in (("eligible", eligible), ("above_ceiling", above), ("mismatched_oracle", mismatched)):
        ids = [bytes.fromhex(b["marketId"][2:]) for b in group]
        data = encode(["bytes32[]", MARKET + "[]"], [ids, [as_tuple(b) for b in group]])
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, f"markets_{name}.hex"), "w") as f:
            f.write("0x" + data.hex())
        print(f"{name}: {len(group)}")


if __name__ == "__main__":
    main(sys.argv[1])
