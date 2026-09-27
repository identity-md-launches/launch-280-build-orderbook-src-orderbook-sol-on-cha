# Local adversarial review

Scope: `src/OrderBook.sol`, its vendored arithmetic, tests, and constructor/integration assumptions. Review date: 2026-09-27. This was a separate review pass by the implementation contributor, not an external independent security audit. The invariant model is independent of the production data structure and arithmetic implementation; its authorship is not independent. No deployment or funded wallet was involved.

## Accounting argument

For each token, liabilities are claimable balances plus remaining escrow of open orders. Sell escrow is remaining base; buy escrow is remaining quote. Successful exact deposits add equal assets and liabilities. Each fill moves liabilities between escrow and claims, with no asset transfer. Cancellation and automatic release move escrow into the same owner's claims. A withdrawal zeros the claim before transfer; if transfer fails, the transaction restores it. Donations increase assets without creating claims.

For an initial buy quantity `B`, limit `L`, filled quantities `f_i`, and execution prices `p_i <= L`, spent quote is `sum(floor(f_i * p_i / 1e18))`. This cannot exceed `sum(f_i * L / 1e18)`. Subtracting it from `ceil(B * L / 1e18)` leaves an integer at least `ceil(remainingBase * L / 1e18)`. Thus subsequent fills at the limit remain funded, even after prior price improvement or multiple rounded fills. Only the eventual close refunds the excess.

Every fill uses the minimum of two quantities each at least `minBaseAmount`. Its maker price is at least `tickSize`. The constructor's mathematical product constraint therefore makes the floored payment at least one raw quote unit. Both maker dust and incoming dust must stop participating. Full-precision `mulDiv` handles products wider than 256 bits; unrepresentable quote escrow reverts before deposit. Normal Solidity checked arithmetic protects all balances and ID increments.

## Attack paths and evidence

| Attempt | Expected behavior and local evidence |
| --- | --- |
| Cancel another maker's order, repeat cancel, or cancel unknown/filled IDs | `NotMaker` / `NotOpen`; behavioral tests and randomized valid/invalid cancellations. |
| Overdraw or steal someone else's credits | Caller-indexed withdrawals only; model compares every actor's wallet and credit, and failed withdrawal retry is tested. |
| Reenter place/cancel/withdraw from a token | All three share one guard, set before deposit/transfer and reset afterward. Callback tests attempt all three during both deposit and withdrawal and inspect `ReentrantCall`. |
| Token returns false, returns nothing, reverts, or delivers a different amount | False/revert calls roll back; empty returns work; short and excess deposits revert with no consumed ID or token loss. Both deposit sides are tested. |
| Change trade priority | Independent linear-scan model selects price then oldest ID and compares each `Filled` event; deterministic tests cross multiple levels in both directions and preserve partially filled head priority. |
| Exceed fill budget or leave a crossed book | Both-side 33-maker cases check exactly 32 fills and refund crossing remainder; uncrossed cap remainder may rest. Invariant checks no crossed book after every action. |
| Exploit rounding or zero-payment dust | Minimum-price maker/taker dust tests, split-fill buy refunds, self-trades, and wide-product arithmetic tests; model checks every predicted quote amount and positive payment. |
| Corrupt FIFO or price-list links | Queue head/middle/tail removal, middle-level insertion/removal, level reuse, exact forward/back links, sorted prices, strictly increasing FIFO IDs, no cycles, deleted absent levels, and unique open-order coverage are checked. |
| Make insertion scan without bound | Both sides exercise 64 successful level steps and a reverted 65th step, including rollback of deposit and ID. Existing deep levels remain usable. |
| Strand ordinary escrow | Every invariant campaign finishes by cancelling all open orders and withdrawing all actors' credits; only deliberate donations may remain. |

No reproducible unresolved violation of the specified behavior was found in this local review. This is a statement about the checked scope, not a guarantee of security.

## Recorded validation

Using Foundry 1.8.3 and the pinned Solidity 0.8.26 compiler:

- `forge build`: passed. Non-failing lint diagnostics about token calls/events and the bounded-loop revert are discussed below.
- `env -i PATH=/usr/local/bin:/usr/bin:/bin forge test`: passed with the surrounding environment cleared except executable search paths; 27 tests, zero failures or skips. Tests use Foundry's default parallel runner.
- The final invariant campaign completed 128 sequences and 12,288 actions with zero unexpected reverts: 3,037 placements, 3,130 cancellation attempts, 3,075 withdrawals, and 3,046 donations. Per-action invariants and final cancellation/withdrawal checks passed.
- `forge fmt --check`: passed after formatting the project.
- Vendored source/license checksums matched the provenance record.

These are local check results, not independent certification.

## Reviewed implementation choices

- Releases with untraded quantity use `Cancelled`, emit `OrderCancelled`, and zero balances. An exactly completed order uses `Filled`. This includes partially executed IOC orders and dust releases.
- Matching stops when incoming dust is below the minimum. Otherwise the constructor's product check alone would not guarantee positive quote payment on a later fill.
- A 64-level walk counts better existing levels passed, not the ordinal position of the new node. There can be more than 64 total levels.
- Caller authorization precedes the closed-status check. Unknown IDs have no maker and cannot be cancelled.
- The token adapter accepts zero-length or true return data. Malformed return data reverts, possibly through ABI decoding; no particular custom error is promised for malformed data.
- Foundry's reentrancy/event lint heuristics flag external token calls and later events despite the shared guard. Manual review and callbacks cover those paths. The revert inside the insertion loop is the intentional gas bound.

## Limits and responsibilities

Stateful fuzzing uses four actors, forty possible prices, bounded quantities, honest 18-decimal tokens, and direct donations. Token failures, callbacks, wide arithmetic, and the 32/64 boundaries have separate targeted tests. Finite fuzz campaigns do not exhaust all sequences, all uint256 inputs, gas schedules, chain behavior, or adversarial ERC-20 implementations. The model shares the written specification with the contract, so specification misunderstandings remain possible.

Deposit balance checks detect inexact incoming transfers, not dishonest balance reporting or later changes to token economics. Outgoing taxes, rebases, token issuer freezes, upgrades, or malicious tokens remain unsupported. A token can consume arbitrary gas inside its calls; the algorithmic bounds apply to book traversal, not arbitrary external token code. Read-only callbacks can observe transient state, so views should not be treated as an oracle by a hooked token integration.

Permissionless order and level spam, transaction ordering/MEV, price selection, and the inability to insert beyond the walk budget are economic/operational constraints. The contract makes no fair-price or liquidity promise. Direct token donations and forced ETH are unrecoverable because no sweep/admin mechanism exists.

Before any future release involving other people's funds, obtain an adversarial review by a separate contributor or auditor, verify the actual token pair and deployment parameters, and evaluate liquidity/spam economics on the intended chain. That release work is outside this local assignment.
