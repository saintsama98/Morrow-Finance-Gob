# Morrow: A Mathematical Model of Dated Senior and Junior Credit

This document sets out the mathematics behind Morrow. It defines every variable, states every expression, explains why each one takes the form it does, and verifies the arithmetic against exact rational computation.

It contains three kinds of statement. Derivations are true given the definitions. Audited results come from an exact integer reference implementation and can be reproduced by anyone. Simulation results depend on modelled market behaviour and are marked as pending where they have not yet been inserted.

---

## Morrow tranches fixed maturity credit

Morrow pools capital from two sources and lends it into fixed maturity credit markets. One source takes a senior claim: a fixed amount owed at maturity, paid first. The other takes a junior claim: whatever remains after the senior claim is paid, and the first loss if the loans perform badly.

Each pool is called a series. A series raises capital once, lends it into one or more markets that share a single maturity date, waits until that date, collects what the markets return, and divides it between the two claims in a fixed order. A series never reopens and none of its terms change after deployment.

Both claims hold the same proportional position in every market a series lends into. Senior does not hold the safer markets and junior the riskier ones. The difference between the claims is created entirely by the order in which proceeds are paid, not by where the capital is invested.

Several series run at once with staggered maturities. When one settles, the proceeds fund the next. This keeps capital continuously deployed while each individual series remains a closed, dated instrument with terms fixed at deployment.

---

## The underlying market is zero coupon

Morrow lends into Morpho Midnight. Each Midnight market has a fixed maturity. Lending positions are fungible credit units, and one credit unit redeems for exactly one unit of the loan token at maturity. A lender buys units at a discount and is repaid at face.

Markets are isolated. Each has its own collateral, its own liquidation threshold and its own lenders. When a liquidation leaves a shortfall, Midnight writes it down proportionally across every lender in that market through a loss factor. A lender's loss in a market is its pro rata share of that market's bad debt.

Two consequences follow. Every lender in a Midnight market holds an identical claim, so there is exactly one lender class per market and no protocol mechanism ranks one lender above another. And the only first loss layer native to a market is borrower equity, the collateral value above the debt.

Morrow therefore cannot create seniority inside a Midnight market. It creates seniority above the market, by aggregating the post loss value of its positions into one number and dividing that number between its own two claims.

---

## Notation is fixed

Values are stored as integers. Assets and credit units use six decimals. Dimensionless ratios use eighteen decimals, written WAD.

| Kind | Scale | Examples |
| --- | --- | --- |
| Assets | 10^6 | S, J, K_alloc, K_d, S_d, J_d, C_S, P, XS, XJ |
| Credit units | 10^6 | F_net |
| Ratios | 10^18 (WAD) | a, u, π, r_pool, r_s, A_F, θ |

The quantities computed for a series, in the order they are fixed:

| Symbol | Meaning | Unit | Can be negative |
| --- | --- | --- | --- |
| S | Senior capital committed | USDC | No |
| J | Junior capital committed | USDC | No |
| K_alloc | Total committed, S + J | USDC | No |
| a | Junior share of the pool | WAD | No |
| u | Coverage utilisation, how hard junior's share is being worked | WAD | No |
| π | Premium, the fraction of the pool return senior pays junior | WAD | No |
| K_d | Capital actually deployed into markets | USDC | No |
| S_d | Senior share of deployed capital | USDC | No |
| J_d | Junior share of deployed capital | USDC | No |
| F_net | Face value due at maturity, net of market fees | units | No |
| r_pool | Term return on deployed capital | WAD | Yes |
| r_s | Senior term return after the premium | WAD | Yes |
| C_S | Senior claim, the fixed amount senior is owed at maturity | USDC | No |
| B_0 | Cushion, face value that can be lost before senior is affected | USDC | Yes |
| A_F | Attachment, the cushion as a fraction of face | WAD | Yes |

The quantities produced at settlement:

| Symbol | Meaning | Unit |
| --- | --- | --- |
| P | Cumulative proceeds recovered from the markets | USDC |
| X | Face loss, F_net minus P | USDC |
| XS | Senior entitlement | USDC |
| XJ | Junior entitlement | USDC |
| fee | Fee on junior profit above principal | USDC |

The parameters, fixed per series at open:

| Symbol | Meaning | Default | Basis |
| --- | --- | --- | --- |
| c | Minimum junior share | 0.15 | Chosen |
| a_max | Maximum junior share | 0.30 | Chosen |
| π_0, π_T, π_1 | Premium at u = 0, at the kink, at u = 1 | 0.10, 0.20, 0.35 | Chosen |
| u_T | Location of the premium kink | 0.90 | Chosen |
| θ | Fee rate on junior profit above principal | 0.10 | Chosen |
| K_min | Minimum deployed size for a tranche | 50,000 USDC | Chosen |
| L_max | Highest permitted liquidation threshold | 0.86 | Chosen, see market selection |
| ψ | Ceiling on mean borrower LTV relative to the threshold | 0.85 | Chosen, see market selection |
| τ | Series tenor | 180 days | Simulation, see tenor section |
| N | Series running at once | 9 | Simulation, see buffer section |
| b_min, b_max | Bounds on the liquidity buffer | 0.02, 0.08 | Simulation, see buffer section |

Chosen means set conservatively without calibration. No parameter in this table has been fitted to operating data, because none exists yet.

---

## Two primitives perform every division

Every rounding decision in the model is made by one of two functions, applied to non negative integers.

```
mulDivDown(x, y, d) = floor(x · y / d)
mulDivUp(x, y, d)   = ceil(x · y / d)
```

Where a quantity must sum exactly with another, it is computed as a residual by subtraction and never by its own division. Three quantities are residuals: J_d, XJ and the junior share of any split. This is what makes conservation exact rather than approximate.

The general rule for direction is that a division rounds so as to leave value inside the pool, and never in favour of the party whose action triggers it. Each direction below is stated with its reason.

---

## The pool is split at open

```
K_alloc = S + J
a       = mulDivDown(J, WAD, K_alloc)
u       = mulDivUp(c, WAD, a)
```

A series may open only if c ≤ a ≤ a_max. The junior share a rounds down so that a pool which clears the minimum only by rounding up is rejected. Utilisation u rounds up because a higher u raises the premium, which favours the party providing protection.

The two directions are opposite by design. Because a is at least c, utilisation never exceeds one. Because a is at most a_max, utilisation is at least c divided by a_max, which is 0.5 at the defaults.

---

## The premium rises with utilisation

The premium is piecewise linear in u, with a shallow slope below the kink and a steep one above it.

```
u < u_T :  π = π_T − mulDivDown(u_T − u, π_T − π_0, u_T)
u ≥ u_T :  π = π_T + mulDivUp(u − u_T, π_1 − π_T, WAD − u_T)
```

The lower branch subtracts a quantity rounded down and the upper branch adds a quantity rounded up, so π rounds up on both sides using only the two primitives. The branches meet at π_T when u equals u_T, so the curve is continuous.

When junior is thin relative to the minimum, u approaches one and junior's capital is working hard. The premium rises steeply there because junior is closest to exhaustion. At the defaults the slope is about 0.11 below the kink and 1.5 above it.

| Junior share a | Utilisation u | Premium π |
| --- | --- | --- |
| 0.15 | 1.000000000000000000 | 0.350000000000000000 |
| 0.20 | 0.750000000000000000 | 0.183333333333333334 |
| 0.25 | 0.600000000000000000 | 0.166666666666666667 |
| 0.30 | 0.500000000000000000 | 0.155555555555555556 |

At the kink the stored values are shown below. The upper branch moves in steps of at least two units because its ceiling rounds a fractional step up. The curve remains monotone.

| Point | u (stored) | π (stored) |
| --- | --- | --- |
| uT minus 1 | 899999999999999999 | 200000000000000000 |
| uT | 900000000000000000 | 200000000000000000 |
| uT plus 1 | 900000000000000001 | 200000000000000002 |
| 0.5 | 500000000000000000 | 155555555555555556 |
| 1.0 | 1000000000000000000 | 350000000000000000 |

---

## Deployment fixes the pool

Deployment rarely fills completely. The quantities that matter are those of the capital actually lent.

```
S_d    = mulDivDown(K_d, WAD − a, WAD)
J_d    = K_d − S_d
r_pool = mulDivDown(F_net, WAD, K_d) − WAD
```

S_d rounds down and J_d is its residual, so S_d plus J_d equals K_d exactly with no remainder. The pool return r_pool rounds down because it flows into the senior claim, which must not be overstated.

The expression for r_pool divides credit units by USDC. That is meaningful only because one credit unit redeems for exactly one loan token at maturity. The one to one redemption is a property of the underlying market, and every rate in this model depends on it.

---

## Negative carry is clamped

If the deployed capital buys no more face than it cost, the pool earns nothing. In that case the senior return is set to zero and the senior claim to senior's deployed principal.

```
if F_net ≤ K_d :  r_s = 0,  C_S = S_d
```

The comparison is made on the raw values F_net and K_d before any subtraction. Branching on the computed r_pool instead would require computing a negative value first, which fails in unsigned arithmetic. Senior remains first in the payment order under the clamp. It simply earns nothing.

---

## The senior claim is fixed at deployment

When the pool return is positive, senior receives the pool return less the premium.

```
r_s = mulDivDown(r_pool, WAD − π, WAD)
C_S = S_d + mulDivDown(S_d, r_s, WAD)
```

Both round down. C_S is the most senior can ever receive from the series and it is never recalculated. Rounding it down means the promised amount never exceeds its exact value, which is the direction that keeps the cushion beneath it intact.

---

## The cushion has three components

The cushion is the face value that can be lost before senior is affected.

```
B_0 = F_net − C_S
A_F = WAD − mulDivUp(C_S, WAD, F_net)
```

The division inside A_F rounds up so that A_F itself rounds down. A published attachment must never overstate the protection senior has.

Substituting F_net = K_d(1 + r_pool) and C_S = S_d(1 + r_pool(1 − π)) into B_0 and collecting terms gives an identity for what the cushion is made of.

```
B_0 = J_d (1 + r_pool) + S_d · r_pool · π
```

The cushion is junior's principal, plus the return junior earns on it, plus the part of the pool return that senior surrendered for protection. The premium is therefore not only junior's compensation. It adds directly to the cushion that protects senior, so raising the premium improves both claims at once.

| Component | Exact value (USDC) |
| --- | --- |
| J_d (1 + r_pool) | 183,636.363637 |
| S_d · r_pool · π | 1,568.181818 |
| Sum | 185,204.545455 |
| Realised B_0 | 185,204.545456 |
| Realised minus exact | 0.629750 units |

The realised cushion exceeds the exact decomposition by 0.63 of a unit, where one unit is 10^-6 USDC. The rounding section explains why the excess is always non negative and always below about one unit.

---

## The cushion never falls below the junior share

Proposition. If F_net ≥ K_d, then A_F ≥ a.

Proof. The ratio C_S / F_net equals (1 − a)(1 + r_s) / (1 + r_pool). Since π is non negative, r_s is at most r_pool, so the ratio is at most 1 − a. Therefore A_F = 1 − C_S / F_net is at least a. The rounding directions of S_d, r_s and C_S all move the ratio down, and the ceiling in A_F cannot push it past the bound because the bound is itself an integer.

The bound is tight. It holds with equality when F_net equals K_d, and the audit confirms equality at that boundary. Above it, the excess of A_F over a is exactly the premium term S_d · r_pool · π expressed as a fraction of face.

This gives the minimum junior share c a direct meaning. Whenever the pool return is non negative, senior is protected against a face loss of at least c, whatever the rates, fills or premium turn out to be.

---

## Returns split exactly

The senior and junior term returns have closed forms.

```
senior:        r_pool (1 − π)
junior gross:  r_pool (1 + π (1 − a) / a)
```

The junior expression follows from dividing B_0 by J_d. The factor (1 − a)/a is the ratio of senior to junior capital, so junior's return is the pool return plus the premium levered by that ratio. Weighting the two gross returns by 1 − a and a recovers r_pool exactly, as it must.

| Quantity | From the waterfall | From the closed form |
| --- | --- | --- |
| Senior term return | 0.808333% | 0.808333% |
| Junior gross term return | 1.862500% | 1.862500% |
| Junior net term return | 1.676250% | Not applicable |
| Weighted average of the two gross returns | Not applicable | 1.000000% |

Junior's net return is its gross return less the fee on profit above principal. The fee applies only when junior receives more than J_d.

---

## The waterfall pays senior first

At settlement the proceeds P are divided as follows.

```
XS  = min(C_S, P)
RJ  = P − XS
fee = mulDivDown(max(RJ, J_d) − J_d, θ, WAD)
XJ  = RJ − fee
```

Senior takes proceeds up to its claim and nothing beyond it. Junior takes what remains. The fee is charged only on the part of junior's remainder above its principal, so a series in which junior does not recover its principal pays no fee. XJ is the residual, so XS + XJ + fee equals P exactly.

As a function of P the three payouts are piecewise linear.

| Range of P | XS | XJ | fee | Slope of XJ |
| --- | --- | --- | --- | --- |
| 0 to C_S | P | 0 | 0 | 0 |
| C_S to C_S + J_d | C_S | P − C_S | 0 | 1 |
| Above C_S + J_d | C_S | J_d + (P − C_S − J_d)(1 − θ) | (P − C_S − J_d) θ | 1 − θ |

Senior is a line that rises and then caps. Junior is zero, then rises one for one, then rises at 1 − θ. That shape is the tranche.

---

## The waterfall is a tranche payoff

Measure the face loss as X = F_net − P. Substituting into the waterfall gives two identities that hold exactly in integers for every X between zero and F_net.

```
C_S − XS = max(X − B_0, 0)
RJ       = max(B_0 − X, 0)
```

The senior shortfall is the loss above the cushion. Junior's gross proceeds are the cushion less the loss, floored at zero. Written as losses against the no loss outcome, this is the canonical tranche payoff.

```
L_J = min(X, B_0)
L_S = max(X − B_0, 0)
```

The cushion B_0 is the attachment point. Junior absorbs every loss up to it and senior absorbs every loss beyond it.

---

## Recoveries rerun the waterfall

Recoveries can arrive after maturity, so P can grow after the first distribution. The waterfall is rerun on cumulative P and only the increase in each entitlement is paid.

Every payout is non decreasing in P. XS is the minimum of a constant and an increasing function. XJ has slopes 0, 1 and 1 − θ, all non negative. The fee has slopes 0 and θ. So every increment paid on a rerun is non negative, and the increments sum to the final entitlement.

This matters because a payout that could fall as P rose would require recovering money already paid. A senior entitlement that could shrink when a recovery arrived would be the opposite of seniority.

---

## Three properties define subordination

A division of a pooled loss X into a senior loss and a junior loss is a subordination if and only if it satisfies three properties.

| Property | Statement |
| --- | --- |
| Conservation | L_S + L_J = X in every state |
| First loss | L_S = 0 whenever X ≤ B_0 |
| Monotone protection | A larger cushion never increases L_S |

The waterfall satisfies all three, as the audit confirms. A structure missing any one of them is not a tranche, whatever it is called.

The third property gives a practical test. Remove the junior claim and recompute the senior loss. If the senior loss does not increase in any state, the junior claim was providing no protection.

---

## Maturity does not create seniority

A proposal that recurs in dated credit is to treat short maturity exposure as senior and long maturity exposure as junior. The three properties show why this fails. Senior capital in one market and junior capital in another produce two independent losses with no common X, so conservation has nothing to conserve.

First loss fails because the short market can lose while the long market is whole. Monotone protection fails because removing the long market changes the short market's loss by nothing. By the test above, there is no subordination.

The underlying reason is general. Maturity is a parameter of the distribution of loss. Seniority is a map applied to a realised loss. Changing a distribution cannot produce a pathwise reallocation between two parties, so maturity can shape risk but cannot rank claims.

Structured finance separates these as time tranching, which orders when claimants are repaid, and credit tranching, which orders who absorbs loss. In sequential pay structures the senior class often has the shorter life, but it is short because it is senior. Priority is the cause and short duration the consequence.

---

## Losses are isolated per series

Each series has its own cushion and no capital in one series absorbs a loss in another. Senior's total loss across n series is therefore the sum of per series shortfalls.

Proposition. For losses X_k and cushions B_k,

```
Σ max(X_k − B_k, 0)  ≥  max(Σ X_k − Σ B_k, 0)
```

The left side is senior's loss under isolation and the right side is what it would be if the cushions were pooled. The inequality follows from the positive part being subadditive. Equality holds when every X_k − B_k has the same sign, which is the case when series losses move together.

Two consequences follow. With a single collateral family and overlapping maturities, series losses are strongly correlated and isolation costs senior little. As collateral diversifies, the gap widens, and the benefit of diversification accrues to junior rather than to senior.

---

## Rounding never overstates the senior claim

Every division in the chain from deployment to the cushion rounds in the direction that keeps the senior claim at or below its exact value and the cushion at or above its exact value.

The bound on the cushion can be stated precisely for F_net > K_d. Let B_exact be the decomposition J_d(1 + r) + S_d · r · π, where r is the exact ratio F_net / K_d − 1 and S_d, J_d and π are the stored values. Then

```
0  ≤  B_0 − B_exact  <  1 + 2 · S_d / 10^18      (in units of 10^-6 USDC)
```

The lower bound holds because F_net equals K_d(1 + r) exactly while each rounded term of C_S is at most its exact value. The upper bound collects the three floors in r_pool, r_s and C_S. For any pool below one hundred million USDC the bound is below 1.0002 units, about one millionth of a USDC.

| Pool size | Draws | Cases below exact | Largest excess over exact (units) |
| --- | --- | --- | --- |
| 1 to 100 USDC | 20,000 | 0 | 0.999994 |
| 50k to 100k USDC | 20,000 | 0 | 0.999933 |
| 10M to 100M USDC | 20,000 | 0 | 0.999981 |
| 10B to 100B USDC | 20,000 | 0 | 1.112153 |

The excess grows only with S_d / 10^18, so it stays near one unit for pools from one USDC to one hundred billion USDC and becomes material at no realistic scale.

---

## Signed arithmetic keeps every pool settleable

Two subtractions in the deployment chain can produce a negative value.

```
r_pool = mulDivDown(F_net, WAD, K_d) − WAD      negative when F_net < K_d
A_F    = WAD − mulDivUp(C_S, WAD, F_net)        negative when C_S > F_net
```

If these quantities are held as unsigned integers, each subtraction fails at execution. The first fails on any fill one unit below par, which is an ordinary outcome of a disappointing deployment rather than an extreme one.

Reverting at this point would be worse than the condition it guards against. By the time the pool is fixed, capital has already been lent to borrowers and cannot be recalled. A pool that cannot complete deployment cannot reach settlement either, so its capital would be stranded until maturity with no path to distribute it.

The model therefore holds r_pool, r_s, A_F and B_0 as signed values, branches on F_net ≤ K_d before subtracting, publishes the attachment as max(A_F, 0), and always completes.

| Fill | F_net / K_d | Unsigned | Signed attachment | Published attachment |
| --- | --- | --- | --- | --- |
| Healthy fill | 1.010000000000 | Completes | 18.3371% | 18.3371% |
| At par | 1.000000000000 | Completes | 18.1818% | 18.1818% |
| One unit below par | 0.999999999999 | Fails | 18.1818% | 18.1818% |
| 0.5% below par | 0.995000000000 | Fails | 17.7707% | 17.7707% |
| Below senior capital | 0.800000000000 | Fails | -2.2727% | 0.0000% |

Completing is safe because the waterfall already handles a missing cushion correctly. When C_S exceeds F_net, every attainable P is below C_S, so XS equals P and XJ equals zero. Senior receives everything recovered and junior receives nothing.

| Proceeds P | Senior XS | Junior XJ |
| --- | --- | --- |
| 0.000000 | 0.000000 | 0.000000 |
| 400,000.000000 | 400,000.000000 | 0.000000 |
| 800,000.000000 | 800,000.000000 | 0.000000 |

In the table the deployed capital is 1,000,000 USDC, face due is 800,000 and the senior claim is 818,181.818181. Seniority holds with no cushion at all.

---

## Undersized pools are not tranched

A series that deploys less than K_min could be settled pro rata instead of through the waterfall, with senior receiving P · S_d / K_d. This allocation is not a subordination, and it fails in two directions rather than one.

Whenever senior falls below its claim, junior still holds value, so first loss fails. And whenever the face loss is below K_d · r_pool · π, which is 1,916.67 USDC in the example, senior receives more than its claim, so the cap fails. At zero loss the excess over the claim equals S_d · r_pool · π, 1,568.181818 USDC in the example, which is the premium senior paid for protection it did not receive.

| Face loss | Senior, waterfall | Senior, pro rata | Junior, waterfall | Junior, pro rata |
| --- | --- | --- | --- | --- |
| 0 | 824,795.454544 | 826,363.636362 | 184,865.909093 | 183,636.363638 |
| 50,000 | 824,795.454544 | 785,454.545453 | 135,204.545456 | 174,545.454547 |
| 150,000 | 824,795.454544 | 703,636.363635 | 35,204.545456 | 156,363.636365 |

Pro rata settlement therefore converts the senior claim into a proportional equity claim for that series, sharing both losses and gains and refunding the premium. The model treats pools below K_min as outside the tranche structure.

---

## The audit reproduces every number

The reference implementation computes every quantity in this document with the same order of operations and the same rounding as the protocol. It then compares each result with exact rational arithmetic from the same stored inputs, so each rounding direction is verified rather than assumed.

The worked example uses S = 900,000 and J = 200,000 USDC, a fill of 1,000,000 USDC that buys 1,010,000 units of face, market fees of zero, and the default parameters.

| Symbol | Meaning | Value | Stored integer |
| --- | --- | --- | --- |
| S | Senior capital committed | 900,000.000000 | 900000000000 |
| J | Junior capital committed | 200,000.000000 | 200000000000 |
| K_alloc | Total committed | 1,100,000.000000 | 1100000000000 |
| a | Junior share | 0.181818181818181818 | 181818181818181818 |
| u | Coverage utilisation | 0.825000000000000001 | 825000000000000001 |
| π | Premium | 0.191666666666666667 | 191666666666666667 |
| K_d | Capital deployed | 1,000,000.000000 | 1000000000000 |
| F_net | Face due at maturity | 1,010,000.000000 | 1010000000000 |
| r_pool | Pool term return | 0.010000000000000000 | 10000000000000000 |
| r_s | Senior term return | 0.008083333333333333 | 8083333333333333 |
| S_d | Senior deployed | 818,181.818181 | 818181818181 |
| J_d | Junior deployed | 181,818.181819 | 181818181819 |
| C_S | Senior claim | 824,795.454544 | 824795454544 |
| B_0 | Cushion | 185,204.545456 | 185204545456 |
| A_F | Attachment | 0.183370837085148514 | 183370837085148514 |

Two stored values sit one unit above their decimal expansions. The stored u is 0.825 plus one unit and the stored π is 0.191666 rounded up in its last place. Both are the ceilings behaving as intended. J_d ends in 819 rather than 818 because it is the residual that absorbs the rounding in S_d.

Settlement outcomes across a range of face losses:

| Face loss | Proceeds P | Senior XS | Junior XJ | Fee | Senior return | Junior return |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 1,010,000.000000 | 824,795.454544 | 184,865.909093 | 338.636363 | 0.808333% | 1.6763% |
| 100,000 | 910,000.000000 | 824,795.454544 | 85,204.545456 | 0.000000 | 0.808333% | -53.1375% |
| 150,000 | 860,000.000000 | 824,795.454544 | 35,204.545456 | 0.000000 | 0.808333% | -80.6375% |
| 185,204 | 824,796.000000 | 824,795.454544 | 0.545456 | 0.000000 | 0.808333% | -99.9997% |
| 185,205 | 824,795.000000 | 824,795.000000 | 0.000000 | 0.000000 | 0.808278% | -100.0000% |
| 200,000 | 810,000.000000 | 810,000.000000 | 0.000000 | 0.000000 | -1.000000% | -100.0000% |
| 300,000 | 710,000.000000 | 710,000.000000 | 0.000000 | 0.000000 | -13.222222% | -100.0000% |

Senior earns its full claim until the loss exceeds the cushion of 185,204.545456. At a loss of 185,205 the proceeds fall 0.454544 below the claim and senior receives 824,795.000000. Junior is exhausted at the same point.

Boundary values of the waterfall, every one of which is a fixed test vector:

| Case | XS | XJ | Fee | Sum equals P |
| --- | --- | --- | --- | --- |
| P = 0 | 0 | 0 | 0 | Yes |
| P = C_S minus 1 | 824795454543 | 0 | 0 | Yes |
| P = C_S | 824795454544 | 0 | 0 | Yes |
| P = C_S plus 1 | 824795454544 | 1 | 0 | Yes |
| P = C_S + J_d minus 1 | 824795454544 | 181818181818 | 0 | Yes |
| P = C_S + J_d | 824795454544 | 181818181819 | 0 | Yes |
| P = C_S + J_d plus 1 | 824795454544 | 181818181820 | 0 | Yes |
| P = C_S + J_d plus 9 | 824795454544 | 181818181828 | 0 | Yes |
| P = C_S + J_d plus 10 | 824795454544 | 181818181828 | 1 | Yes |
| P = F_net | 824795454544 | 184865909093 | 338636363 | Yes |

The fee is exactly zero at P = C_S + J_d and remains zero for the first nine units of junior profit, because the fee rounds down. It first reaches one unit at ten units of profit.

Randomised property checks, each counting the states in which the stated property fails:

| Property tested | Draws | Failures |
| --- | --- | --- |
| Loss is conserved exactly | 500,000 | 0 |
| Junior receives nothing while senior is short | 500,000 | 0 |
| Every payout is non-decreasing in proceeds | 300,000 | 0 |
| Recovery deltas are non-negative and sum to the entitlement | 30,000 | 0 |
| The waterfall equals the canonical tranche payoff | 200,000 | 0 |
| A larger cushion never increases the senior shortfall | 300,000 | 0 |
| The realised cushion is below its exact value | 150,000 | 0 |
| The stored senior claim exceeds its exact value | 150,000 | 0 |
| The stored attachment exceeds its exact value | 150,000 | 0 |
| The attachment falls below the junior share at non-negative carry | 300,000 | 0 |
| The deployed split fails to sum to the deployed capital | 300,000 | 0 |
| The premium decreases somewhere on the admissible domain | 100,001 | 0 |
| The premium leaves the band between its end anchors | 100,001 | 0 |
| The signed chain fails on some input | 300,000 | 0 |
| Senior fails to take everything when there is no cushion | 100,000 | 0 |
| Isolation gives senior a smaller loss than pooling | 200,000 | 0 |
| Unsigned arithmetic fails on a below par fill | 50,025 | 50,025 (expected in every case) |
| Pro rata: junior keeps value while senior is short | 82,851 | 82,851 (expected in every case) |
| Pro rata: senior exceeds its claim on a small loss | 17,149 | 17,149 (expected in every case) |

Every structural property holds with zero failures. The three rows marked expected: all confirm the failure modes described above occur in every state where they should. The attachment floor holds with equality at zero carry, which is the tightest case the bound allows.

---

## Loss requires a gap through the buffer

The market model begins from a fact about liquidation. An orderly price decline, however deep, does not create bad debt. The position crosses its liquidation threshold, a liquidator acts, the collateral is sold and the lender is repaid. The loss falls on the borrower's equity.

Bad debt requires the price to move through the whole liquidation buffer faster than liquidation can clear it. That requires a gap, an absent liquidator or a congested clearing process. Loss is a friction phenomenon, which rules out any model in which lender loss simply grows with price variance.

A liquidator seizes collateral worth the incentive factor M times the debt repaid, where M is defined as follows.

```
M = 1 / (1 − γ (1 − LLTV))
```

Here γ is the liquidation cursor and LLTV is the liquidation threshold. Seizure remains fully collateralised while the loan to value is at most 1/M. Three quantities follow.

```
Breakeven LTV   = 1 − γ (1 − LLTV)
Solvent band    = (1 − γ)(1 − LLTV)
Minimum gap g*  = ln( (1 − γ (1 − LLTV)) / LLTV )
```

The minimum gap g* is the smallest instantaneous log price move that takes a position from its liquidation threshold to insolvency. A gap smaller than g* is absorbed by liquidation. A larger gap produces bad debt.

| LLTV | γ | Incentive factor | Liquidator discount | Breakeven LTV | Solvent band | Minimum gap g* |
| --- | --- | --- | --- | --- | --- | --- |
| 0.77 | 0.5 | 1.1299 | 12.99% | 0.8850 | 0.1150 | 13.92% |
| 0.86 | 0.25 | 1.0363 | 3.63% | 0.9650 | 0.1050 | 11.52% |
| 0.86 | 0.5 | 1.0753 | 7.53% | 0.9300 | 0.0700 | 7.83% |
| 0.915 | 0.5 | 1.0444 | 4.44% | 0.9575 | 0.0425 | 4.54% |
| 0.945 | 0.5 | 1.0283 | 2.83% | 0.9725 | 0.0275 | 2.87% |
| 0.98 | 0.5 | 1.0101 | 1.01% | 0.9900 | 0.0100 | 1.02% |

The table shows why the top of the threshold ladder is dangerous. At an LLTV of 0.98 the liquidator's discount is about 1 percent, below plausible execution cost in stress, and the gap to insolvency is about 1 percent.

It also shows what γ is. A higher cursor raises the liquidator's discount, which helps liquidation clear, and narrows the solvent band. It is a subsidy paid from borrower equity to buy execution speed, useful where the buffer is thin and wasteful where it is wide. It does not rank lenders.

---

## Distance to the threshold sets frequency

For a borrower at loan to value LTV_0, the log distance to the liquidation threshold is b_0 = ln(LLTV / LTV_0). Expressed in standard deviations over a horizon τ with annual volatility σ,

```
z = ln(LLTV / LTV_0) / (σ √τ)
```

This is the only scale on which markets with different collateral, tenor and borrower leverage can be compared. A 30 day market on a volatile asset and a 120 day market on a calm one can have the same z.

Liquidation can occur at any moment during the term, not only at maturity. By the reflection principle, with zero drift the probability that the threshold is touched during the term is

```
P(touch within τ) = 2 Φ(−z)
```

Here Φ is the standard normal distribution function. This is about twice the probability of ending below the threshold. For a borrower at 0.70 in a 0.86 market at 60 percent volatility, it is about 23, 49 and 62 percent at 30, 90 and 180 days.

Debt accrues over the term, so the buffer erodes even with no price movement. The drift of b_0 is −σ²/2 minus the accrual rate, which is negative. The zero drift formula is therefore slightly optimistic, which is acceptable for comparison and not for a safety margin.

---

## Expected loss has three factors

Expected lender loss in a market decomposes as

```
E[loss] = P(liquidation) × P(bad debt | liquidation) × E[loss | bad debt]
```

The first factor is frequency and is governed by z. The second is conditional failure and is governed by g*, execution cost and clearing capacity. The third is severity. The decomposition makes clear which levers act where.

Tenor enters the first factor through σ√τ. It does not enter the second, because what happens once a position reaches its threshold depends on the local dynamics at that moment and not on how long the term is. LLTV and γ enter the second through g*. Seniority appears in none of the three, because it acts on the division of the realised loss.

---

## Market selection bounds the buffer

A market is eligible for a series only if it satisfies four constraints. Each follows from the quantities above.

| Constraint | Statement | Reason |
| --- | --- | --- |
| Threshold ceiling | LLTV ≤ L_max | Bad debt rises steeply as the solvent band narrows |
| Cursor rule | γ = 0.50 when LLTV ≥ 0.915 | A higher cursor is worth its cost only where the band is thin |
| Borrower buffer | Debt weighted mean borrower LTV ≤ ψ · LLTV | Sets a floor under b_0 and therefore under z |
| Tenor tier | LLTV ≤ 0.86 when τ exceeds 91 days | A longer term gives collateral more room to move |

At the defaults the cursor rule and the tenor tier do not bind, because L_max is already 0.86. They take effect only if the threshold ceiling is raised.

The borrower buffer constraint is the most consequential. It is the only one that acts on the starting distance b_0, which the stress results below show to be the largest single driver of loss. Borrower positions are public, so the constraint can be evaluated exactly at the moment a series opens.

---

## Stress thresholds are computed, not forecast

A stress threshold is the smallest instantaneous collateral price shock that produces a given outcome for a series. It is computed deterministically by passing the shock through each borrower's loan to value, the liquidation incentive, recovery, the market loss factor and the waterfall, then solving for the shock.

Recovery depends on whether the incentive clears execution cost. If M − 1 exceeds the cost, a liquidator acts and recovers the collateral value divided by M. If not, no liquidator bids, the position clears late at the full cost, and recovery falls sharply. This produces a discontinuity at an execution cost equal to M − 1.

The inputs readable from the chain are borrower collateral and debt, the collateral price, LLTV, γ and the series share of each market. The inputs that cannot be read, execution cost and whether liquidators are active, are varied rather than assumed. Correlation between markets is set to one.

The tables below use a synthetic reference book of three borrowers in one market, with LLTV 0.86 and γ 0.50. The series holds 1,010,000 of the market's 4,040,000 units of face, and total borrower debt equals total face. The book is illustrative and does not describe any live market.

At an execution cost of 2 percent:

| Borrower book | First liquidation | First bad debt | Junior exhausted | Senior down 10% |
| --- | --- | --- | --- | --- |
| Conservative | 27.9% | 33.3% | 48.3% | 53.9% |
| Median | 12.8% | 19.4% | 37.2% | 43.9% |
| Levered | 1.7% | 9.1% | 27.6% | 35.4% |

At an execution cost of 20 percent, above the 7.53 percent incentive:

| Borrower book | First liquidation | First bad debt | Junior exhausted | Senior down 10% |
| --- | --- | --- | --- | --- |
| Conservative | 27.9% | 27.9% | 39.9% | 46.4% |
| Median | 12.8% | 12.8% | 27.0% | 34.8% |
| Levered | 1.7% | 1.7% | 15.8% | 24.9% |

At a 2 percent execution cost the borrower book moves the point at which junior is exhausted by about twenty percentage points, with the threshold, cursor and tenor unchanged. That is the quantitative case for the borrower buffer constraint.

The discontinuity at the incentive, for the median book at a 30 percent shock:

| Execution cost | Pool loss at a 30% shock (USDC) | Junior return |
| --- | --- | --- |
| 2.00% | 91,062 | -48.22% |
| 5.00% | 91,062 | -48.22% |
| 7.00% | 91,062 | -48.22% |
| 7.52% | 91,062 | -48.22% |
| 7.54% | 96,398 | -51.16% |
| 10.00% | 120,705 | -64.53% |
| 20.00% | 219,515 | -100.00% |

Loss is flat in execution cost up to 7.52 percent and jumps above 7.53 percent, where liquidators stop bidding. Liquidity depth belongs in market selection for this reason.

Named scenarios for the median book:

| Scenario | Shock | Execution cost | Liquidators active | Pool loss (USDC) | Senior return | Junior return |
| --- | --- | --- | --- | --- | --- | --- |
| Orderly decline | 15% | 1% | Yes | 0 | 0.81% | 1.68% |
| Moderate crash | 30% | 2% | Yes | 91,062 | 0.81% | -48.22% |
| Gap above the incentive | 35% | 8% | Yes | 165,875 | 0.81% | -89.37% |
| Crash with thin liquidity | 35% | 20% | Yes | 275,979 | -10.29% | -100.00% |
| Liquidation absent | 35% | 1% | No | 321,855 | -15.89% | -100.00% |

The orderly decline produces no bad debt, which is a check on the model rather than on the series. Senior earns its full claim in the first three scenarios and is impaired only after junior is exhausted.

| Live book result | Value |
| --- | --- |
| Junior exhausted, current borrower book | [Pending: computed from live market state] |
| Date and block of computation | [Pending] |

---

## Tenor is chosen per calendar year

Published parameter research asks what threshold is safe for one market over one term. Morrow asks a different question, because its capital is continuously redeployed. The relevant measure is loss per calendar year on capital that never stops working.

If expected loss over a term of length τ scales as EL(τ) = C τ^p, the annual loss rate is

```
ℓ(τ) = EL(τ) · 365 / τ  ∝  τ^(p − 1)
```

When p is below one, ℓ falls as τ rises and longer tenors are cheaper per year, even though each individual term loses more. Six 30 day terms consume six independent borrower cohorts where one 180 day term consumes one.

The first passage structure predicts p near one half when borrowers sit close to their thresholds, and above one when they start far from them, because the time spent near the threshold grows differently in the two cases. The tenor choice therefore depends on the borrower book, and the simulation must report p as a function of b_0.

The model also predicts that P(bad debt | liquidation) is invariant to tenor, since it depends on local dynamics at the threshold. If confirmed, tenor affects frequency only.

| Tenor | P(liquidation) | P(bad debt given liquidation) | Loss per term | Loss per year | Tail loss (CVaR 99) |
| --- | --- | --- | --- | --- | --- |
| 30 days | [Pending] | [Pending] | [Pending] | [Pending] | [Pending] |
| 90 days | [Pending] | [Pending] | [Pending] | [Pending] | [Pending] |
| 180 days | [Pending] | [Pending] | [Pending] | [Pending] | [Pending] |

| Borrower starting LTV | Loss at 30 days | Loss at 180 days | Fitted exponent p |
| --- | --- | --- | --- |
| Deep buffer | [Pending] | [Pending] | [Pending] |
| Median | [Pending] | [Pending] | [Pending] |
| Thin buffer | [Pending] | [Pending] | [Pending] |

---

## The liquidity buffer is sized to flow

Holders of either claim may redeem, but capital in a series is committed until maturity. Redemptions are served first from a liquidity buffer held in an open term market with the same collateral, threshold and oracle as the series markets, then from settlement proceeds, then from a queue.

With N series spread evenly over a tenor τ, the gap in days between settlements is

```
g = τ / N
```

The buffer needs to cover net outflow over one gap, not the senior claim. The first is a flow and the second a stock, and sizing against the stock overshoots by several times.

```
target = clamp( q95(net outflow over g) / total assets, b_min, b_max ) × total assets
```

Here q95 is the 95th percentile of redemptions minus deposits over any window of length g. The target is recomputed on a fixed cadence. At the defaults, 180 days and nine series give a gap of 20 days.

Deposits are liquidity. Incoming deposits pay outgoing redemptions before any series settles, so the buffer is insurance against net outflow and earns its cost only when the book is flat or shrinking. It buys service quality, not solvency, because the wait without a buffer is bounded by the gap g.

The buffer venue carries its own credit risk. It is an open term lending market, not cash, and belongs in the loss model with its own allowance.

| Flow regime | Buffer | Same day fill | Mean wait | Net yield |
| --- | --- | --- | --- | --- |
| Growing | [Pending] | [Pending] | [Pending] | [Pending] |
| Flat | [Pending] | [Pending] | [Pending] | [Pending] |
| Shrinking | [Pending] | [Pending] | [Pending] | [Pending] |
| Redemption burst | [Pending] | [Pending] | [Pending] | [Pending] |

| Series running | Gap | Buffer | Same day fill | Net yield |
| --- | --- | --- | --- | --- |
| [Pending] | [Pending] | [Pending] | [Pending] | [Pending] |

---

## The simulation stack models four things

The tenor and buffer results depend on simulated market behaviour. The stack must model four components, each for a stated reason.

| Component | What it must model | Why |
| --- | --- | --- |
| Price process | Diffusion with jumps and clustered volatility | Bad debt requires gaps, and gaps cluster in stress |
| Liquidation engine | Incentive against execution cost, clearing capacity, recovery close factor, dust threshold | Loss depends on whether and how fast liquidation clears |
| Borrower book | Starting LTV distribution, accrual, repayment at maturity | The starting distance b_0 dominates frequency |
| Flow process | Deposits, redemptions and bursts over a year | Sizes the buffer and the series cadence |

| Configuration item | Value |
| --- | --- |
| Price data source and window | [Pending] |
| Time step | [Pending] |
| Paths per configuration | [Pending] |
| Calibration target | [Pending] |
| Borrower book source | [Pending] |
| Flow data source | [Pending] |

Each reported figure should state its configuration and the number of paths behind it.

---

## The model has stated limits

The arithmetic covers how a loss is divided, not how likely it is. The audit is an independent implementation that agrees with the protocol on large random samples. It is strong evidence of correct arithmetic and is not a formal proof.

Oracle failure is outside every threshold here. The underlying market uses its price feed without a staleness check, and a wrong price is instantaneous and identical for every tenor. The controls for it are the choice of oracle and a validating wrapper, not any quantity in this model.

A Midnight position that reaches maturity unrepaid is liquidated even when its loan to value is healthy. That default channel is operational rather than price driven and is absent from the stress model. It scales with the number of maturities a book passes through.

The stress thresholds are instantaneous, which is conservative for liquidation and optimistic about the total size of a move. They have no time dimension and say nothing about tenor. Execution cost is the least certain input and is varied for that reason.

Every parameter default is chosen conservatively and not calibrated. The basis of each is stated in the notation section. Defaults will be revised against operating data rather than against models.

---

## Reproducing the results

The reference implementation and the stress model use only the Python standard library.

```
python3 reference_model.py
python3 stress_model.py
```

The first prints every table in the audit and writes them to audit_tables.md. The second prints every table in the market and stress sections and writes them to stress_tables.md. Every value in this document is generated by one of the two.

---

## References

| Author | Work | Source |
| --- | --- | --- |
| Block Analitica | A Guide for Setting On Chain Parameters on Morpho Midnight | blockanalitica.substack.com/p/a-guide-for-setting-on-chain-parameters |
| R. C. Merton | On the Pricing of Corporate Debt: The Risk Structure of Interest Rates | Journal of Finance, 1974 |
| F. Black and J. C. Cox | Valuing Corporate Securities: Some Effects of Bond Indenture Provisions | Journal of Finance, 1976 |
| R. C. Merton | Option Pricing When Underlying Stock Returns Are Discontinuous | Journal of Financial Economics, 1976 |
