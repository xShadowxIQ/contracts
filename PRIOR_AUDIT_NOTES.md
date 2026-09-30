# Priors audit — static analysis notes

Target: `priors-agents/priors`, bounty in `BOUNTY.md`. Pool holds **$3,440**.
Critical $3,000 / High $1,000 / Medium $250 / Low unpaid. One award per root cause.

## Environment note
This sandbox has wiped `/tmp` and `~/.foundry` three times mid-session. Clone into
the workspace, not `/tmp`. `CreditPoolV2` needs via-IR (per-file restriction in
`foundry.toml`), so every `forge test` recompiles ~30 files (~85 s) — run one
suite at a time and reuse the cache.

## Scope (from BOUNTY.md)
`CreditPoolV2` + `PoolV2Lib`, `CreditLensV2`, `TreasurySponsorV4`, `SeatVaultV3`,
`SeatVaultV4`, both `SeatSizer`s, `InviteBond`, `StockVault` (+ its implementation,
the one upgradeable contract), plus SDK/packages/CLIs/facilitator. Out: v3 sizer,
MCP, API, bot.

## Known findings already claimed (docs/SECURITY-v2.md)
IDs: P-1..P-16, P-1271, P-712, R2-1..R2-3, SV-1..SV-14, SZ-1..SZ-7, IB-1/2,
X-1..X-5, T1..T18, O-1..O-3, S-1, L-1, V-1/V-2, F-6, GHSA refs. ~40 rows, each with
a test. Do not re-report any of these.

## Static review completed — surfaces checked and why they are sound

### CreditPoolV2 `_slash()` — REFUTED as a finding
Critical accounting path: burns a backer's shares on default, tops up from
`reserve` so share price cannot fall.
```
burn = ceil((p+f) * ts / ta);   ta = poolLiquidity + totalPrincipalOut
if (burn > held) { burn = held; need = (p*ts - held*ta)/ts; gap = min(need, reserve); ... }
```
Proved `burn > held` is unreachable beyond rounding, and even with the reserve
fully drained (`withdrawReserve(reserve)`, then 8 defaults) `totalBadDebt` stays 0
and share price holds. The fee lock at borrow time establishes
`backing >= delegatedOut + feeLocked` at vouch; share price is monotone
non-decreasing across all eight mutating paths; the floor in `convertToAssets`
cancels the round-up in `burn`. Matches the source's own comment. **Not a finding.**

Empirically (8 tests, `test/PoolBackingStress.t.sol`, since deleted by the wipe):
many defaults under one root, ten sequential defaults with re-vouching, reserve
drained before defaults, partially drawn line, freeze-then-default, handoff refused
while a loan is open, dead-agent residual, reserve movement. All held
`totalBadDebt == 0`, price never fell, `delegatedOut == sum(delegatedIn)`,
cash >= `poolLiquidity + reserve + unclaimedSponsorFees`.

### `SeatVaultV4.settle()` / `StockVault.settle()` proof-of-default — REFUTED
The Critical definition is "stock taken other than by a default of its own
position's loan", and `settle(id, loanId)` is permissionless. Guard:
```
if (l.sponsorId == agentId && l.issuedAt >= p.openedAt) seize = true;
else tokens go back to the depositor
```
Traced the reachability requirement (sponsorship ending forces `activeLoans == 0`;
only one loan can default per agent; a defaulted agent can never re-seat or change
sponsor) and the `issuedAt < openedAt` guard blocks an old defaulted loan from
seizing a fresh position. Sound.

### `SeatVaultV4` protocol-seat accounting — REFUTED
Traced every `protocolTokens` write (4 sites) and `tokensHeld` (5 sites).
Invariant `locked = tokensHeld + protocolTokens` is preserved across open, clean
close, settle-with-keep, writeOff and reclaim. `rescue` cannot reach a staker's
tokens or the protocol stake. A protocol seat's own slash is burnt in full
(`kept = 0`), so defaults shrink the stake and never refill it.

### StockVault `_payout` / `held` pro-rata under an issuer burn — REFUTED
SV-4/SV-13/SV-14 already cover this and the code now refuses a deposit during a
shortfall (`_pull`: `if (before < held[token]) revert Shortfall`), and both
`canBorrow` and `borrowRoom` value what `_payout` would pay, not `p.amount`.
The pro-rata arithmetic checks out in `_end` and `_send`.

### Epoch-budget refunds (StockVault `_end`, SeatVaultV4 `_end`) — REFUTED
A refund only fires when the seat was charged to the epoch still running
(`!_epochOver() && openedAt >= epochStart`). Verified the epoch can't be
double-refunded: `status` flips to Closed/Settled on the first `_end`, and a
refund is gated on `p.closing`/`refund`, which the freeze path passes as `false`.

### TreasurySponsorV4 — REFUTED
`InviteBond` is **not referenced by any contract** — it is bot-side gating only, so
a bug there is not an on-chain fund path. `raise()` requires
`delegatedIn >= secondLine` to be false, `_score(a) >= minScore`, seasoning,
`childrenDefaulted == 0`, not frozen, not defaulted, owner not marked;
`firstLine` needs an inviter's EIP-712 invite **plus** the agent owner's pool
consent. `firstLined` is written and never read (dead variable, Informational at
most). `reclaim` requires idle >= `idleAfter` with no loan open.

### SeatSizer median-vs-recent-cluster — REFUTED (7 tests, deleted by the wipe)
Modelled the ring: a 10 %-frequency outlier cannot move the median, observations
older than `MAX_AGE` drop out entirely, the recent cluster wins over a stale one,
exactly `MIN_OBS` is usable and one fewer refuses. X-3 already covers the
"moving price" rule.

### Slither-equivalent checks
No third-party audit has touched v2 (stated in AGENTS.md). Ran their own
invariant suites instead — see below.

## Still open / not yet finished
- `SeatVaultV3` and `SeatVaultV2` (983 + ~600 LoC) — **not yet read in this pass.**
  V3 is the live seat vault with real TVL and the one `SeatSizer` targets.
- `InviteBond` internal logic (`deposit` / `release` / `_releasable`, the
  `qualifiedAt` snapshot and the `importFromV1` raise) — only partially read.
- `CreditLensV2`, `ScoreLib` weight edge cases — skimmed, not audited.
- `TreasurySponsorV4` lines 120–330 (`firstLine`, `leave`, `handoff`, reserve) —
  skimmed.
- The x402 SDK / facilitator path — the bounty explicitly pays for user-money
  losses there even when the contracts are sound. Unaudited.

## Bottom line so far
No reportable bug found. The pool accounting is genuinely well built — the
invariant suite (7 properties, 2x fuzz runs) plus 40+ documented findings plus an
external audit on v1 suggests the obvious paths are harvested. The remaining
value is in the **newest** code (`StockVault`, live 2026-09-28, upgraded
2026-09-30 for SV-13/14; `SeatVaultV4`, live 2026-09-29) and in
`SeatVaultV3`, which is live and holds real TVL.
