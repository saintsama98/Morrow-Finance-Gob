"""Generates differential test vectors from the Python twin (sim/series_math.py).

Writes JSON files under sim/vectors/, one per math function family, consumed by
contracts/test/differential/*.t.sol via forge's typed JSON array cheatcodes (parseJsonUintArray /
parseJsonIntArray / parseJsonBoolArray). Every vector's expected output is produced by the same code exercised
by contracts/test/unit/*.t.sol's fixed-point checks, so a Solidity/Python mismatch here means either the
Solidity implementation or this twin has drifted from the build spec's formulas -- ci fails on any mismatch
(section 25.6).

Format is COLUMNAR (one JSON array per field, all vectors' i-th values at index i across every field), not an
array of objects. forge's generic `abi.decode(vm.parseJson(json), (Struct[]))` path is ambiguous for plain
numeric JSON strings -- whether a string like "12345" coerces to uint256 or is left as a dynamic `string`
depends on a magnitude heuristic, and gets it wrong silently for values that fit inside normal JSON number
range, corrupting the whole struct array's ABI layout. The typed per-field cheatcodes (parseJsonUintArray etc.)
don't have this ambiguity, so columnar format sidesteps the whole class of bug.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from series_math import (  # noqa: E402
    WAD,
    mul_div_down,
    mul_div_up,
    premium_pi,
    price,
    nav,
    waterfall,
)

OUT_DIR = Path(__file__).resolve().parent
N = 2000

random.seed(1337)  # deterministic vectors, reproducible across CI runs


def rand_uint(max_bits: int) -> int:
    return random.randrange(0, 2**max_bits)


def columnar(rows: list[dict]) -> dict:
    """Transpose a list of row-dicts (all with str values, ints as str, bools as bool) into column arrays."""
    if not rows:
        return {}
    cols: dict[str, list] = {k: [] for k in rows[0]}
    for row in rows:
        for k, v in row.items():
            cols[k].append(v)
    return cols


def gen_wadmath() -> dict:
    rows = []
    while len(rows) < N:
        x = rand_uint(128)
        y = rand_uint(128)
        d = rand_uint(128)
        if d == 0:
            continue
        if (x * y) // (d if d > 0 else 1) > 2**256 - 1:
            continue
        down = mul_div_down(x, y, d)
        up = mul_div_up(x, y, d)
        rows.append({"x": str(x), "y": str(y), "d": str(d), "down": str(down), "up": str(up)})
    return columnar(rows)


def gen_premium_curve() -> dict:
    rows = []
    pi0, pi_t, pi1 = int(0.10 * WAD), int(0.20 * WAD), int(0.35 * WAD)
    u_t = int(0.9 * WAD)
    while len(rows) < N:
        u = rand_uint(60) % (2 * WAD)
        if random.random() < 0.3:
            a0 = random.randrange(0, int(0.5 * WAD))
            at = random.randrange(a0, int(0.8 * WAD))
            a1 = random.randrange(at, WAD - 1)
        else:
            a0, at, a1 = pi0, pi_t, pi1
        result = premium_pi(u, u_t, a0, at, a1)
        rows.append({"u": str(u), "uT": str(u_t), "pi0": str(a0), "piT": str(at), "pi1": str(a1), "pi": str(result)})
    return columnar(rows)


def gen_series_pricing() -> dict:
    rows = []
    while len(rows) < N:
        k_d = random.randrange(1, 10_000_000) * 10**6
        a_wad = random.randrange(1, int(0.5 * WAD))
        if random.random() < 0.1:
            f_net = random.randrange(1, k_d)
        else:
            f_net = k_d + random.randrange(0, k_d // 2 + 1)
        if f_net == 0:
            continue
        pi_wad = random.randrange(0, int(0.5 * WAD))

        r = price(k_d, a_wad, f_net, pi_wad)
        rows.append(
            {
                "kDeployed": str(k_d),
                "juniorShareWad": str(a_wad),
                "faceNetAtFinalize": str(f_net),
                "piWad": str(pi_wad),
                "seniorDeployed": str(r.senior_deployed),
                "juniorDeployed": str(r.junior_deployed),
                "poolRateWad": str(r.pool_rate_wad),
                "seniorRateWad": str(r.senior_rate_wad),
                "seniorClaim": str(r.senior_claim),
                "attachmentWad": str(r.attachment_wad),
                "buffer0": str(r.buffer0),
                "negativeCarry": r.negative_carry,
            }
        )
    return columnar(rows)


def gen_waterfall() -> dict:
    rows = []
    theta = int(0.10 * WAD)
    while len(rows) < N:
        senior_claim = random.randrange(0, 10_000_000) * 10**6
        junior_deployed = random.randrange(0, 5_000_000) * 10**6
        proceeds = random.randrange(0, 15_000_000) * 10**6
        xs, xj, fee = waterfall(proceeds, senior_claim, junior_deployed, theta)
        rows.append(
            {
                "proceeds": str(proceeds),
                "seniorClaim": str(senior_claim),
                "juniorDeployed": str(junior_deployed),
                "thetaWad": str(theta),
                "seniorPaid": str(xs),
                "juniorPaid": str(xj),
                "fee": str(fee),
            }
        )
    return columnar(rows)


def gen_nav() -> dict:
    rows = []
    theta = int(0.10 * WAD)
    while len(rows) < N:
        tau = random.randrange(1, 365 * 86400)
        elapsed = random.randrange(0, 2 * tau)
        k_d = random.randrange(1, 5_000_000) * 10**6
        f_net = k_d + random.randrange(0, k_d // 2 + 1)
        face_loss = random.randrange(0, f_net + 1)
        s_d = random.randrange(0, k_d + 1)
        j_d = k_d - s_d
        r_s_wad = random.randrange(0, WAD)
        c_s = s_d + mul_div_down(s_d, r_s_wad, WAD)

        nav_s, nav_j, fee_accrued = nav(elapsed, tau, k_d, f_net, face_loss, s_d, c_s, j_d, theta)
        rows.append(
            {
                "elapsed": str(elapsed),
                "tau": str(tau),
                "kDeployed": str(k_d),
                "faceNetAtFinalize": str(f_net),
                "faceLoss": str(face_loss),
                "seniorDeployed": str(s_d),
                "seniorClaim": str(c_s),
                "juniorDeployed": str(j_d),
                "thetaWad": str(theta),
                "navS": str(nav_s),
                "navJ": str(nav_j),
                "feeAccrued": str(fee_accrued),
            }
        )
    return columnar(rows)


def main() -> None:
    generators = {
        "wadmath.json": gen_wadmath,
        "premium_curve.json": gen_premium_curve,
        "series_pricing.json": gen_series_pricing,
        "waterfall.json": gen_waterfall,
        "nav.json": gen_nav,
    }
    for filename, gen in generators.items():
        cols = gen()
        out_path = OUT_DIR / filename
        out_path.write_text(json.dumps(cols, indent=None))
        n_rows = len(next(iter(cols.values()))) if cols else 0
        print(f"wrote {n_rows} vectors ({len(cols)} columns) to {out_path}")


if __name__ == "__main__":
    main()
