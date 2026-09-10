# morrow-finance

dated senior and junior credit tranches on Morpho Midnight.

morrow issues closed-end series, one per maturity date. a series pools USDC, buys fixed-term credit across a basket of at least eight Midnight markets that all mature on that date, and splits the claim into two tranches. the senior tranche, token srS-T, is a fixed claim paid first and held by allow-listed addresses only. the junior tranche, token jrS-T, takes the first loss and the residual and is open to anyone. capital enters during a subscription window and leaves only at settlement. every parameter is frozen at deployment, every transition is governed by rule, and nothing depends on an operator or keeper showing up.

## tranches and roles

senior earns a fixed rate set at deployment, with a published attachment point, and is paid first at settlement. transfers are allow-list to allow-list.

junior absorbs losses first and in full and receives everything above the senior claim less a fee on profit. it also funds a small reserve on top of its principal. a designated sponsor must hold at least half of junior, locked until settlement, and serves as the named liquidator on gated OTC markets in the basket. the sponsor is a role within junior, not a separate class, and holds the same claim per token as every other junior holder.

the operator is a bounded multisig role. it selects the basket and executes deployment and settlement steps inside deadlines, and it has no discretion over whether a series proceeds, refunds or writes off.

## how a series runs

during the open window junior commits freely and senior commits are admitted only up to the capacity the committed junior supports. commitments earn yield in the parking vault and can be withdrawn until close. at close the proceed rules are checked on-chain. if they pass the series deploys, if they fail everyone is refunded, and nobody decides this. in deployment the operator buys credit units in each market up to its weight at a limit price snapshotted at close. short fills shrink the series pro rata and a fill below the minimum refunds everyone. final terms are written on-chain and frozen. during the lock nothing enters or leaves, and write-downs are read from the protocol and reflected in the ledger in the same block. at maturity markets repay or liquidate, unresolved debt is written off by rule at a fixed deadline, recoveries pay senior first and junior second, holders redeem, and opted-in balances roll into the next series.

## architecture

a series is a core state machine plus two ERC-7540 asynchronous vaults, one per tranche, over a shared accountant. subscriptions are deposit requests fulfilled at finalisation and redemptions are redeem requests fulfilled when the settlement flag is set. both tranches expose their claim in face terms during the lock, never a mark. cancellation follows ERC-7887, delegated claiming uses the standard operator role, and senior access control is enforced as vault gates. the parking vault, a Morpho Vault V2, and Midnight itself are external dependencies.

execution is on-chain only. takes are executed by the series directly against Midnight offers, with no off-chain matching, quoting or relay. the operator acts through transactions inside deadlines and every deadline has a permissionless fallback.

## settlement facilitation

fulfilment is rule-based, never admin-based. requests become claimable when the series reaches the corresponding state, at the rate the accountant writes, with no manual fulfil step. closing, finalising after the deployment window, liquidating after grace, writing off after the deadline, setting the settlement flag and executing opted-in rolls are callable by anyone once their conditions hold. gated OTC markets carry a capped sponsor grace period, after which any address can liquidate through the series. write-off assigns unrecovered face to a recovery ledger, and later recoveries flow to junior, then senior, then junior per the settlement snapshot. no senior redemption is possible before the settlement flag, for anyone, and cancel and refund paths never touch the operator.

## build

foundry end to end. forge build and forge test cover unit tests per module and a stateful invariant suite for the state machine under test/invariants. scenario replays against a Midnight fork live under test/scenarios and need a fork rpc url.

## status
pre-beta. open before the first series: coverage per series or per market, recovery token or snapshot claim, class B grace as a sponsor or operator right, and the legal characterisation of srS-T.

software, not an offer. senior tokens are restricted to allow-listed addresses.

pre-beta. open before the first series: coverage per series or per market, recovery token or snapshot claim, class B grace as a sponsor or operator right, and the legal characterisation of srS-T.

software, not an offer. senior tokens are restricted to allow-listed addresses.
