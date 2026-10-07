# PANIC test coverage

Run `forge build` and `forge test`. Dependencies are already vendored; these tests require
no RPC, environment variables, FFI, or additional installations. Local verification can keep
generated artifacts inside scratch with `--out test/scratch/out --cache-path test/scratch/cache`.

The existing integration suites cover exact 5%, 15%, and 30% boundaries, the sell that crosses
from flat to 20% down, buy fees based on pre-swap prices, same-block reference isolation,
one-hour recovery, the 30% fee cap, claims, donations, and buyback routing and failure paths.
They deploy the actual vendored Uniswap v4 PoolManager and mine the production hook address.
This is offline integration coverage, not a rehearsal against a live chain deployment.

`PanicHook.Invariant.t.sol` adds three campaigns: native pairing, PANIC as currency0, and PANIC
as currency1. Each runs 256 sequences of 64 randomly ordered actions, with unexpected reverts
treated as failures. Three funded traders buy with exact input or exact output, sell, transfer PANIC, advance blocks/time, and
call the permissionless fee outlets. Inputs include zero outlet budgets and one-wei trades.
The deterministic handler tests exercise funded operations, rejection paths, and both buy modes
before and after a full reference window. Exact-output amounts include one wei and are bounded by
the current virtual PANIC reserve so the campaigns continue to execute meaningful trades.

The handler derives taxes from actual wallet movements and the PoolManager's swap event,
then maintains an independent allocation ledger. The invariant checks claims against all
three buckets, lifetime fee conservation including buyback fees, the fixed claim recipient,
delivery of every bought token to the dead address, fixed token supply, and settled manager
deltas. Every successful buyback must also satisfy the 98% reference output floor, including
tiny budgets. Its independent quote squares the reference price and divides once, without calling
the hook's quote helper. Failed buybacks must preserve LP fee growth as well as balances and buckets.
A separate spot-price timeline is integrated over one hour to check the reference;
it never reads the hook's observation array. Full-range liquidity is kept in these campaigns;
deferred donations and zero-liquidity failure/recovery are exercised by the existing bucket suite.

`PanicMonkeys.Properties.t.sol` adds a separate token campaign over transfers, approval
replacement/revocation, and delegated transfers. An independent balance/allowance ledger checks
successful calls and rollback after expected failures, including self-transfers, full balances,
zero amounts, and unlimited approvals. Its finite-allowance rollback property runs 1,000 cases.
The bucket split fuzz test now performs real swaps rather than asserting an arithmetic identity.

`PanicHook.Atomicity.t.sol` checks rejection and recovery with native currency and both ERC-20
orderings. Partial fee-bearing exact-input buys, unsupported exact-output sells, zero swaps, and
overpriced buybacks must roll back wallet balances, pool price, LP fee growth, claims, and oracle
observations. Successful operations immediately afterward check that a failed callback cannot
poison the next swap's transient fee context or consume the block's observation. A native-recipient
probe attempts to reenter both claim and buyback during payout; neither can withdraw a second
bucket, and a later legitimate buyback remains usable.

The historical double-truncation issue is fixed in the supplied implementation. The existing
`PanicHook.PriceMath.t.sol` regression and the restored invariant output-floor check guard it.
Sell splitting is explicitly accepted; there are no anti-splitting comparisons. The fixed Oracle
Fund recipient remains covered by constructor and payout tests. No production contracts,
deployment files, or build/dependency configuration are changed by these test additions.
