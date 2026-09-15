# Morrow-Finance-Gob (Gob - symbolizes early beta and testing cascade for the protocol, similar to early form of glass as a base material, also known as "Gob") 

dated senior and junior credit tranches on Morpho Midnight, one surface with two tokens.

morrow runs a series engine and two vault tokens. the allocator opens series against staggered maturities on Midnight, each series lends into a basket of 1–4 ungated USDC markets maturing at the same date, and splits every outcome through a strict waterfall. senior vault holders (`srUSDC`) are paid first at maturity up to a fixed senior claim. junior vault holders (`jrUSDC`) take the first loss of every series and receive the residual.

deposits are always open. senior deposits are synchronous ERC-4626. junior deposits and all redemptions go through weekly epochs with ERC-7540 async request/fulfillment. the only user-facing tokens are `srUSDC` and `jrUSDC`; series are internal state machines managed by the core.

every series locks capital from finalization until maturity, with no early exit. withdrawable liquidity from market repayments and liquidations is collected into the books and allocated into the next series. settlement is rule-based: finalize after the deployment window, collect at any time, write off after T + 7 days, settle once all markets are resolved. every deadline has a permissionless fallback, keepers earn nothing.

## system overview

| role | trust |
|---|---|
| senior depositors | deposit USDC, hold `srUSDC` shares |
| junior depositors | deposit USDC through epochs, hold `jrUSDC` shares |
| allocator | opens series, deploys capital into Midnight, runs finalization and settlement steps. a safe multisig, caps set by curator |
| curator | sets risk policy: eligible markets and oracles, coverage minimum and junior share band, premium curve anchors, caps and idle floors. must hold ≥10% of `jrUSDC` supply |
| sentinel | can only reduce risk: pause deposits, lower caps, cancel series before any fill |
| keeper | anyone. runs deadline-driven state transitions (finalize, collect, settle, writeOff, closeEpoch, fulfillEpoch) after their time has passed |
| governance | owns the factory allowlists and the curator seat, behind a 48h timelock |

## architecture

| layer | contracts | role |
|---|---|---|
| vaults (L2) | `SeniorVault`, `JuniorVault`, `EpochQueue` | share ledgers on top of the core books |
| core (L1) | `SeriesCore` | custody, books (senior and junior), series registry, coverage and capacity rules |
| engine (L0) | `SeriesFactory`, `Series` per maturity, `parking` adapters | lend into Midnight per series, run waterfall, push payouts to core |

the core holds all USDC in a parking adapter (idle capital earns yield). the vaults hold no assets; they read their value from the core's books and manage epoch requests. series are immutable per maturity and created by the core only. value moves down through `openSeries` and back up through `receiveReturn` (at finalize) and `receivePayout` (at every waterfall rerun). the roll is the product: settled cash returns to the books and is allocated into the next series.

## series lifecycle

```
DEPLOYING (allocator registers offers, borrows take bids on Midnight)
    ↓ (finalize: price senior claim, freeze rates)
LOCKED (no entry or exit, navs follow Midnight credit updates)
    ↓ (after maturity, startSettlement)
SETTLING (collect when borrowers repay or liquidators settle, sync loss)
    ↓ (all markets resolved, or T + 7 days passed)
SETTLED (rerun waterfall on recoveries until no more cash arrives)
```

cancellation if `K_d == 0` (nothing filled), returning cash to both books immediately.

## pricing and tranches

a series with allocated `S` (senior) and `J` (junior) sets `a = J / (S + J)` and `u = COV / a` (coverage utilization). a three-anchor premium curve adjusts based on `u` and `a`; the realized senior rate is `r_s = r_pool * (1 - pi(u))` where `r_pool` is net pool rate and `pi(u)` is the junior premium. senior gets a fixed claim `C_S = S_d * (1 + r_s)` priced at finalize; junior gets the residual after every loss and the operator fee (10% of junior profit by default).

early losses hit junior in full immediately (via live loss factor sync). if junior is wiped, senior takes the next loss (stress gate then closes senior deposits). if a series underperforms, recovery flows senior-first, keeping strict seniority.

## parameters (defaults)

coverage minimum `COV = 0.15`, junior share band `[0.15, 0.30]`, premium anchors `pi0/piT/pi1 = 0.10/0.20/0.35`, operator fee on junior profit `theta = 0.10`, series size typically 250k–1m USDC per maturity, max 4 markets per basket (cbBTC and WBTC collateral, ungated, Base only), write-off delay after maturity 7 days, epoch length 7 days, backstop enabled by default (junior is first loss for entire senior book).

## build

Foundry, solc 0.8.34, EVM version `osaka` (Midnight uses `clz`). tests deploy the real Midnight contract from a pinned commit, not a mock. unit tests per module, fuzz tests per main invariant, stateful invariant suite with handlers for every actor, scenario tests S0–S14 (base and fork), differential tests (Solidity vs Python twins of all math).

repository layout: `/contracts/src` (contracts), `/contracts/test` (tests), `/sim` (Python harness), `/docs` (this spec + VERIFY_LOG.md).

## status

v0.5, pre-beta. build spec is the source of truth (section 0 of `/docs/SERIES_BUILD_SPEC.md`). milestones M0–M12 lay out the build order: M0 resolves Midnight facts, M1–M8 build engine and surface, M9 forks to Base, M10 optional Vault V2 adapter, M11 simulation and risk report, M12 audit prep.

software, not an offer. `srUSDC` and `jrUSDC` are unregistered and their legal characterization is jurisdiction-specific (a launch gate).
