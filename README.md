# Morrow-Finance-Gob  

Dated senior and junior credit tranches on Morpho Midnight, behind two vault tokens.

(** Gob - symbolizes early beta and testing cascade for the protocol, similar to early form of glass as a base material, also known as "Gob" **)

morrow runs a series engine and two vault tokens. the allocator opens series against staggered maturities on Midnight, each series lends into a basket of 1–4 ungated USDC markets maturing at the same date, and splits every outcome through a strict waterfall. senior vault holders (`srUSDC`) are paid first at maturity up to a fixed senior claim. junior vault holders (`jrUSDC`) take the first loss of every series and receive the residual.

## What Morrow does

Morrow pools USDC from two kinds of depositor and lends it into fixed-maturity credit markets on Morpho Midnight.

- **Senior** (`srUSDC`) holds a fixed claim on each series: paid first at maturity, up to an amount set when the series is priced.
- **Junior** (`jrUSDC`) takes the first loss of every series and receives the residual, including a premium paid by senior.

Capital is deployed in **series**. A series lends into a basket of Midnight markets that share one maturity date, holds the credit to maturity, collects what the markets return, and divides it between senior and junior through a fixed waterfall. Series are opened on staggered maturities, and settled cash rolls into the next series. Depositors never hold series directly; the two vault tokens are the only user-facing surface.

Seniority cannot exist inside a Midnight market, where every lender shares losses pro rata. Morrow creates it above the market by aggregating the post-loss value of its positions and splitting that one number in a fixed order.

## Architecture

| Layer | Contracts | Role |
|---|---|---|
| Vaults | `usdcSeniorVault`, `usdcJuniorVault` (with `usdcVaultBase`) | Share ledgers over the core's books. Senior deposits are synchronous (ERC-4626). Junior deposits and all exits are batched (ERC-7540 requests with ERC-7887 cancels). |
| Core | `seriesCore` | Single custody. Keeps a senior book and a junior book as claims on one parking position, a series registry, capacity and coverage rules, the stress gate, the cross-series backstop and the policy timelock. |
| Engine | `seriesFactory`, `creditSeries` (one per maturity) | Eligibility checks, offers and fills on Midnight, finalize and pricing, collection, settlement, write-off and waterfall payouts. |
| Parking | `blueParking`, `morphoParking`, `idleParking` behind `iParking` | Holds idle USDC. `blueParking` lends it directly in one Morpho Blue market whose collateral, threshold and oracle match the series markets. `morphoParking` wraps an ERC-4626 vault. `idleParking` holds plain USDC. |

Value flows down through `openSeries` and back up through `receiveReturn` (at finalize or cancel) and `receivePayout` (on every waterfall run). The vaults hold no assets.

### Series lifecycle

```
DEPLOYING   offers registered, borrowers fill the series' bids on Midnight
    | finalize: price the senior claim, return undeployed cash
LOCKED      held to maturity, marked to Midnight credit and loss factor
    | startSettlement, after maturity
SETTLING    collect repayments and liquidation proceeds
    | settle (all markets resolved) or writeOff (after the write-off delay)
SETTLED     the waterfall reruns on every later recovery
```

A series with no fills is cancelled and its cash returns to both books. A series that deploys less than its minimum size settles pro rata instead of through the waterfall.

### Fills funded just in time

The series is its own Midnight buy callback. When a borrower takes a series bid, Midnight calls the series' `onBuy`, which checks price, caps and window, then withdraws exactly the needed USDC from parking. With `blueParking`, that withdrawal comes out of the Morpho Blue position inside the same transaction.

## Pricing and the waterfall

For a series with senior `S` and junior `J`:

```
a   = J / (S + J)                     junior share, between 0.15 and 0.30
u   = 0.15 / a                        coverage utilisation
pi  = premium(u)                      piecewise linear: 0.10, 0.20 at u = 0.9, 0.35
r_s = r_pool * (1 - pi)               senior rate, from the realised pool rate
C_S = S_d * (1 + r_s)                 senior claim, fixed at finalize
```

At settlement, proceeds `P` pay senior up to `C_S`, junior the remainder, and a fee of 10% on junior profit above its principal. Recoveries rerun the waterfall on cumulative proceeds and pay only increments.

The full model, with every rounding direction and its audit, is in [`docs/morrow-finance-gob-arithmatic.md`](docs/morrow-finance-gob-arithmatic.md). Its two Python models (`docs/morrow-finance-gob-reference_model.py`, `docs/morrow-finance-gob-stress_model.py`) reproduce every number in it.

## Loss order

1. **Inside a series:** the waterfall. Junior absorbs every loss up to the cushion; senior only beyond it.
2. **Across series:** a cross-series backstop, on by default. A senior shortfall in a settled series is covered from up to 50% of junior's idle cash.
3. **On idle cash:** junior-first. A fall in the parking position's value moves claims from the junior book to the senior book until senior is restored to its value at the last settlement point, limited by junior's idle. Gains are shared pro rata. The settlement point advances on every book-changing call and on the permissionless `syncAll`.

While any live series' junior value is below half its deployed junior, the stress gate closes senior deposits.

## Roles

| Role | Can do |
|---|---|
| Senior and junior depositors | Deposit, request exits, cancel, claim |
| Allocator | Open series within policy, register offers, take asks, finalize early, operate batches |
| Curator | Set risk policy through a timelock (risk-reducing moves are instant). Must hold at least 10% of `jrUSDC`. Can pause. |
| Sentinel | Risk-reducing only: pause, lower caps, cancel an unfilled series, move Blue parking to cash |
| Governance | Factory allowlists (collateral, oracles, maximum threshold, markets per basket) behind a 48-hour timelock, role wiring |
| Keeper (anyone) | Every deadline has a permissionless path: finalize, collect, settle, write off, close and fill batches after their windows, sync |

## Market eligibility

A market is accepted into a series only if:
- its loan token is USDC and it shares the basket's maturity;
- it has no enter or liquidator gate;
- every collateral and oracle is allowlisted, and every threshold is within the factory ceiling (a deployment parameter, hard cap 0.915);
- a threshold of 0.915 or more has a liquidation cursor of at least 0.50 (cursor rule);
- a market maturing more than 91 days out has every threshold at 0.86 or below (tenor tier).

## Parameters

| Parameter | Default |
|---|---|
| Minimum junior share, maximum junior share | 0.15, 0.30 |
| Premium anchors | 0.10, 0.20 (kink at u = 0.9), 0.35 |
| Fee on junior profit | 0.10 |
| Senior capacity | 4 × junior assets |
| Junior exit coverage floor | 0.15 |
| Idle floor per book (kept out of new series, available to exits) | 0.05 |
| Stress gate | junior value below 0.50 of deployed junior in any live series |
| Backstop | on, up to 0.50 of junior idle |
| Live series, per-series size | 12, 1,000,000 USDC |
| Markets per basket | deployment parameter, hard cap 8 |
| Exit batches | permissionless close after 7 days, permissionless fill after 3 more, cancel 14 days after close |
| Blue parking raw buffer | 5% of the parking pool |

## Build and test

Foundry 1.7.1, solc 0.8.34, `via_ir`, EVM `osaka` (Midnight requires it). Dependencies are git submodules; Morpho Blue is used from the copy vendored inside Midnight.

```
forge build
forge test                                   # unit, scenario, fuzz, invariants, formal twins
BASE_RPC_URL=<base rpc> forge test --match-path "contracts/test/fork/*"   # Base mainnet fork suites
```

Fork tests are skipped when `BASE_RPC_URL` is unset. Stateful fuzzing, static analysis and symbolic checks have their own entry points, listed with every result in [`docs/VERIFICATION.md`](docs/VERIFICATION.md).

## Verification

[`docs/VERIFICATION.md`](docs/VERIFICATION.md) records everything run against this code, with the commands to reproduce it:
- unit, scenario, fuzz and invariant suites;
- differential tests against Python twins of the arithmetic;
- Slither and Aderyn, with every result triaged;
- a 24-mutant mutation campaign;
- Echidna and Medusa campaigns;
- Halmos targets;
- Base mainnet fork tests against real Midnight markets and the real Morpho Blue market;
- historical crash replays at Chainlink round level, 124 rolling windows, default and recovery grids, and a correlated crash across series and parking.

## Status

Pre-audit. Not deployed. The contracts have not been reviewed by an external auditor.

This is software, not an offer. `srUSDC` and `jrUSDC` are unregistered, and their legal characterisation depends on jurisdiction.

## License

BUSL-1.1. See [`LICENSE`](LICENSE).
