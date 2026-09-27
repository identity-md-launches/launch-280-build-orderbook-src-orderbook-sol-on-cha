# OrderBook

A fully escrowed limit-order book for one ERC-20 base token and one ERC-20 quote token. Orders match by best price and then FIFO at each price, with partial fills, maker-only cancellation, and pull withdrawals. There is no owner, fee, pause, upgrade mechanism, oracle, or ETH interface.

This is a local implementation and test project. No deployment or transaction submission is included.

## Build and check

Foundry and Solidity **0.8.26** are required. The compiler version, Cancun EVM target, and optimizer settings are pinned in `foundry.toml`. With that compiler installed, all project dependencies are ordinary local files; building and testing require no network. No FFI, filesystem cheatcodes, environment variables, or submodules are used.

```sh
forge build
forge test
forge fmt --check
```

`test/OrderBook.t.sol` covers behavioral boundaries and hostile token responses using two 18-decimal mock tokens. `test/invariant/OrderBookInvariant.t.sol` uses four actors and an independent array-based reference model. Each campaign checks predicted trades, all orders and wallets, liabilities, list integrity, FIFO queues, dust, and an uncrossed book after random placements, cancellations, withdrawals, and donations. Every campaign ends by cancelling and withdrawing all liabilities. Defaults: 256 runs per fuzz test, and 128 invariant campaigns of 96 actions.

The only production dependency is the vendored OpenZeppelin v5.0.2 `Math.sol`, used for full-precision multiplication and division. Provenance, checksum, and MIT license are in `lib/openzeppelin-contracts/`.

## Parameters and units

Constructor: `OrderBook(address base, address quote, uint256 tickSize, uint256 minBaseAmount)`.

| Parameter | Meaning and requirements |
| --- | --- |
| `base` | Nonzero base-token address, distinct from `quote`. |
| `quote` | Nonzero quote-token address. |
| `tickSize` | Positive raw quote units per `1e18` raw base units. Every price must be a positive multiple. |
| `minBaseAmount` | Minimum raw base quantity for new orders and every fill. Positive, with mathematical product `minBaseAmount * tickSize >= 1e18`. |

All four parameters are immutable. The constructor checks the product requirement without overflowing. It does not check token code, decimals, upgradeability, or issuer behavior; these are integration responsibilities. This project's supported deployment configuration assumes two conventional 18-decimal tokens.

For example, `tickSize = 1e16` and `minBaseAmount = 1e15` represent a price increment of 0.01 quote tokens per base token and a minimum order of 0.001 base tokens. A price of `2e18` means two quote tokens per base token. The tests deliberately use a much smaller minimum (`100` raw base units at the same tick) to exercise the one-quote-unit boundary.

## User interface

1. Approve base tokens for sells or quote tokens for buys.
2. Call `place(isBuy, price, baseAmount, immediateOrCancel)`. IDs start at one and include immediately closed orders. Reverts consume neither an ID nor tokens.
3. Call `cancel(id)` to release an open order's escrow. The caller must be its maker. Authorization is checked before status: a different caller or unknown ID gets `NotMaker`; the maker of a closed order gets `NotOpen`.
4. Call `withdraw(base)` and/or `withdraw(quote)` to receive each token's entire claimable balance. Zero credit is a no-op. Unsupported token addresses revert.

Sells deposit exactly `baseAmount`. Buys deposit `ceil(baseAmount * limitPrice / 1e18)`. Deposits compare the contract's balances before and after the transfer and reject any delta other than the requested amount. Tokens returning `false` or reverting fail atomically; tokens returning no data are supported.

Each fill pays `floor(fillBase * makerPrice / 1e18)`. Buyers receive base credit and sellers receive quote credit. No token transfer occurs during matching. Price improvement and rounding can leave excess quote escrow; it stays with an open buy and is credited when the buy is filled, cancelled, or released. Credits are not automatically reused for new orders. Self-trades use identical settlement rules.

Matching visits at most **32 resting orders**. A remaining quantity rests only if it is at least `minBaseAmount`, is no longer crossing, and is not IOC. Otherwise it is credited immediately for withdrawal. A maker's subminimum remainder is also released. An incoming remainder below the minimum stops matching immediately: allowing it to continue would permit a fill worth zero quote units even with the constructor constraint.

An IOC order never rests. A market-style order is an IOC with a deliberately chosen far price limit, still subject to the 32-fill cap and a sufficiently funded buy escrow. A far buy limit can require much more escrow than the eventual cost. Clients must inspect the result and choose whether to submit another order; execution of the entire quantity is not guaranteed.

## State and traversal

`order(id)` returns `(maker, isBuy, price, remainingBase, remainingQuote, status)`:

| Status | Meaning |
| --- | --- |
| `Open` (0) | Resting, with at least the minimum quantity. |
| `Filled` (1) | The whole original base quantity traded. |
| `Cancelled` (2) | Some quantity was released, whether manually, due to IOC, due to dust, or due to a still-crossing remainder at the fill cap. |

Closed orders retain maker, side, and price, but have zero remaining balances and queue links. Unknown IDs return zero fields; ignore their default enum value unless `maker != address(0)`.

`bestBid()` and `bestAsk()` return zero on an empty side. `nextLevel(isBuy, price)` traverses toward worse prices and returns zero at the end or for an absent level. `level(isBuy, price)` exposes `(prev, next, head, tail)`; `orderLinks(id)` exposes FIFO `(prev, next)` order IDs. Read a consistent block when indexing multiple views.

New levels walk from the best price past at most **64 better levels**. Walking past 64 is allowed; needing to pass a 65th reverts `TooDeep`, rolling back the deposit. This is not a total-level cap: inserting better prices can grow a longer list, and appending to an existing level needs no level walk. Cancellation and empty-level removal are constant work.

`OrderPlaced` precedes its fills. `Filled` includes maker ID, incoming ID, maker price, base quantity, and quote payment. `OrderCancelled` is emitted for both manual and automatic releases. `Withdrawn` records actual successful withdrawal calls with nonzero credit. Original amount minus recorded fills gives the released quantity for a cancelled order.

## Operational responsibilities

Before any separately authorized deployment, select and verify the token pair, units, tick/minimum economics, chain support for Cancun bytecode, and immutable constructor arguments. There is no deployment script reading implicit wallet or environment configuration. The deployment parameters can be supplied directly to the constructor and are exercised directly by the local tests.

Use honest, stable-balance tokens with exact transfers. Rebasing, transfer taxation, deceptive `balanceOf`, arbitrary upgrades, or issuer freezes can invalidate assumptions or prevent withdrawal. Incoming balance checks do not certify outgoing token behavior or future token upgrades. A failed withdrawal preserves the caller's credit for retry; no administrator can repair a permanently frozen or broken token.

Users manage approvals, private keys, cancellation, and withdrawals. Operators/indexers monitor transactions and chain finality, reconstruct released amounts from events, and display actual fills rather than assuming complete execution. Public transaction ordering permits front-running and other MEV; time priority means on-chain insertion order. There is no fair-price oracle or guaranteed liquidity. Fine ticks and small minimums make level/order spam cheaper; choose these parameters accordingly. The walk cap can prevent insertion at deep prices.

Do not send tokens directly: unsolicited balances create no claims and cannot be swept. Ordinary ETH transfers are rejected; forcibly delivered ETH cannot be recovered. No external funds were used in this assignment.

See [the security review](docs/REVIEW.md) for reasoning, checked attack paths, limitations, and the distinction between an independent test model and an independent external audit.
