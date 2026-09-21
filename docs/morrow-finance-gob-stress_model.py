"""
Morrow deterministic stress model.

Maps an instantaneous collateral price shock to a pool's loss and to each
claim's outcome. No randomness. Outputs are thresholds, not probabilities.

Consistency rule: in a zero-coupon market every credit unit is one unit of
borrower debt due at maturity, so total borrower debt in face terms equals
the market's total credit units.

Run:  python3 stress_model.py      writes stress_tables.md
"""

import math
from fractions import Fraction as Q

WAD = 10**18
USDC = 10**6


def max_lif(lltv, gamma):
    return 1.0 / (1.0 - gamma * (1.0 - lltv))


def breakeven_ltv(lltv, gamma):
    return 1.0 - gamma * (1.0 - lltv)


def g_star(lltv, gamma):
    return math.log(breakeven_ltv(lltv, gamma) / lltv)


class Market:
    def __init__(self, lltv, gamma, price, borrower_ltvs, total_units, pool_units):
        self.lltv, self.gamma, self.price = lltv, gamma, price
        self.total_units, self.pool_units = total_units, pool_units
        per = total_units / len(borrower_ltvs)
        # debt in face terms, collateral sized from the stated LTV at the current price
        self.book = [(per / (ltv * price), per) for ltv in borrower_ltvs]

    def bad_debt(self, shock, cost, works=True, distress=0.25):
        p = self.price * (1.0 - shock)
        mlif = max_lif(self.lltv, self.gamma)
        acts = works and (mlif - 1.0) > cost
        clearing = cost if works else max(cost, distress)
        total = 0.0
        for qty, debt in self.book:
            cv = qty * p
            if cv * self.lltv >= debt:
                continue
            recovered = cv / mlif if acts else cv * (1.0 - clearing)
            total += max(debt - recovered, 0.0)
        return total

    def any_liquidatable(self, shock):
        p = self.price * (1.0 - shock)
        return any(q * p * self.lltv < d for q, d in self.book)


class Pool:
    """Frozen pool terms, taken from the reference model's worked example."""
    S_d = 818_181.818181
    J_d = 181_818.181819
    C_S = 824_795.454544
    F_net = 1_010_000.0
    theta = 0.10

    def __init__(self, markets):
        self.markets = markets

    def loss(self, shock, cost, works=True):
        return sum(m.bad_debt(shock, cost, works) * m.pool_units / m.total_units
                   for m in self.markets)

    def outcome(self, shock, cost, works=True):
        L = self.loss(shock, cost, works)
        P = max(self.F_net - L, 0.0)
        XS = min(self.C_S, P)
        RJ = P - XS
        fee = max(RJ - self.J_d, 0.0) * self.theta
        XJ = RJ - fee
        return dict(loss=L, P=P, XS=XS, XJ=XJ,
                    sr=XS / self.S_d - 1, jr=XJ / self.J_d - 1)


def bisect(pred, lo=0.0, hi=0.99, tol=1e-6):
    if not pred(hi):
        return None
    if pred(lo):
        return lo
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if pred(mid):
            hi = mid
        else:
            lo = mid
        if hi - lo < tol:
            break
    return hi


def thresholds(pool, cost, works=True):
    return dict(
        first_liq=bisect(lambda s: any(m.any_liquidatable(s) for m in pool.markets)),
        first_bad=bisect(lambda s: pool.loss(s, cost, works) > 1e-9),
        junior_wiped=bisect(lambda s: pool.outcome(s, cost, works)["XJ"] <= 1e-9),
        senior_10=bisect(lambda s: pool.outcome(s, cost, works)["sr"] <= -0.10),
    )


BOOKS = {
    "Conservative": [0.55, 0.60, 0.62],
    "Median": [0.68, 0.72, 0.75],
    "Levered": [0.80, 0.83, 0.845],
}


def build(book):
    m = Market(lltv=0.86, gamma=0.50, price=100_000.0, borrower_ltvs=BOOKS[book],
               total_units=4_040_000.0, pool_units=1_010_000.0)
    return Pool([m])


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "| " + " | ".join("---" for _ in headers) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def pct(x):
    return "none below 99%" if x is None else f"{x * 100:.1f}%"


if __name__ == "__main__":
    T = {}

    rows = []
    for lltv, g in ((0.77, 0.50), (0.86, 0.25), (0.86, 0.50), (0.915, 0.50),
                    (0.945, 0.50), (0.98, 0.50)):
        rows.append((f"{lltv}", f"{g}", f"{max_lif(lltv, g):.4f}",
                     f"{(max_lif(lltv, g) - 1) * 100:.2f}%",
                     f"{breakeven_ltv(lltv, g):.4f}",
                     f"{(1 - g) * (1 - lltv):.4f}",
                     f"{g_star(lltv, g) * 100:.2f}%"))
    T["band"] = table(["LLTV", "γ", "Incentive factor", "Liquidator discount",
                       "Breakeven LTV", "Solvent band", "Minimum gap g*"], rows)

    rows = []
    for book in BOOKS:
        p = build(book)
        t = thresholds(p, 0.02)
        rows.append((book, pct(t["first_liq"]), pct(t["first_bad"]),
                     pct(t["junior_wiped"]), pct(t["senior_10"])))
    T["thresholds_2"] = table(["Borrower book", "First liquidation", "First bad debt",
                               "Junior exhausted", "Senior down 10%"], rows)

    rows = []
    for book in BOOKS:
        p = build(book)
        t = thresholds(p, 0.20)
        rows.append((book, pct(t["first_liq"]), pct(t["first_bad"]),
                     pct(t["junior_wiped"]), pct(t["senior_10"])))
    T["thresholds_20"] = table(["Borrower book", "First liquidation", "First bad debt",
                                "Junior exhausted", "Senior down 10%"], rows)

    scen = [("Orderly decline", 0.15, 0.01, True),
            ("Moderate crash", 0.30, 0.02, True),
            ("Gap above the incentive", 0.35, 0.08, True),
            ("Crash with thin liquidity", 0.35, 0.20, True),
            ("Liquidation absent", 0.35, 0.01, False)]
    rows = []
    p = build("Median")
    for name, s, c, w in scen:
        o = p.outcome(s, c, w)
        rows.append((name, f"{s * 100:.0f}%", f"{c * 100:.0f}%", "Yes" if w else "No",
                     f"{o['loss']:,.0f}", f"{o['sr'] * 100:.2f}%", f"{o['jr'] * 100:.2f}%"))
    T["scenarios"] = table(["Scenario", "Shock", "Execution cost", "Liquidators active",
                            "Pool loss (USDC)", "Senior return", "Junior return"], rows)

    # the cliff: recovery as a function of execution cost at a fixed shock
    rows = []
    for c in (0.02, 0.05, 0.07, 0.0752, 0.0754, 0.10, 0.20):
        o = p.outcome(0.30, c)
        rows.append((f"{c * 100:.2f}%", f"{o['loss']:,.0f}", f"{o['jr'] * 100:.2f}%"))
    T["cliff"] = table(["Execution cost", "Pool loss at a 30% shock (USDC)",
                        "Junior return"], rows)

    with open("stress_tables.md", "w") as fh:
        for k, v in T.items():
            fh.write(f"<!-- {k} -->\n{v}\n\n")
    for k, v in T.items():
        print(f"\n{k}\n{v}")
