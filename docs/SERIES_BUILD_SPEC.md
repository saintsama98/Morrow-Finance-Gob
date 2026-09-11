# series: dated senior / junior tranching on morpho midnight, behind one surface

build spec for agents. version 0.5, 11 sep 2026. derived from "series v1, specification for structure, math, and simulation" (8 sep 2026), reduced to what is buildable on midnight markets that exist today.

v0.3 restructures the product around one public surface, the way idle, strata and royco present tranching: exactly two tokens, a senior vault token (`srUSDC`) and a junior vault token (`jrUSDC`). the dated, per maturity series of the v1 pdf still exist and still run the full tranching math, but they are internal. their only two holders are the senior vault and the junior vault. compared with v0.2 this removes the public tranche tokens, the per series entry points, the per series subscription window and the admission rule, and turns the roll module into the core behaviour of the product.

v0.4 validates the engine against the midnight source code (`src/Midnight.sol`) and the morpho sdk. it replaces the custom ratifier with midnight's `SetterRatifier`, records fills inside `onBuy` from the units midnight passes, reads face value as `credit - pendingFee`, collects withdrawable liquidity before maturity, and switches tests to the real midnight contract. section 30 issues 22 to 27 list what changed and why. v0.5 closes the remaining protocol questions from the verified base deployments (setter ratifier abi and bytecode, mempool contract, addresses), see sections 2.2, 2.6 and 10.

this file is the single source of truth for contracts, tests and the simulation harness. where it disagrees with the v1 pdf or with earlier versions of this file, this file wins, and section 30 explains why.

---

## 0. how agents should use this document

1. read sections 1 to 5 fully before writing any code. they define scope, the protocol facts we depend on, and the numeric conventions every module shares.
2. every item tagged `[VERIFY]` is a fact about midnight or morpho vault v2 that could not be confirmed from primary source code at the time of writing. the first milestone (M0, section 29) is to resolve every `[VERIFY]` against pinned commits and update this file before any production code is written.
3. every formula has a rounding direction. never change a rounding direction without updating section 5.4 and the invariant it protects.
4. pure math lives in libraries with no storage access. every library function has a python twin in `/sim/series_math.py`. differential tests (section 25.6) keep them identical.
5. nothing in this build may assume gates, kyc, rwa collateral, otc counterparties, pt collateral or multi class baskets. those are deferred (section 1.3).
6. when in doubt, prefer the rule that keeps the senior claim exact and makes junior the residual. conservation must hold to the wei.
7. the build has two parts. part A (sections 5 to 19) is the series engine: one contract per maturity that lends into midnight and splits the outcome through the waterfall. part B (sections 20 to 24) is the surface: the core that owns every series and holds the books, and the two vault tokens users hold. the order in section 29 builds the engine first and the surface on top.
8. users never touch a series. if a function in part A needs a caller, that caller is the core or a permissionless keeper.

---

## 1. scope

### 1.1 what we are building

one engine, two tokens:

- users deposit usdc into the **senior vault** and receive `srUSDC`, or into the **junior vault** and receive `jrUSDC`. these are the only user facing tokens.
- a single **core** contract holds both vaults' cash and owns every series. the allocator opens a series for a midnight maturity `T`, funding it with `S` from the senior book and `J` from the junior book, with `J / (S + J) >= COV`.
- each **series** (internally also called a sleeve) lends into one or more midnight markets maturing at `T`, freezes a senior claim `C_S = S * (1 + r_s)` priced by the premium curve, and at maturity splits what comes back through the strict waterfall: senior vault first up to `C_S`, junior vault the residual.
- the core keeps several series alive at staggered maturities. settled cash returns to the books and is allocated into the next series. this ladder is the roll.

### 1.2 what is kept from the v1 spec

| v1 section | kept as | notes |
|---|---|---|
| series per maturity | yes, internal | holders are the two vaults only, section 8 |
| lifecycle state machine | yes, simplified | no OPEN subscription state, section 6 |
| `COV` as the required minimum junior share | yes | checked on every allocation (section 8) and at vault level as a senior capacity cap (section 20.4) |
| premium curve, three anchors, kink at `u_T = 0.9` | yes | unchanged math, frozen at finalize |
| senior rate `r_s = r_pool * (1 - pi(u))`, attachment `A_F` | yes | `r_pool` measured net of protocol fees, section 9 |
| deployment by takes with price limit | yes, plus a maker path | maker path is the default on thin books, section 10 |
| partial fill scaling `S_d = (1 - a) K_d` | yes | undeployed cash returns to the books, section 11 |
| face term ledger | yes | reads protocol credit after loss factor and fees, no separate `Phi` |
| display navs | yes, corrected and fee netted | they now price both vault tokens, section 12.4 |
| write off rule | yes, time based only | section 13.4 |
| waterfall | yes | reserve removed, recoveries rerun the waterfall, payouts go to the books |
| operator fee on junior profit | yes | unchanged |
| roll module | yes, as the product itself | the core rolls every book continuously |
| invariants I1 to I14 | adapted | section 26 |
| simulation harness | yes, reduced | btc collateral only, section 27 |

### 1.3 what is dropped or deferred

| item | status | reason |
|---|---|---|
| public per series tranche tokens (`srS-T`, `jrS-T`) | dropped in v0.3 | one surface. a dated, per maturity note can return later as an optional wrapper if demand appears |
| per series subscription window, fifo or pro rata admission, per series refunds | dropped in v0.3 | the allocator funds a series from the books in one call |
| per series erc 7540 entry points and erc 7575 share tokens | dropped in v0.3 | nothing to enter per series anymore |
| anchor junior per series | replaced | the junior vault is structurally the first loss of every series, and the curator holds a minimum share of the junior vault |
| classes A to E, class caps, `w_A + w_B >= 0.40` floor | dropped | those market types do not exist on midnight today |
| `N >= 8` and `w_max = 0.15` | replaced by `M_max` and `w_max` params | only a handful of usdc markets exist per maturity |
| kyc senior whitelist | dropped | no compliance layer in scope |
| gates (enter gate, liquidator gate) | markets with any gate are ineligible | midnight launched without gates |
| sponsor as named liquidator, class B grace `G_max` | dropped | no gated otc markets |
| issuer and oracle provider concentration | dropped | replaced by an oracle allowlist per collateral |
| reserve `R_0` and execution cost `E` | dropped | settlement is permissionless, and `E > R_0` could underflow the waterfall |
| taps (open entry into a live series) | dropped | the vaults already take deposits at any time |
| operator review hash of oracle, market age check, depth rule | off chain checks by the allocator | cannot be verified on chain, section 7.3 |

### 1.4 what the v1 math still guarantees in this build

- in every series, the senior vault is paid before the junior vault.
- in every series, the junior vault bears losses from the first dollar.
- each series' senior claim is fixed at finalize and never re evaluated.
- conservation: every usdc that comes back from midnight goes to the senior book, the junior book, or the operator fee recipient, nothing else.

### 1.5 loss isolation between series

by default losses are isolated per series: junior capital in series A does not cover a senior shortfall in series B. this keeps each waterfall exact and auditable on its own. an optional cross series backstop (section 20.8) lets the junior book cover a senior shortfall from its idle cash. it is off by default and listed as an open decision (section 31).

---

## 2. midnight facts the contracts depend on

this section is checked against the midnight source (`src/Midnight.sol` on `main`, pragma `0.8.34`, read on 11 sep 2026), the morpho sdk documentation, and the verified base deployments of `SetterRatifier` and the mempool on basescan (abi, compiler settings and bytecode, read on 11 sep 2026). M0 must pin an exact commit hash and re diff these facts against it. anything still uncertain is tagged `[VERIFY]`.

### 2.1 markets, units, positions

- a market is the struct `Market { chainId, midnight, loanToken, maturity, collateralParams[], rcfThreshold, enterGate, liquidatorGate }` with `collateralParams[i] = { token, lltv, liquidationCursor, oracle }`. collaterals are sorted by address, 1 to 128 per market. the id is `IdLib.toId(market)`, and `toMarket(id)` returns the struct (it is stored in code). most entry points take the full `Market` struct, so each series stores the structs of its basket.
- markets are created lazily on first touch (`touchMarket`). a market exists when `marketState[id].tickSpacing > 0`. lltv tiers and liquidation cursors must be enabled by the configurator, and a market requires `maxLif <= 2` and `lltv * maxLif <= 0.999` unless `lltv == 1`.
- units have the loan token's decimals: `withdraw` transfers exactly `units` of the loan token, so 1 unit is 1 base unit of usdc. prices and lltvs are wad.
- a position is `{ credit, pendingFee, lastLossFactor, lastAccrual, debt, collateralBitmap, collateral[] }`. the stored `credit`, `pendingFee` and `lastLossFactor` are lazy. `updatePositionView(market, id, user)` returns the up to date `(credit, pendingFee, accruedFee)`, and `updatePosition(market, user)` writes it. both are permissionless.
- "in the absence of bad debt realizations, the face value of a lender's position is `credit - pendingFee`" (midnight natspec). this is exactly the projected redeemable amount the series needs.

### 2.2 offers, ratification, callbacks

- `take(Offer offer, bytes ratifierData, uint256 units, address taker, address receiverIfTakerIsSeller, address takerCallback, bytes takerCallbackData) returns (buyerAssets, sellerAssets)`. takes are sized in units. `taker` must be `msg.sender` or authorized by it. the maker can never be the taker (`SelfTake`).
- `Offer` field order (verified from the deployed setter ratifier abi): `market, buy, maker, start, expiry, tick, group, callback, callbackData, receiverIfMakerIsSeller, ratifier, reduceOnly, maxUnits (uint128), maxAssets (uint128), continuousFeeCap`. `Market` field order: `chainId, midnight, loanToken, collateralParams[] {token, lltv, liquidationCursor, oracle}, maturity, rcfThreshold, enterGate, liquidatorGate`. exactly one of `maxAssets` and `maxUnits` is nonzero. for a buy offer `maxAssets` caps buyer assets. consumption is tracked on chain per `(maker, group)`, so a group budget is enforced by the protocol. `setConsumed(group, type(uint128).max, maker)` cancels a whole group.
- prices sit on a tick grid. `TickLib.tickToPrice(tick)` gives a wad price `<= 1`, `MAX_TICK = 6744`, default tick spacing 4, and offers must use ticks that are multiples of the market's spacing.
- ratification: `take` requires `isAuthorized[offer.maker][offer.ratifier]` and `IRatifier(offer.ratifier).isRatified(offer, ratifierData, taker) == CALLBACK_SUCCESS`. two ratifiers ship with the protocol: `EcrecoverRatifier` (eoa signs a merkle root) and `SetterRatifier` (a contract maker approves a merkle root on chain with `setIsRootRatified(maker, root, bool)`, reversible). the hosted midnight api and router only index offers whose ratifier is on their allowlist. **custom ratifiers are takeable on chain but never appear in books or quotes.**
- `SetterRatifier` on base (verified, solc 0.8.34, osaka): four functions, `MIDNIGHT()`, `isRootRatified(maker, root)`, `setIsRootRatified(maker, root, bool)` and the view `isRatified(offer, ratifierData, taker)`. `setIsRootRatified` accepts the maker itself or any account the maker authorized on midnight (a static call to `midnight.isAuthorized(maker, msg.sender)`). the whole bytecode contains exactly one storage write (the root flag) and exactly one external call, a `STATICCALL` to `isAuthorized`. no `CALL`, `DELEGATECALL` or `SELFDESTRUCT`. so authorizing it cannot let it move a maker's funds.
- `isRatified` decodes `ratifierData` as `(bytes32 root, uint256 leafIndex, bytes32[] proof)`, computes the leaf as the eip 712 style struct hash of the offer, walks the proof using the bits of `leafIndex` (bit 0 means the current node is on the left), requires the result to equal `root` and `leafIndex < 2^proof.length`, then requires `isRootRatified[offer.maker][root]`. the maker in the lookup is the offer's own maker, so a leaf naming another maker is useless unless that maker ratified the same root.
- leaf hashing, as executed by the deployed bytecode:

```
collateralHash_k = keccak256(abi.encode(COLLATERAL_PARAMS_TYPEHASH, token, lltv, liquidationCursor, oracle))
marketHash       = keccak256(abi.encode(MARKET_TYPEHASH, chainId, midnight, loanToken,
                       keccak256(abi.encodePacked(collateralHash_0 .. collateralHash_n)),
                       maturity, rcfThreshold, enterGate, liquidatorGate))
leaf             = keccak256(abi.encode(OFFER_TYPEHASH, marketHash, buy, maker, start, expiry, tick, group,
                       callback, keccak256(callbackData), receiverIfMakerIsSeller, ratifier, reduceOnly,
                       maxUnits, maxAssets, continuousFeeCap))
node             = keccak256(abi.encodePacked(left, right))
typehashes       COLLATERAL_PARAMS_TYPEHASH 0x39ed3f92..85b841, MARKET_TYPEHASH 0x510b3862..20391a,
                 OFFER_TYPEHASH 0x99052142..9d8906 (full values in the ratifier's HashLib and the sdk constants)
```

- the mempool is a `Log` contract with a payable fallback that emits `Data(bytes)` with the calldata and reverts above 1,000,000 bytes. it has no sender check, so any account can publish a payload on chain. the hosted router then indexes the offers it can ratify.
- authorization is broad: an authorized account can call every position changing function on behalf of the user, including authorizing others. authorize only contracts whose full behaviour is known.
- buy side flow inside `take`: positions are updated first, then `onBuy(bytes32 id, Market market, uint256 buyerAssets, uint256 units, uint128 buyerPendingFeeIncrease, address buyer, bytes data)` is called on the buyer callback, then midnight pulls `buyerAssets` from the payer (the callback if set). so a buy callback knows the exact units and must approve midnight for `buyerAssets`.
- midnight can call an offer's callback through a no op take (units 0), even on a fully consumed offer. every callback must treat a zero amount call as a harmless no op.
- the settlement fee is always carried by the taker: for a buy offer the maker pays exactly the tick price and the seller receives the price minus the fee. for a sell offer the taker pays the price plus the fee.

### 2.3 health, liquidation, bad debt

- healthy while `maxDebt = sum(collateral_i * price_i * lltv_i) >= debt`, `maxDebt` rounded down.
- normal mode liquidation (unhealthy borrower) uses `maxLif = 1 / (1 - cursor * (1 - lltv))` and is capped by the recovery close factor, which is switched off below `rcfThreshold`. post maturity mode (any unpaid debt after maturity) ramps the incentive linearly from 1 to `maxLif` over `TIME_TO_MAX_LIF = 3600` seconds, with no rcf cap.
- at `lltv == 1` the incentive is exactly 1 and the rcf is inactive. unhealthy positions almost always realize bad debt.
- bad debt is computed with `maxLif`, realized inside `liquidate` (a liquidation with 0 seized and 0 repaid only realizes bad debt, and anyone can call it unless a liquidator gate exists), and socialized by raising `lossFactor`. each lender is slashed at its next update: `credit * (MAX - lossFactor) / (MAX - lastLossFactor)`, rounded down. the loss factor rounds against lenders.
- midnight applies no staleness check, bounds or circuit breaker to oracles. if an activated collateral oracle reverts, `liquidate` reverts.

### 2.4 fees

- settlement fee: piecewise linear over time to maturity with breakpoints at 0, 1, 7, 30, 90, 180, 360 days, stored in centi basis points, capped at 50 bps at 360 days and scaled linearly below.
- continuous fee: per second rate, capped at `MAX_CONTINUOUS_FEE = 317097919` (about 1 percent a year). when a lender's credit increases, the whole future fee is crystallized at once: `pendingFeeIncrease = creditIncrease * continuousFee * timeToMaturity`. `pendingFee` then accrues linearly into realized fee until maturity and is released pro rata on early withdrawal. an offer can cap the fee it accepts with `continuousFeeCap`.

### 2.5 withdrawals and liquidity

- `withdraw(Market market, uint256 units, address onBehalf, address receiver)` updates the position, then burns `units` of credit and transfers `units` of loan token. it is **not** restricted to maturity: it only needs `marketState.withdrawable >= units`.
- `withdrawable` grows with every repayment and every liquidation, before or after maturity. it is shared by all lenders, first come first served. the natspec notes that lenders "might race to withdraw first".
- consequence: withdrawing early at par is strictly good for a lender (it receives face value now and sheds future bad debt exposure and unaccrued fee). the series collects whenever `withdrawable > 0`, from finalize onward (section 13.2).

### 2.6 what is live today

- base (chain id 8453), addresses from the morpho contracts page:

| contract | address |
|---|---|
| Midnight | `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A` |
| SetterRatifier | `0x800B5F12A61B8198a5a6EfD794Cac6699B294d63` |
| EcrecoverRatifier | `0xd6e70365C8E8DDa9a4ca662C07bbE663b017755E` |
| EcrecoverAuthorizer | `0x292bEa9f1443d54E0E509120c919106765c6a493` |
| Mempool (`Log`) | `0xdD6DCE32e21f7b020898a8258dA37355b4017993` |

- base markets: cbBTC / USDC across several maturities (launched 21 jul 2026). the setter ratifier alone has handled more than 12,000 transactions, so contract makers already quote on base.
- ethereum: news reports from early september 2026 say cbBTC / USDC and WBTC / USDC markets launched, but the morpho contracts page lists no ethereum midnight deployment and none could be found on etherscan. treat ethereum as unconfirmed.
- no gates, no vault adapter, no auto roll at launch. morpho vault v2 cannot allocate to midnight yet.
- depth is thin. the ethereum markets page showed about 7.41m usdc of deposits and 2.63m of loans in early september 2026.
- toolchain: midnight, the setter ratifier and the mempool are compiled with solc 0.8.34, 466 optimizer runs, `evm_version = osaka` (midnight uses the `clz` opcode). local tests that deploy midnight, and fork tests, must run with `evm_version = "osaka"`.

consequence for this build: a basket is 1 to 4 markets, all btc collateral, all ungated, on base first. parameters in section 28 are sized for this.

---

## 3. system overview

### 3.1 actors

| actor | role | trust |
|---|---|---|
| senior depositor | deposits usdc into the senior vault, holds `srUSDC` | untrusted |
| junior depositor | deposits usdc into the junior vault, holds `jrUSDC` | untrusted |
| curator | sets risk policy: eligible markets and oracles, `COV`, premium anchors, junior share band, caps, idle floors, stress thresholds. must hold a minimum share of `jrUSDC` | trusted within timelocks |
| allocator | opens and funds series, runs deployment (registers bids, submits takes), may finalize early, fulfills redemption epochs | trusted within caps set by the curator, a safe multisig |
| sentinel | can only reduce risk: pause deposits, lower caps, cancel a series that has not filled | trusted, cannot move funds out |
| keeper | anyone. finalize after deadline, sync, collect, settle, write off, close epochs | untrusted |
| governance | owns the factory allowlists and the curator seat, behind a timelock | trusted, slow |

nobody can move assets anywhere except into eligible midnight markets through a series, at prices at or better than the published floor, or back to the books, or out to redeeming depositors.

### 3.2 contracts

```
SeriesCore             single custody and accounting. holds the senior and junior books (parking shares plus claims on
                       live series), opens and funds series, receives payouts, enforces coverage and caps
SeniorVault            srUSDC. erc 4626 sync deposit, erc 7540 async redeem by epoch, erc 7887 redeem cancel.
                       holds no assets, reads and moves value only through the core
JuniorVault            jrUSDC. erc 7540 async deposit and redeem by epoch, erc 7887 cancel on both sides
SeriesFactory          deploys series for the core only, holds allowlists, snapshots them into each series
Series                 one per maturity. lends into midnight, keeps the face ledger, computes navs, runs the waterfall,
                       pushes payouts to the core. implements onBuy (buyer callback) for its own bids
(external) SetterRatifier   midnight's shipped ratifier for contract makers. each series authorizes it once and approves
                       merkle roots of its own bid trees. no custom ratifier: the hosted router would not index it
IParking               adapter interface for idle capital
  IdleParking          holds usdc as is
  Erc4626Parking       wraps an erc 4626 vault (for example a morpho vault v2 usdc vault)
SeniorVaultAdapter     optional morpho vault v2 adapter into SeniorVault
libraries
  WadMath              mulDivDown, mulDivUp, wMulDown, wDivDown, wDivUp (same semantics as morpho blue MathLib)
  PremiumCurve         pi(u), three anchors, kink at 0.9
  SeriesMath           pricing, attachment, nav, waterfall, recovery rerun
  EpochMath            pro rata epoch fulfillment, min and max price rules
  MidnightReader       thin read wrappers over IMidnight, isolates every [VERIFY] call site
```

### 3.3 series lifecycle at a glance

```
core.openSeries --> DEPLOYING --finalize--> LOCKED --t >= T--> SETTLING --all resolved or T+D_wo--> SETTLED
                        |
                        +--cancel before any fill, or nothing filled--> CANCELED (cash back to the books)
```

`passThrough` is a mode flag set at finalize when `K_d < kMin`. the lifecycle is the same, only the waterfall changes (section 13.6).

### 3.4 layers

```
L3  distribution   morpho vault v2 --(SeniorVaultAdapter)--> SeniorVault                  optional
L2  surface        SeniorVault (srUSDC)        JuniorVault (jrUSDC)                         the only user tokens
L1  engine         SeriesCore: senior book, junior book, series registry, coverage, caps
L0  sleeves        Series T1 .. Tn (internal, one per maturity) --> midnight markets, parking
```

value moves down only through core calls (`openSeries`, funding transfers) and back up only through series payouts (`receivePayout`) and parking withdrawals. vaults never hold assets. the core never reads a series' storage directly, only its view functions defined in this document.

---

## 4. repository layout

```
/contracts
  src/
    core/SeriesCore.sol
    vaults/SeniorVault.sol
    vaults/JuniorVault.sol
    vaults/EpochQueue.sol                shared epoch request book used by both vaults
    series/SeriesFactory.sol
    series/Series.sol
    adapters/SeniorVaultAdapter.sol
    parking/IParking.sol
    parking/IdleParking.sol
    parking/Erc4626Parking.sol
    libraries/WadMath.sol
    libraries/PremiumCurve.sol
    libraries/SeriesMath.sol
    libraries/EpochMath.sol
    libraries/MidnightReader.sol
    interfaces/ISeries.sol
    interfaces/ISeriesCore.sol
    interfaces/IMidnightMinimal.sol      only the functions we call, copied from the pinned midnight commit
    interfaces/IBuyCallback.sol          copied from the pinned midnight commit
    interfaces/IRatifier.sol             copied from the pinned midnight commit
    interfaces/IERC7540.sol              operator, deposit request, redeem request interfaces
    interfaces/IERC7575.sol              share() on vaults
    interfaces/IERC7887.sol              cancelation interfaces
    interfaces/IVaultV2Adapter.sol       copied from the pinned morpho vault v2 commit [VERIFY]
  test/
    unit/                                one file per library and per contract
    fuzz/
    invariant/
      handlers/                          AllocatorHandler, DeployHandler, MidnightChaosHandler, SettleHandler,
                                         VaultHandler, EpochHandler, AdapterHandler
      SeriesInvariants.t.sol
      CoreInvariants.t.sol
    compliance/                          erc 4626, 7540, 7887 conformance for both vaults
    scenario/                            S0 to S14, section 25.5
    fork/                                base and mainnet, pinned blocks
    differential/                        solidity vs python vectors
    mocks/
      MidnightHarness.sol                deploys the real midnight from lib/midnight, enables lltvs and cursors, sets fees
      MockOracle.sol                     settable price, used to trigger real liquidations and bad debt
      MockOracle.sol
      MockUSDC.sol
      MockErc4626.sol                    with a lossy mode and a liquidity cap
  script/
    DeployCore.s.sol                     factory, core, both vaults, dead deposits
    OpenSeries.s.sol
  foundry.toml
/sim
  series_math.py                         pure twin of SeriesMath, PremiumCurve, EpochMath
  loss_model.py
  env/btc_paths.py
  scenarios/
  metrics.py
  report.py
  vectors/                               json vectors consumed by test/differential
/docs
  SERIES_BUILD_SPEC.md                   this file
  VERIFY_LOG.md                          results of M0, one row per [VERIFY] tag
```

foundry settings: solc 0.8.34 (the version midnight uses), `evm_version = "osaka"` (midnight uses the `clz` opcode), optimizer on with 200 runs, `via_ir = true` only if a contract exceeds the 24 kb size limit. series are deployed as full contracts, not clones, so every series is immutable code. fuzz runs 10000 locally, 100000 in ci. invariant runs 512, depth 128.

---

# part A: series engine

---
## 5. conventions

### 5.1 units

- all amounts in usdc base units (6 decimals). call them "assets".
- midnight credit is in units with the loan token's decimals (6 for usdc). one unit redeems for one asset at maturity, before losses and fees.
- series have no tokens. vault shares (`srUSDC`, `jrUSDC`) use 18 decimals with a decimals offset of 12 over usdc (section 21.1).
- rates are term rates unless the name ends in `Ann`. `annual = term * 365 days / tau`.
- time is `block.timestamp` in seconds. `tau = T - tFinalize`.

### 5.2 fixed point

- `WAD = 1e18`. ratios (`a`, `COV`, `u`, `pi`, `r_pool`, `r_s`, `A_F`, `w_i`, `theta`) are wad.
- use `WadMath.mulDivDown` and `mulDivUp` with full 512 bit intermediate (same approach as openzeppelin `Math.mulDiv` or solady `FullMath`). never `a * b / c` inline.

### 5.3 naming

| symbol | solidity name | meaning |
|---|---|---|
| `S` | `seniorAllocated` | senior book assets allocated to a series at open |
| `J` | `juniorAllocated` | junior book assets allocated to a series at open |
| `K_alloc` | `allocatedAssets` | `S + J` |
| `a` | `juniorShareWad` | `J / K_alloc` |
| `K_d` | `deployedAssets` | usdc actually spent buying credit |
| `S_d`, `J_d` | `seniorDeployed`, `juniorDeployed` | scaled by fill |
| `U_i` | `unitsBought[i]` | units bought in market i |
| `F` | `faceGross` | `sum U_i` |
| `F_net` | `faceNetAtT` | projected redeemable at `T` after crystallized fees |
| `r_pool` | `poolRateWad` | `F_net / K_d - 1` |
| `C_S` | `seniorClaim` | fixed senior claim in assets |
| `A_F` | `attachmentWad` | `1 - C_S / F_net` |
| `B(t)` | `buffer()` | projected face minus `C_S`, signed |
| `P` | `proceeds` | usdc collected from midnight, cumulative |

### 5.4 rounding rules

the rule is: the senior claim and every payout round down, junior is computed as the exact residual so conservation is exact and dust accrues to junior.

| quantity | direction | why |
|---|---|---|
| senior capacity (section 20.4) | down | never let senior exceed what junior can cover |
| `a` | down | conservative: lower `a` means higher `u` means higher premium to junior, and the rule `a >= COV` is checked with the rounded down value |
| `u = COV / a` | up | same reason |
| `pi(u)` | up | favors junior (the buffer provider) |
| `r_s` | down | |
| `C_S` | down | |
| `A_F` | down | published attachment must never overstate protection, see note |
| `X_S = min(C_S, P)` | exact | `C_S` already rounded |
| `Fee_op` | down | |
| `X_J` | residual | `P - X_S - Fee_op` exactly |
| senior share of undeployed cash returned at finalize | down | junior book takes the residual |
| vault share mint on deposit | down | against the depositor |
| vault assets paid on redemption | down | against the redeemer |

note on `A_F`: compute it as `A_F = WAD - mulDivUp(C_S, WAD, F_net)`. rounding the ratio `C_S / F_net` up rounds the attachment down, so the published number never overstates the junior buffer.

### 5.5 decimals safety

reject any loan token whose `decimals() != 6`, both in the factory and in the core. this removes a whole class of scaling bugs for v1.

---

## 6. series state machine

### 6.1 states

```
enum State { DEPLOYING, LOCKED, SETTLING, SETTLED, CANCELED }
bool passThrough     set once at finalize, never unset
```

| state | entered by | who can move it out | exit condition | allowed actions |
|---|---|---|---|---|
| DEPLOYING | `SeriesCore.openSeries` | allocator any time, anyone after `tDeployEnd` | `finalize()` | allocator registers bids, submits takes, midnight fills bids through `onBuy` |
| LOCKED | `finalize()` with `K_d > 0` | anyone once `block.timestamp >= T` | `startSettlement()` | `sync(i)`, views |
| SETTLING | `startSettlement()` | anyone | `settle()` when every market is resolved, or `writeOff()` after `T + D_wo` | `collect(i)`, `sync(i)` |
| SETTLED | `settle()` or `writeOff()` | terminal | none | `collect(i)` for recoveries, each receipt reruns the waterfall and pushes deltas to the core |
| CANCELED | `cancel()` by allocator or sentinel before any fill, or `finalize()` with `K_d == 0` | terminal | none | none. all cash has gone back to the core |

### 6.2 guards (all enforced in code, all tested)

- G1: a series pays out only through the waterfall, and only to the core (both books) and the fee recipient. no other address ever receives usdc from a series except midnight during a fill.
- G2: midnight credit of the series can only increase while `state == DEPLOYING`. `onBuy` reverts in every other state. takes revert in every other state.
- G3: the series never holds midnight debt and never supplies collateral. the only midnight authorization it ever grants is `setIsAuthorized(setterRatifier, true, series)` at creation (section 10.3). there is no code path that calls `setIsAuthorized` with any other address, `supplyCollateral`, `repay`, or `liquidate`.
- G4: finalize after deadline, start settlement, collect, settle and write off never require the allocator.
- G5: every transition is one way. no state is re entered.
- G6: all external state changing functions are `nonReentrant`, including `onBuy`. `onBuy` is entered from midnight inside a third party's take of one of our bids, so the series lock is free at that moment. the taker path passes no taker callback. test that a malicious oracle or token hook, or a crafted no op take, cannot re enter `finalize`, `collect`, `settle` or the core while `onBuy` or `deployTake` is on the stack.
- G7: only the core can create a series (through the factory) and only the core funds it. the series has no deposit function.

### 6.3 timestamps frozen at open

```
tOpen        block.timestamp at openSeries
tDeployEnd   last second any bid can be filled (tOpen + D_deploy)
T            midnight maturity, read from every basket market and required equal
D_wo         write off delay after T
```

require `tOpen < tDeployEnd < T - minTerm`, `minTerm` default 14 days.

---

## 7. factory and eligibility

### 7.1 allowlists held by the factory

```
address   midnight                       the midnight singleton on this chain
address   usdc                           the only allowed loan token
address   core                           the only address allowed to call createSeries
mapping   collateralAllowed[token]       cbBTC, WBTC today
mapping   oracleAllowed[token][oracle]   one or more approved oracle contracts per collateral
uint256   maxLltvWad                     default 0.86e18, hard ceiling 0.915e18 in code
uint256   maxMarketsPerSeries            M_max, default 4, hard ceiling 8 in code
```

changes to allowlists go through a timelock (48h). a change never affects a series that is already open, because the series snapshots what it needs at creation.

### 7.2 on chain eligibility checks at creation

for every market in the proposed basket, read the market config from midnight through `MidnightReader.marketConfig(id)` and require:

```
E1  loanToken == usdc
E2  maturity == T                                 same T for all markets in the basket
E3  enterGate == address(0) and liquidatorGate == address(0)
E4  for every accepted collateral c in the market (not only what borrowers post today):
      collateralAllowed[c.token]
      oracleAllowed[c.token][c.oracle]
      c.lltv <= maxLltvWad and c.lltv < WAD
E5  no duplicate market ids in the basket
E6  1 <= basket.length <= maxMarketsPerSeries
```

E4 iterates the full collateral list because a lender in a multi collateral market is exposed to every accepted collateral. markets with more than `maxCollateralsChecked` (default 8) collaterals are rejected to bound gas.

### 7.3 off chain checks (allocator, before `openSeries`)

these cannot be proven on chain. the allocator publishes a json attestation and passes its hash to `openSeries`, which emits it.

```
O1  visible bid and ask depth at each market over the last 7 days, and borrower demand at T
O2  market age >= 14 days, or explicit waiver with reason
O3  oracle review: feed source, heartbeat, deviation threshold, historical staleness
O4  size check: K_alloc <= depthMultiple * observed 7 day average fill capacity
```

### 7.4 series parameters

set by the core from the allocator's call plus curator policy, frozen at creation:

```
struct SeriesParams {
  bytes32[] marketIds
  uint64    tDeployEnd
  uint64    dWriteOff                 D_wo
  uint256   covWad                    COV, from curator policy
  uint256   pi0Wad, piTWad, pi1Wad    premium anchors, from curator policy
  uint256[] rateFloorWad              r_min per market, each >= curator minimum
  uint256[] marketCapAssets           max assets deployable per market
  uint256   kMinAssets                below this fill the series runs pass through
  uint256   thetaWad                  operator fee on junior profit, from curator policy
  address   feeRecipient
  address   allocator
  IParking  parking
  bytes32   offchainAttestationHash
}
```

validation: `covWad in [0.05e18, 0.50e18]`, `pi0 <= piT <= pi1 < WAD`, `thetaWad <= 0.20e18`, each `rateFloorWad > 0`, `sum(marketCapAssets) >= K_alloc`.

---

## 8. funding a series (replaces the v1 subscription module)

### 8.1 design

there is no subscription window and no admission rule. the allocator decides `S` and `J` for a series in one call and the core moves the cash. users are exposed to a series only through the vault they hold, pro rata to their vault shares.

### 8.2 `openSeries`

```
function openSeries(SeriesParams calldata p, uint256 S, uint256 J) external onlyAllocator returns (address series)
```

core side checks, all required:

```
C1  a = mulDivDown(J, WAD, S + J) and covWad <= a <= aMaxWad          junior share inside the curator band
C2  S <= seniorIdleAvailable() and J <= juniorIdleAvailable()          idle after reserved redemptions and idle floors
C3  liveSeriesCount < maxSeries
C4  S + J <= maxPerSeriesAssets
C5  maturity window cap: assets maturing within 30 days of T, including this series, <= maxPerMaturityWindowWad * totalAssets
C6  !paused
```

then the core calls `SeriesFactory.createSeries(p)` (eligibility E1 to E6 run there), withdraws `S + J` from parking, transfers it to the series, calls `series.initialize(S, J)`, and records the series in the registry with `seniorAllocated = S`, `juniorAllocated = J`.

the series parks the cash in its own parking position until fills pull it.

### 8.3 why the band on `a`

the allocator sets how much junior backs each series, which also sets the premium through `u = COV / a`. the allocator works for both vaults, so the curator fixes the band `[covWad, aMaxWad]` behind a timelock. inside the band the allocator targets `a` near the curve's efficient point (`u` near 0.9), where junior earns a meaningful premium and senior still has headroom.

### 8.4 indicative quote (view)

```
function quote(uint256 S, uint256 J, uint256[] calldata rateFloorWad, uint256[] calldata caps) external view returns (uint256 uWad, uint256 piWad, uint256 rSFloorWad)
```

`rSFloorWad = weightedFloor * (WAD - pi)`. the realized senior rate is never below this if all fills respect their floors.

### 8.5 cancel

```
function cancel() external       allocator or sentinel, only in DEPLOYING and only while totalFilled == 0
```

returns all cash to the core, split by `S` and `J` (parking yield split by `a`, junior takes the rounding), and sets `state = CANCELED`.

---

## 9. pricing module

### 9.1 buffer usage

```
u = cov / a       rounded up, in (0, WAD] by check C1 of section 8.2
```

junior is co invested in the same basket as senior (beta = 1). coverage is `a`, utilization of coverage is `u`, exactly as in royco dawn where utilization measures how much of junior's coverage capacity backs senior.

### 9.2 premium curve

```
if u < uT (0.9e18):
    delta = (uT - u) / uT                     wad, rounded down
    pi    = piT - delta * (piT - pi0)         rounded up overall
else:
    delta = (u - uT) / (WAD - uT)             wad, rounded up
    pi    = piT + delta * (pi1 - piT)         rounded up overall
```

implementation note: write the lower branch as `pi = piT - mulDivDown(uT - u, piT - pi0, uT)` which rounds pi up because the subtracted term rounds down. write the upper branch as `pi = piT + mulDivUp(u - uT, pi1 - piT, WAD - uT)`.

checks (unit tests, exact at these points):

| a | u | pi |
|---|---|---|
| 0.15 | 1.00 | 0.35 |
| 0.1818... (200k / 1.1m) | 0.825 | 0.191666... |
| 0.20 | 0.75 | 0.183333... |
| 0.25 | 0.60 | 0.166666... |
| 0.30 | 0.50 | 0.155555... |
| u = 0 (limit) | 0 | pi0 |
| u = 0.9 | 0.9 | piT |

### 9.3 senior rate, claim, attachment (computed once, at finalize)

```
F       = sum U_i                                        units, exact
F_net   = sum projectedRedeemableAtT(i)                  units, see 12.2, equals F when fees are 0
r_pool  = mulDivDown(F_net, WAD, K_d) - WAD              term rate, net of fees
r_s     = mulDivDown(r_pool, WAD - pi, WAD)
S_d     = mulDivDown(K_d, WAD - a, WAD)
J_d     = K_d - S_d                                      residual, so S_d + J_d == K_d exactly
C_S     = S_d + mulDivDown(S_d, r_s, WAD)
A_F     = WAD - mulDivUp(C_S, WAD, F_net)
B_0     = F_net - C_S                                    must be >= J_d when r_pool >= 0
```

if `F_net <= K_d` (non positive pool rate, which floors should prevent) set `r_s = 0`, `C_S = S_d`, and flag `NegativeCarry` in the event. senior is still first, but earns nothing.

### 9.4 equivalence used by the simulation

```
1 + r_s = (1 - A_F) * (1 + r_pool) / (1 - a)
junior term return with zero losses and zero fee:
r_J = r_pool * (1 + pi * (1 - a) / a)
```

the python twin must reproduce both identities within 1e-12 relative error on random inputs.

---

## 10. deployment module (DEPLOYING)

### 10.1 two paths

| path | how | when to use | fee |
|---|---|---|---|
| maker (default) | the series is the maker of buy offers (bids) on each basket market, ratified through midnight's `SetterRatifier`. borrowers take them. midnight calls `Series.onBuy`, which pulls usdc from parking and approves midnight | thin books, which is the current state of midnight | none for the series: the taker (the borrower) carries the settlement fee |
| taker | allocator calls `Series.deployTake(...)` with existing sell offers (asks). the series is the taker and pays from its own balance | when asks exist below the floor price | series pays price plus settlement fee, included in its effective price |

both paths write to the same ledger and obey the same limits.

### 10.2 per market limits

```
P_max_i        = mulDivDown(WAD, WAD, WAD + rateFloorWad[i])     max price per unit, wad
tickMax_i      = highest tick t with t % tickSpacing_i == 0 and tickToPrice(t) <= P_max_i
cap_i          = marketCapAssets[i]
filled_i       <= cap_i
sum filled_i   <= K_alloc
effective price of every fill = assets paid / units received <= P_max_i
```

`P_max_i` rounds down so the realized rate is never below the floor. `tickMax_i` is computed at registration from the market's current tick spacing (spacing can only get finer, so a registered tick stays valid). the sdk's `priceToTick` returns the lowest tick at or above a price, so `tickMax_i` is the tick just below that result when the price is not exactly on the grid.

### 10.3 one time setup at series creation

```
midnight.setIsAuthorized(setterRatifier, true, address(this))
```

this is the only authorization a series ever grants (guard G3). midnight requires the maker to authorize its ratifier, and the `SetterRatifier` is the audited contract that the hosted router indexes. the allocator is never authorized on midnight: an authorized account could withdraw the series' credit to any address.

verified (section 2.2): the deployed setter ratifier has no code path that calls midnight except a read of `isAuthorized`, and `setIsRootRatified` accepts the maker itself, so the series sets its own roots.

### 10.4 maker path, step by step

1. the allocator builds offers off chain with the sdk: `maker = series`, `buy = true`, `tick <= tickMax_i`, `maxAssets` from the per market budget, `start = 0`, `expiry <= tDeployEnd`, `continuousFeeCap = policy.maxContinuousFee`, `reduceOnly = false`, `callback = address(series)`, `callbackData = abi.encode(i)`, `ratifier = setterRatifier`. offers that should share one budget are put in one group (all offers in a group share maker, side, loan token and cap). the whole set is committed to one merkle tree.
2. the allocator calls `Series.registerOffers(bytes32 root, Offer[] calldata leaves)`, where `leaves` is the full, padded leaf list of the tree in leaf order (at most 64 leaves, so height at most 6). the series:
   - recomputes the root on chain with the exact hashing of section 2.2 and requires it to equal `root`,
   - checks every leaf whose `maker == address(this)` against 10.2 and the offer template of step 1 (basket market, `buy`, tick, expiry, cap, callback, `callbackData`, fee cap, ratifier, group budget `<= K_alloc - totalFilled`),
   - ignores leaves with any other maker, because the setter ratifier looks up `isRootRatified[offer.maker][root]` and no other maker has ratified this root,
   - calls `setterRatifier.setIsRootRatified(address(this), root, true)` and stores the root and its groups for revocation.
   recomputing the full tree is what stops a compromised allocator from hiding a bad leaf in the root, since the ratifier only proves membership. how the sdk pads a tree to a power of two must be matched exactly (`[VERIFY]` in the sdk `Tree` source, or by a differential test that builds trees with the sdk and recomputes them in solidity).
3. the allocator publishes the encoded payload to the mempool (`Log`) contract from its own account. the mempool has no sender check (section 2.2), so no series function is needed for publishing. the allocator runs the sdk's `tree.mempoolValidate` first so the router accepts the payload.
4. a borrower takes a bid. midnight checks the ratifier authorization and the merkle proof, updates positions, then calls `Series.onBuy`:

```
function onBuy(bytes32 id, Market memory market, uint256 buyerAssets, uint256 units,
               uint128 pendingFeeIncrease, address buyer, bytes memory data) external returns (bytes32)

require msg.sender == midnight
require buyer == address(this)
if units == 0 and buyerAssets == 0: return CALLBACK_SUCCESS            no op take, nothing to record
require state == DEPLOYING and block.timestamp <= tDeployEnd
i = abi.decode(data, (uint256))
require id == basketId[i]                                              never trust callbackData alone
require units > 0
require mulDivUp(buyerAssets, WAD, units) <= P_max_i                   second line of defence after 10.2 checks
require filled_i + buyerAssets <= cap_i and totalFilled + buyerAssets <= K_alloc
parking.withdraw(buyerAssets, address(this))
usdc.forceApprove(midnight, buyerAssets)
filled_i += buyerAssets, U_i += units, feeCrystallized_i += pendingFeeIncrease, totalFilled += buyerAssets
emit Filled(i, buyerAssets, units, price, true)
return CALLBACK_SUCCESS
```

midnight passes `units` and the crystallized fee directly, so the fill is recorded inside the callback. there is no lazy reconciliation. if `onBuy` reverts, the whole take reverts and nothing changes.

5. several fills in one transaction simply call `onBuy` several times. each call is self contained.

### 10.5 taker path

```
function deployTake(uint256 i, Offer calldata offer, bytes calldata ratifierData, uint256 units) external onlyAllocator nonReentrant
```

```
require state == DEPLOYING and block.timestamp <= tDeployEnd
require offer.market id == basketId[i] and offer.buy == false
maxAssets = mulDivUp(units, tickToPrice(offer.tick) + settlementFee(id, ttm), WAD)
require filled_i + maxAssets <= cap_i and totalFilled + maxAssets <= K_alloc
parking.withdraw(maxAssets, this)
usdc.forceApprove(midnight, maxAssets)
creditBefore = credit after update
(buyerAssets, ) = midnight.take(offer, ratifierData, units, address(this), address(0), address(0), "")
units_got = credit after update - creditBefore                         measure, then require units_got == units
require mulDivUp(buyerAssets, WAD, units) <= P_max_i                    includes the settlement fee
parking.deposit(maxAssets - buyerAssets)
usdc.forceApprove(midnight, 0)
record fill with buyerAssets, units and the pending fee delta
```

`receiverIfTakerIsSeller` must be `address(0)` because the series is the buyer (midnight enforces it).

### 10.6 revocation

```
function revokeOffers(bytes32 root) external onlyAllocator         setIsRootRatified(series, root, false)
function cancelGroup(bytes32 group) external onlyAllocator        setConsumed(group, type(uint128).max, series)
```

finalize and cancel revoke every registered root and exhaust every registered group. even without that, `onBuy` reverts outside DEPLOYING, so no fill can land after finalize.

---

## 11. finalize

```
function finalize() external nonReentrant
```

callable by the allocator at any time during DEPLOYING, by anyone once `block.timestamp > tDeployEnd`.

```
revoke every registered root (setIsRootRatified false) and exhaust every registered group (setConsumed max)
K_d = totalFilled
if K_d == 0:
    return all cash to the core (as in cancel), state = CANCELED, emit, return
passThrough = K_d < kMin
compute S_d, J_d, F, F_net, u, pi, r_pool, r_s, C_S, A_F, B_0      (section 9.3)
returnS = S - S_d                                                  senior share of undeployed cash
returnJ = J - J_d                                                  junior share, J_d = K_d - S_d so returns sum to K_alloc - K_d
extra   = parking assets of the series - (returnS + returnJ)       parking yield earned while deploying, >= 0
extraS  = mulDivDown(extra, WAD - a, WAD), extraJ = extra - extraS
core.receiveReturn(returnS + extraS, returnJ + extraJ)             usdc transferred with the call
state = LOCKED
tFinalize = block.timestamp
emit Finalized(K_d, S_d, J_d, F, F_net, a, u, pi, r_pool, r_s, C_S, A_F, passThrough, units per market, filled per market)
```

if parking lost value during deployment, `extra` is negative. then the loss is taken pro rata by `a` from the returns, junior taking the rounding.

why partial fills simply proceed: once units are bought, the usdc is lent to midnight borrowers and cannot be refunded without selling units at a loss. the tranche math is scale invariant because `a` is fixed, so a partially filled series is the same deal at a smaller size. below `kMin` it runs pass through (section 13.6) because the premium machinery is not worth it on dust.

after finalize the core records `seniorAllocated = S_d` and `juniorAllocated = J_d` for this series. from then on each vault's exposure to the series is its nav leg (section 12.4).

---

## 12. accounting module (LOCKED and after)

### 12.1 what is read, what is stored

stored at finalize (write once): `U_i`, `filled_i`, `feeCrystallized_i`, `F`, `F_net`, `K_d`, `S_d`, `J_d`, `C_S`, `A_F`, `r_pool`, `r_s`, `pi`, `u`, `a`, `tFinalize`, `tau = T - tFinalize`.

read live through `MidnightReader`, never estimated:

```
(credit_i, pendingFee_i, ) = midnight.updatePositionView(market_i, id_i, series)     slashed and accrued, view only
collected_i                                                                             usdc already withdrawn from market i
```

### 12.2 projected redeemable face

```
E_i(t)          = credit_i(t) - pendingFee_i(t)                        face still in market i (midnight natspec definition)
F_net           = sum over i of (U_i - feeCrystallized_i)              face at finalize
F_net(t)        = sum over i of (E_i(t) + collected_i)                 face still owed plus cash already collected
L(t)            = F_net - F_net(t)                                     realized face loss since finalize, >= 0
B(t)            = F_net(t) - C_S                                       signed buffer before senior impairment
```

- continuous fees need no separate term. midnight crystallizes the whole future fee into `pendingFee` at entry, accrues it linearly, and deducts it from credit. `credit - pendingFee` is already net of every fee to maturity.
- early withdrawals (section 13.2) move value from `E_i` to `collected_i` one for one, and release the matching share of `pendingFee`, so they never show up as a loss. they can show up as a small gain (the released fee), which is correct: the series paid less fee than it crystallized.
- bad debt shows up only once it has been realized by a liquidation. an underwater borrower that nobody has liquidated yet is invisible to every lender, including the series. that is a property of midnight, not of this design, and the sim models it through liquidation latency.
- why there is no separate `Phi`: subtracting an estimated fee on top of net credit, as the v1 pdf does in `B(t)` and in the waterfall, would count fees twice. section 30, issue 5.

### 12.3 sync

```
function sync(uint256 i) external
```

permissionless. calls `midnight.updatePosition(market_i, series)`, which applies the latest loss factor and accrues the fee on chain, then emits `BufferUpdated(i, credit_i, F_net_t, B_t, L_t)`. views use `updatePositionView` and need no sync. `syncAll` in the core calls `navsSynced`, which runs `sync` on every basket market.

the series never makes economic decisions from `B(t)`. it is published so integrators, junior holders and monitoring can react.

### 12.4 display navs (corrected)

define the pool mark, with profit accruing linearly and losses recognized immediately:

```
s          = min(t - tFinalize, tau)                             elapsed, capped
V(t)       = K_d + (F_net - K_d) * s / tau - L(t)                pool value mark, floored at 0
NAV_S      = min(S_d + (C_S - S_d) * s / tau, V(t))
NAV_J_gross = V(t) - NAV_S                                       always >= 0
feeAccrued = mulDivDown(max(NAV_J_gross, J_d) - J_d, theta, WAD)  operator fee on junior profit so far
NAV_J      = NAV_J_gross - feeAccrued                            the published junior mark
```

in pass through mode: `NAV_S = mulDivDown(V, S_d, K_d)`, `NAV_J = V - NAV_S`, no fee.

properties (all unit tested and fuzzed):

- with `L = 0` and `theta = 0`, `NAV_J = J_d + (B_0 - J_d) * s / tau`, exactly the v1 pdf junior formula.
- a loss hits `NAV_J` in full immediately, and hits `NAV_S` only once `NAV_J` is zero.
- `NAV_S + NAV_J + feeAccrued == V(t)` always.
- at `t = T` with every market resolved, `NAV_S == XS`, `NAV_J == XJ` and `feeAccrued == fee` from the waterfall of section 13.5. the mark converges to the payout exactly. without netting the fee, the junior mark would end above the junior payout (by 338.64 usdc in the section 19 example), which the junior vault, pricing off this mark, would pay out to exiting holders at the expense of those who stay.

why the v1 pdf senior formula is replaced: it spreads a senior impairment over time (`+ B(t) * t / tau`) while junior takes losses instantly, so the two marks stop summing to the pool. with the worked example of section 19 at `t = 0.1 tau` and a 200k face loss, the pdf formula marks senior at about 817.4k while the whole pool is worth about 801k. the senior vault would overprice `srUSDC` by the same amount.

views used by the core:

```
function navs() external view returns (uint256 navS, uint256 navJ, uint256 feeAccrued)
function navsSynced() external returns (uint256 navS, uint256 navJ, uint256 feeAccrued)    calls sync on every basket market first
```

in DEPLOYING, `value` is the series' parking assets plus the assets spent on fills (units held at cost), and the legs are `navS = mulDivDown(value, WAD - a, WAD)`, `navJ = value - navS`. in SETTLING the legs use the same formula as LOCKED with `s = tau`. in SETTLED and CANCELED both legs are 0 because every payout has already been pushed to the core. unrealized recoveries on written off markets are valued at 0 until collected.

### 12.5 what the ledger does not do

- no rebalancing, no selling of units before `T`, no early exit.
- no reaction to oracle staleness. an informational `staleOracle_i` flag can be computed off chain from the oracle's last update.

---

## 13. settlement module

### 13.1 start

```
function startSettlement() external
```

anyone, once `block.timestamp >= T` and `state == LOCKED`. sets `state = SETTLING`.

### 13.2 collect

```
function collect(uint256 i) external nonReentrant returns (uint256 received)
```

anyone, in LOCKED, SETTLING or SETTLED. collecting before maturity is allowed on purpose (section 2.5 on withdrawals): withdrawable liquidity from early repayments and liquidations is shared by all lenders first come first served, and taking it at par is strictly good for the series.

```
midnight.updatePosition(market_i, series)
units     = min(credit_i, midnight.withdrawable(id_i))
if units == 0: return 0
balBefore = usdc.balanceOf(this)
midnight.withdraw(market_i, units, address(this), address(this))
received  = usdc.balanceOf(this) - balBefore                     measure, never trust return values
require received == units
collected_i += received
parking.deposit(received)                                        collected cash earns parking yield until paid out
if block.timestamp > T and credit_i == 0: resolved_i = true
if state == SETTLED: _rerunWaterfall()
```

borrowers repay, or keepers liquidate overdue positions with their own capital through the midnight auction. the series never liquidates and never borrows.

cumulative proceeds used by the waterfall:

```
P = usdc.balanceOf(this) + parking.convertToAssets(parkingShares) + paidS + paidJ + feeClaimed
```

so parking yield on collected cash is part of `P`, and cash already pushed to the core is never double counted.

### 13.3 settle

```
function settle() external
```

anyone, in SETTLING, when every `resolved_i` is true. runs `_rerunWaterfall()`, sets `state = SETTLED`, `tSettled = block.timestamp`.

### 13.4 write off

```
function writeOff() external
```

anyone, in SETTLING, once `block.timestamp >= T + D_wo`. marks every unresolved market `writtenOff_i = true`, runs `_rerunWaterfall()` on proceeds so far, sets `state = SETTLED`.

the v1 pdf condition ("auction open 24h with no taker" or "collateral frozen 72h") cannot be observed on chain, and with btc collateral and open liquidation the frozen case does not apply. time is the only on chain signal, so write off is purely time based. `D_wo` default 7 days.

written off markets keep their credit. `collect(i)` stays callable forever and every later receipt is a recovery.

### 13.5 cumulative waterfall

every payout is a function of cumulative proceeds `P` only. rerunning it after each receipt gives the correct result for recoveries automatically and keeps strict seniority.

```
function _rerunWaterfall() internal
  P      = cumulative proceeds as defined in 13.2
  if passThrough: see 13.6
  XS     = min(C_S, P)
  RJ     = P - XS
  fee    = mulDivDown(max(RJ, J_d) - J_d, theta, WAD)          operator fee on junior profit only
  XJ     = RJ - fee                                             residual, exact
  dS     = XS - paidS,  dJ = XJ - paidJ,  dFee = fee - feeAccounted
  paidS  = XS, paidJ = XJ, feeAccounted = fee, feeOwed += dFee
  core.receivePayout(dS, dJ)                                    usdc transferred with the call
  emit Waterfall(P, XS, XJ, fee, dS, dJ)
```

monotonicity (fuzz test): `XS`, `XJ` and `fee` are non decreasing in `P`, so every delta is `>= 0`. `XJ` has slope 1 below `J_d` of junior profit and `1 - theta` above, so it never decreases.

conservation at every rerun: `XS + XJ + fee == P`.

recovery order: because `XS = min(C_S, P)`, any recovery goes to senior until senior is whole, then to junior, then fee. this replaces the v1 pdf rule "junior up to its realized loss, then senior, then junior", which would pay junior before an impaired senior and break seniority. section 30, issue 7.

### 13.6 pass through mode

```
XS  = mulDivDown(P, S_d, K_d)
XJ  = P - XS
fee = 0
```

both books get the market outcome pro rata. no premium, no subordination. this only happens when the fill is below `kMin`.

### 13.7 fee payment

```
function claimFee() external
```

pays `feeOwed` to `feeRecipient`. callable by anyone.

---

## 14. payout routing

a series never pays a user. it pays the core, which credits the books:

```
function receiveReturn(uint256 toSenior, uint256 toJunior) external onlySeries    at finalize or cancel
function receivePayout(uint256 toSenior, uint256 toJunior) external onlySeries    at every waterfall rerun
```

- the series transfers `toSenior + toJunior` usdc in the same call. the core measures its balance delta and requires it to equal the sum.
- the core deposits the cash into parking and credits the parking shares to the senior and junior books.
- the core then updates the series registry: after `settle` or `writeOff`, the series moves from live to settled. recoveries later arrive through `receivePayout` from a settled series and are credited the same way.
- because payouts are pushed, there is no per holder redemption state, no index, and no recovery claim anywhere in the system. a depositor's share of any recovery arrives automatically through the vault share price.

---

## 15. fees summary

| fee | who pays | how |
|---|---|---|
| midnight settlement fee | taker. zero for a series on the maker path, included in effective price on the taker path | protocol |
| midnight continuous fee | all lenders, including every series | deducted from credit, visible in `E_i(t)` |
| operator fee `theta` | junior book, only on junior profit above `J_d` in each series | series waterfall |
| vault performance fee | optional, default 0, on nav growth above a high water mark, per vault | minted as shares at epoch close |
| senior fee | none by default | |

---

## 16. access control and operations

| function | who |
|---|---|
| vault `deposit`, `mint`, `requestDeposit`, `requestRedeem`, `cancel*`, claims | the controller or an operator it approved through `setOperator` |
| `SeriesCore.openSeries`, `Series.registerOffers`, `revokeOffers`, `deployTake`, early `finalize`, `fulfillEpoch` | allocator |
| `Series.cancel` | allocator or sentinel, only before any fill |
| `finalize` after `tDeployEnd`, `sync`, `startSettlement`, `collect`, `settle`, `writeOff`, `claimFee`, `closeEpoch`, `fulfillEpoch` after `fulfillDelay` | anyone |
| curator policy (section 20.5) | curator, risk increases behind a 3 day timelock, decreases immediate |
| pause deposits, lower caps | sentinel |
| factory allowlists, curator seat | governance, 48h timelock |

- no upgradeability. the core, both vaults and every series are immutable. a new core with new vaults is a new product, and users migrate by redeeming.
- allocator and curator are safes. recommended 2 of 3, as in the v1 pdf. this is an ops rule, not contract logic.
- no emergency withdrawal exists, by design. cash leaves only through the waterfall and the redemption epochs.

---

## 17. events

series:

```
SeriesOpened(address series, uint64 T, bytes32[] markets, uint256 S, uint256 J, bytes32 attestationHash)
OffersRegistered(bytes32 root, uint64 expiry, uint256[] budgets)
OffersRevoked(bytes32 root)
Filled(uint256 i, uint256 assets, uint256 units, uint256 priceWad, bool maker)
Finalized(uint256 K_d, uint256 S_d, uint256 J_d, uint256 F, uint256 F_net, uint256 aWad, uint256 uWad, uint256 piWad, uint256 rPoolWad, uint256 rSWad, uint256 C_S, uint256 A_FWad, bool passThrough, bool negativeCarry)
Canceled(uint256 toSenior, uint256 toJunior)
BufferUpdated(uint256 i, uint256 credit, uint256 F_net_t, int256 B_t, uint256 L_t)
SettlementStarted()
Collected(uint256 i, uint256 received, uint256 proceedsCum, bool resolved)
WrittenOff(uint256[] markets, uint256 proceedsCum)
Waterfall(uint256 P, uint256 XS, uint256 XJ, uint256 fee, uint256 dS, uint256 dJ)
Settled(uint256 P)
FeeClaimed(uint256 amount)
```

core:

```
SeriesFunded(address series, uint256 S, uint256 J)
ReturnReceived(address series, uint256 toSenior, uint256 toJunior)
PayoutReceived(address series, uint256 toSenior, uint256 toJunior)
Reserved(bool senior, uint256 assets)
Paid(bool senior, address to, uint256 assets)
PolicySubmitted(bytes32 key, uint256 value, uint256 executableAt)
PolicyExecuted(bytes32 key, uint256 value)
Synced(uint256 seniorAssets, uint256 juniorAssets)
StressGate(bool open)
Backstop(address series, uint256 assets)
```

vault events are the standard erc 4626, erc 7540 and erc 7887 events, plus `EpochClosed(uint256 epoch, uint256 totalShares, uint256 ppsCloseWad)` and `EpochFulfilled(uint256 epoch, uint256 shares, uint256 assets, uint256 priceWad)`.

every storage change must be reconstructible from events. this is also what midnight's own review guidelines ask for, and indexers will rely on it.

---

## 18. errors

```
WrongState(State expected, State actual)
TooEarly(uint256 at)
TooLate(uint256 at)
NotAllocator()
NotCore()
NotSeries()
NotVault()
NotMidnight()
NotSelfBuyer()
IneligibleMarket(bytes32 id, uint8 rule)
CapExceeded(uint256 i)
PriceFloorBreached(uint256 i, uint256 priceWad, uint256 maxWad)
CoverageBand(uint256 aWad)
CapacityExceeded(uint256 senior, uint256 capacity)
StressGateClosed()
IdleInsufficient(bool senior, uint256 asked, uint256 available)
MaxOpenEpochs()
ZeroUnits()
MarketMismatch(bytes32 expected, bytes32 actual)
NotResolved(uint256 i)
Reentrancy()
```

---

## 19. worked example (all numbers verified in python)

inputs: `COV = 0.15`, anchors `0.10 / 0.20 / 0.35`, `theta = 0.10`, pool term rate 1.0 percent (about 6.5 percent annualized over 56 days), fees 0. the allocator opens a series with `J = 200,000` from the junior book and `S = 900,000` from the senior book.

open:

```
K_alloc = 1,100,000
a       = 0.181818...                     inside the band [0.15, aMax]
u       = 0.15 / 0.181818                = 0.825
pi      = 0.20 - (0.9 - 0.825) / 0.9 * 0.10 = 0.191667
```

deployment fills 1,000,000 of 1,100,000 (fill ratio 0.909), buying 1,010,000 units.

```
S_d   = 818,181.82        J_d = 181,818.18        100,000 undeployed returns to the books (81,818 senior, 18,182 junior)
r_pool = 1.0000%   r_s = 0.80833%   C_S = 824,795.45   A_F = 18.337%   B_0 = 185,204.55
```

outcomes at maturity:

| face loss | P | to senior book | senior multiple | to junior book | junior return | fee |
|---|---|---|---|---|---|---|
| 0 | 1,010,000 | 824,795.45 | 1.008083 | 184,865.91 | +1.676% | 338.64 |
| 150,000 | 860,000 | 824,795.45 | 1.008083 | 35,204.55 | -80.64% | 0 |
| 200,000 | 810,000 | 810,000.00 | 0.990000 | 0 | -100% | 0 |

gross junior return with no loss and no fee: 1.8625 percent, which is `r_pool * (1 + pi * (1 - a) / a) = 1.0% * 1.8625`. junior downside leverage: a 1 percent face loss costs junior about 5.5 percent of its capital (`1 / a`).

---

# part B: surface

---

## 20. SeriesCore

### 20.1 purpose

the core is the single place where value lives and is counted. it holds all idle cash in parking, owns every series, and keeps two books: what belongs to senior depositors and what belongs to junior depositors. the two vaults are share ledgers on top of these books. this is the same split idle, strata and royco use: one engine, two tranche tokens.

### 20.2 state

```
struct Book {
  uint256 parkingShares           idle cash of this book, held in parking, earns parking yield
  uint256 reservedAssets          usdc set aside for fulfilled redemptions, held as usdc, not in parking
  uint256 pendingDeposits         junior only: usdc from deposit requests not yet fulfilled, held as usdc
}
Book senior
Book junior
address[] liveSeries              DEPLOYING, LOCKED, SETTLING. length <= maxSeries
address[] recoveringSeries        SETTLED with written off credit left. length <= maxRecovering
mapping(address => SeriesInfo) info       S_alloc, J_alloc (updated at finalize), T, status
Policy policy                     section 20.5
```

### 20.3 valuation

```
seniorAssets() = parking.convertToAssets(senior.parkingShares) + sum over liveSeries of navS
juniorAssets() = parking.convertToAssets(junior.parkingShares) + sum over liveSeries of navJ
```

- `navS`, `navJ` come from `Series.navs()` (section 12.4), junior net of the accrued operator fee.
- reserved assets and pending junior deposits are excluded. they are owed to specific redeemers or not yet invested.
- recovering series contribute 0 until cash actually arrives.
- every term rounds down.
- `seniorAssetsSynced()` and `juniorAssetsSynced()` call `navsSynced()` on every live series first (section 20.7).

### 20.4 coverage at vault level

each series enforces `a >= COV` when it is opened. the core adds two vault level rules so the books cannot drift apart:

```
seniorCapacity = mulDivDown(juniorAssets, WAD - covVaultWad, covVaultWad)
senior deposits:        seniorAssets + assets <= seniorCapacity                     (default covVaultWad = 0.20)
junior redemptions:     after fulfillment, juniorAssets >= seniorAssets * covVaultMinWad / (WAD - covVaultMinWad)
                                                                                    (default covVaultMinWad = COV = 0.15)
```

- the first rule is the v1 idea that senior capacity opens with junior (`Cap_S` on `COV`), moved from a single series to the whole product. at `covVaultWad = 0.20` every 1 usdc of junior opens 4 usdc of senior.
- the second rule mirrors royco, where junior withdrawals are paused when coverage would fall below the minimum. a junior redemption epoch fills only up to the amount that keeps coverage at the floor. the rest waits for more junior deposits or for senior to shrink.
- neither rule forces anything. if junior losses shrink `juniorAssets`, senior deposits close and the allocator can deploy less senior, but existing positions are untouched.

### 20.5 curator policy

```
covWad                  COV, minimum junior share of every series, default 0.15
aMaxWad                 maximum junior share of a series, default 0.30
covVaultWad             vault level target coverage for senior capacity, default 0.20
covVaultMinWad          vault level floor for junior redemptions, default 0.15
pi0Wad, piTWad, pi1Wad  premium anchors, default 0.10 / 0.20 / 0.35
thetaWad                operator fee on junior profit, default 0.10
minRateFloorWad         lowest rate floor the allocator may set for any market, annualized
maxSeries               hard ceiling 12, bounds every loop
maxRecovering           hard ceiling 8
maxPerSeriesAssets      absolute cap per series
maxPerMaturityWindowWad cap on assets maturing inside any 30 day window, default 0.50 of total assets
minIdleSeniorWad        idle floor kept out of new series, default 0.05 of senior assets
minIdleJuniorWad        default 0.05 of junior assets
stressJuniorFloorWad    stress gate threshold, default 0.50
backstopEnabled         default false (section 20.8)
backstopWad             share of junior idle usable for backstop, default 0.50
epochLength             default 7 days, both vaults
fulfillDelay            default 1 day
maxOpenEpochsPerController   default 4
performanceFeeWad       per vault, default 0
curatorMinShareWad      minimum share of jrUSDC supply held by the curator, default 0.10
```

risk increasing changes (for example raising `aMaxWad`, caps, anchors that shift premium away from junior, enabling backstop) wait for the curator timelock. risk decreasing changes apply at once, and the sentinel can make them too.

### 20.6 functions

allocator:

```
function openSeries(SeriesParams calldata p, uint256 S, uint256 J) external returns (address series)     section 8.2
```

series only:

```
function receiveReturn(uint256 toSenior, uint256 toJunior) external       section 14
function receivePayout(uint256 toSenior, uint256 toJunior) external       section 14
```

vaults only:

```
function depositFor(bool senior, uint256 assets) external                 usdc already transferred, parked, shares credited to the book
function addPendingJunior(uint256 assets) external                        junior deposit request, usdc held as pending
function removePendingJunior(uint256 assets, address to) external         junior deposit cancel
function investPendingJunior(uint256 assets) external                     junior deposit fulfillment, pending to book
function reserveFor(bool senior, uint256 assets) external                 redemption fulfillment, book to reserved
function payFrom(bool senior, address to, uint256 assets) external        redemption claim, reserved to user
```

anyone:

```
function syncAll() external
function pruneSeries() external              moves settled series out of liveSeries, bounded loop
```

views:

```
function seniorAssets() external view returns (uint256)
function juniorAssets() external view returns (uint256)
function seniorCapacity() external view returns (uint256)
function idleAvailable(bool senior) external view returns (uint256)       book idle minus idle floor
function idle(bool senior) external view returns (uint256)                book idle, floor included
function stressGateOpen() external view returns (bool)
function juniorRedeemable() external view returns (uint256)               max junior assets redeemable under the coverage floor
```

### 20.7 sync rule

every action that sets a price calls `syncAll()` first: senior deposits, every epoch close, every epoch fulfillment, junior deposit fulfillment. cost is bounded by at most 12 live series times at most 4 markets. sync can only reveal losses (accretion is time based and needs no sync), so a synced price is never higher than the unsynced view.

### 20.8 cross series backstop (optional, off by default)

when a series reruns its waterfall with `XS < C_S` and `backstopEnabled`, the core moves

```
backstop = min(C_S - XS - backstopPaid[series], mulDivDown(juniorIdle, backstopWad, WAD))
```

from the junior book to the senior book and emits `Backstop`. later recoveries on that series repay the junior book first, up to `backstopPaid`, before anything else flows to junior.

with the backstop on, junior depositors are first loss for the whole senior book, not just per series. that is stronger protection for senior and more tail risk for junior. it is an open decision (section 31) because it changes what `jrUSDC` holders are underwriting.

### 20.9 stress gate

`stressGateOpen()` is false when any live series has `navJ < stressJuniorFloorWad * J_d`, or any recovering series still holds written off credit. while closed, senior deposits revert. the second condition matters because a written off market is valued at 0 until recovered, so a recovery would jump the senior price and a depositor entering just before it would capture part of it.

---

## 21. SeniorVault (`srUSDC`)

### 21.1 standards and share token

- the vault is its own share token (`share() == address(this)`).
- deposits are synchronous erc 4626. redemptions are asynchronous erc 7540 with epoch request ids. redeem cancelation is erc 7887, synchronous, only while the epoch is still open.
- `supportsInterface` returns true for erc 165 (`0x01ffc9a7`), erc 7540 operator (`0xe3bc4e65`), erc 7575 (`0x2f0a18c5`), erc 7540 async redeem (`0x620ee8e4`), erc 7887 redeem cancelation (`0xe76cffc7`). it must return false for erc 7540 async deposit (`0xce3bbe50`).
- share decimals 18, with a decimals offset of 12 over usdc and virtual shares and assets in the conversion (the openzeppelin erc 4626 offset approach). the deploy script makes a dead deposit. both protect against the first depositor inflation attack.
- the vault holds no usdc. `asset()` is usdc, `totalAssets()` is `core.seniorAssets()`.

### 21.2 deposit (synchronous)

```
deposit(assets, receiver):
  require !paused and core.stressGateOpen()
  core.syncAll()
  require core.seniorAssets() + assets <= core.seniorCapacity()
  shares = convertToShares(assets)            rounded down, virtual offset
  usdc.transferFrom(msg.sender, core, assets), core.depositFor(SENIOR, assets)
  mint shares to receiver
```

`maxDeposit` returns `seniorCapacity - seniorAssets` while open, 0 while paused or gated. `previewDeposit` uses unsynced marks. sync can only lower the price, so the shares minted are never fewer than the preview, as erc 4626 requires.

### 21.3 redemption (asynchronous, epochs)

shared with the junior vault through `EpochQueue`:

```
struct Epoch {
  uint256 totalShares           requested in this epoch
  uint256 ppsCloseWad           price per share at close, 0 while open
  uint256 sharesFulfilled
  uint256 assetsFulfilled
}
mapping(uint256 => Epoch) epochs
mapping(uint256 => mapping(address => uint256)) requested        epoch -> controller -> shares
mapping(uint256 => mapping(address => uint256)) sharesClaimed
mapping(address => uint256[]) openEpochs                         bounded by maxOpenEpochsPerController
uint256 currentEpoch
```

1. `requestRedeem(shares, controller, owner)` returns `requestId = currentEpoch`. shares move into vault custody and keep bearing price changes until fulfilled.
2. `closeEpoch()` anyone, once `block.timestamp >= epochStart + epochLength`. runs `core.syncAll()`, stores `ppsCloseWad = totalAssets * WAD / totalSupply` (with the virtual offset), opens the next epoch.
3. `fulfillEpoch(e, maxAssets)` allocator, or anyone once `fulfillDelay` has passed:

```
core.syncAll()
priceWad  = min(ppsCloseWad, ppsNowWad)                            min rule
available = min(maxAssets, core.idle(SENIOR))                       redemptions may use the whole idle, floor included
shares    = min(e.totalShares - e.sharesFulfilled, available * WAD / priceWad)
assets    = shares * priceWad / WAD                                 rounded down
burn shares from custody, core.reserveFor(SENIOR, assets)
e.sharesFulfilled += shares, e.assetsFulfilled += assets
```

4. per controller, claimable shares are `requested * sharesFulfilled / totalShares - sharesClaimed`, and claimable assets are the matching share of `assetsFulfilled`. every controller in an epoch gets the same pro rata fill at the same price, which erc 7540 requires of a shared request id.
5. `redeem(shares, receiver, controller)` and `withdraw` claim across the controller's open epochs, oldest first, paying through `core.payFrom`.
6. `cancelRedeemRequest(e, c)` only while `e == currentEpoch`. shares return through `claimCancelRedeemRequest`.

why the min rule: a loss realized while the request waits hits the redeemer too, so nobody can queue an exit, watch a loss arrive, and leave it to the holders who stay. gains during the wait stay with the vault.

### 21.4 liquidity

- no instant exit. the worst case wait is the longest live maturity plus `D_wo`.
- the allocator staggers maturities so some series settles in most epochs, and keeps `minIdleSeniorWad` of senior assets in parking.
- the ui shows the expected fulfillment date per epoch from the maturity schedule of live series.

### 21.5 risks specific to this vault

| risk | mitigation |
|---|---|
| stale marks used for pricing | `syncAll` before every price setting action |
| senior impairment in one series | shows as a price drop at the next sync, spread across holders. caps per series and per maturity window limit it. optional backstop (20.8) |
| recovery jumps after write off | stress gate closes deposits while any recovering credit is outstanding |
| senior outgrowing junior | capacity rule of 20.4 |
| idle drag when senior capacity is unused | idle earns parking yield. capacity rule stops deposits the allocator could not deploy |
| long waits | ladder discipline, idle floor, public maturity schedule |

---

## 22. JuniorVault (`jrUSDC`)

### 22.1 purpose and standards

permanent first loss capital for every series. the curator must hold at least `curatorMinShareWad` of `jrUSDC` supply: the party that picks the series takes the first loss of the first loss.

- fully asynchronous erc 7540: deposits and redemptions both go through epochs. erc 7887 cancelation on both sides, synchronous, only while the epoch is open.
- `supportsInterface` returns true for async deposit, async redeem, operator, erc 7575 and both erc 7887 ids.
- same share decimals, offset and dead deposit as the senior vault.

### 22.2 deposits (epochs, max rule)

```
requestDeposit(assets, controller, owner)  -> requestId = currentEpoch
                                              usdc to the core as pending (core.addPendingJunior)
closeEpoch()                                  core.syncAll, ppsCloseWad snapshot
fulfillDeposits(e)                            core.syncAll
                                              priceWad = max(ppsCloseWad, ppsNowWad)        max rule
                                              shares   = assets * WAD / priceWad            rounded down
                                              core.investPendingJunior(assets)
                                              shares claimable via deposit or mint
cancelDepositRequest(e, c)                    only while e is open, core.removePendingJunior, claim via claimCancelDepositRequest
```

pending deposits are not part of `juniorAssets` and earn nothing until fulfilled, so they cannot dilute or be diluted.

the max rule protects existing holders when the price jumps up while a request waits, for example when a written off market recovers.

### 22.3 redemptions (epochs, min rule, coverage floor)

same as section 21.3, with one more cap at fulfillment:

```
assets <= core.juniorRedeemable()          keeps vault coverage at or above covVaultMinWad (20.4)
curator requestRedeem reverts if it would take the curator below curatorMinShareWad
```

---

## 23. morpho vault v2 adapter (`SeniorVaultAdapter`), optional distribution

### 23.1 purpose

morpho vault v2 connects to external yield sources through adapters that report their value through `realAssets()`. an adapter into the senior vault lets any vault v2 curator allocate a slice of an existing usdc vault to `srUSDC`, before the dao enables direct midnight allocations.

### 23.2 behaviour

```
allocate(assets)     deposit into SeniorVault (synchronous), hold srUSDC
deallocate(assets)   only up to assets already claimable from fulfilled redemption epochs
requestExit(shares)  vault v2 allocator queues a redemption epoch through the adapter
realAssets()         convertToAssets(sharesHeld) + value of pending redemption shares + claimable assets
ids                  adapter id, "series-senior", and one id per collateral token of live series
```

every name above must be mapped onto the real vault v2 adapter interface in M0 `[VERIFY]`.

### 23.3 constraints

- vault v2 lets anyone move assets from an adapter back to idle with `forceDeallocate`, with a penalty set per adapter. this adapter cannot pay instantly, so force deallocation beyond claimable assets reverts. curators must treat it as illiquid: a relative cap of at most 10 percent, a liquid liquidity adapter elsewhere, and the maximum force deallocate penalty.
- `realAssets()` is a mark. the vault v2 share price follows it. document this in the adapter natspec and in the curator runbook.

---

## 24. end to end flows

### 24.1 cash path

```
1  depositors -> SeniorVault.deposit / JuniorVault.requestDeposit + fulfillDeposits     usdc into the core books
2  allocator -> core.openSeries(params, S, J)                                           books -> series parking
3  series deploys, finalize                                                             usdc lent on midnight, undeployed back to books
4  series LOCKED to T                                                                   vault prices follow navS and navJ via sync
5  series settles, waterfall                                                            XS to senior book, XJ to junior book, fee aside
6  allocator -> core.openSeries for the next maturity                                   the ladder rolls
7  closeEpoch, fulfillEpoch                                                             usdc reserved for redeemers at the min rule price
8  redeemers -> redeem                                                                  usdc out through core.payFrom
```

### 24.2 pricing rules

| action | price | why |
|---|---|---|
| senior deposit | synced price, stress gate, capacity | sync only lowers marks, so previews are safe |
| senior redemption | min(close snapshot, fulfillment) | no escaping realized losses while queued |
| junior deposit | max(close snapshot, fulfillment) | no capturing recovery jumps while queued |
| junior redemption | min(close snapshot, fulfillment), coverage floor | same, plus senior keeps its buffer |
| vault v2 adapter | unsynced mark | view only |

### 24.3 failure containment

| event | effect |
|---|---|
| series nothing filled | CANCELED, cash back to both books, no loss beyond parking |
| series pass through | both books take the market outcome pro rata for that series. caps bound it |
| junior wiped in one series, senior impaired | senior price drops at next sync. stress gate closes senior deposits. backstop if enabled |
| write off with credit left | series settles on collected cash. recovering credit valued at 0, senior deposits gated, recoveries flow to the books when collected |
| junior redemptions larger than the coverage floor allows | epochs fill partially, the rest waits |
| midnight, oracle or parking failure | no function in the surface depends on one series being live. fulfillment waits for cash |

---

# part C: verification, simulation, delivery

---

## 25. test suite

all tests in foundry. naming: `test_<contract>_<behaviour>`, `testFuzz_...`, `invariant_...`. every test that encodes a number from this document cites the section.

### 25.1 test harness: the real midnight, not a mock

midnight's `test`, `interfaces` and `libraries` folders are gpl 2.0 or later and the core is busl 1.1, which allows non production use. so tests deploy the **real** `Midnight` contract from `lib/midnight` at the pinned commit instead of a mock. this removes a whole class of "the mock behaved differently" bugs.

`MidnightHarness` (reuse midnight's own `test/BaseTest.sol` helpers where possible):

```
deploy Midnight with the harness as configurator
enableLltv for the tiers used in tests, enableLiquidationCursor for 0.25e18 and 0.5e18
setFeeSetter, then set default settlement and continuous fees per scenario (0 by default, caps in fee scenarios)
deploy the shipped SetterRatifier
create markets for cbBTC and WBTC mocks with MockOracle prices
helpers: borrow(borrower, market, collateral, units) by taking a series bid,
         crash(oracle, price) then liquidate to realize bad debt,
         repay(borrower, units), warp(to maturity), noOpTake(offer)
```

the real protocol requires `evm_version = "osaka"` and solc 0.8.34 for the midnight sources. compile our contracts with the same solc.

`MockErc4626` has a `lossBps` knob to simulate a parking vault loss and a `liquidityCap` to simulate a vault that cannot pay a withdrawal.

### 25.2 unit tests

**WadMath**
- mulDivDown and mulDivUp against openzeppelin `Math.mulDiv` on 10,000 random triples including max uint values.
- `mulDivUp(x, y, d) - mulDivDown(x, y, d) in {0, 1}`.

**PremiumCurve** (section 9.2)
- the seven exact table points, continuity at `u = uT` (difference <= 1 wei), monotone non decreasing over a 1,000 point grid, clamp for `u > WAD`.

**SeriesMath**
- `pricing`: section 19 numbers to the wei with 6 decimal inputs, `NegativeCarry` path, identity 9.4 within 1 wei.
- `nav`: the properties of 12.4, including convergence to the waterfall at `T`, and the v1 counter example producing `NAV_S <= V`.
- `waterfall`: the table of section 19, conservation, monotonicity, `P = 0`, `P < C_S`, `P == C_S`, very large `P`, `J_d == 0` guard, pass through.

**EpochMath**
- pro rata fill across 1 to 200 controllers: sum of claimable shares equals `sharesFulfilled`, sum of claimable assets `<= assetsFulfilled`, dust bounded by controller count.
- several fulfillment rounds per epoch at different prices, each respecting the min rule. max rule for junior deposits.
- a controller with `maxOpenEpochsPerController` open epochs cannot request again until one is claimed.

**Series**
- creation: every eligibility rule E1 to E6 failing alone, only the core can create and fund.
- maker fill through `onBuy` on the real midnight: records units, assets and crystallized fee, a tick at the floor passes, `registerOffers` rejects a tick one step above `tickMax_i`, wrong caller, wrong buyer, wrong market id in `callbackData`, per market cap, total cap, fill after `tDeployEnd`, fill after finalize all revert.
- a no op take (units 0) calls `onBuy` with zero amounts and changes no state, in every series state.
- the only address the series ever authorizes on midnight is the setter ratifier (read `isAuthorized` for the allocator, core and a random address after every flow).
- early collect: a repayment before maturity makes liquidity withdrawable, `collect` takes it at par, `navJ` does not drop, released pending fee shows as a small gain.
- taker path: settlement fee included in effective price, leftover returned to parking, allowance reset to zero.
- batched fills: 1 to 20 fills in one transaction across markets are each recorded exactly.
- parking cannot pay (`liquidityCap`): fill reverts, series state unchanged.
- cancel before any fill returns `S` and `J` exactly. cancel after a fill reverts.
- finalize: `K_d == 0` cancels, `K_d < kMin` sets pass through, normal path writes every field, undeployed and parking yield return to the right books.
- accounting: `sync` after `injectBadDebt` lowers `credit_i`, `L`, `B` and `navJ` by exactly the loss. fees on: `E_i(t)` falls only by the fee.
- settlement: partial collect, full collect, resolved flag, settle only when all resolved, write off before `T + D_wo` reverts, collect after write off reruns the waterfall and pushes senior first deltas.

**SeriesCore**
- `openSeries`: each check C1 to C6 failing alone, cash moves exactly `S + J`, registry updated.
- `receiveReturn` and `receivePayout`: only from registered series, balance delta must equal the amounts, books credited.
- valuation equals parking plus the sum of series legs, every term rounded down.
- senior capacity and the junior coverage floor at their exact boundaries.
- stress gate opens and closes on both conditions.
- backstop off by default. with it on: shortfall moved from junior idle up to `backstopWad`, and repaid to junior first from later recoveries.
- curator timelock: risk increases need the delay, decreases apply at once. sentinel can only decrease.

**SeniorVault and JuniorVault**
- first depositor inflation attack with the dead deposit and offset in place: attacker profit negative for every donation size up to 1m usdc.
- senior deposit shares never fewer than `previewDeposit`, including when `syncAll` reveals a loss in the same call.
- senior deposit reverts above capacity, while gated, while paused.
- junior deposit request, cancel, fulfillment at the max rule, claim.
- redemption request, cancel while open, close, partial and full fulfillment at the min rule, claims across open epochs.
- junior redemption fulfillment stops at the coverage floor. curator cannot redeem below `curatorMinShareWad`.

### 25.3 fuzz targets

```
F1  random S, J, cov band -> openSeries accepts exactly when C1 to C6 hold
F2  random partial fills across 1 to 4 markets with random prices <= P_max -> r_pool, C_S, A_F identities
F3  random loss vector h_i in [0, 1] and random recovery sequence -> conservation and seniority at every rerun
F4  random order of collect, sync, writeOff, recoveries -> sum pushed to books + fee + series balance == P
F5  onBuy with randomized unnamed uint params, random data, random caller -> only the valid path succeeds
F6  write downs in the same block as finalize (inject loss, then finalize) -> ledger consistent
F7  kMin boundaries: K_d == kMin, kMin - 1
F8  P < fee edge: P tiny, P exactly C_S, P exactly C_S + J_d
F9  parking vault loss while a series is deploying -> returns split by a, no underflow
F10 random interleaving of vault deposits, requests, epoch closes, fulfillments and series payouts -> no value moves between depositors except by price
```

### 25.4 invariant testing (stateful)

handlers:

```
AllocatorHandler      openSeries within and outside policy, cancel, registerOffers, deployTake, finalize
DeployHandler         borrowerTakesBid (a funded borrower takes series bids on the real midnight), noOpTake, warp
MidnightChaosHandler  injectBadDebt, repay, setFees (within caps), warp, oracle moves
SettleHandler         startSettlement, collect, settle, writeOff, claimFee, pruneSeries
VaultHandler          senior deposit, junior requestDeposit, requestRedeem, cancels, transfers, curator actions
EpochHandler          closeEpoch, fulfillEpoch, fulfillDeposits, claims across epochs
AdapterHandler        vault v2 allocate, deallocate, requestExit, forceDeallocate
```

ghost variables: total usdc in, total usdc out per path, total units bought, cumulative proceeds per series, expected payouts computed with the python twin logic re implemented in solidity test helpers.

every invariant of section 26 is asserted after every handler call. run with `fail_on_revert = false` and count reverts per selector so handlers are not trivially reverting (target less than 30 percent per selector).

### 25.5 scenario tests (deterministic, mock and fork)

| id | scenario | expected |
|---|---|---|
| S0 | base: two series 3 weeks apart, both settle clean | senior price grows at the blended senior rate, junior at the blended junior rate net of fee |
| S1 | btc crash with lag: bad debt of 3 percent of face in one series on day 20 | junior price steps down at the next sync, senior unchanged |
| S2 | junior wipe: bad debt of 25 percent of face in one series | that series pays senior `L - B_0` short, senior price drops, stress gate closes |
| S3 | maturity wall: half the borrowers do not repay, overdue auctions clear over 3 days | settles after resolution, no loss if auctions recover |
| S4 | stuck market: write off at T + 7d, repayment 10 days later | recovery flows senior first to the books, senior deposits gated in between |
| S5 | under fill: 30 percent fill above kMin | smaller series, same `a`, undeployed back to the books |
| S6 | micro fill below kMin | pass through payouts pro rata |
| S7 | nothing fills | CANCELED, full cash back |
| S8 | oracle manipulation: mock oracle drops 40 percent for one block | loss realized, junior first, no series code path touched except sync |
| S9 | fees at caps | `F_net < F`, no double count, conservation |
| S10 | parking stress: 2 percent parking loss while deploying | returns split by `a` |
| S11 | redemption demand larger than idle | partial fills over several epochs, pro rata and consistent |
| S12 | redemption queued, loss realized before fulfillment | redeemers priced at the post loss price by the min rule |
| S13 | junior mass redemption | fills stop at the coverage floor, senior capacity shrinks, senior deposits close |
| S14 | vault v2 allocates 10 percent through the adapter, then its depositors withdraw | vault v2 pays from its liquid adapters, the senior slice exits through epochs |

### 25.6 differential tests (solidity vs python)

`/sim/series_math.py` implements admission, premium curve, pricing, nav and waterfall with python integers and the same rounding rules (use `//` for down, `-(-x // d)` for up). a generator writes 2,000 random cases to `/sim/vectors/*.json`. `test/differential` loads them with `vm.readFile` and `vm.parseJson` and asserts exact equality. ci fails on any mismatch.

### 25.7 fork tests

- chain: base (cbBTC / USDC), addresses in section 2.6. pin block numbers in `foundry.toml` profiles. ethereum only once a deployment is confirmed.
- f0: at the pinned block, assert the fork's setter ratifier and mempool bytecode hashes equal the values recorded in `VERIFY_LOG.md`, so a redeployment cannot silently change the assumptions of section 2.2.
- f1: deploy core, vaults and factory. open a series against a real market id and maturity, assert eligibility reads.
- f2: maker path end to end by impersonating a borrower that supplies cbBTC collateral and takes the series bid.
- f3: taker path against a real ask if one exists at the pinned block, else skip with a log line.
- f4: warp to maturity, impersonated borrower repays, collect, settle, payouts land in the books, a senior redemption epoch pays out.
- f5: warp to maturity without repayment, liquidate through the real overdue auction as a keeper, collect, settle.
- f6: replay the local harness scenarios S0 to S4 on the fork and compare series state step by step with the local run.
- f7: a two maturity ladder on a fork: settle the first, roll into the second, both vault prices checked against the python twin.

### 25.8 static analysis and formal checks

- slither and aderyn clean or triaged in ci.
- optional certora rules for waterfall conservation and monotonicity once the code is stable. midnight itself is verified with certora and its repo documents cvl pitfalls (vacuity, unsound preserved blocks). reuse that discipline.

### 25.9 standards compliance (both vaults)

- `supportsInterface` returns exactly the ids of sections 21.1 and 22.1, and false for flows a vault does not implement.
- preview functions of every async flow revert for all callers and inputs.
- no request short circuits the claim, even when claimable in the same block. no function pushes tokens or assets to a user after a request.
- `controller` and `owner` checks: non operators revert, approved operators succeed, `setOperator` emits `OperatorSet` and returns true.
- `requestRedeem` through an erc 20 allowance spends it unless the caller is an operator.
- `requestDeposit` reverts when the full amount cannot be requested.
- the `Deposit` event on claims has the controller as first parameter and the receiver as second.
- erc 7887: a cancel moves the request to claimable, the claim pays exactly the canceled amount, a cancel outside the open epoch reverts.
- `maxDeposit`, `maxMint`, `maxRedeem`, `maxWithdraw` equal the claimable amounts, and 0 when paused or gated.
- run the a16z erc 4626 property tests on the synchronous side of the senior vault, and reuse the openzeppelin erc 7540 reference test patterns.

---

## 26. invariants

| id | invariant | how |
|---|---|---|
| I1 | for each basket market, a series' `lastCredit_i` after `sync(i)` equals the protocol credit of that series | invariant, fork |
| I2 | a series' `B(t)` view equals `F_net(t) - C_S` from live reads | invariant |
| I3 | per series `navS + navJ + feeAccrued == V(t)`, `navJ >= 0`, `navS` falls only when `navJ == 0`, a realized loss `dL` lowers `navJ` by `min(dL, navJ before)` | invariant, unit |
| I4 | at open: `covWad <= a <= aMaxWad` | unit, fuzz |
| I5 | at finalize: `filled_i <= cap_i`, `sum filled_i <= K_alloc`, every fill price `<= P_max_i` | invariant |
| I6 | a series pays usdc only to midnight (fills), the core, and the fee recipient | invariant |
| I7 | series credit increases only in DEPLOYING, `onBuy` succeeds only in DEPLOYING before `tDeployEnd` | invariant |
| I8 | every series' midnight debt and collateral are always 0, and the setter ratifier is the only account it has authorized | invariant, fork |
| I9 | `onBuy` succeeds only with `msg.sender == midnight` and `buyer == series` | fuzz |
| I10 | at every waterfall rerun `XS + XJ + fee == P`, and cumulative pushed deltas equal `XS` and `XJ` | invariant |
| I11 | write off only in SETTLING and only when `block.timestamp >= T + D_wo` | unit |
| I12 | keeper paths (finalize after deadline, sync, startSettlement, collect, settle, writeOff, closeEpoch, fulfillEpoch after delay) succeed without the allocator | invariant (allocator handler disabled run) |
| I13 | `XS == min(C_S, P)` for every cumulative `P` (seniority, including recoveries) | invariant |
| I14 | state transitions follow section 6.1 only, no state re entered | invariant |
| I15 | core usdc balance `==` senior reserved + junior reserved + junior pending deposits (plus bounded dust), and core parking shares `==` senior book shares + junior book shares | invariant |
| I16 | `SeniorVault.totalAssets() == core.seniorAssets()` and `JuniorVault.totalAssets() == core.juniorAssets()` | invariant |
| I17 | core reserved assets `>=` sum of unclaimed fulfilled redemption assets, per vault | invariant |
| I18 | per epoch: `sharesFulfilled <= totalShares`, sum over controllers of claimable plus claimed assets `<= assetsFulfilled` | invariant |
| I19 | redemption fulfillment price `<= ppsCloseWad`, junior deposit fulfillment price `>= ppsCloseWad` | invariant |
| I20 | after any senior deposit, `seniorAssets <= seniorCapacity` | invariant |
| I21 | after any junior redemption fulfillment, vault coverage `>= covVaultMinWad` | invariant |
| I22 | senior deposits revert whenever the stress gate is closed | invariant |
| I23 | the curator holds `>= curatorMinShareWad` of `jrUSDC` after any curator action | invariant |
| I24 | `liveSeries.length <= maxSeries`, `recoveringSeries.length <= maxRecovering`, open epochs per controller `<= maxOpenEpochsPerController` | invariant |
| I25 | with backstop off, a loss in one series never changes the other series' legs | invariant |
| I26 | every storage write emits an event that allows reconstruction (indexer replay test) | scenario |
| I27 | adapter `realAssets` equals the adapter's value in the senior vault | invariant |
| I28 | a no op take (units 0) against any series offer changes no series or core state, in every state | invariant, fuzz |
| I29 | cumulative proceeds `P` equals total usdc withdrawn from midnight plus parking yield on it, and never decreases | invariant |

---

## 27. simulation harness (reduced)

goal: size `cov`, `a`, anchors and `kMin` for btc collateral markets, and check acceptance criteria before a beta series.

### 27.1 data model

```
market i (static): collateral in {cbBTC, WBTC}, lltv_i, gamma_i, oracle heartbeat and deviation,
                   borrower ltv distribution at T - tau, rcf threshold
environment (per path): btc price path (5 minute grid), oracle path (price held between updates),
                        liquidator latency (depends on congestion), dex depth for btc to usdc,
                        repayment behaviour at T (fraction q not repaying)
series and core: all parameters of section 28
```

### 27.2 loss model per market

- price: bootstrap real 5 minute btc returns with drift removed, plus a jump component for crash days.
- liquidation: a position is liquidated when `debt > maxDebt` and a liquidator acts after latency `l`. if collateral value at execution is below debt, the shortfall is bad debt, realized immediately.
- recovery: liquidator receives collateral at `LIF_i = 1 / (1 - gamma_i (1 - lltv_i))` of repaid debt. liquidators act only if `LIF - 1` covers slippage at current depth plus gas.
- maturity: fraction `q_i` does not repay. overdue auction runs 60 minutes with incentive ramping from 1 to `LIF_i`. executes if profitable, else stays open until write off.
- output: `h_i`, the fraction of face lost, per path.

the block analitica midnight study (june 2026) is a useful calibration anchor: flat expected loss up to a cliff near the top of the lltv ladder, and a lower safe lltv for longer maturities. reproduce its weth numbers first as a sanity check, then run btc.

### 27.3 correlation

one btc factor drives both markets, plus a congestion factor. with one collateral family there is no diversification. report the loss distribution of `L / F_net` for a single market basket and for a two market basket (cbBTC and WBTC), low, medium and high congestion.

### 27.4 metrics

```
P(senior impaired)                  target <= 1 percent per series
E[senior loss | impaired]
distribution of junior return, E[junior return], P(junior wiped)
A_F adequacy: P(L / F_net > A_F)
buffer margin at T: B(T) / F_net
days from T to settlement
fill ratio K_d / K_alloc under observed depth
senior and junior vault price paths across a rolling ladder, redemption wait times per epoch
```

### 27.5 acceptance for the first beta ladder

- base scenario, medium congestion: `P(senior impaired) <= 1%`, `P(junior wiped) <= 10%`.
- junior expected return under base `>= 1.5 * r_pool`. note from 9.4: with zero losses the junior multiple is `1 + pi (1 - a) / a`, which is exactly 1.5 at `a = 0.25` with the v1 anchors and below 1.5 for any larger `a`. so this criterion caps `a` at about 0.25 before any loss is counted, which fits the default band `[0.15, 0.30]` only in its lower part. either cap `aMaxWad` at 0.25, lower the criterion, or raise the anchors. section 30, issue 9.
- all invariants green in fuzz and invariant runs.

---

## 28. parameters

| param | default | sim range | notes |
|---|---|---|---|
| `covWad` (COV) | 0.15 | 0.10 to 0.25 | minimum junior share of every series |
| `aMaxWad` | 0.30 | 0.20 to 0.35 | see section 27.5 on the 1.5 multiple |
| `covVaultWad` | 0.20 | 0.15 to 0.30 | senior capacity |
| `covVaultMinWad` | 0.15 | 0.10 to 0.25 | junior redemption floor |
| `pi0 / piT / pi1` | 0.10 / 0.20 / 0.35 | plus or minus 50 percent | |
| `uT` | 0.90 | fixed | |
| `thetaWad` | 0.10 | 0 to 0.20 | |
| series size `S + J` | 250,000 to 1,000,000 | 100,000 to 3,000,000 | sized to current midnight depth, see 2.6 |
| `maxPerSeriesAssets` | 1,000,000 | | |
| `kMinAssets` | 50,000 | 25,000 to 250,000 | below this a series runs pass through |
| `tau` | market maturity minus finalize | 28 to 91 days | |
| `M_max` | 4 | 1 to 4 | markets per series |
| `maxLltvWad` | 0.86 | 0.77 to 0.915 | study shows a loss cliff above about 0.945 for weth at 90 days |
| `minRateFloorWad` | set from observed bids | | annualized, published |
| `D_deploy` | 3 days | 1 to 7 days | |
| `D_wo` | 7 days | 3 to 14 days | |
| `maxSeries` | 12 | 4 to 12 | loop bound |
| `maxRecovering` | 8 | | loop bound |
| `maxPerMaturityWindowWad` | 0.50 | 0.25 to 1.0 | 30 day window |
| `minIdleSeniorWad`, `minIdleJuniorWad` | 0.05 | 0 to 0.20 | |
| `stressJuniorFloorWad` | 0.50 | 0.25 to 0.75 | |
| `backstopEnabled` / `backstopWad` | false / 0.50 | on and off | open decision |
| `epochLength` | 7 days | 1 to 14 days | both vaults |
| `fulfillDelay` | 1 day | 0 to 3 days | |
| `maxOpenEpochsPerController` | 4 | | loop bound |
| `curatorMinShareWad` | 0.10 | 0 to 0.50 | |
| `performanceFeeWad` | 0 | 0 to 0.20 | per vault |
| curator timelock | 3 days | 1 to 7 days | |
| midnight fees | read from protocol | up to caps (50 bps settle ann, 100 bps cont ann) | |
| adapter relative cap (vault v2 side) | 10 percent suggested | | set by the vault v2 curator |

---

## 29. milestones for agents

one sequence, engine first, surface second. a milestone starts only when every milestone it depends on is green.

| id | deliverable | depends on | done when |
|---|---|---|---|
| M0 | pin the midnight commit that matches the base deployment, add it as `lib/midnight`, resolve the open items of section 31 (tree padding, router publishing policy, usdc default fees, vault v2 adapter interface), write `VERIFY_LOG.md` | none | every tag has a source line and a decision, this file updated |
| M1 | `WadMath`, `PremiumCurve`, `SeriesMath` (fee netted nav), `EpochMath`, python twins, vectors | none | unit and differential tests green |
| M2 | `MidnightHarness` over the real midnight, `SeriesFactory` and eligibility, `Series` creation and funding against a stub core, maker path with `onBuy` and the setter ratifier, taker path, cancel, finalize | M0, M1 | series unit tests, F2, F5, F6, F7, F9 green |
| M3 | series accounting, sync, navs, settlement, write off, waterfall reruns with payout deltas | M2 | F3, F4, F8, I1 to I3, I10, I13 green |
| M4 | series invariant suite | M3 | I1 to I14 green at 512 runs, depth 128 |
| M5 | `SeriesCore`: books, `openSeries` checks, returns and payouts, valuation, capacity and coverage floor, stress gate, curator policy with timelock, optional backstop | M4 | core unit tests, I15, I20, I21, I24, I25 green |
| M6 | `SeniorVault` and `EpochQueue` | M5 | vault tests, compliance 25.9, I16 to I19, I22 green |
| M7 | `JuniorVault` | M6 | vault tests, compliance, I23 green |
| M8 | full invariant suite across series, core and vaults, scenarios S0 to S13 | M7 | all of section 26 green, scenarios pass, F10 green |
| M9 | fork tests on base and ethereum | M8 | f1 to f7 green at pinned blocks |
| M10 | `SeniorVaultAdapter` against a forked vault v2 | M9 | I27 green, S14 passes |
| M11 | simulation harness and report, including vault price paths and redemption waits | M1, M8 | acceptance 27.5 evaluated and parameters proposed |
| M12 | audit prep | all | natspec complete, threat model for engine and surface, known issues list, slither triage |

agents must not start M2 before M0 is complete. tree padding decides how `registerOffers` recomputes roots. M10 is the only optional milestone.

---

## 30. issues found in the v1 pdf and how this build resolves them

| # | v1 section | issue | resolution here |
|---|---|---|---|
| 1 | 3.1, 3.2 | basket needs `N >= 8` markets across five collateral classes. midnight today has cbBTC / USDC on base and cbBTC / USDC plus WBTC / USDC on ethereum | basket of 1 to 4 ungated btc markets. concentration is accepted and priced through `cov` |
| 2 | 3.1, 4.3 | depth rule `D_mult = 3` and `K_target = 10m`. ethereum midnight showed about 7.41m of deposits in total | series sized 250k to 1m by default, depth rule moved off chain (7.3) |
| 3 | 6.1 | deployment only by taking offers. lenders take asks, and asks from borrowers are scarce on a new market. the pdf's own diagram says callbacks pull usdc at fill, which is the maker pattern | maker path is the default. the series posts bids and implements `onBuy`. taker path kept as secondary. maker also avoids the settlement fee |
| 4 | 6.2 | "if `K_d < 0.5 (S + J)`: REFUNDED (all)" after units are bought. bought units cannot be refunded | proceed at any `K_d >= kMin`, pass through below, cancel only on `K_d == 0`. undeployed cash returns to the books |
| 5 | 7.1, 9.4 | `B(t) = F(t) - C_S - Phi` and `P = sum recovered - Phi` while midnight already deducts the continuous fee from lender credit. fees counted twice | ledger reads net credit, no `Phi` term |
| 6 | 7.2 | senior nav spreads impairment over time while junior takes it instantly. navs stop summing to the pool | corrected nav in 12.4 |
| 7 | 9.5 | recoveries paid "junior up to its realized loss, then senior". breaks seniority when senior was impaired | cumulative waterfall rerun, senior first always |
| 8 | 4.2, I4 | fifo senior queue with withdrawable junior commitments. a junior withdrawal can push admitted senior above `Cap_S`, violating I4, and fifo with holes needs unbounded loops | moot in v0.3: there is no public subscription. coverage is checked per series at open and per vault through the capacity rule (section 20.4) |
| 9 | 14.7 | "junior expected return under S0 >= 1.5 r_pool" is impossible for `a > 0.25` even with zero losses given the v1 anchors | flagged in 27.5, pick one of: cap target `a` at 0.25, or lower the criterion, or raise `pi` anchors |
| 10 | 8, 9.4 | `X_J = R_J - Fee_op + (R_0 - E)` goes negative when `R_J` is small and `E > R_0` | reserve removed, keepers are unpaid, settlement is cheap |
| 11 | 9.3 | write off conditions ("auction open 24h with no taker", "frozen 72h") are not observable on chain | time based write off only |
| 12 | 3.1 | oracle reviewed by operator. midnight trusts the oracle completely, with no staleness check, bounds or circuit breaker | on chain oracle allowlist per collateral, checked for every accepted collateral of every market |
| 13 | 3.1 | "LLTV <= 0.915, LLTV != 1" checked on collateral actually posted | checked on every accepted collateral, since borrowers can switch |
| 14 | 5.3, 6.1 | `r_pool` from fill prices. on the taker path the settlement fee changes the effective price | effective price per fill is `assets spent / units received`, fee included |
| 15 | 1, 2 | 2 of 3 operator with timelock, kyc, class B grace | ops rule only, kyc and grace dropped |
| 16 | 7.2 | the junior nav formula ignores the operator fee, so the mark ends above the junior payout | junior mark is net of accrued fee, marks converge exactly to the waterfall at T (section 12.4) |
| 17 | 10 | roll module moves each holder's payout into the next series through opt ins and a gap in parking | the roll is the product: payouts land in the books and the allocator funds the next series (section 24.1) |
| 18 | none | any layer that prices entries or exits off navs is exposed to stale marks and to jumps while requests wait | sync before every price, min rule for redemptions, max rule for junior deposits, stress gate for senior deposits (section 24.2) |
| 19 | v0.2 of this file | two public surfaces: per series tranche tokens and ladder vault tokens, both called senior and junior | one surface: `srUSDC` and `jrUSDC` only. series are internal sleeves held by the core (v0.3) |
| 20 | 4.3 | anchor sponsor committing at least 50 percent of each series' junior | the junior vault is the whole junior of every series. the curator holds a minimum share of `jrUSDC` |
| 21 | none | with one surface, the allocator sets the junior share of every series and therefore the premium between the two vaults | curator fixed band `[covWad, aMaxWad]` behind a timelock, premium anchors set by the curator, not the allocator |
| 22 | v0.3 of this file | a custom `SeriesRatifier`. midnight's hosted api and router only index offers whose ratifier is on their allowlist, so custom ratified bids would be invisible to borrowers | use the shipped `SetterRatifier`, the route midnight documents for contract makers. state and deadline guards move into `onBuy`, offer expiry and on chain checks in `registerOffers` |
| 23 | v0.3 of this file | "the series never grants a midnight authorization". midnight requires the maker to authorize its ratifier, and any authorized account can act on the maker's whole position | exactly one authorization, to the setter ratifier, by the series itself. the allocator is never authorized. roots are set by the series on the allocator's instruction |
| 24 | v0.3 of this file | lazy fill reconciliation because units were thought unknown in the callback | `onBuy` receives `units` and `buyerPendingFeeIncrease`, so fills are recorded inside the callback |
| 25 | midnight natspec | midnight can call an offer's callback through a no op take, even on a fully consumed offer | `onBuy` returns success without touching state when units and assets are 0, invariant I28 |
| 26 | v0.3 of this file | collect only after maturity. midnight lets any lender withdraw as soon as `withdrawable > 0`, first come first served | collect from finalize onward. the ledger counts collected cash in `F_net(t)` so early collection is never read as a loss |
| 27 | v0.3 of this file | a separate `futureFee` estimate | midnight crystallizes the full future fee into `pendingFee` at entry, so face is `credit - pendingFee` with no estimate |
| 28 | setter ratifier bytecode | the ratifier proves only that an offer is in a ratified root, so an allocator could hide an unsafe leaf in a root it asks the series to ratify | `registerOffers` recomputes the full tree on chain and checks every leaf whose maker is the series. leaves naming other makers are harmless because the ratifier looks up the offer's own maker |
| 29 | v0.4 of this file | a `Series.publish` function in case the mempool required the maker as sender | the mempool is a `Log` contract with no sender check. publishing is done by the allocator's own account |

---

## 31. open questions to close in M0

resolved from the midnight source and the verified base deployments (kept here so nobody re opens them): the `onBuy` signature passes units and the crystallized fee, `take` is sized in units, credit with the latest loss factor comes from `updatePositionView`, projected face is `credit - pendingFee`, `withdraw` works before maturity against shared `withdrawable`, group budgets are enforced on chain, units have the loan token's decimals, post maturity liquidation ramps over 3600 seconds, the `Offer` and `Market` field order, the setter ratifier's permissions and leaf hashing, the mempool has no sender check, and the base addresses.

still open:

1. sdk tree padding to a power of two, so `registerOffers` recomputes exactly the root the sdk builds. close it with a differential test.
2. whether the hosted router's mempool policy accepts payloads published by an account other than the maker (the chain does not care, the api might). close it by running `mempoolValidate` against a test payload with the series as maker.
3. the ethereum deployment, if ethereum is ever chosen.
4. the default settlement and continuous fees currently set for usdc on base (read `defaultSettlementFeeCbp` and `defaultContinuousFee` on a fork).
5. the exact morpho vault v2 adapter interface (allocate, deallocate, realAssets, ids), the force deallocate penalty cap, and whether an adapter may revert on deallocate beyond its liquidity.
6. current status of erc 7887 (7540 is final and requires 7575, 7887 is a draft). if 7887 changes before audit, only the cancel functions of the two vaults change.
7. whether routers and aggregators on base support erc 7540 claim flows, which decides how much claim automation the ui must do itself.

product decisions, not protocol facts, to close before M5:

10. cross series backstop on or off (section 20.8). on means `jrUSDC` holders are first loss for the whole senior book.
11. `aMaxWad` versus the junior acceptance criterion (section 27.5).
12. launch chain: base (older cbBTC market, cheaper keepers) or ethereum (two markets).
13. whether to add an optional dated wrapper later, so an institution can hold senior exposure to one maturity without the rolling book.
14. legal characterisation of `srUSDC` and `jrUSDC` in the target jurisdiction. a launch gate, not a design question.

---

## 32. references

- midnight whitepaper, may 2026: https://morpho.org/whitepapers/midnight-whitepaper.pdf
- midnight code: https://github.com/morpho-org/midnight (interfaces, libraries, ratifiers and periphery are gpl 2.0 or later, core is busl 1.1)
- midnight core contract (take, onBuy, withdraw, updatePositionView, liquidate, fees): https://github.com/morpho-org/midnight/blob/main/src/Midnight.sol
- base deployments: setter ratifier https://basescan.org/address/0x800B5F12A61B8198a5a6EfD794Cac6699B294d63 , mempool https://basescan.org/address/0xdD6DCE32e21f7b020898a8258dA37355b4017993 , addresses page https://docs.morpho.org/developers/contracts/addresses/
- morpho sdk, midnight toolkit (offers, groups, trees, SetterRatifier and EcrecoverRatifier routes, custom ratifier limits, tick math, protocol constants): https://docs.morpho.org/developers/sdks/morpho-sdk/midnight/
- midnight docs, concepts: https://docs.morpho.org/learn/concepts/midnight/
- midnight docs, market mechanics (units, loss factor, pending fee): https://docs.morpho.org/developers/midnight/concepts/market-mechanics/
- midnight docs, collateral, health, liquidations: https://docs.morpho.org/developers/midnight/concepts/collateral-health-liquidations/
- midnight docs, callbacks (onBuy, BlueBuyCallback): https://docs.morpho.org/developers/midnight/concepts/callbacks/
- launch post: https://morpho.org/blog/now-live-morpho-midnight
- block analitica, parameter study for midnight: https://blockanalitica.substack.com/p/a-guide-for-setting-on-chain-parameters
- royco dawn docs (coverage, utilization, three anchor yield curve with 90 percent kink, co investment beta 1): https://royco.gitbook.io/royco-dawn
- royco dawn audit notes (division by zero on nav scaling, deposit rules during impermanent loss): https://hexens.io/audit-reports/royco-perpetual-risk-tranching-protocol-jan-2026
- strata tranches (two erc4626 tranche vaults, senior target gain, junior residual): https://docs.strata.markets/technical-documentation/protocol-overview
- idle perpetual yield tranches, `IdleCDO.sol` (virtual price vs stored price divergence found in audit, precision loss favoring one tranche): https://github.com/Idle-Labs/idle-tranches and https://diligence.consensys.io/audits/2021/06/idle-finance/
- 3jane suppliers (usd3 senior, susd3 first loss erc4626, lock period, morpho blue based core): https://docs.3jane.xyz/architecture/core-money-market/suppliers
- erc 7540 asynchronous erc 4626 tokenized vaults (final): https://eips.ethereum.org/EIPS/eip-7540
- erc 7575 multi asset erc 4626 vaults (external share token, `share()`): https://eips.ethereum.org/EIPS/eip-7575
- erc 7887 cancelation for erc 7540 vaults (draft): https://eips.ethereum.org/EIPS/eip-7887
- openzeppelin erc 7540 implementation (admin, delay and sync strategies): https://docs.openzeppelin.com/community-contracts/erc7540
- morpho vault v2 (adapters, realAssets, forceDeallocate, roles): https://github.com/morpho-org/vault-v2 and https://docs.morpho.org/learn/concepts/vault-v2/

### 32.1 lessons borrowed from each reference

| source | lesson applied |
|---|---|
| morpho blue MathLib | one mulDiv helper per rounding direction, round against the user, no inline division |
| midnight | measure balance and credit deltas instead of trusting return values, callbacks check caller and buyer, events must reconstruct state |
| royco dawn | utilization defined as `cov / a`, flat below target and steep above, coverage checked before accepting senior. their audit found a division by zero when a tranche nav reaches zero, so every denominator here (`K_alloc`, `J_d`, `S_d`, `F_net`, `tau`, vault supplies) has an explicit zero guard |
| strata | one orchestrator plus two vault tokens, senior as a target gain and junior as the exact residual, which is what makes conservation exact |
| idle | one engine behind two tranche tokens. one pure function computes prices for both the view and the state write, so view and storage can never diverge. rounding favors a named party, stated up front |
| 3jane | first loss capital with a lock is what makes senior safe in practice. mirrored by the junior vault's epochs and the curator's minimum share |
| erc 7540 and centrifuge style vaults | aggregated request ids per controller where requests are fungible, epoch ids where fills are pro rata, previews revert on async flows |
| morpho vault v2 | curator, allocator and sentinel split, timelocked risk increases, immediate risk decreases, adapters report value through one function |
