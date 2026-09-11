# M0 verification log

Checked 2026-09-11 against `lib/midnight` pinned at commit `70607569ac348e9880b512ffd3b574be55405932` (2026-09-10), Base mainnet (chain id 8453, RPC `https://mainnet.base.org`), and the periphery reference contracts shipped in the Midnight repo itself. Where the build spec (`docs/SERIES_BUILD_SPEC.md`) made a claim, it is checked against source and/or live chain state below. Any mismatch is called out explicitly rather than silently accepted.

## pinned dependency

| item | value |
|---|---|
| repo | `github.com/morpho-org/midnight` |
| commit | `70607569ac348e9880b512ffd3b574be55405932` |
| commit date | 2026-09-10 15:23:16 +0200 |
| solc | `0.8.34` (matches spec) |
| evm_version | `osaka` (matches spec, repo's own `foundry.toml` confirms) |
| optimizer_runs | `466` (matches spec section 2.6) |

## section 2.1 — markets, units, positions

| claim | verified against | result |
|---|---|---|
| `Market` struct field order: `chainId, midnight, loanToken, collateralParams[], maturity, rcfThreshold, enterGate, liquidatorGate` | `src/interfaces/IMidnight.sol:5-14` | **match** |
| `CollateralParams { token, lltv, liquidationCursor, oracle }` | `src/interfaces/IMidnight.sol:16-20` | **match** |
| `Position { credit, pendingFee, lastLossFactor, lastAccrual, debt, collateralBitmap, collateral[] }` | `src/interfaces/IMidnight.sol:59-67` | **match**, all `uint128` except `collateral` array of 128 |
| lazy market creation via `touchMarket`, existence via `tickSpacing > 0` | `MarketState.tickSpacing: uint8` field present in `IMidnight.sol:56` | consistent, not independently re-derived line by line |

## section 2.2 — offers, ratification, callbacks

| claim | verified against | result |
|---|---|---|
| `take(Offer, bytes, uint256, address, address, address, bytes) returns (uint256, uint256)` | `IMidnight.sol:161` | **match** |
| `Offer` field order: `market, buy, maker, start, expiry, tick, group, callback, callbackData, receiverIfMakerIsSeller, ratifier, reduceOnly, maxUnits, maxAssets, continuousFeeCap` | `IMidnight.sol:23-39` | **match** |
| `SetterRatifier`: one storage write (`isRootRatified[maker][root]`), one external call (`STATICCALL` to `isAuthorized`), no `CALL`/`DELEGATECALL`/`SELFDESTRUCT` | `src/ratifiers/SetterRatifier.sol` (full source read) | **match**, confirmed by direct source read, not just bytecode inspection |
| `setIsRootRatified` accepts the maker itself or an account the maker authorized on Midnight | `SetterRatifier.sol:28`: `require(maker == msg.sender \|\| IMidnight(MIDNIGHT).isAuthorized(maker, msg.sender), ...)` | **match** |
| leaf hashing scheme and typehash values (`COLLATERAL_PARAMS_TYPEHASH`, `MARKET_TYPEHASH`, `OFFER_TYPEHASH`) | `src/ratifiers/libraries/HashLib.sol` | **match, exact**. `hashCollateralParams`, `hashMarket` (uses `abi.encodePacked` of child hashes via inline assembly, equivalent to spec's description), `hashOffer` all reproduce the spec's pseudocode byte for byte. All three typehash constants match the spec's stated prefixes. |
| Merkle proof walk uses `leafIndex` bits, bit 0 = left | `HashLib.sol` `isLeaf()`: `(leafIndex >> i) & 1 == 0 ? hashNode(currentHash, proof[i]) : hashNode(proof[i], currentHash)` | **match** |
| mempool `Log` contract: payable fallback, emits `Data(bytes)`, no sender check, reverts above 1,000,000 bytes | `src/periphery/log/Log.sol` (full source read) | **match, exact** |
| **`onBuy` callback signature** | `src/interfaces/ICallbacks.sol:9`: `function onBuy(bytes32 id, Market memory market, uint256 buyerAssets, uint256 units, uint256 pendingFeeIncrease, address buyer, bytes memory data) external returns (bytes32)` | **MISMATCH** — see finding below |

### finding: `onBuy`'s `pendingFeeIncrease` is `uint256`, not `uint128`

Spec section 10.4 step 4 gives `Series.onBuy`'s signature as:
```
function onBuy(bytes32 id, Market memory market, uint256 buyerAssets, uint256 units,
               uint128 pendingFeeIncrease, address buyer, bytes memory data) external returns (bytes32)
```
The actual `IBuyCallback` interface (`src/interfaces/ICallbacks.sol:9`) and the reference `BlueBuyCallback.onBuy` implementation (`src/periphery/blue-buy-callback/BlueBuyCallback.sol:80-88`) both declare it `uint256 pendingFeeIncrease`. Solidity computes function selectors from the canonical ABI type name, so a `Series.onBuy` declared with `uint128` in that slot would have a **different selector** than the one Midnight actually calls — the callback would never be invoked as intended (Midnight would call the four-byte selector for the `uint256` variant, which wouldn't match our function, causing every take against our offers to revert `NoCode`/similar rather than fill). This must be fixed to `uint256` in the implementation; flagging rather than silently fixing since it's a correction to the spec's own code listing, not an ambiguity.

*Storage* can still pack `pendingFeeIncrease` as `uint128` internally after receiving it as `uint256` and validating it fits — Midnight's own `Position.pendingFee` is `uint128`, so the crystallized fee is bounded — but the callback's external signature must match Midnight's call exactly.

## section 2.3–2.4 — health, liquidation, fees

| claim | verified against | result |
|---|---|---|
| `TIME_TO_MAX_LIF = 3600` seconds | `src/libraries/ConstantsLib.sol:19`: `uint256 constant TIME_TO_MAX_LIF = 60 minutes` | **match** |
| `MAX_CONTINUOUS_FEE = 317097919` | `ConstantsLib.sol:18`: `uint32(uint256(0.01e18) / uint256(365 days))` = 10,000,000,000,000,000 / 31,536,000 = 317,097,919 (integer division) | **match, recomputed exactly** |
| settlement fee breakpoints at 0/1/7/30/90/180/360 days, capped 50bps at 360 days | `ConstantsLib.sol:11-17`: `MAX_SETTLEMENT_FEE_360_DAYS = 0.005e18` (=0.5%=50bps), 7 breakpoint constants present | **match** |
| `MAX_TICK = 6744` | `src/libraries/TickLib.sol:6` | **match** |

## section 2.5 — withdrawals

| claim | verified against | result |
|---|---|---|
| `withdraw(Market, uint256 units, address onBehalf, address receiver)`, not maturity-gated, checks `marketState.withdrawable` | `IMidnight.sol:162`, `withdrawable(bytes32) view returns (uint128)` at `IMidnight.sol:186` | **match** |

## section 2.6 — live deployment (Base, chain id 8453)

All queried live via `cast call` against `https://mainnet.base.org` on 2026-09-11.

| contract | address | result |
|---|---|---|
| Midnight | `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A` | has code (~24.5kb runtime) |
| SetterRatifier | `0x800B5F12A61B8198a5a6EfD794Cac6699B294d63` | has code (~2.7kb); `SetterRatifier.MIDNIGHT()` returns exactly `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A` — **cross-verified against the Midnight address independently**, not just trusted from the address table |
| Mempool (`Log`) | `0xdD6DCE32e21f7b020898a8258dA37355b4017993` | has minimal code (~120 bytes), consistent with the trivial `Log` bytecode |
| EcrecoverRatifier, EcrecoverAuthorizer | (spec addresses) | not independently re-verified this pass (not on the critical path — build uses `SetterRatifier` only, per spec section 10.3) |

### finding: default USDC fees on Base are currently zero

`defaultSettlementFeeCbp(USDC, i)` for `i` in `0..6` and `defaultContinuousFee(USDC)` both returned `0` when queried live (`Midnight.defaultSettlementFeeCbp(address,uint256)` / `defaultContinuousFee(address)`, `USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`). This **resolves open item 4** from section 31: as of 2026-09-11, series opened on Base pay zero settlement fee and zero continuous fee by default. This can change at any time (the fee setter can update it), so `MidnightReader` must read it live rather than hardcode it, and simulation/test fixtures that want to exercise the fee-netting logic (section 25.1, "caps in fee scenarios") must explicitly set non-zero fees rather than relying on defaults.

## section 31 open items — resolution status

| # | item | status |
|---|---|---|
| 1 | SDK tree padding to a power of two | **partially resolved**. The `EcrecoverRatifier`'s EIP-712 test fixture (`test/frontend/sign-root.ts`) shows the tree is a **complete binary tree of exactly `2^height` leaves**, built as literal nested arrays (e.g. height 2 → `[[o1,o2],[o3,o4]]`), not a dynamic list padded with zero-hashes or duplicated leaves. Unused leaf slots must hold real (but harmless) `Offer` structs — consistent with the spec's own note that a leaf naming another maker is harmless. `HashLib.isLeaf`'s proof-walking algorithm (leaf-index-bit-directed) is agnostic to how the tree was built, so this constraint is specifically about `registerOffers` recomputing the *same* root the off-chain SDK computes. I do not have the actual `@morpho-org/midnight-sdk` npm package source in this pass — recommend a differential test against real SDK output (build a small tree with the SDK, diff against Solidity recomputation) before finalizing `registerOffers`, per the spec's own suggestion in section 10.4 step 2. |
| 2 | hosted router mempool sender policy | **not resolved this pass** — requires calling the SDK's `mempoolValidate` or the live hosted API, out of scope for a source/chain-only verification pass. |
| 3 | ethereum deployment | **moot** — user decided Base-only launch. |
| 4 | default USDC fees on Base | **resolved**, see finding above: both zero as of 2026-09-11. |
| 5 | Morpho Vault V2 adapter interface | **not resolved this pass** — deferred to M10 per the spec's own milestone ordering (`SeniorVaultAdapter` is optional, M10 depends on M9). Not blocking M0-M1. |
| 6 | ERC-7887 draft status | **not resolved this pass** — needs a check against eips.ethereum.org at implementation time (M6/M7), not a Midnight-source concern. |
| 7 | router/aggregator ERC-7540 support on Base | **not resolved this pass** — a UI/integration question, not blocking the engine or surface contracts. |

## additional finding: reusable reference implementation

`src/periphery/blue-buy-callback/BlueBuyCallback.sol` is Morpho's own shipped example of a Midnight buy-offer callback (parks funds in a Morpho Blue market between offer registration and fill). Its `onBuy` guard pattern is a direct precedent for `Series.onBuy`:
```solidity
require(msg.sender == MIDNIGHT, NotMidnight());
require(buyer == OWNER, NotOwnerBuyer());
```
— exactly the checks the spec's own section 10.4 pseudocode calls for (`require msg.sender == midnight`, `require buyer == address(this)`). It also confirms the exact-amount-approve pattern (`safeApprove(market.loanToken, MIDNIGHT, buyerAssets)`, not infinite approval) and shows that a no-op take (zero `buyerAssets`) can be handled by simply guarding the state-changing branch (`if (buyerAssets > 0) withdraw(...)`) while still returning `CALLBACK_SUCCESS` unconditionally — consistent with invariant I28.

## conclusion

Every `[VERIFY]`-tagged fact in section 2 that could be checked against source and/or live Base state is confirmed, with one material correction (`onBuy`'s `pendingFeeIncrease` parameter must be typed `uint256` in the actual implementation, not `uint128` as written in the spec's section 10.4 listing — this will be applied when `Series.sol` is written in M2, and is called out here rather than silently patched into the spec). Open items 2, 5, 6, 7 remain genuinely open and are not blocking M1 (pure math, no Midnight dependency) or M2 (which needs items 1 resolved further via SDK differential testing, tracked above).
