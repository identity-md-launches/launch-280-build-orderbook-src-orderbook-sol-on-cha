# Independent test review of OrderBook

Scope: `src/OrderBook.sol`, its local arithmetic dependency, and the existing and added Foundry tests. This review changes only tests and this report. It uses local deployments with two mock ERC-20s whose decimals are 18; it performs no network deployment.

## Findings

No reproducible unresolved violation of the requested behavior was found in this review. No implementation behavior believed to be defective is asserted as correct. This conclusion is limited to the inputs and properties described below.

## New independent checks

`test/invariant/OrderBookSolvencyInvariant.t.sol` adds a separate handler and observer. It neither inherits the existing matching model nor reproduces the contract's matching algorithm. Ghost state records only submitted order identity/parameters and the expected external deposits and withdrawals. The observer reads all returned order IDs and traverses the public level/queue views independently.

Five actors place buys and sells, both IOC and resting, over nine adjacent tick prices. Tick size is `3e16` and minimum base is `34`, exercising a valid non-exact minimum-product boundary (`34 * 3e16 > 1e18`). Quantities from 34 to 306 raw base units create partial fills, dust and rounded quote payments. All actors have sufficient initial funding; no donation or mint action is exposed to the invariant runner.

After every handler action the suite checks:

- Base assets equal all open sell remainders plus every actor's claimable base, exactly.
- Quote assets equal all open buy escrows plus every actor's claimable quote, exactly.
- Actor wallets equal initial funding minus recorded deposits plus actual checked withdrawals. Book assets also equal net cash received.
- Bids have enough quote for their remaining quantity, no sub-minimum order rests, and no IOC order is open.
- Every open order is reachable exactly once from the appropriate best price; closed orders have no remaining escrow or links.
- Price lists are sorted and acyclic, every linked level has a non-empty FIFO queue, predecessor links and tails agree, order IDs increase within each queue, and absent levels have cleared metadata.
- Best prices agree with an independent scan of open orders, and `bestBid < bestAsk` if both exist.
- Matching makes no outgoing token transfers. Every outgoing transfer is accounted for by a successful nonzero withdrawal.

Each withdrawal compares the token wallet increase and book balance decrease to the caller's claim immediately before the call, checks the returned amount and cleared claim, then retries and requires zero payment without another token transfer. End-of-sequence cleanup cancels every open order and withdraws every actor's two claims, requiring an empty book with zero assets.

## Failure-path checks

Random sequences include unknown-ID, non-maker and closed-order cancellation attempts with exact expected errors. A fourth action attempts zero prices, off-tick prices, below-minimum quantities, fee/bonus deposits, false-return/reverting token deposits, missing allowance, and unsupported-token withdrawals. Rejected operations must leave an identical fingerprint of order fields, links, levels, claims, balances, supplies, allowances and token transfer counters after the test token's mode/allowance is restored. Unexpected reverts fail the invariant campaign.

`testRejectedActionsPreserveLiveBookAndCredits` deterministically attempts every rejection on both sides while a partially filled ask, a non-crossing bid and claimable balances exist. It then tests successful and repeated withdrawals, non-maker cancellation, valid cancellation, repeated cancellation, filled-order cancellation and an unknown ID. This guarantees coverage of those branches independently of randomized action selection.

## Existing coverage retained

The original array-scanning specification model remains useful as a separate oracle for exact maker selection, maker prices, floor/ceiling rounding, individual credits and statuses. Its donation campaign is retained separately; donations are excluded from the new campaign so its asset/liability assertions use the exact equations required by the assignment.

The existing deterministic/fuzz tests cover complete entry fills, multi-level matching in both directions, FIFO after partial fills, 33 makers with a 32-fill cap, released versus resting cap remainders, empty/partial IOC, maker and taker dust, unused buy escrow, self-trades, queue and level removal/reuse, constructor validation, reentrancy, token failures, wide-product arithmetic, events and the insertion walk boundary. The latter permits walking 64 better existing levels and rejects a required 65th step; it also checks deposit/ID rollback and appending to an existing deep level.

Both invariant entry points set **256 runs and depth 100** through inline `forge-config` comments. Only explicit handler action selectors are targeted. The original configuration, implementation and vendored dependencies are unchanged.

## Review rationale and limits

Deposits add equal assets and escrow. Matching moves escrow into claims without transferring tokens. Cancellation and releases convert the remaining escrow to the maker's claim. Withdrawal clears the caller's claim before the external token call; a failed call reverts the entire operation. All three state-changing entry points share a reentrancy guard. The code unlinks exhausted/dust makers and checks whether a remainder still crosses before allowing it to rest.

The suite assumes honest, stable ERC-20 balances and exact normal transfers. Deliberate fee, bonus and failed-deposit modes test rejection rather than support for those tokens. Rebasing, dishonest balance reporting, arbitrary outgoing transfer taxes, gas-exhausting tokens, external transaction ordering and all possible uint256 sequences are outside this finite local campaign. The new nine-price campaign cannot reach the 64-level walk bound or reliably generate 33 simultaneous makers; the retained explicit boundary tests supply that coverage. Queue order alone does not prove execution priority; the retained independent fill-event model checks execution priority and per-account settlement.

## Validation

Validated locally with Foundry 1.8.3 and Solidity 0.8.26:

- `forge build`: passed. Existing non-fatal lint warnings concern token calls/events guarded by the shared lock and the intentional bounded-walk revert.
- `forge test`: **29 passed, 0 failed, 0 skipped** across three suites.
- Each invariant completed **256 runs, 25,600 actions, zero unexpected handler reverts** (51,200 actions total), confirming that the inline depth/run settings took effect.
- The new campaign exercised 6,463 placements, 6,350 cancellation attempts, 6,245 withdrawal actions and 6,542 rejected-input/token actions, plus end-of-run cleanup.
- `git diff --check`: passed. All submitted changes are under `test/`; no dependency installation was needed.

These results are local evidence, not exhaustive verification or a security guarantee.
