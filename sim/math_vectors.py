# Morrow Finance: deterministic differential vectors from the Python twins, ABI-encoded for the Solidity tests.
# @author adiii.eth

import os
import random

from eth_abi import encode

import series_math as m

WAD = m.WAD
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vectors")
N = 400


def write(name, types, values):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name + ".hex"), "w") as f:
        f.write("0x" + encode(types, values).hex())


def usdc(rng, hi=10**13):
    return rng.randint(0, hi)


def wad_frac(rng):
    return rng.choice([0, 1, WAD - 1, WAD, rng.randint(0, WAD)])


def main():
    rng = random.Random(20260928)

    rows = []
    while len(rows) < N:
        d = rng.choice([1, 3, WAD, rng.randint(1, 2**128), rng.randint(1, 2**255)])
        x = rng.randint(0, 2**200)
        y = rng.randint(0, 2**200)
        if x * y // d > m.UINT_MAX or m.mul_div_up(x, y, d) > m.UINT_MAX:
            continue
        rows.append([x, y, d, m.mul_div_down(x, y, d), m.mul_div_up(x, y, d)])
    rows.append([2**255, 2, 2**255, 2, 2])
    rows.append([m.UINT_MAX, m.UINT_MAX, m.UINT_MAX, m.UINT_MAX, m.UINT_MAX])
    write("wad_math", ["uint256[5][]"], [rows])

    rows = []
    for _ in range(N):
        pi0, pit, pi1 = sorted(rng.randint(0, WAD - 1) for _ in range(3))
        ut = rng.randint(1, WAD - 1)
        u = rng.choice([0, ut, ut - 1, WAD, 2 * WAD, rng.randint(0, WAD)])
        rows.append([u, ut, pi0, pit, pi1, m.premium_pi(u, ut, pi0, pit, pi1)])
    write("premium_curve", ["uint256[6][]"], [rows])

    rows, buffers = [], []
    for _ in range(N):
        k = rng.randint(1, 10**13)
        a = wad_frac(rng)
        face = rng.choice([k, k - 1 if k > 1 else 1, rng.randint(1, 2 * k), k + rng.randint(0, k // 5 + 1)])
        p = rng.randint(0, WAD - 1)
        r = m.price(k, a, face, p)
        rows.append([k, a, face, p, r["seniorDeployed"], r["juniorDeployed"], r["poolRateWad"],
                     r["seniorRateWad"], r["seniorClaim"], r["attachmentWad"], int(r["negativeCarry"])])
        buffers.append(r["buffer0"])
    write("series_price", ["uint256[11][]", "int256[]"], [rows, buffers])

    rows = []
    for _ in range(N):
        k = rng.randint(0, 10**13)
        face = rng.choice([k, rng.randint(0, 2 * k + 1)])
        tau = rng.choice([0, 1, rng.randint(1, 400 * 86400)])
        elapsed = rng.choice([0, tau, tau + 1, rng.randint(0, 2 * tau + 1)])
        loss = rng.choice([0, rng.randint(0, face + 1), face + 10])
        sd = rng.randint(0, k)
        claim = rng.choice([sd, sd + rng.randint(0, sd // 5 + 1), rng.randint(0, sd + 1)])
        jd = k - sd
        theta = rng.randint(0, WAD // 5)
        ns, nj, fee = m.nav(elapsed, tau, k, face, loss, sd, claim, jd, theta)
        rows.append([elapsed, tau, k, face, loss, sd, claim, jd, theta, ns, nj, fee])
    write("series_nav", ["uint256[12][]"], [rows])

    rows = []
    for _ in range(N):
        claim = usdc(rng)
        jd = usdc(rng)
        proceeds = rng.choice([0, claim, claim + jd, rng.randint(0, 2 * (claim + jd) + 1)])
        theta = rng.randint(0, WAD // 5)
        rows.append([proceeds, claim, jd, theta, *m.waterfall(proceeds, claim, jd, theta)])
    write("series_waterfall", ["uint256[7][]"], [rows])

    rows = []
    for _ in range(N):
        k = rng.choice([0, usdc(rng)])
        sd = rng.randint(0, k)
        proceeds = usdc(rng)
        rows.append([proceeds, sd, k, *m.waterfall_pass_through(proceeds, sd, k)])
    write("series_passthrough", ["uint256[5][]"], [rows])

    rows = []
    for _ in range(N):
        k = usdc(rng)
        a = wad_frac(rng)
        rows.append([k, a, *m.allocation_split(k, a)])
    write("series_split", ["uint256[4][]"], [rows])

    rows = []
    for _ in range(N):
        close = rng.choice([0, 10**6, rng.randint(0, 10**7)])
        now = rng.choice([0, close, rng.randint(0, 10**7)])
        remaining = rng.randint(0, 10**30)
        available = usdc(rng)
        price_wad = m.redemption_price(close, now)
        rows.append([
            close, now, remaining, available,
            price_wad, m.deposit_price(close, now),
            m.shares_fillable(remaining, available, price_wad),
            m.assets_for_shares(remaining, price_wad),
            m.shares_for_assets(available, price_wad),
        ])
    write("epoch_math", ["uint256[9][]"], [rows])


if __name__ == "__main__":
    main()
