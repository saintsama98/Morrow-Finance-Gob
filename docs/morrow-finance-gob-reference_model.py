"""
Morrow reference model.

Exact integer implementation of the tranche arithmetic, with every rounding
decision made explicitly through two primitives. Audits compare the integer
results against exact rational arithmetic (fractions.Fraction) computed from
the same stored inputs, so each rounding direction is verified rather than
assumed.

Run:  python3 reference_model.py
Output: a console report, audit_results.json, and audit_tables.md
"""

import json
import random
from fractions import Fraction as Q

WAD = 10**18
USDC = 10**6

# Default parameters, fixed point.
C_MIN = 15 * WAD // 100      # minimum junior share, c
A_MAX = 30 * WAD // 100      # maximum junior share
PI0 = 10 * WAD // 100        # premium at u = 0
PIT = 20 * WAD // 100        # premium at the kink
PI1 = 35 * WAD // 100        # premium at u = 1
UT = 90 * WAD // 100         # kink location
THETA = 10 * WAD // 100      # fee rate on junior profit above principal


# ---------------------------------------------------------------- primitives

def mul_div_down(x, y, d):
    if d == 0:
        raise ZeroDivisionError
    return (x * y) // d


def mul_div_up(x, y, d):
    if d == 0:
        raise ZeroDivisionError
    return -((-(x * y)) // d)


# ---------------------------------------------------------------- open

def junior_share(J, K_alloc):
    """a = J / K_alloc, rounded down."""
    return mul_div_down(J, WAD, K_alloc)


def utilisation(c, a):
    """u = c / a, rounded up."""
    return mul_div_up(c, WAD, a)


def premium(u, pi0=PI0, piT=PIT, pi1=PI1, uT=UT):
    """Piecewise linear premium, rounded up on both branches."""
    if u < uT:
        return piT - mul_div_down(uT - u, piT - pi0, uT)
    return piT + mul_div_up(u - uT, pi1 - piT, WAD - uT)


# ---------------------------------------------------------------- deployment

def fix_pool(K_d, F_net, a, pi):
    """
    All quantities fixed at the end of deployment. Signed where the value can
    be negative. The negative carry branch compares raw values before any
    subtraction, so no step can underflow.
    """
    if K_d <= 0 or F_net <= 0:
        raise ValueError("empty pool")
    S_d = mul_div_down(K_d, WAD - a, WAD)
    J_d = K_d - S_d
    negative_carry = F_net <= K_d
    r_pool = mul_div_down(F_net, WAD, K_d) - WAD          # signed
    if negative_carry:
        r_s = 0
        C_S = S_d
    else:
        r_s = mul_div_down(r_pool, WAD - pi, WAD)
        C_S = S_d + mul_div_down(S_d, r_s, WAD)
    A_F = WAD - mul_div_up(C_S, WAD, F_net)               # signed
    B_0 = F_net - C_S                                     # signed
    return dict(K_d=K_d, F_net=F_net, a=a, pi=pi, S_d=S_d, J_d=J_d,
                r_pool=r_pool, r_s=r_s, C_S=C_S, A_F=A_F, B_0=B_0,
                A_F_published=max(A_F, 0), negative_carry=negative_carry)


def fix_pool_unsigned(K_d, F_net, a, pi):
    """Same chain with every quantity treated as uint256. Used only to show the failure."""
    def sub(x, y):
        if y > x:
            raise ArithmeticError("underflow")
        return x - y
    r_pool = sub(mul_div_down(F_net, WAD, K_d), WAD)
    S_d = mul_div_down(K_d, WAD - a, WAD)
    r_s = mul_div_down(r_pool, WAD - pi, WAD)
    C_S = S_d + mul_div_down(S_d, r_s, WAD)
    return sub(WAD, mul_div_up(C_S, WAD, F_net))


# ---------------------------------------------------------------- settlement

def waterfall(P, C_S, J_d, theta=THETA):
    XS = min(C_S, P)
    RJ = P - XS
    profit = max(RJ, J_d) - J_d
    fee = mul_div_down(profit, theta, WAD)
    XJ = RJ - fee
    return XS, XJ, fee


def pro_rata(P, S_d, K_d):
    XS = mul_div_down(P, S_d, K_d)
    return XS, P - XS


# ---------------------------------------------------------------- helpers

def f_usdc(x):
    s = "-" if x < 0 else ""
    x = abs(x)
    return f"{s}{x // USDC:,}.{x % USDC:06d}"


def f_wad(x):
    s = "-" if x < 0 else ""
    x = abs(x)
    return f"{s}{x // WAD}.{x % WAD:018d}"


def f_pct(x, dp=6):
    return f"{Q(x, WAD) * 100:.{dp}f}".rstrip() + "%" if False else f"{float(Q(x, WAD) * 100):.{dp}f}%"


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "| " + " | ".join("---" for _ in headers) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


TABLES = {}
RESULTS = {}


# ---------------------------------------------------------------- worked example

def worked_example():
    J, S = 200_000 * USDC, 900_000 * USDC
    K_alloc = J + S
    a = junior_share(J, K_alloc)
    u = utilisation(C_MIN, a)
    pi = premium(u)
    K_d = 1_000_000 * USDC
    F_net = 1_010_000 * USDC
    p = fix_pool(K_d, F_net, a, pi)

    rows = [
        ("S", "Senior capital committed", f_usdc(S), str(S)),
        ("J", "Junior capital committed", f_usdc(J), str(J)),
        ("K_alloc", "Total committed", f_usdc(K_alloc), str(K_alloc)),
        ("a", "Junior share", f_wad(a), str(a)),
        ("u", "Coverage utilisation", f_wad(u), str(u)),
        ("π", "Premium", f_wad(pi), str(pi)),
        ("K_d", "Capital deployed", f_usdc(K_d), str(K_d)),
        ("F_net", "Face due at maturity", f_usdc(F_net), str(F_net)),
        ("r_pool", "Pool term return", f_wad(p["r_pool"]), str(p["r_pool"])),
        ("r_s", "Senior term return", f_wad(p["r_s"]), str(p["r_s"])),
        ("S_d", "Senior deployed", f_usdc(p["S_d"]), str(p["S_d"])),
        ("J_d", "Junior deployed", f_usdc(p["J_d"]), str(p["J_d"])),
        ("C_S", "Senior claim", f_usdc(p["C_S"]), str(p["C_S"])),
        ("B_0", "Cushion", f_usdc(p["B_0"]), str(p["B_0"])),
        ("A_F", "Attachment", f_wad(p["A_F"]), str(p["A_F"])),
    ]
    TABLES["worked"] = table(["Symbol", "Meaning", "Value", "Stored integer"], rows)

    # exact decomposition of the cushion, using the stored S_d, J_d and pi
    r_ex = Q(F_net, K_d) - 1
    j_part = Q(p["J_d"]) * (1 + r_ex)
    s_part = Q(p["S_d"]) * r_ex * Q(pi, WAD)
    B_exact = j_part + s_part
    gap = Q(p["B_0"]) - B_exact
    TABLES["decomp"] = table(
        ["Component", "Exact value (USDC)"],
        [("J_d (1 + r_pool)", f"{float(j_part / USDC):,.6f}"),
         ("S_d · r_pool · π", f"{float(s_part / USDC):,.6f}"),
         ("Sum", f"{float(B_exact / USDC):,.6f}"),
         ("Realised B_0", f_usdc(p["B_0"])),
         ("Realised minus exact", f"{float(gap):.6f} units")])

    # returns
    XS, XJ, fee = waterfall(F_net, p["C_S"], p["J_d"])
    sr = Q(XS - p["S_d"], p["S_d"])
    jr_gross = Q(F_net - XS - p["J_d"], p["J_d"])
    jr_net = Q(XJ - p["J_d"], p["J_d"])
    a_ex, pi_ex = Q(a, WAD), Q(pi, WAD)
    jr_formula = r_ex * (1 + pi_ex * (1 - a_ex) / a_ex)
    blended = (1 - a_ex) * r_ex * (1 - pi_ex) + a_ex * jr_formula
    TABLES["returns"] = table(
        ["Quantity", "From the waterfall", "From the closed form"],
        [("Senior term return", f"{float(sr) * 100:.6f}%",
          f"{float(r_ex * (1 - pi_ex)) * 100:.6f}%"),
         ("Junior gross term return", f"{float(jr_gross) * 100:.6f}%",
          f"{float(jr_formula) * 100:.6f}%"),
         ("Junior net term return", f"{float(jr_net) * 100:.6f}%", "Not applicable"),
         ("Weighted average of the two gross returns", "Not applicable",
          f"{float(blended) * 100:.6f}%")])

    # outcome table
    out_rows = []
    for loss in (0, 100_000, 150_000, 185_204, 185_205, 200_000, 300_000):
        P = F_net - loss * USDC
        XS, XJ, fee = waterfall(P, p["C_S"], p["J_d"])
        out_rows.append((f"{loss:,}", f_usdc(P), f_usdc(XS), f_usdc(XJ),
                         f_usdc(fee),
                         f"{float(Q(XS - p['S_d'], p['S_d'])) * 100:.6f}%",
                         f"{float(Q(XJ - p['J_d'], p['J_d'])) * 100:.4f}%"))
    TABLES["outcomes"] = table(
        ["Face loss", "Proceeds P", "Senior XS", "Junior XJ", "Fee",
         "Senior return", "Junior return"], out_rows)

    RESULTS["worked"] = {k: v for k, v in p.items()}
    RESULTS["worked"].update(u=u, B_gap_units=float(gap))
    return p


# ---------------------------------------------------------------- boundaries

def boundaries(p):
    C_S, J_d, F_net = p["C_S"], p["J_d"], p["F_net"]
    cases = [
        ("P = 0", 0),
        ("P = C_S minus 1", C_S - 1),
        ("P = C_S", C_S),
        ("P = C_S plus 1", C_S + 1),
        ("P = C_S + J_d minus 1", C_S + J_d - 1),
        ("P = C_S + J_d", C_S + J_d),
        ("P = C_S + J_d plus 1", C_S + J_d + 1),
        ("P = C_S + J_d plus 9", C_S + J_d + 9),
        ("P = C_S + J_d plus 10", C_S + J_d + 10),
        ("P = F_net", F_net),
    ]
    rows = []
    for name, P in cases:
        XS, XJ, fee = waterfall(P, C_S, J_d)
        rows.append((name, XS, XJ, fee, "Yes" if XS + XJ + fee == P else "No"))
    TABLES["boundary"] = table(["Case", "XS", "XJ", "Fee", "Sum equals P"], rows)

    # premium vectors
    prow = []
    for label, a_val in (("0.15", 15 * WAD // 100), ("0.20", 20 * WAD // 100),
                         ("0.25", 25 * WAD // 100), ("0.30", 30 * WAD // 100)):
        u = utilisation(C_MIN, a_val)
        prow.append((label, f_wad(u), f_wad(premium(u))))
    TABLES["premium_a"] = table(["Junior share a", "Utilisation u", "Premium π"], prow)

    krow = []
    for label, u in (("uT minus 1", UT - 1), ("uT", UT), ("uT plus 1", UT + 1),
                     ("0.5", WAD // 2), ("1.0", WAD)):
        krow.append((label, str(u), str(premium(u))))
    TABLES["kink"] = table(["Point", "u (stored)", "π (stored)"], krow)


# ---------------------------------------------------------------- properties

def rand_pool(rng, lo=50_000 * USDC, hi=100_000_000 * USDC, fmin=Q(95, 100), fmax=Q(120, 100)):
    K_d = rng.randrange(lo, hi)
    F_net = int(K_d * (float(fmin) + rng.random() * float(fmax - fmin)))
    a = rng.randrange(C_MIN, A_MAX + 1)
    pi = premium(utilisation(C_MIN, a))
    return K_d, F_net, a, pi


def properties():
    rng = random.Random(20260917)
    res = {}

    # P1 conservation, P2 first loss, over wide random inputs
    n, c_fail, fl_fail = 500_000, 0, 0
    for _ in range(n):
        C_S = rng.randrange(0, 10**15)
        J_d = rng.randrange(0, 10**15)
        th = rng.randrange(0, WAD // 5)
        P = rng.randrange(0, 3 * 10**15)
        XS, XJ, fee = waterfall(P, C_S, J_d, th)
        if XS + XJ + fee != P:
            c_fail += 1
        if XS < C_S and (XJ != 0 or fee != 0):
            fl_fail += 1
    res["conservation"] = (n, c_fail)
    res["first_loss"] = (n, fl_fail)

    # P3 monotonicity in P
    n, m_fail = 300_000, 0
    for _ in range(n):
        C_S = rng.randrange(0, 10**15)
        J_d = rng.randrange(0, 10**15)
        th = rng.randrange(0, WAD // 5)
        P1 = rng.randrange(0, 3 * 10**15)
        P2 = P1 + rng.randrange(0, 10**14)
        w1, w2 = waterfall(P1, C_S, J_d, th), waterfall(P2, C_S, J_d, th)
        if any(y < x for x, y in zip(w1, w2)):
            m_fail += 1
    res["monotonicity"] = (n, m_fail)

    # P4 telescoping deltas over receipt sequences
    n, t_fail = 30_000, 0
    for _ in range(n):
        C_S = rng.randrange(1, 10**14)
        J_d = rng.randrange(1, 10**14)
        th = rng.randrange(0, WAD // 5)
        P = paid_s = paid_j = paid_f = 0
        ok = True
        for _ in range(16):
            P += rng.randrange(0, 10**13)
            XS, XJ, fee = waterfall(P, C_S, J_d, th)
            if XS < paid_s or XJ < paid_j or fee < paid_f:
                ok = False
            paid_s, paid_j, paid_f = XS, XJ, fee
        if paid_s + paid_j + paid_f != P:
            ok = False
        t_fail += 0 if ok else 1
    res["telescoping"] = (n, t_fail)

    # P5 the waterfall equals the canonical tranche payoff
    n, tr_fail = 200_000, 0
    for _ in range(n):
        K_d, F_net, a, pi = rand_pool(rng)
        p = fix_pool(K_d, F_net, a, pi)
        X = rng.randrange(0, F_net + 1)
        XS, XJ, fee = waterfall(F_net - X, p["C_S"], p["J_d"])
        if p["C_S"] - XS != max(X - p["B_0"], 0):
            tr_fail += 1
        if (F_net - X) - XS != max(p["B_0"] - X, 0):
            tr_fail += 1
    res["tranche_form"] = (n, tr_fail)

    # P6 monotone protection: a larger cushion never increases the shortfall
    n, mp_fail = 300_000, 0
    for _ in range(n):
        F = rng.randrange(1, 10**15)
        B1 = rng.randrange(0, F)
        B2 = rng.randrange(B1, F + 1)
        X = rng.randrange(0, F + 1)
        if max(X - B2, 0) > max(X - B1, 0):
            mp_fail += 1
    res["monotone_protection"] = (n, mp_fail)

    # P7 cushion never understated, claim never overstated, attachment never overstated
    n = 150_000
    b_neg = c_over = af_over = 0
    b_gap_max = Q(0)
    c_gap_max = Q(0)
    for _ in range(n):
        K_d, F_net, a, pi = rand_pool(rng, fmin=Q(100, 100))
        if F_net <= K_d:
            F_net = K_d + 1
        p = fix_pool(K_d, F_net, a, pi)
        r_ex = Q(F_net, K_d) - 1
        pi_ex = Q(pi, WAD)
        C_ex = Q(p["S_d"]) * (1 + r_ex * (1 - pi_ex))
        B_ex = Q(p["J_d"]) * (1 + r_ex) + Q(p["S_d"]) * r_ex * pi_ex
        AF_ex = 1 - Q(p["C_S"], F_net)
        if Q(p["B_0"]) < B_ex:
            b_neg += 1
        if Q(p["C_S"]) > C_ex:
            c_over += 1
        if Q(p["A_F"], WAD) > AF_ex:
            af_over += 1
        b_gap_max = max(b_gap_max, Q(p["B_0"]) - B_ex)
        c_gap_max = max(c_gap_max, C_ex - Q(p["C_S"]))
    res["cushion_understated"] = (n, b_neg)
    res["claim_overstated"] = (n, c_over)
    res["attachment_overstated"] = (n, af_over)
    res["cushion_gap_max_units"] = float(b_gap_max)
    res["claim_gap_max_units"] = float(c_gap_max)

    # size independence of the dust: tiny to very large pools
    size_rows = []
    for lo, hi, label in ((10**6, 10**8, "1 to 100 USDC"),
                          (5 * 10**10, 10**11, "50k to 100k USDC"),
                          (10**13, 10**14, "10M to 100M USDC"),
                          (10**16, 10**17, "10B to 100B USDC")):
        mx = Q(0)
        neg = 0
        for _ in range(20_000):
            K_d = rng.randrange(lo, hi)
            F_net = K_d + rng.randrange(1, max(2, K_d // 5))
            a = rng.randrange(C_MIN, A_MAX + 1)
            pi = premium(utilisation(C_MIN, a))
            p = fix_pool(K_d, F_net, a, pi)
            r_ex = Q(F_net, K_d) - 1
            B_ex = Q(p["J_d"]) * (1 + r_ex) + Q(p["S_d"]) * r_ex * Q(pi, WAD)
            g = Q(p["B_0"]) - B_ex
            neg += 1 if g < 0 else 0
            mx = max(mx, g)
        size_rows.append((label, "20,000", neg, f"{float(mx):.6f}"))
    TABLES["dust_size"] = table(
        ["Pool size", "Draws", "Cases below exact", "Largest excess over exact (units)"],
        size_rows)

    # P8 attachment floor A_F >= a when F_net >= K_d, including the boundary
    n, fl_bad = 300_000, 0
    tight = None
    for i in range(n):
        K_d, F_net, a, pi = rand_pool(rng, fmin=Q(100, 100))
        if i % 10 == 0:
            F_net = K_d                                   # exact boundary
        elif F_net < K_d:
            F_net = K_d
        p = fix_pool(K_d, F_net, a, pi)
        d = p["A_F"] - a
        if d < 0:
            fl_bad += 1
        tight = d if tight is None else min(tight, d)
    res["attachment_floor"] = (n, fl_bad)
    res["attachment_floor_tightest_wad"] = tight

    # P9 split is exact
    n, sp = 300_000, 0
    for _ in range(n):
        K_d, F_net, a, pi = rand_pool(rng)
        p = fix_pool(K_d, F_net, a, pi)
        sp += 0 if p["S_d"] + p["J_d"] == K_d else 1
    res["split_exact"] = (n, sp)

    # P10 premium range and monotonicity over the admissible u domain
    prev, pm_bad, rng_bad = -1, 0, 0
    lo_u = utilisation(C_MIN, A_MAX)
    grid = 100_000
    for i in range(grid + 1):
        u = lo_u + (WAD - lo_u) * i // grid
        v = premium(u)
        if v < prev:
            pm_bad += 1
        if v < PI0 or v > PI1:
            rng_bad += 1
        prev = v
    res["premium_monotone"] = (grid + 1, pm_bad)
    res["premium_in_range"] = (grid + 1, rng_bad)

    # P11 signed chain never fails over the full space, including losses on the fill
    n, sg_fail = 300_000, 0
    for _ in range(n):
        K_d, F_net, a, pi = rand_pool(rng, fmin=Q(30, 100), fmax=Q(150, 100))
        try:
            fix_pool(K_d, max(F_net, 1), a, pi)
        except Exception:
            sg_fail += 1
    res["signed_no_failure"] = (n, sg_fail)

    # P12 unsigned chain fails whenever F_net < K_d
    n, us_fail, below = 100_000, 0, 0
    for _ in range(n):
        K_d, F_net, a, pi = rand_pool(rng, fmin=Q(80, 100), fmax=Q(120, 100))
        if F_net < K_d:
            below += 1
            try:
                fix_pool_unsigned(K_d, F_net, a, pi)
            except ArithmeticError:
                us_fail += 1
    res["unsigned_fails_below_par"] = (below, us_fail)

    # P13 no cushion: senior takes everything recovered, junior nothing
    n, nc_fail = 100_000, 0
    for _ in range(n):
        K_d, F_net, a, pi = rand_pool(rng, fmin=Q(30, 100), fmax=Q(80, 100))
        p = fix_pool(K_d, F_net, a, pi)
        if p["C_S"] <= F_net:
            continue
        P = rng.randrange(0, F_net + 1)
        XS, XJ, fee = waterfall(P, p["C_S"], p["J_d"])
        if XS != P or XJ != 0 or fee != 0:
            nc_fail += 1
    res["no_cushion_seniority"] = (n, nc_fail)

    # P14 pro rata: first loss fails in every state where senior is short,
    #     and senior exceeds its claim whenever the loss is below K_d * r_pool * pi
    n = 100_000
    short_states = short_with_junior = 0
    small_states = small_above_claim = 0
    for _ in range(n):
        K_d, F_net, a, pi = rand_pool(rng, fmin=Q(101, 100))
        p = fix_pool(K_d, F_net, a, pi)
        X = rng.randrange(0, F_net // 10)
        XS, XJ = pro_rata(F_net - X, p["S_d"], K_d)
        if XS < p["C_S"]:
            short_states += 1
            short_with_junior += 1 if XJ > 0 else 0
        thresh = Q(K_d) * (Q(F_net, K_d) - 1) * Q(pi, WAD)
        if X < thresh - 2:
            small_states += 1
            small_above_claim += 1 if XS > p["C_S"] else 0
    res["pro_rata_short"] = (short_states, short_with_junior)
    res["pro_rata_small"] = (small_states, small_above_claim)

    # P15 isolation across pools never helps senior
    n, iso_bad = 200_000, 0
    for _ in range(n):
        k = rng.randrange(2, 9)
        Xs = [rng.randrange(0, 10**12) for _ in range(k)]
        Bs = [rng.randrange(0, 10**12) for _ in range(k)]
        iso = sum(max(x - b, 0) for x, b in zip(Xs, Bs))
        pool = max(sum(Xs) - sum(Bs), 0)
        if iso < pool:
            iso_bad += 1
    res["isolation_never_helps_senior"] = (n, iso_bad)

    RESULTS["properties"] = res

    label = {
        "conservation": "Loss is conserved exactly",
        "first_loss": "Junior receives nothing while senior is short",
        "monotonicity": "Every payout is non-decreasing in proceeds",
        "telescoping": "Recovery deltas are non-negative and sum to the entitlement",
        "tranche_form": "The waterfall equals the canonical tranche payoff",
        "monotone_protection": "A larger cushion never increases the senior shortfall",
        "cushion_understated": "The realised cushion is below its exact value",
        "claim_overstated": "The stored senior claim exceeds its exact value",
        "attachment_overstated": "The stored attachment exceeds its exact value",
        "attachment_floor": "The attachment falls below the junior share at non-negative carry",
        "split_exact": "The deployed split fails to sum to the deployed capital",
        "premium_monotone": "The premium decreases somewhere on the admissible domain",
        "premium_in_range": "The premium leaves the band between its end anchors",
        "signed_no_failure": "The signed chain fails on some input",
        "no_cushion_seniority": "Senior fails to take everything when there is no cushion",
        "isolation_never_helps_senior": "Isolation gives senior a smaller loss than pooling",
    }
    rows = []
    for k, text in label.items():
        draws, fails = res[k]
        rows.append((text, f"{draws:,}", f"{fails:,}"))
    below, fails = res["unsigned_fails_below_par"]
    rows.append(("Unsigned arithmetic fails on a below par fill",
                 f"{below:,}", f"{fails:,} (expected in every case)"))
    d, b = res["pro_rata_short"]
    rows.append(("Pro rata: junior keeps value while senior is short", f"{d:,}", f"{b:,} (expected in every case)"))
    d, b = res["pro_rata_small"]
    rows.append(("Pro rata: senior exceeds its claim on a small loss", f"{d:,}", f"{b:,} (expected in every case)"))
    TABLES["properties"] = table(["Property tested", "Draws", "Failures"], rows)
    return res


# ---------------------------------------------------------------- underflow and pro rata tables

def failure_tables(p_worked):
    a = p_worked["a"]
    pi = p_worked["pi"]
    K_d = 1_000_000 * USDC
    rows = []
    for label, F in (("Healthy fill", 1_010_000), ("At par", 1_000_000),
                     ("One unit below par", None), ("0.5% below par", 995_000),
                     ("Below senior capital", 800_000)):
        F_net = K_d - 1 if F is None else F * USDC
        try:
            fix_pool_unsigned(K_d, F_net, a, pi)
            u = "Completes"
        except ArithmeticError:
            u = "Fails"
        p = fix_pool(K_d, F_net, a, pi)
        rows.append((label, f"{float(Q(F_net, K_d)):.12f}", u,
                     f"{float(Q(p['A_F'], WAD)) * 100:.4f}%",
                     f"{float(Q(p['A_F_published'], WAD)) * 100:.4f}%"))
    TABLES["underflow"] = table(
        ["Fill", "F_net / K_d", "Unsigned", "Signed attachment", "Published attachment"], rows)

    p = fix_pool(K_d, 800_000 * USDC, a, pi)
    rows = []
    for P in (0, 400_000 * USDC, 800_000 * USDC):
        XS, XJ, fee = waterfall(P, p["C_S"], p["J_d"])
        rows.append((f_usdc(P), f_usdc(XS), f_usdc(XJ)))
    TABLES["no_cushion"] = table(["Proceeds P", "Senior XS", "Junior XJ"], rows)
    RESULTS["no_cushion_claim"] = p["C_S"]

    pw = p_worked
    rows = []
    for loss in (0, 50_000, 150_000):
        P = pw["F_net"] - loss * USDC
        ws, wj, _ = waterfall(P, pw["C_S"], pw["J_d"])
        ps, pj = pro_rata(P, pw["S_d"], pw["K_d"])
        rows.append((f"{loss:,}", f_usdc(ws), f_usdc(ps), f_usdc(wj), f_usdc(pj)))
    TABLES["pro_rata"] = table(
        ["Face loss", "Senior, waterfall", "Senior, pro rata",
         "Junior, waterfall", "Junior, pro rata"], rows)
    ps, _ = pro_rata(pw["F_net"], pw["S_d"], pw["K_d"])
    excess = ps - pw["C_S"]
    closed = Q(pw["S_d"]) * (Q(pw["F_net"], pw["K_d"]) - 1) * Q(pw["pi"], WAD)
    RESULTS["pro_rata_excess"] = (excess, float(closed))


# ---------------------------------------------------------------- main

if __name__ == "__main__":
    p = worked_example()
    boundaries(p)
    res = properties()
    failure_tables(p)

    with open("audit_tables.md", "w") as fh:
        for k, v in TABLES.items():
            fh.write(f"<!-- {k} -->\n{v}\n\n")

    def enc(o):
        if isinstance(o, tuple):
            return list(o)
        return o
    with open("audit_results.json", "w") as fh:
        json.dump({k: v for k, v in RESULTS.items()}, fh, indent=1, default=str)

    print("Worked example")
    print(TABLES["worked"])
    print("\nCushion decomposition")
    print(TABLES["decomp"])
    print("\nReturns")
    print(TABLES["returns"])
    print("\nOutcomes")
    print(TABLES["outcomes"])
    print("\nProperties")
    print(TABLES["properties"])
    print("\nDust by size")
    print(TABLES["dust_size"])
    print(f"\ncushion gap max {res['cushion_gap_max_units']:.6f} units, "
          f"claim gap max {res['claim_gap_max_units']:.6f} units, "
          f"attachment floor tightest {res['attachment_floor_tightest_wad']} wad")
    print("\nUnderflow")
    print(TABLES["underflow"])
    print("\nNo cushion")
    print(TABLES["no_cushion"])
    print("\nPro rata")
    print(TABLES["pro_rata"])
    print(f"\npro rata excess at zero loss: {RESULTS['pro_rata_excess']}")
