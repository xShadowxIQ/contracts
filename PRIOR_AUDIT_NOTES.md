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

---

## CONFIRMED FINDING (2026-09-30) — @priors/x402 redirect guard

**`packages/x402/src/payer.mjs:174`** — `asRequest`:
```js
const asRequest = (input, init) => new Request(input, { redirect: "manual", ...(init || {}) });
```
Spread AFTER the default, so `init.redirect === undefined` overwrites "manual"; `new Request`
then applies the platform default "follow". The signed PAYMENT-SIGNATURE header follows a 302.

- Affected: `resend()` / `payer.resend()`. **Not** `pay()` (passes no init), **not** MCP pay_url
  (`server.mjs:403` sets `redirect: "manual"` explicitly).
- Sibling `sdk/float.mjs:201` was fixed for exactly this in commit `32e0e8d`
  (`{...init, redirect: init.redirect ?? "manual"}`); the fix did not reach the package copy.
- CI: run 36790461475 (green) — unit PoC + end-to-end PoC, both against upstream `32e0e8d`.
  E2E proves the header ARRIVES INTACT at a second origin.
- Severity: Medium (CVSS 4.6). Possible P-3 duplicate; caller-side trigger.
- PoC files: `.github/poc/x402-redirect-guard.mjs`, `.github/poc/x402-redirect-e2e.mjs`.
- Advisory draft: `priors-x402-redirect-advisory.md`.
- NOTE: this bot has NO push access to xShadowxIQ/priors (403). PoCs live in the contracts repo.

## Refuted since (static)

- **`isPrivateAddress` (packages/mcp/src/server.mjs)** — SSRF guard, P-3's fix. Probed 10 cases:
  over-long IPv6 literals, ::ffff: mapped, NAT64, 6to4, Teredo, unspecified, garbage. All refuse.
  `v6Bytes`'s `Array(8 - h.length - tl.length)` CAN go negative, but `isIP()` gates first and
  returns non-6 for malformed input, so `v6Bytes` is unreachable on it. **Sound.**
- **`guardedFetch` redirect forwarding** (`redirect: r.redirect`) — r.redirect is always set by the
  MCP's own `{method, redirect:"manual"}`. **Sound.**
- **`dollarsToUnits` / `numberToPlain` (packages/x402/src/merchant.mjs)** — traced trailing-zero
  strip, sub-unit refusal, float rounding, large values. All correct. **Sound.**
- **`priorsFacilitator` URL guard** — uses exact hostname equality, not suffix, so
  `localhost.evil.com` is rejected. **Sound.**
- **Redirect audit, all four call sites** — payer.mjs:174 is the ONLY unfixed one.

## Refuted since (round 2 — static, no PoC written)

- **Pinned-address guard `resolveV2` (sdk/env.mjs:331)** — GHSA-xw44's fix. Checked the gap I
  suspected: `addresses[k] !== undefined && pinned[k] !== undefined && differs` SKIPS keys the
  published file lacks. But `deployments/4663.v2.json` publishes all 10 guard keys, and the 10
  are a SUPERSET of everything `PriorsV2` consumes (pool, treasuryV4, seatVault, seatVaultV4,
  usdg, priors, registry, stockVault) plus what the CLIs read (chainId, deployBlock, pool,
  seatVaultV4, stockVault — the last three pinned). **No gap. Sound.**
- **`isPrivateAddress` (packages/mcp/src/server.mjs)** — probed 10 IPv6 cases incl. over-long
  literals; `isIP()` gates before `v6Bytes`, so `Array(negative)` is unreachable. All refuse.
- **`dollarsToUnits` / `numberToPlain` (merchant.mjs)** — traced trailing-zero strip, sub-unit
  refusal, float rounding, large values. Correct.
- **`parseInvite` (sdk/priors.mjs)** — validates embedded agentId against the argument; the
  digest binds agentId+expiry anyway. Sound.
- **Consent struct order** — Solidity `Consent`, SDK `consentTuple`, and SDK EIP-712 `CONSENT_TYPES`
  all agree on (agentId, sponsorId, owner, maxPremiumBps, nonce, deadline). No mis-encoded call.
- **`fenced()` prompt-injection fence (server.mjs)** — fresh `randomBytes(8)` id per call, so the
  merchant cannot close its own fence; FENCE_RE strips attacker-supplied markers. Sound.
- **`ScoreLib` score inflation** — `importFromV1` caps `dollarSecondsRepaid` at
  `MAX_IMPORT_AMOUNT * MAX_PERIOD` = 1e15*MAX_PERIOD; `timePts` hard-caps at 400 and `countPts` at
  200 regardless, so no import path inflates the score beyond its own caps.
- **`ReserveFunder.sol` — OUT OF SCOPE** (not in SECURITY.md's scope table). Do not report here.

## Refuted since (round 3 — static)

- **V3 vs V4 seat vaults, shared functions diffed.** Only the intended V4 features differ
  (protocol seats, keepBps split, `maxLoanTerm`). V3 HAS `TermsChanged` (offer-terms staleness) and
  X-1's `OwnerChanged`. `_epochOver()` missing in V3's refund is harmless (stale `linedThisEpoch`
  is not consulted once the epoch is over). **No V4 fix missing from the live V3.**
- **`toUnits` divergence (millionfold).** env.mjs `toUnits` treats a bigint as WHOLE DOLLARS;
  priors-v2.mjs `toUnits` treats it as RAW UNITS; `toAtomicUsdg` (x402 pkg) also raw units.
  Divergent BY DESIGN (v1 SDK = dollars, v2 = units). Traced every import:
  `bin/priors-v2.mjs` imports `toUnits` from priors-v2.mjs and only `resolveV2` from env.mjs;
  `bin/priors.mjs` (v1) imports from env.mjs. **No cross-import. No millionfold bug.**
- **`serial()` money-tool queue (server.mjs:184)** — uses ONE shared `moneyQueue` closure var, so
  `pay_url`, `borrow` and `repay` are mutually exclusive. No balance race between them.
- **Secret scrubbing (server.mjs:241/366/367)** — `redact()` applied in BOTH `text()` and
  `failure()`; line 381 wraps every tool call in one of them (`try{return text(...)}catch{return
  failure(explain(e))}`). Re-thrown pay_url errors and the per-loan repay catch both re-enter
  through 381. **No unredacted output path.**
- **`checkTarget` (server.mjs:197)** — https-only, exact-host local opt-in, resolves and checks every
  address, and `guardedFetch` re-checks at connect time for rebinding. Sound.

## Refuted since (round 4 — static)

- **v2 SDK call encoding.** Extracted all 16 `sendChecked` write calls and compared argument order to
  the contract signatures: deposit/withdraw/enrollRoot/addStake/repay/claimSponsorFees/vouchWithConsent/
  firstLine/accept/open/addCollateral/close. **All match. No mis-encoded call.**
- **`PriorsV2.borrow` fee cap** — defaults `maxFee` to a fresh `quoteFee` at execution time and passes
  it as the pool's `maxFee`, so a fee move reverts rather than overpaying. Sound.
- **`bin/priors-v2.mjs` amount handling** — `toUnits` from priors-v2 (validated), `days` finite/positive
  checked, and it REFUSES a private key passed on argv (line 204). Sound.
- **`setHook` / `applyHook` (CreditPoolV2)** — `setHook` is `_onlyOwnerOf` and rejects h == pool/usdg/
  registry/no-code; with an open line it queues behind `HOOK_DELAY`. `applyHook` is permissionless but
  only installs what the owner queued. **No hijack, no stale-eta install.**
- **SCOPE (full table re-read).** In scope: CreditPoolV2+PoolV2Lib, CreditLensV2, TreasurySponsorV4,
  SeatVaultV3, SeatVaultV4, SeatSizer, InviteBond, StockVault+Proxy, sdk/, bin/, packages/x402,
  packages/mcp, the live v2 deployment, priors.trade + facilitator + mcp.priors.trade + api.priors.trade
  (source NOT in repo), Telegram bot (no payout). OUT of scope: ReserveFunder, TDEDisbursement,
  BatchCaller, CCADisbursementTracker, CreditPool v1, Priors v1.

## Remaining in-scope surface (untriaged)
- `sdk/x402-income.mjs` (436 lines) — score/income from payments. Display only unless something
  money-moving consumes it (not yet checked).
- `sdk/priors.mjs` + `bin/priors.mjs` (v1) — in scope via `sdk/`/`bin/`, but drive the PAUSED v1 pool.
- Services whose source is not in this repo (facilitator, priors.trade, api) — unauditable from here.

## Live-deployment verification (scripts/verify_live_bytecode.py, verify_stockvault_impl.py)

Bounty scope includes "The live v2 deployment" and lists as a priority "differences between
implementation and documented behavior". Read the live code on Robinhood Chain (4663) and
compared it with the locally compiled src/.

- **StockVault is behind StockVaultProxy (upgradeable).** The proxy at
  `0xbEcd07EC689988e16b870C121756C4c2C8cb02B6` is only ~1 KB (correct for a proxy); a naive
  source-vs-chain byte compare is meaningless there. Resolved EIP-1967 implementation slot
  instead: implementation runtime = 23,912 B metadata-stripped, EXACTLY the local
  src/StockVault.sol length.
- **StockVault implementation == src/StockVault.sol.** 614 of 23,912 bytes differ (2.5%), and
  every differing region is a constructor-set immutable holding a deployed address, with the
  local artifact holding zeros: USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, pool
  `0x281210097f0de7A8FB6F87310AF0f089c9C8DE21`, registry `0x8004a169fb4a3325136eb29fa0ceb6d2e539a432`.
  No logic difference. **The upgradeable contract users interact with is the audited source.**
- All other in-scope contracts differ from local only in the same way (2-6%, address-shaped
  immutables patched at deploy: pool, usdg, registry). Deployed solc = **0.8.26**, matching
  `foundry.toml` (`solc_version = "0.8.26"`); deployed CreditPoolV2 runtime = 24,083 B.
- Pool is live: 3,245,884,919 shares / 3,456,054,383 assets, 757,220,000 principal out, 199,296,047 reserve.

So "live deployment differs from source" is NOT a finding here. Good negative result.

## Refuted since (round 5 — static)

- **`resolveV2` address-pin guard, ATTACK SIMULATED.** Suspected the GHSA-xw44 fix had a hole:
  `fromDotEnv` records which vars came from a `.env` so an opt-in set in a `.env` cannot bypass
  the pin. Ran the guard's exact expression with a `.env` supplying BOTH `PRIORS_ADDRESSES` and
  `PRIOR_ALLOW_CUSTOM_ADDRESSES=1`: `optIn = false` (because `fromDotEnv.has(...)` is true), so the
  guard stays ACTIVE and differing pool/usdg/registry are REFUSED. **The .env opt-in is correctly
  ignored.** Sound.
- **`setHook`/`applyHook`** — verified: `_onlyOwnerOf`, rejects h==pool/usdg/registry/no-code,
  queues behind HOOK_DELAY when a line is open; `applyHook` is permissionless but only installs
  what the OWNER queued. No hijack, no stale-eta install.
- **`pause`/`unpause`** — onlyGuardian (owner or guardian), sets `pausedUntil = now + MAX_PAUSE`
  (14 d, bounded), `renounceOwnership` reverts. Exits (withdraw/unlock/repay/markDefault/
  claimSponsorFees) carry no `whenNotPaused`, so funds are never trapped. Sound.
- **All 16 v2 SDK write calls** vs contract signatures — argument order matches everywhere.
- **`vouchWithConsent` consent validation** — checks `c.agentId/sponsorId/owner==_ownerOf(agentId)`,
  nonce, `maxPremiumBps<=MAX_PREMIUM_BPS`, `validSig` over the full EIP-712 digest, deadline, and
  `premiumBps<=c.maxPremiumBps`. Premium path (`quoteFee`/`_splitFee`) can't underflow (sponsorCut+
  reserveCut <= base since sponsorFeeBps+protocolFeeBps<=10000). Sound.
- **`importFromV1`** — permissionless but one-shot per agent (`importedFromV1` flag), bounded by
  MAX_IMPORT_COUNT/MAX_IMPORT_AMOUNT; raises `qualifiedRepaid`/`dollarSecondsRepaid` but both feed
  ScoreLib which hard-caps (200/400). Can only ever lower a score (childrenDefaulted/recourseHonored
  also carry over). Sound.
- **SeatVaultV4 protocol seats + slash split** — hand-verified the three-way
  tokensHeld/protocolTokens/kept algebra across clean close, settle-with-keep, writeOff, reclaim,
  freeze. `locked = tokensHeld + protocolTokens` invariant holds on every path; `rescue` cannot
  reach staker tokens or the protocol stake; a protocol seat's own slash is burnt in full (kept=0)
  so a default shrinks the stake and never refills it. Sound.
- **SeatVaultV4 `maxLoanTerm` + `canBorrow` extra gates** — `term > maxTerm` blocks long loans
  (finding 8); protocol seats check `protocolSeatsOpen` + `protocolEligibleOwner[id]==owner`;
  `owner != s.owner` binds the loan to the vetted owner (L-1/R2-2). Sound.
- **`float.mjs` double-payment** — `pay()` has NO `unsettled` map (unlike payer.mjs). Calling
  `pay()` twice for one purchase signs twice. BUT the docstring explicitly instructs callers to
  `resend()` and "never call pay() again for the same purchase" — documented caller
  responsibility, and payQueues serialises per-wallet borrows so no double-BORROW. Working as
  documented; Low at best, not worth reporting.
- **Live-deployment parity** — the live v2 code matches src/ (see prior entry). Not a finding.
- **`dollarsToUnits` / `numberToPlain`** — trailing-zero strip, sub-unit refusal, large/float
  inputs all correct; a >1e21 float throws (safety), not a money bug.

## CONFIRMED finding strengthened (still unfixed upstream)

- `32e0e8d` IS upstream `main` HEAD (verified `git log 32e0e8d..upstream/main` is empty). The
  vulnerable `asRequest` line is STILL on upstream main. **Finding is live and unfixed.**
- `npm pack ./packages/x402 --dry-run` shows `src/payer.mjs` (21.8 kB) ships in the published
  tarball (package.json `files` includes `src`). So the vulnerable code is what npm consumers of
  `@priors/x402` actually install — not just repo source.
- Pinned upstream commit for the report: `32e0e8dfadfc7c5fcb8d99c2d30e061d7d8a84ea`.
