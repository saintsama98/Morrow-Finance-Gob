# Morrow Finance: exact integer twins of the Solidity math libraries (wadMath, premiumCurve, seriesMath, epochMath).
# @author adiii.eth

WAD = 10**18
UINT_MAX = 2**256 - 1


def mul_div_down(x, y, d):
    if d == 0:
        raise ZeroDivisionError("DivisionByZero")
    r = x * y // d
    if r > UINT_MAX:
        raise OverflowError("MulDivOverflow")
    return r


def mul_div_up(x, y, d):
    r = mul_div_down(x, y, d)
    if (x * y) % d > 0:
        if r == UINT_MAX:
            raise OverflowError("MulDivOverflow")
        r += 1
    return r


def premium_pi(u, u_t, pi0, pi_t, pi1):
    if not (pi0 <= pi_t <= pi1 < WAD):
        raise ValueError("InvalidAnchors")
    u = min(u, WAD)
    if u < u_t:
        return pi_t - mul_div_down(u_t - u, pi_t - pi0, u_t)
    return pi_t + mul_div_up(u - u_t, pi1 - pi_t, WAD - u_t)


def allocation_split(k_deployed, junior_share):
    senior = mul_div_down(k_deployed, WAD - junior_share, WAD)
    return senior, k_deployed - senior


def price(k_deployed, junior_share, face_net, pi_wad):
    senior, junior = allocation_split(k_deployed, junior_share)
    if face_net <= k_deployed:
        negative_carry, pool_rate, senior_rate, claim = True, 0, 0, senior
    else:
        negative_carry = False
        pool_rate = mul_div_down(face_net, WAD, k_deployed) - WAD
        senior_rate = mul_div_down(pool_rate, WAD - pi_wad, WAD)
        claim = senior + mul_div_down(senior, senior_rate, WAD)
    claim_over_face = mul_div_up(claim, WAD, face_net)
    attachment = 0 if claim_over_face >= WAD else WAD - claim_over_face
    return {
        "seniorDeployed": senior,
        "juniorDeployed": junior,
        "poolRateWad": pool_rate,
        "seniorRateWad": senior_rate,
        "seniorClaim": claim,
        "attachmentWad": attachment,
        "buffer0": face_net - claim,
        "negativeCarry": negative_carry,
    }


def nav(elapsed, tau, k_deployed, face_net, face_loss, senior_deployed, senior_claim, junior_deployed, theta):
    s = min(elapsed, tau)
    accretion = mul_div_down(face_net - k_deployed, s, tau) if tau > 0 and face_net >= k_deployed else 0
    gross = k_deployed + accretion
    v = gross - face_loss if gross > face_loss else 0
    senior_accretion = (
        mul_div_down(senior_claim - senior_deployed, s, tau) if tau > 0 and senior_claim >= senior_deployed else 0
    )
    mark = senior_deployed + senior_accretion
    nav_s = mark if mark < v else v
    junior_gross = v - nav_s
    fee = mul_div_down(junior_gross - junior_deployed, theta, WAD) if junior_gross > junior_deployed else 0
    return nav_s, junior_gross - fee, fee


def waterfall(proceeds, senior_claim, junior_deployed, theta):
    senior_paid = min(proceeds, senior_claim)
    residual = proceeds - senior_paid
    fee = mul_div_down(residual - junior_deployed, theta, WAD) if residual > junior_deployed else 0
    return senior_paid, residual - fee, fee


def waterfall_pass_through(proceeds, senior_deployed, k_deployed):
    senior_paid = 0 if k_deployed == 0 else mul_div_down(proceeds, senior_deployed, k_deployed)
    return senior_paid, proceeds - senior_paid


def redemption_price(pps_close, pps_now):
    return min(pps_close, pps_now)


def deposit_price(pps_close, pps_now):
    return max(pps_close, pps_now)


def shares_fillable(remaining, available, price_wad):
    if price_wad == 0:
        return 0
    return min(remaining, mul_div_down(available, WAD, price_wad))


def assets_for_shares(shares, price_wad):
    return mul_div_down(shares, price_wad, WAD)


def shares_for_assets(assets, price_wad):
    if price_wad == 0:
        return 0
    return mul_div_down(assets, WAD, price_wad)
