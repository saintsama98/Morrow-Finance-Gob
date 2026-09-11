"""Pure Python twin of the Solidity math libraries (WadMath, PremiumCurve, SeriesMath, EpochMath).

Every function here must reproduce its Solidity counterpart bit-for-bit on the same inputs. Rounding rules
follow build spec section 5.4: senior claim and every payout round down, junior is the exact residual. Integer
division `//` is floor (round down for non-negative operands); `ceil_div` is round up. Amounts are USDC base
units (6 decimals, plain Python ints); ratios are wad-scaled ints (1e18 == 1.0).

Differential tests (contracts/test/differential/*.t.sol) load vectors generated from this file via
sim/vectors/generate.py and assert exact equality against the Solidity implementation.
"""

from __future__ import annotations

from dataclasses import dataclass

WAD = 10**18


def mul_div_down(x: int, y: int, d: int) -> int:
    if d == 0:
        raise ZeroDivisionError("mulDivDown: division by zero")
    return (x * y) // d


def ceil_div(n: int, d: int) -> int:
    if d == 0:
        raise ZeroDivisionError("ceil_div: division by zero")
    return -(-n // d)


def mul_div_up(x: int, y: int, d: int) -> int:
    if d == 0:
        raise ZeroDivisionError("mulDivUp: division by zero")
    return ceil_div(x * y, d)


def w_mul_down(x: int, y: int) -> int:
    return mul_div_down(x, y, WAD)


def w_mul_up(x: int, y: int) -> int:
    return mul_div_up(x, y, WAD)


def w_div_down(x: int, y: int) -> int:
    return mul_div_down(x, WAD, y)


def w_div_up(x: int, y: int) -> int:
    return mul_div_up(x, WAD, y)


# --- PremiumCurve (section 9.2) ---------------------------------------------------------------


def premium_pi(u: int, u_t: int, pi0: int, pi_t: int, pi1: int) -> int:
    assert pi0 <= pi_t <= pi1 < WAD, "invalid anchors"
    if u > WAD:
        u = WAD
    if u < u_t:
        delta = mul_div_down(u_t - u, pi_t - pi0, u_t)
        return pi_t - delta
    else:
        delta = mul_div_up(u - u_t, pi1 - pi_t, WAD - u_t)
        return pi_t + delta


# --- SeriesMath (sections 9.3, 12.4, 13.5, 13.6) ----------------------------------------------


@dataclass
class PricingResult:
    senior_deployed: int
    junior_deployed: int
    pool_rate_wad: int
    senior_rate_wad: int
    senior_claim: int
    attachment_wad: int
    buffer0: int
    negative_carry: bool


def allocation_split(k_deployed: int, junior_share_wad: int) -> tuple[int, int]:
    senior_deployed = mul_div_down(k_deployed, WAD - junior_share_wad, WAD)
    junior_deployed = k_deployed - senior_deployed
    return senior_deployed, junior_deployed


def price(k_deployed: int, junior_share_wad: int, face_net_at_finalize: int, pi_wad: int) -> PricingResult:
    senior_deployed, junior_deployed = allocation_split(k_deployed, junior_share_wad)

    if face_net_at_finalize <= k_deployed:
        negative_carry = True
        pool_rate_wad = 0
        senior_rate_wad = 0
        senior_claim = senior_deployed
    else:
        negative_carry = False
        pool_rate_wad = mul_div_down(face_net_at_finalize, WAD, k_deployed) - WAD
        senior_rate_wad = mul_div_down(pool_rate_wad, WAD - pi_wad, WAD)
        senior_claim = senior_deployed + mul_div_down(senior_deployed, senior_rate_wad, WAD)

    claim_over_face = mul_div_up(senior_claim, WAD, face_net_at_finalize)
    attachment_wad = 0 if claim_over_face >= WAD else WAD - claim_over_face

    buffer0 = face_net_at_finalize - senior_claim

    return PricingResult(
        senior_deployed=senior_deployed,
        junior_deployed=junior_deployed,
        pool_rate_wad=pool_rate_wad,
        senior_rate_wad=senior_rate_wad,
        senior_claim=senior_claim,
        attachment_wad=attachment_wad,
        buffer0=buffer0,
        negative_carry=negative_carry,
    )


def nav(
    elapsed: int,
    tau: int,
    k_deployed: int,
    face_net_at_finalize: int,
    face_loss: int,
    senior_deployed: int,
    senior_claim: int,
    junior_deployed: int,
    theta_wad: int,
) -> tuple[int, int, int]:
    s = min(elapsed, tau)

    if tau == 0:
        accretion = 0
    elif face_net_at_finalize >= k_deployed:
        accretion = mul_div_down(face_net_at_finalize - k_deployed, s, tau)
    else:
        accretion = 0

    gross_v = k_deployed + accretion
    v = gross_v - face_loss if gross_v > face_loss else 0

    if tau == 0:
        senior_accretion = 0
    elif senior_claim >= senior_deployed:
        senior_accretion = mul_div_down(senior_claim - senior_deployed, s, tau)
    else:
        senior_accretion = 0

    senior_mark = senior_deployed + senior_accretion
    nav_s = senior_mark if senior_mark < v else v

    nav_j_gross = v - nav_s

    fee_accrued = mul_div_down(nav_j_gross - junior_deployed, theta_wad, WAD) if nav_j_gross > junior_deployed else 0
    nav_j = nav_j_gross - fee_accrued

    return nav_s, nav_j, fee_accrued


def nav_pass_through(v: int, senior_deployed: int, k_deployed: int) -> tuple[int, int]:
    nav_s = 0 if k_deployed == 0 else mul_div_down(v, senior_deployed, k_deployed)
    nav_j = v - nav_s
    return nav_s, nav_j


def waterfall(proceeds: int, senior_claim: int, junior_deployed: int, theta_wad: int) -> tuple[int, int, int]:
    senior_paid = proceeds if proceeds < senior_claim else senior_claim
    residual_to_junior = proceeds - senior_paid
    fee = (
        mul_div_down(residual_to_junior - junior_deployed, theta_wad, WAD)
        if residual_to_junior > junior_deployed
        else 0
    )
    junior_paid = residual_to_junior - fee
    return senior_paid, junior_paid, fee


def waterfall_pass_through(proceeds: int, senior_deployed: int, k_deployed: int) -> tuple[int, int]:
    senior_paid = 0 if k_deployed == 0 else mul_div_down(proceeds, senior_deployed, k_deployed)
    junior_paid = proceeds - senior_paid
    return senior_paid, junior_paid


# --- identities used by the simulation (section 9.4) ----------------------------------------


def identity_senior_rate(a_f_wad: int, r_pool_wad: int, a_wad: int) -> int:
    """1 + r_s == (1 - A_F) * (1 + r_pool) / (1 - a). Returns 1 + r_s in wad."""
    return w_div_down(w_mul_down(WAD - a_f_wad, WAD + r_pool_wad), WAD - a_wad)


def identity_junior_return(r_pool_wad: int, pi_wad: int, a_wad: int) -> int:
    """r_J == r_pool * (1 + pi * (1 - a) / a), zero losses and zero fee. Returns r_J in wad (can be negative)."""
    factor = WAD + w_div_down(w_mul_down(pi_wad, WAD - a_wad), a_wad)
    return w_mul_down(r_pool_wad, factor)
