# Morrow Finance (Gob): Verification Record

This document records the testing and analysis performed on the Gob contracts, the results, the defects found and how each was resolved, and the limits of what the evidence shows. Every result below can be reproduced from this repository with the commands given.

Passing tests and clean scanner output are evidence, not proof of security. Each result is classified as one of: implementation bug, test gap, specification gap, violated assumption, tooling limitation, or confirmed property within a stated scope. The contracts have not been reviewed by an external auditor.

## 1. Scope and environment

| Item | Value |
|---|---|
| Contracts in scope | `contracts/src` (vaults, core, series engine, parking adapters, libraries) |
| Toolchain | Foundry 1.7.1, solc 0.8.34, `via_ir`, EVM `osaka`, optimizer 200 runs |
| Dependencies | Morpho Midnight (git submodule), Morpho Blue as vendored inside Midnight, OpenZeppelin, forge-std |
| Chain for fork tests | Base mainnet, chain id 8453 |
| Static analysis | Slither 0.11.5, Aderyn 0.6.8 |
| Stateful fuzzing | Medusa, Echidna |
| Symbolic execution | Halmos |
| Date of the record | 2026-10-05 |

## 2. Reproducing

```
git submodule update --init --recursive
forge build
forge test                                      # unit, scenario, fuzz, formal twins, invariants (fork tests skip)
BASE_RPC_URL=<base rpc> forge test --match-path "contracts/test/fork/*" --threads 1
python3 docs/morrow-finance-gob-reference_model.py
python3 docs/morrow-finance-gob-stress_model.py
```

The default profile runs fuzz tests at 10,000 runs and invariants at 512 runs of depth 128. `memory_limit` is raised to 256 MiB in `foundry.toml` because the round-level crash replays step through every Chainlink round of a month.

Further entry points are listed in each section below.

## 3. Summary

| Layer | What ran | Result |
|---|---|---|
| Unit | 24 suites, 264 tests | all pass |
| Scenario | 24 suites, 48 tests (deterministic loss, liquidity and lifecycle scenarios, on three parking venues) | all pass |
| Formal twins | fuzz twins of the Halmos targets, 10,000 runs each | all pass |
| Invariants | 6 suites, 512 runs x 128 depth, on idle, ERC-4626 and Morpho Blue parking | 63 invariants, all pass |
| Differential | Solidity libraries against independent Python twins | pass |
| Mutation | 24 hand-written mutants on value-bearing paths | 23 killed, 1 equivalent, 0 surviving |
| Medusa and Echidna | 16 properties, 41 actions | final campaign 16 of 16 over 323,236 calls |
| Halmos | 5 `check_` targets | see section 9 |
| Slither and Aderyn | every result triaged | Slither 277 results triaged, 0 open; Aderyn 129 accepted instances, 0 new |
| Base fork | 13 suites, 97 tests at pinned blocks, real Midnight, real Morpho Blue | 96 pass, 1 skipped (no live borrower ask); three tests were corrected on the last run (TG-3) |
| Historical crash replays | 124 rolling 30-day windows, round-level month, four named crashes, de-peg and default grids | senior never impaired while junior had value |

## 4. Unit, scenario and fuzz tests

Unit suites cover every library (pricing, waterfall, epoch math, idle-loss math, full-precision mulDiv), the core's books, policy timelock and gates, the two vaults' synchronous and batched flows, the series lifecycle against a local Midnight, the factory's eligibility rules, and all three parking adapters.

Scenario suites S0 to S18 drive complete lifecycles: baseline, small and severe bad debt, junior wipe, maturity wall, stuck market, under-fill and pass-through, nothing filled, oracle manipulation, fees at caps, parking stress, exit demand above idle, loss queued before fulfilment, junior mass exit, idle yield, liquidity crunch, parking venue loss and a keeper-only lifecycle. The parking scenarios are run on the ERC-4626 venue and again on Morpho Blue.

`contracts/test/unit/MathDifferential.t.sol` checks the pricing, waterfall and epoch libraries against Python twins written independently in `sim/`. `contracts/test/unit/OfferTreeSdkDifferential.t.sol` checks offer-tree roots against vectors built with the official Midnight SDK.

## 5. Stateful invariants

Handlers drive the real core, vaults, factory and series against a local Midnight, with chaos handlers that move the market and the parking venue underneath the protocol. Suites:

| Suite | Parking venue |
|---|---|
| `CoreVaultInvariants` | idle USDC |
| `CoreVaultInvariantsNoBackstop` | idle USDC, backstop off |
| `CoreVaultInvariantsMorpho` | ERC-4626 vault with yield, loss, liquidity cap and donation knobs |
| `CoreVaultInvariantsBlue` | Morpho Blue market (mock built on Blue's own share math and accrual) with yield, loss, liquidity cap, donation to the adapter and supply on behalf of the adapter, and the one-way exit to cash |
| `NoValueLeakage`, `SeriesInvariants` | series-level conservation and lifecycle |

The properties include: core cash equals reserved plus pending; vault assets equal core books; reserved cash covers every unclaimed entitlement; batch pro-rata soundness and pricing direction; batch ledgers balance; fills are oldest first; series counts within caps; every parking share belongs to the core or a funded series; parking accounts never exceed the pool; the Blue share count is backed by the market's record; a parking loss never reaches senior idle while junior idle covers it.

| Suite | Invariants | Result at 512 x 128 |
|---|---|---|
| `CoreVaultInvariantsBlue` | 15, plus one regression test | pass |
| `CoreVaultInvariantsMorpho` | 14 | pass |
| `CoreVaultInvariantsNoBackstop` | 12 | pass |
| `CoreVaultInvariants` | 11 | pass |
| `SeriesInvariants` | 10 | pass |
| `F10_NoValueLeakage` | 1 | pass |

Each invariant ran 512 sequences of 128 calls, 65,536 calls in total. A short metrics run confirms that every chaos action on the Blue venue is exercised.

## 6. Stateful fuzzing with Medusa and Echidna

Harness: `contracts/test/crytic/MorrowCrytic.sol`, configs `medusa.json` and `echidna.yaml` in the same folder. Forge-std assertions run through cheatcodes neither engine implements, so the harness is separate from the Foundry handlers. It deploys the real core, both vaults and the ERC-4626 parking adapter (the Blue adapter is covered by the Foundry suite `CoreVaultInvariantsBlue`), drives them through actor contracts, and exposes 41 actions (every deposit, request, cancel, claim, transfer, operator and permissionless batch step, time warps, parking yield, loss, liquidity, donation and rebalance, pause).

Properties (16): USDC conservation; core cash and books against parking; vault assets against books; reserved covers owed; pro-rata soundness; batch prices within bounds; batch ledgers; oldest-first; queued demand; no stranded batch; no stranded request slot; claims never exceed owed; operator windows respected; junior coverage after every exit fill that moves shares; idle loss is junior first.

```
cd contracts/test/crytic && medusa fuzz --config medusa.json
echidna contracts/test/crytic/MorrowCrytic.sol --contract MorrowCrytic --config contracts/test/crytic/echidna.yaml
```

| Campaign | Calls | Result |
|---|---|---|
| Medusa, 30 min | 331,798 | 14 of 15 pass; coverage property failed (see F-P1) |
| Medusa, 30 min, corrected property | 329,099 | 15 of 15 |
| Echidna, 30 min | 41,712 | 15 of 15 |
| Medusa, after junior-first idle loss was added | 66,967 (stopped at the first failure, 6 min 22 s) | 15 of 16; idle-loss property failed (see W-1) |
| Medusa, final code | 323,236 | 16 of 16 |

## 7. Mutation testing

24 mutants were written by hand against value-bearing paths and applied one at a time to a disposable copy of the sources. Each was scored against the full local suite.

| Result | Count | Notes |
|---|---|---|
| Killed | 23 | including two that first survived (M08, M12) and were killed by new tests |
| Equivalent | 1 | M13: the strict transfer check in `collect` cannot be reached with honest Midnight and USDC; it is a defensive check |
| Surviving | 0 | |

Mutants covered: batch pricing direction for entries and exits, senior payout cap, junior premium, fee base, premium curve, batch detach, entry slot clearing, controller checks, zero-asset claims, short-paying parking, the fill allocation cap, settlement order, the stress gate, the backstop cap, oldest-first fills, parking share rounding, reserved accounting, the yield split, fee binding, gated markets and the threshold ceiling. M16 (backstop cap) is killed only indirectly.

## 8. Static analysis

```
slither . --filter-paths "lib/|test/"            # uses slither.db.json, reports only new results
aderyn . --src contracts/src -o cache/aderyn-new.json
```

`slither.db.json` holds every accepted Slither result with its classification. `aderyn.baseline.json` lists the accepted Aderyn instances; a new run is compared against it:

```
python3 -c "import json;k=lambda d:{(i['title'],x['contract_path'],x['line_no']) for s in ('high_issues','low_issues') for i in d[s]['issues'] for x in i['instances']};b=set(map(tuple,json.load(open('aderyn.baseline.json'))['accepted']));n=k(json.load(open('cache/aderyn-new.json')));print(sorted(n-b) or 'no new Aderyn results')"
```

| Tool | Results | Implementation bugs | Accepted with reason |
|---|---|---|---|
| Slither | 277 across all runs (3 High, the rest Medium, Low and Informational) | one root cause behind two High results (F-02), fixed | all others, each recorded with its class in `slither.db.json` |
| Aderyn | 129 instances | none | all, listed in `aderyn.baseline.json` |

The High results that remain accepted:
- `arbitrary-send-erc20` on the junior deposit request: the pulled address must be the caller or have made the caller its operator, and since F-02 the same holds for the controller (tooling limitation; tested).
- `incorrect-exp` in the full-precision mulDiv: the XOR is the intended seed of the Newton inverse (tooling limitation; fuzz and differential tested).
- `reentrancy-balance` in `collect` and in the exit reservation: only Midnight's withdraw or the trusted parking venue runs between the two balance reads. A donation cannot break the check, and a venue that pays short reverts (confirmed property within that trust scope; tested).

The Medium and Low results are reentrancy into trusted callees (USDC, the immutable parking adapter, Midnight, factory-created series) under `nonReentrant` or role checks; bounded loops; day-scale timestamps; deliberate tuple destructuring; strict equalities used as guards; and the governance setters, which are kept as they are and listed in section 13. One Slither run reported a single result that did not reproduce on the next run; every subsequent run reports 0.

## 9. Symbolic execution (Halmos)

| Target | Property | Status |
|---|---|---|
| `EpochDetachMath.check_detachNeverDilutesOthers` | removing a cancelling controller from a batch keeps the ledger valid and never dilutes or overpays the others | no counterexample; the available solvers time out on the degree-three products. A hand proof and a 10,000-run fuzz twin over the full `uint128` range stand in. |
| `IdleLossMath.check_conservation` | the junior-first move never creates or destroys claims | fuzz twin passes; symbolic run pending on the 1e36 price scale |
| `IdleLossMath.check_onlyJuniorToSenior_andBounded` | claims move only from junior to senior, at most junior's claims | fuzz twin passes; symbolic run pending |
| `IdleLossMath.check_noMoveAtOrAboveTheMark` | nothing moves while the price is at or above the mark | symbolic run pending |
| `IdleLossMath.check_seniorKeepsItsMarkedValue_whileJuniorCovers` | while junior has claims left, senior keeps its marked value within two base units plus one claim's price | fuzz twin passes; symbolic run pending |

```
FOUNDRY_OUT=cache/halmos-out halmos --root . --forge-build-out cache/halmos-out --contract IdleLossMathTest --function check_
```

## 10. Base mainnet fork tests

All fork suites run at pinned blocks against the deployed contracts. The pinned runtime code hashes of Midnight, its SetterRatifier and its mempool are asserted before anything else runs.

| Group | What it shows |
|---|---|
| f0 to f7 | Series opened on real Midnight; a real borrower takes the series bid; repaid maturity settles and pays a senior exit; unrepaid maturity is liquidated and settles; bad debt on real Midnight hits junior first; a two-maturity ladder settles and rolls. f3 (taker path) is skipped: no borrower ask exists on an eligible market at the pinned block. |
| A0 to A10 | The live market ids match the Midnight API; standard series, ladders, two-collateral baskets, a defaulting basket written off junior first, recovery after write-off reopening the gate, overdue liquidation of a two-collateral borrower, threshold band edges, pass-through below the minimum size, cancellation with exact cash return. |
| O1 to O3 | Eligibility against every live market in the Midnight API snapshot: 7 class E markets pass; 2 are refused by the oracle allowlist and 2 (cbBTC at 0.915, cursor 0.30) by the cursor rule; 9 above-ceiling markets and a cbBTC market priced by a cbETH oracle are refused. |
| Blue parking | Against the real Morpho Blue cbBTC/USDC 0.86 market (the same oracle contract as the series markets): every fill is funded from Blue inside Midnight's buy callback (about 541k gas for register plus take); the adapter's valuation equals Blue's after interest accrual at four points; series settle; senior and junior exits are paid out of Blue with yield (1,514,284.5 USDC on 1.5M senior, 505,684.5 on 500k junior); the one-way exit to cash returns everything liquid. |
| Stress on Blue | The tranche-mechanics and crash-realism suites are run twice, once with idle USDC and once with idle cash lent in the real Blue market. Every assertion holds on both venues; junior payouts on Blue are slightly higher from Blue interest. |

## 11. Stress tests and historical crash replays

The reference book for the stress suites is a cbBTC series of 319,704.70 USDC senior claim and 79,597.31 USDC junior, built from borrowers placed at 70 to 79 percent of their liquidation threshold on the real Midnight market. Prices follow recorded paths. Three liquidator models are used: L1 liquidates when profitable after capacity and slippage; L2 liquidates with a set delay; L3 is absent until the maturity auction.

### 11.1 Rolling windows (H1)

124 rolling 30-day windows from April 2024 to September 2026, daily closes, on BTC and ETH.

| Liquidator | Windows with junior principal loss | Worst junior loss | Windows with senior loss |
|---|---|---|---|
| L1 profit-bound | 34 | 32.01% | 0 |
| L3 absent | 17 | 74.77% | 0 |

### 11.2 Round-level replay (H1r)

Every Chainlink round from 8 January to 7 February 2026.

| Liquidator | Liquidations | Junior paid on 79,597.31 | Senior |
|---|---|---|---|
| L1 profit-bound | 10 during the crash | 78,894.15 | paid in full |
| L2 120-minute delay | 10 during the crash | 78,894.15 | paid in full |
| L3 absent | 7 at the maturity auction | 43,487.47 | paid in full |

### 11.3 Crash realism (H2) and named crashes (C1 to C5)

| Event | Liquidator | Junior paid | Senior |
|---|---|---|---|
| Feb 2025, Apr 2025, Oct 2025, all models | L1, L2, L3 | 79,587.85 to 80,225.51 | paid in full |
| Oct 2025 with a liquidation cascade at thin depth | cascade | 72,072.88 | paid in full |
| Oct 2025 at three times depth | L3 absent | 35,027.96 | paid in full |
| C1 Oct 10 to 11 2025, real path (BTC -14.0%, ETH -19.8%) | keeper | 80,122.60 | paid in full |
| C4 Oct 2025 shape at three times depth | keeper | 76,441.15 | paid in full |
| C5 Oct 2025 to Jul 2026 bear (-52.9%), compressed | keeper | 77,046.40 | paid in full |

### 11.4 Default and recovery grids

On a 239,778 USDC senior claim and 59,697 USDC junior (mid-term, one market):
- the smallest realized loss at which junior first loses principal is 1,260 USDC;
- the smallest realized loss at which senior first loses is 64,133 USDC, about 21.5% of deployed capital;
- the timing of a loss within the term does not change its split;
- a recovery after write-off reruns the waterfall and restores both tranches, whether it arrives after 1, 30 or 180 days.

A correlated 3x-depth BTC shock across an October, November and December ladder liquidates 12 positions; all three seniors are paid in full and junior absorbs 0.7 to 1.6 thousand USDC per series.

### 11.5 Structural stress

| Test | Result |
|---|---|
| cbBTC de-peg of 25%, oracle blind, L1 | no liquidation needed; both tranches paid in full |
| cbBTC de-peg of 40%, oracle blind, L3 or naive keeper | positions liquidated at the maturity auction; both tranches paid in full |
| cbBTC de-peg of 40%, oracle blind, L1 bidding on real value | no liquidator bids; the series is written off with nothing collected; later recoveries rerun the waterfall. This is the accepted oracle limitation in section 13. |
| D1: de-peg default with the backstop on | senior's shortfall is covered from junior idle (170,151 USDC); the stress gate closes |
| D2a, D2b | with the backstop off another series' legs are untouched; with it on only junior idle moves |
| E1 | donations during stress never move the books |
| S1: shared real market | outside lenders absorb 33.56% of the bad debt Morrow's borrowers cause, and part of the series' credit waits on outside borrowers before the market resolves (Midnight design) |
| T2 to T6 | flows across loss stages; junior front-running an unrealized loss (an operator fill before realization pays the pre-loss price; a permissionless fill after it pays the post-loss price); a fully wiped junior; an exit batch spanning a write-off pays the post-loss price |

### 11.6 Real liquidation day replay (B1, B2)

The busiest real liquidation day on Midnight, 16 July 2026, is replayed transaction by transaction with the feed rounds of the time while Morrow holds a live series in the market. In the WETH market 2 of 24 real liquidations replay directly; senior is paid in full and the series settles.

The cbBTC market of that day has a threshold of 0.915 and a liquidation cursor of 0.30. It passed the same replay before the cursor rule was added (2 of 19 transactions replayed, 8 liquidation effects re-applied, senior paid in full). It is now refused by the factory, and B2 asserts that refusal.

### 11.7 Correlated crash across a series and parking

`contracts/test/scenario/CorrelatedCrashBlue.t.sol` crashes one collateral that both a series market and the Blue parking market depend on, across a grid of crash depth and parking loss.

Senior deposits 1,000,000 USDC and junior 1,000,000. A series deploys 850,000. The rest is parked. Returns are on each book at settlement.

| Collateral crash | Blue loss 0% | 2% | 5% | 15% |
|---|---|---|---|---|
| 20% | senior +0.26%, junior -1.52% | +0.26%, -3.69% | +0.26%, -6.94% | +0.26%, -17.78% |
| 30% | +0.26%, -11.31% | +0.26%, -13.48% | +0.26%, -16.73% | +0.26%, -27.57% |
| 40% | +0.26%, -21.11% | +0.26%, -23.27% | +0.26%, -26.52% | +0.26%, -37.36% |

Senior's return is the same in every cell: both the series loss and the parking loss land on junior.

## 12. Defects found and their resolution

| Id | Class | Defect | Resolution | Regression |
|---|---|---|---|---|
| F-01 | implementation bug | Settlement ran the waterfall before marking the series settled, so it never left the live set and the stress gate closed senior deposits after every clean settlement | state set before the waterfall | `S18_KeeperOnlyLifecycle`, fork f4 and f7 |
| F-02 | implementation bug | Anyone could open a request naming another address as controller; a dust redeem then locked that controller's slot permanently | controller authorisation on every request; a full-remainder claim worth zero clears the slot | `ControllerSlotGriefing.t.sol` |
| F-03 | implementation bug | Exit reservation trusted the parking venue to pay in full | balance delta, revert on short payment | `AdversarialParking.t.sol` M1b |
| F-04 | implementation bug | ERC-4626 parking let an account with no shares withdraw up to 100 base units of dust per call | dust tolerance only for accounts with shares; built into Blue parking | `MorphoParking.t.sol`, `BlueParking.t.sol` |
| F-05 | implementation bug | The junior-first idle-loss mark kept about 12 significant digits, so each settle point could shave about 1e-12 of the senior book off senior | mark held at 1e36 scale | `IdleLossMath.t.sol` exact-value twin; `CoreVaultInvariantsBlue` regression |
| O-01 | specification gap | Senior exit fills were capped at idle above the floor, so a full exit completed only over many batches | exits may use the whole idle, floor included | `SeniorVault.t.sol`, S11 |
| W-1 | specification gap | Junior-first idle loss is measured from the last settle point, so a gain accrued since then is shared pro rata by a later loss | the permissionless `syncAll` and the backstop settle first; the residual window is documented in section 13 | Medusa property 16, `CoreIdleLossJuniorFirst.t.sol` |
| M08, M12 | test gap | Two mutants survived: an entry slot cleared while a cancel refund was pending, and the fill allocation cap | new tests kill both; the production checks were correct | `ControllerSlotGriefing.t.sol`, `SeriesCallbackReentrancy.t.sol` |
| F-P1 | test gap | The junior coverage property fired on a no-op fill after market moves shifted coverage by a fraction of a base unit | the property fires only after a fill that moved shares, in both harnesses | `MorrowCryticRepro.t.sol` |
| TG-1 | test gap | The junior-first check inside the parking chaos handler was an assertion in a handler, which the invariant runner counts as a revert rather than a failure; it hid F-05 | the handler records a ghost counter that an invariant asserts | `invariant_parkingLossIsJuniorFirst` on two venues |
| TG-2 | test gap | Scenario S11's sanity check compared assets with shares and could never fail | compares assets with assets; the scenario deploys part of senior so demand really exceeds idle | S11 |
| TG-3 | test gap and tooling limitation | Three fork tests failed on the last full run after the Blue venue and the cursor rule were added. T5 deposited senior at exactly four times junior, which Blue's round-down on supply puts one base unit over capacity. B2 opened a series in a 0.915 market that the cursor rule now refuses. The two round-level H1r replays exceeded forge's default 128 MiB EVM memory. | T5 funds both books with a 10 USDC margin; B2 now asserts the refusal; the memory limit is raised. The H1r results are identical to the base unit to the earlier run. | the tests themselves |

## 13. Limitations and trust assumptions

- **Not audited.** No external review has taken place.
- **Oracle.** The cbBTC oracle prices cbBTC as BTC. A de-peg of cbBTC is invisible to it; section 11.5 shows the worst case. Midnight uses its price feed without a staleness check.
- **Shared markets.** Bad debt and withdrawable cash in a Midnight market are shared with other lenders. A series can wait on outside borrowers before its market resolves.
- **Parking venue.** The parking adapter is immutable and trusted. Morpho Blue lending is not cash: the Blue market can take bad debt, and its liquidity can be borrowed out. Losses there are carried junior first, limited by junior's idle cash.
- **Idle loss window.** The junior-first rule restores senior to its value at the last settle point. Gains accrued since then are shared pro rata if a loss arrives first. Keepers are expected to call `syncAll` on a regular cadence. Precision: senior is restored to within two base units.
- **Junior-first idle protection is unpriced.** Junior provides it without a separate premium.
- **Governance setters.** Role setters emit no events, `setVaults` and `setCore` are one-shot, and governance transfer is single step. Deployment arguments must be verified.
- **USDC.** The code assumes USDC charges no transfer fee and has no transfer hooks.
- **Stress inputs.** The stress tests replay recorded paths on a reference book; they do not forecast. Tenor and buffer simulations in the arithmetic document are pending.
- **Not run.** Certora formal verification and an independent economic review have not been run.
