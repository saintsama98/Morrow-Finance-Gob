# Morrow-Finance-Gob: Verification

This document records every verification run against the Gob contracts and how each one landed: unit and scenario tests, stateful invariants, stateful fuzzing, mutation testing, static analysis, symbolic execution, differential checks against independent models, and tests against the live Base deployment, including historical crashes replayed at Chainlink round level and real bad debt in the parking market.

Passing tests and clean static analysis are evidence, not proof of security. Each result is stated with its scope. Where a tool surfaced an issue during this work, it was either fixed and covered by a regression test before the runs reported here, or it is listed under limitations. The contracts have not been reviewed by an external auditor.

## Scope and environment

| Item | Value |
|---|---|
| Contracts | `contracts/src`: vaults, core, series engine, parking adapters, libraries |
| Toolchain | Foundry 1.7.1, solc 0.8.34, `via_ir`, EVM `osaka`, optimizer 200 runs |
| Dependencies | Morpho Midnight (git submodule), Morpho Blue as vendored inside Midnight, OpenZeppelin, forge-std |
| Live deployment | Base mainnet, chain id 8453, pinned at block 51,894,109; the 16 July 2026 replay pins block 48,660,990 |
| Static analysis | Slither 0.11.5, Aderyn 0.6.8 |
| Stateful fuzzing | Medusa, Echidna |
| Symbolic execution | Halmos 0.3.3 with Bitwuzla, Yices, CVC5 and Z3 |
| Date of the record | 2026-10-06 |

## Reproducing

```
git submodule update --init --recursive
forge build
forge test                                      # unit, scenario, fuzz, formal twins, invariants (fork tests skip)
BASE_RPC_URL=<base rpc> forge test --match-path "contracts/test/fork/*" --threads 1
python3 docs/morrow-finance-gob-reference_model.py
python3 docs/morrow-finance-gob-stress_model.py
```

The default profile runs fuzz tests at 10,000 runs and invariants at 512 runs of depth 128. `memory_limit` is raised to 256 MiB in `foundry.toml` because the round-level crash replays step through every Chainlink round of a month. Commands for the other tools are given in their sections.

## Summary

| Layer | What ran | Result |
|---|---|---|
| Unit | 24 suites, 264 tests | all pass |
| Scenario | 24 suites, 48 tests: loss, liquidity and lifecycle scenarios on three parking venues | all pass |
| Invariants | 6 suites, 63 invariants, 512 runs of depth 128, on idle, ERC-4626 and Morpho Blue parking | all pass |
| Stateful fuzzing | Medusa and Echidna, 16 properties over 43 actions | final Medusa campaign: 16 of 16 over 323,236 calls |
| Mutation | 40 hand-written mutants on value-bearing paths | 39 killed, 1 equivalent, 0 surviving |
| Symbolic | Halmos on the math libraries | waterfall, allocation, pricing and batch-price properties proven, some within input bounds; see the Halmos section for what timed out or was not run |
| Differential | Solidity libraries against independent Python twins and the official Midnight SDK | bit-for-bit agreement |
| Reference model | integer reference implementation of the arithmetic | every audited figure reproduced; 80,000 random pools with no rounding against senior |
| Static analysis | Slither and Aderyn | every result classified; no open result |
| Base fork | 13 suites, 100 tests against real Midnight and real Morpho Blue, with recorded Chainlink rounds | 99 pass, 1 skipped (no live borrower ask at the pinned block) |
| Historical crashes | 124 rolling windows, a round-level month, named crashes, de-pegs, default and recovery grids | senior never impaired while junior had value; the limits are stated below |

## Unit and scenario tests

Unit suites cover every library (pricing, waterfall, epoch math, idle-loss math, full-precision mulDiv), the core's books, policy timelock and gates, both vaults' synchronous and batched flows, the series lifecycle against a local Midnight, the factory's eligibility rules and all three parking adapters.

Scenario suites S0 to S18 (there is no S14) drive complete lifecycles: baseline, small bad debt, junior wipe, maturity wall, stuck market, under-fill, micro fill with pass-through, nothing filled, oracle manipulation, fees at caps, parking stress, exit demand above idle, loss queued before fulfilment, junior mass exit, idle yield, liquidity crunch, parking venue loss and a keeper-only lifecycle. The parking scenarios run on the ERC-4626 venue and again on Morpho Blue.

A correlated crash grid (`contracts/test/scenario/CorrelatedCrashBlue.t.sol`) hits one collateral that both a series market and a local Morpho Blue parking market depend on. Senior deposits 1,000,000 USDC and junior 1,000,000; a series of 850,000 opens and fills 800,000 units of credit, and the rest is parked. Returns are on each book at settlement.

| Collateral crash | Blue loss 0% | 2% | 5% | 15% |
|---|---|---|---|---|
| 20% | senior +0.26%, junior -1.52% | +0.26%, -3.69% | +0.26%, -6.94% | +0.26%, -17.78% |
| 30% | +0.26%, -11.31% | +0.26%, -13.48% | +0.26%, -16.73% | +0.26%, -27.57% |
| 40% | +0.26%, -21.11% | +0.26%, -23.27% | +0.26%, -26.52% | +0.26%, -37.36% |

Senior's return is the same in every cell: both the series loss and the parking loss land on junior.

## Stateful invariants

Handlers drive the real core, vaults, factory and series against a local Midnight. Chaos handlers move the market and the parking venue underneath the protocol: interest, losses, liquidity squeezes, donations, and for Blue, supply on behalf of the adapter and the one-way exit to cash.

| Suite | Parking venue | Invariants | Result |
|---|---|---|---|
| `CoreVaultInvariantsBlue` | Morpho Blue market built on Blue's own share math and accrual | 15 | pass |
| `CoreVaultInvariantsMorpho` | ERC-4626 vault | 14 | pass |
| `CoreVaultInvariantsNoBackstop` | idle USDC, backstop off | 12 | pass |
| `CoreVaultInvariants` | idle USDC | 11 | pass |
| `SeriesInvariants` | series level | 10 | pass |
| `F10_NoValueLeakage` | series level | 1 | pass |

Each invariant ran 512 sequences of 128 calls. The properties include: core cash equals reserved plus pending; vault assets equal the core's books; reserved cash covers every unclaimed entitlement; batch pro-rata soundness and pricing direction; batch ledgers balance; fills are oldest first; series counts stay within caps; every parking share belongs to the core or a funded series; parking accounts never exceed the pool; the Blue share count is backed by the market's record; a parking loss never reaches senior idle while junior idle covers it. A metrics run on the Blue suite confirms that every Blue chaos action is exercised.

## Stateful fuzzing (Medusa and Echidna)

Harness: `contracts/test/crytic/MorrowCrytic.sol`, with `medusa.json` and `echidna.yaml` in the same folder. It deploys the real core, both vaults and the ERC-4626 parking adapter, drives them through actor contracts, and exposes 43 actions: every deposit, request, cancel, claim and transfer, operator and permissionless batch steps, time warps, parking yield, loss, liquidity, donation and rebalance, and pause. The Blue adapter is covered by the Foundry suite `CoreVaultInvariantsBlue`.

Properties (16): USDC conservation; core cash and books against parking; vault assets against books; reserved covers owed; pro-rata soundness; batch prices within bounds; batch ledgers; oldest first; queued demand; no stranded batch; no stranded request slot; claims never exceed owed; operator windows respected; junior coverage after every exit fill that moves shares; idle loss is junior first.

```
cd contracts/test/crytic && medusa fuzz --config medusa.json
echidna contracts/test/crytic/MorrowCrytic.sol --contract MorrowCrytic --config contracts/test/crytic/echidna.yaml
```

| Campaign | Calls | Result |
|---|---|---|
| Medusa, 30 minutes, final code | 323,236 | 16 of 16 |
| Echidna, 30 minutes | 41,712 | 15 of 15 (run before the idle-loss property was added) |

## Mutation testing

40 mutants were written by hand and applied one at a time to a disposable copy of the sources, each scored against the full local suite at reduced depth (fuzz 256 runs, invariants 24 runs of depth 64). A mutant counts as killed when at least one test fails.

| Area | Mutants | Killed | Notes |
|---|---|---|---|
| Pricing, waterfall, fees, batch pricing, batch detach, request slots, controller checks, short-paying parking, fill caps, settlement order, stress gate, backstop cap, oldest-first fills, reserved accounting, yield split, fee binding, eligibility | 24 | 23 | one equivalent: a defensive transfer check in `collect` that honest Midnight and USDC cannot reach; the backstop-cap mutant is killed indirectly |
| Blue adapter: share rounding, dust rule, position transfers, exit-to-cash access and stickiness, caller check, illiquid guard, liquidity view | 8 | 8 | |
| Junior-first idle loss: direction, junior cap, price precision, mark advance, settle points, `syncAll` | 6 | 6 | the junior-first invariant kills three of them |
| Exit liquidity caps, senior and junior | 2 | 2 | |

## Symbolic execution (Halmos)

Halmos ran on the math libraries (`wadMath`, `premiumCurve`, `seriesMath`, `epochMath`), whose logic is unchanged in the current code. The run was made on a separate machine. Its harnesses are not yet in this repository; the targets included here are `contracts/test/formal/EpochDetachMath.t.sol` and `contracts/test/formal/IdleLossMath.t.sol`. Every proven property has a reachability companion that produced a counterexample, which shows the proven paths are not vacuous.

| Target | Property | Result |
|---|---|---|
| Waterfall | senior + junior + fee = proceeds; senior paid min(proceeds, claim); junior and fee are zero while senior is short | proven, inputs to `uint128` |
| Pass-through waterfall | pro-rata split conserves proceeds | proven, inputs to `uint128` |
| Allocation split | senior + junior = deployed; junior rounds up | proven, inputs to `uint128` |
| Pricing | negative carry clamped; senior rate ceiling; attachment at most one; cushion identity | proven, inputs to `uint128` |
| Marks | senior + junior + fee = pool value; marks converge to the waterfall at maturity | proven, inputs to `uint64` |
| Batch prices | exits at the lower of close and current price, entries at the higher; zero price fills nothing; claimable amounts never underflow | proven, inputs to `uint128` |
| Premium curve | bounds and anchors at 0, the kink and 1; invalid anchors revert | proven |
| Rounding helpers | rounding up exceeds rounding down by at most one; WAD helpers match | proven; this restates how the helpers are built, and the exact floor of `mulDivDown` is covered by fuzzing and the differential tests instead |
| Batch detach, ledger consistency | the canceller's removal keeps the ledger consistent | proven, inputs to `uint64` |
| Batch detach, no dilution | removing a canceller never lowers anyone else's entitlement | timed out on every solver; covered by a hand proof and 10,000 fuzz runs over `uint128` |
| Junior-first idle loss | conservation, direction, no move at or above the mark, senior kept within two base units | not yet run symbolically; fuzz twins pass at 10,000 runs |
| Core parking-claim rounding | rounding of book claims on the parking position | not run |

Mutation sanity: a waterfall that pays senior regardless of proceeds and a batch price that takes the higher of two prices for exits are both caught by Halmos within a second. A detach that rounds up is caught by the fuzz twin.

```
FOUNDRY_OUT=cache/halmos-out halmos --root . --forge-build-out cache/halmos-out --contract IdleLossMathTest --function check_
```

The following are not yet proven symbolically: the exact floor of `mulDivDown`, the bound that rounding never overstates the senior claim, that the waterfall never decreases as proceeds rise, and that the premium curve never decreases. Each is covered by fuzzing, differential tests or the reference model.

## Differential checks and the reference model

`contracts/test/unit/MathDifferential.t.sol` checks the pricing, waterfall and epoch libraries against Python twins written independently in `sim/`, on 400 deterministic vectors per function. `contracts/test/unit/OfferTreeSdkDifferential.t.sol` checks offer-tree roots against trees of 1 to 33 offers built with the official Midnight SDK.

`docs/morrow-finance-gob-reference_model.py` is an exact integer implementation of the arithmetic. It reproduces every audited figure in the arithmetic document. Across 80,000 random pools from 1 USDC to 100 billion USDC, the cushion never rounds below its exact value, so the senior claim never rounds above it; the excess stays near one base unit.

## Static analysis

```
slither . --filter-paths "lib/|test/"            # uses slither.db.json, reports only new results
aderyn . --src contracts/src -o cache/aderyn-new.json
```

`slither.db.json` holds every Slither result with its classification. `aderyn.baseline.json` lists the Aderyn instances; a new run is compared against it:

```
python3 -c "import json;k=lambda d:{(i['title'],x['contract_path'],x['line_no']) for s in ('high_issues','low_issues') for i in d[s]['issues'] for x in i['instances']};b=set(map(tuple,json.load(open('aderyn.baseline.json'))['accepted']));n=k(json.load(open('cache/aderyn-new.json')));print(sorted(n-b) or 'no new Aderyn results')"
```

| Tool | Results | Open |
|---|---|---|
| Slither | 258 in the current run, each classified | 0 |
| Aderyn | 129 instances | 0 new |

The High results and why they stand:
- `arbitrary-send-erc20` on the junior deposit request: the pulled address must be the caller, or must have made the caller its operator, for both owner and controller. Tested.
- `incorrect-exp` in the full-precision mulDiv: the XOR is the intended seed of the Newton inverse. Fuzz and differential tested.
- `reentrancy-balance` in `collect` and in the exit reservation: only Midnight's withdraw or the trusted parking venue runs between the two balance reads. A donation cannot break the check, and a venue that pays short reverts. Tested within that trust scope.

The Medium and Low results are calls into trusted callees (USDC, the immutable parking adapter, Midnight, factory-created series) under `nonReentrant` or role checks, bounded loops, day-scale timestamps, deliberate tuple destructuring, strict equalities used as guards, and the governance setters listed under limitations.

## Tests against the live Base deployment

Fork suites run against the deployed Midnight, its SetterRatifier, USDC, cbBTC, WETH, their oracles and the real Morpho Blue market. A dedicated test asserts the runtime code hashes of Midnight, the SetterRatifier and the mempool contract at the pinned block.

| Group | What it shows |
|---|---|
| f0 to f7 | Series opened on real Midnight; a real borrower takes the series bid; a repaid maturity settles and pays a senior exit; an unrepaid maturity is liquidated and settles; bad debt on real Midnight hits junior first; a two-maturity ladder settles the first series and rolls into the second. The taker path is skipped: no borrower ask exists on an eligible market at the pinned block. |
| A0 to A10 | Market ids match the Midnight API; a standard series repaid with both exits paid; an October, November, December ladder; two-collateral baskets; a defaulting basket written off junior first; a recovery after write-off reruns the waterfall and reopens the gate; overdue liquidation of a two-collateral borrower; threshold band edges; pass-through below the minimum size; cancellation with exact cash return. |
| O1 to O3 | Eligibility against every live market in the Midnight API snapshot: 7 class E markets pass; 2 are refused by the oracle allowlist and 2 (cbBTC at 0.915, cursor 0.30) by the cursor rule; 9 above-ceiling markets and a cbBTC market priced by a cbETH oracle are refused. |
| Blue lifecycle | Against the real cbBTC/USDC 0.86 market, priced by the same oracle contract as the series markets: fills are funded from Blue inside Midnight's buy callback (about 541,000 gas for register plus take); the adapter's valuation equals Blue's own accounting at four points; series settle; exits are paid out of Blue with interest (1,514,284.5 USDC on 1.5M senior, 505,684.5 on 500k junior); the exit to cash returns everything liquid. |
| Blue fully borrowed | Every free dollar in the Blue market is borrowed out. A 39,798 USDC fill is served from the raw slice. A 300,000 fill is refused with `Illiquid` and leaves the books and the Blue position untouched; after the borrower repays, the same fill is funded from Blue. A senior exit pays the 83,085 USDC that is withdrawable at once and the remaining 670,529 after the repayment, at the same price. The exit to cash moves nothing during the squeeze and completes once liquidity returns. |
| Real Blue bad debt | A liquidation with the oracle crashed realizes 53.2M USDC of bad debt in the Blue market. Morrow's parked cash loses 61,189 USDC. Junior idle absorbs all of it; senior idle is unchanged, in the views and after `syncAll`. |
| Stress on Blue | The tranche-mechanics and crash-realism suites run twice, with idle USDC and with idle cash lent in the real Blue market. Every assertion holds on both. |

## Historical crashes and stress

The reference book for the rolling-window, round-level and crash suites is a two-market series on the real Midnight deployment: cbBTC at 0.86 and WETH at 0.77, with five borrowers in each market at 80, 90, 95, 97 and 99 percent of their liquidation threshold, a 319,704.70 USDC senior claim and 79,597.31 USDC of junior. Prices follow recorded Chainlink paths. Three liquidator models are used: L1 liquidates when profitable after capacity and slippage; L2 liquidates after a set delay; L3 is absent until the maturity auction.

### Rolling windows

124 rolling 30-day windows from April 2024 to September 2026, daily closes, on BTC and ETH.

| Liquidator | Windows with junior principal loss | Worst junior loss | Windows with senior loss |
|---|---|---|---|
| L1 profit-bound | 34 | 32.01% | 0 |
| L3 absent | 17 | 74.77% | 0 |

### Round-level replay

Every Chainlink round from 8 January to 7 February 2026.

| Liquidator | Liquidations | Junior paid on 79,597.31 | Senior |
|---|---|---|---|
| L1 profit-bound | 10 during the crash | 78,894.15 | paid in full |
| L2 120-minute delay | 10 during the crash | 78,894.15 | paid in full |
| L3 absent | 7 at the maturity auction | 43,487.47 | paid in full |

### Named crashes

| Event | Liquidator | Junior paid | Senior |
|---|---|---|---|
| Feb 2025, Apr 2025 and Oct 2025 | L1, L2 at 5, 30 and 120 minutes, L3 | 79,636.36 to 80,225.51 | paid in full |
| Oct 2025 with a liquidation cascade | cascade | 79,587.85 | paid in full |
| Oct 2025 with a liquidation cascade at thin depth | cascade | 72,072.88 | paid in full |
| Oct 2025 at three times depth | L3 absent | 35,027.96 | paid in full |
| Oct 10 to 11 2025, real path (BTC -14.0%, ETH -19.8%) | keeper | 80,122.60 | paid in full |
| Oct 2025 shape at three times depth | keeper | 76,441.15 | paid in full |
| Oct 2025 to Jul 2026 bear (-52.9%), compressed | keeper | 77,046.40 | paid in full |

### Default and recovery grids

On an isolated cbBTC series with a 239,778 USDC senior claim and 59,697 USDC of junior:
- the smallest realized loss at which junior first loses principal is 1,260 USDC;
- the smallest realized loss at which senior first loses is 64,133 USDC, about 21.5% of deployed capital;
- the timing of a loss within the term does not change its split;
- a recovery after write-off reruns the waterfall and restores both tranches, after 1, 30 or 180 days.

At high default and zero recovery, senior is impaired once junior is exhausted, as the waterfall requires: with half the book defaulted and nothing recovered, senior receives 150,143 of 239,778.

A correlated three-times-depth BTC shock across an October, November and December ladder liquidates 12 positions; all three seniors are paid in full and junior absorbs 0.7 to 1.6 thousand USDC per series.

### Structural stress

| Test | Result |
|---|---|
| cbBTC de-peg of 25%, oracle blind, L1 | both tranches paid in full |
| cbBTC de-peg of 40%, oracle blind, L3 or naive keeper | positions liquidated at the maturity auction; both tranches paid in full |
| cbBTC de-peg of 40%, oracle blind, L1 bidding on real value | no liquidator bids; the series is written off with nothing collected, and later recoveries would rerun the waterfall |
| De-peg default with the backstop on | junior is wiped first; the backstop pays 170,151 USDC from junior idle toward senior, and senior still ends about 46,212 USDC short of its 239,778 claim; the stress gate closes |
| Backstop off and on | off, another series' legs are untouched; on, only junior idle moves |
| Donations during stress | the books never move |
| Shared real market | outside lenders absorb 33.56% of the bad debt Morrow's borrowers cause, and part of the series' credit waits on outside borrowers before the market resolves |
| Flows across loss stages | senior deposits stop once a loss is realized; a junior exit filled by the operator before an unrealized loss is realized pays the pre-loss price (99,999 USDC), the same exit filled after it pays 90,151; an exit batch spanning a write-off pays the post-loss price; after junior is nearly wiped, a new junior deposit mints at the near-zero price and the old holders exit with the remaining value |

### Real liquidation day

The busiest real liquidation day on Midnight, 16 July 2026, is replayed transaction by transaction with the feed rounds of the time while Morrow holds a live series in the WETH market. 2 of 24 real liquidations replay directly, senior is paid in full and the series settles. The cbBTC market of that day has a threshold of 0.915 and a cursor of 0.30, and the factory refuses it.

## Limitations

- **Not audited.** No external review has taken place.
- **Oracle.** The cbBTC oracle prices cbBTC as BTC and cannot see a de-peg; the structural stress table shows the worst case. Midnight reads its price feed without a staleness check.
- **Shared markets.** Bad debt and withdrawable cash in a Midnight market are shared with other lenders, and a series can wait on outside borrowers before its market resolves.
- **Parking venue.** The parking adapter is immutable and trusted. Lending in Morpho Blue is not cash: the market can take bad debt and its liquidity can be borrowed out. Losses there are carried junior first, limited by junior's idle cash.
- **Idle loss window.** Senior is restored to its value at the last settlement point, within two base units. A gain accrued since then is shared pro rata if a loss arrives first, so keepers call `syncAll` on a regular cadence. Junior provides this protection without a separate premium.
- **Operator fill timing.** An exit batch filled by the curator or allocator before an unrealized loss is realized pays the pre-loss price. Operators should not fill exit or entry batches while the stress gate is closed or a live position is unhealthy; this is operating policy and is not enforced on chain. The permissionless fill after the grace period keeps exits live.
- **Governance and gating.** Governance transfer is single step, role setters emit no events, and the wiring is one-shot. The curator's 10% junior holding is enforced only on its own exit requests. The idle floor is fixed rather than sized to flows. The borrower buffer rule is evaluated off chain. A written-off series is not tracked once the recovering list is full.
- **USDC.** The code assumes USDC charges no transfer fee and has no transfer hooks.
- **Stress inputs.** The stress tests replay recorded paths on a reference book; they do not forecast.
- **Not run.** Certora formal verification and an independent economic review.
