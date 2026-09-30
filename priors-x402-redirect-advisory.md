# Security Advisory — `@priors/x402` follows redirects with a signed payment header when `init.redirect` is `undefined`

| | |
|---|---|
| **Package** | `@priors/x402` |
| **Affected versions** | 0.2.3 (current release); the defect is present in `main` at `32e0e8d` |
| **Vulnerable file** | `packages/x402/src/payer.mjs`, line 174 (`asRequest`) |
| **Severity** | **Medium** |
| **CVSS 3.1** | 4.6 — `AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:N/A:N` |
| **Reported** | 2026-09-30 |
| **Credit** | as you prefer — tell me the name or handle |

---

## Summary

`asRequest()` builds every request the payer signs with `{ redirect: "manual", ...(init || {}) }`. The object
spread comes **after** the default, so a caller-supplied `init` that *mentions* `redirect` but leaves it
`undefined` overwrites `"manual"` with `undefined`. The `Request` constructor then applies the platform default,
`"follow"`. A `PAYMENT-SIGNATURE` header — a live EIP-3009 authorization — is subsequently sent to whatever host
a 302 names, inside its `validBefore` window.

The file's own comment states the intended invariant: *"A redirect is never followed by default: a signed payment
header must not travel to a host the caller did not name."* That invariant does not hold in this case.

## Details

`packages/x402/src/payer.mjs:174`

```js
// A redirect is never followed by default: a signed payment header must not travel to a host the caller did not
// name, and a 3xx is handed back as the answer (its Location is the caller's to judge).
const asRequest = (input, init) => new Request(input, { redirect: "manual", ...(init || {}) });
```

`{ redirect: "manual", ...{ redirect: undefined } }` is `{ redirect: undefined }` — JavaScript object spread
copies keys whose value is `undefined`, so the key is present and the default is gone.

The language and runtime behaviour, isolated (Node v22):

```js
new Request(u, { redirect: "manual", ...{ redirect: undefined } }).redirect
// => "follow"
new Request(u, {}).redirect
// => "follow"
```

## This was already fixed in the sibling copy, one commit earlier

`sdk/float.mjs` carries the same request loop and the same signed-header comment. Commit `32e0e8d` fixed this
exact defect there — its own message reads *"float keeps redirect `manual` for `redirect: undefined`"*:

```diff
- return { redirect: "manual", ...init, ...(signals...) };
+ return { ...init, redirect: init.redirect ?? "manual", ...(signals...) };
```

The fix moved the default **after** the spread and coalesced with `??`. It did not reach
`packages/x402/src/payer.mjs`, so the two copies now disagree.

I read this as one loop written twice and corrected once, rather than a new discovery — which is also why I
have rated it Medium rather than higher, and why I would not object if you treat it as a P-3 residual.

## Reproduction

Against unmodified upstream, commit `32e0e8dfadfc7c5fcb8d99c2d30e061d7d8a84ea`:

```
git clone https://github.com/priors-agents/priors.git && cd priors
git checkout 32e0e8dfadfc7c5fcb8d99c2d30e061d7d8a84ea
npm install
node scripts/test-x402-redirect-guard.mjs
```

Output:

```
@priors/x402 redirect guard
  ok   init with no `redirect` key:        redirect="manual" (expected "manual"), payment header present: yes
  FAIL init with `redirect: undefined`:    redirect="follow"  (expected "manual"), payment header present: yes
  ok   init with `redirect: "manual"`:     redirect="manual" (expected "manual"), payment header present: yes
  ok   init omitted (the path pay() uses): redirect="manual" (expected "manual"), payment header present: yes
FAIL: 1 case(s) lost the redirect guard.
```

The PoC is 40 lines and needs only a stub signer and a stub `fetch`; it is a Node script rather than a `forge
test` because the defect is in the JavaScript package, not in `src/`. I have a GitHub Actions run that checks out
the exact commit and asserts the reproduction, if you would like the link.

The whole PoC:

```js
import assert from "node:assert/strict";
import { createPayer } from "./packages/x402/src/payer.mjs";

const PAYMENT = { "PAYMENT-SIGNATURE": "c2lnbmVkLXBheW1lbnQ" };
const signer = {
  getAddress: async () => "0x1111111111111111111111111111111111111111",
  signTypedData: async () => "0x" + "11".repeat(65),
  provider: {},
};

async function probe(init) {
  const seen = [];
  const fetchImpl = async (req) => {
    seen.push({ redirect: req.redirect, leaked: req.headers.get("PAYMENT-SIGNATURE") });
    return new Response(null, { status: 200 });
  };
  const payer = createPayer({ signer, fetchImpl, pendingRetries: 0 });
  await payer.resend("https://merchant.example/resource", PAYMENT, init);
  assert.equal(seen.length, 1);
  return seen[0];
}

const got = await probe({ method: "GET", redirect: undefined });
console.log(got.redirect, got.leaked);   // "follow" true
```

## Impact

A merchant the payer chose answers `302 Location: https://attacker.example/`. Because the request is built with
`redirect: "follow"`, the runtime follows it and re-sends the custom `PAYMENT-SIGNATURE` header — the platform
strips `Authorization` and `Cookie` on a cross-origin redirect, but not application headers. The attacker now
holds a signed EIP-3009 authorization, live until `validBefore`.

What that buys an attacker:

- **Payment for a resource not delivered.** The authorization is paid to the signed `payTo` regardless of
  whether the original resource ever answered. The buyer is out the money.
- **Replay within the window.** The authorization is a bearer instrument; whoever holds it can submit it.
- **SSRF from the payer's context.** The follow reaches hosts the caller never named, including loopback and
  link-local addresses reachable from where the payer runs.

Note the ceiling honestly: `payTo` is fixed inside the signature, so a leaked header cannot be redirected to
divert funds to a *new* address. The exposure is paying the merchant for a resource that went somewhere else,
plus replay and SSRF.

## Exact surface

I checked each entry point rather than assuming, so the scope is narrow:

| Entry point | Affected | Why |
|---|---|---|
| `resend()` / `payer.resend()` (exported) | **Yes** | The caller's `init` reaches `asRequest` directly |
| `pay()` | **No** | Calls `resend(base, headers, resendOpts)` with no `init`, so the payment-carrying request re-asserts `"manual"` on an already-built `Request` |
| Hosted MCP `pay_url` (`@priors/mcp`) | **No** | `packages/mcp/src/server.mjs:403` builds `init` as `{ method, redirect: "manual" }` explicitly |
| `createUsdgClient()` for `@x402/fetch`'s own wrapper | Not via this path | The wrapper supplies its own init |

The exposure is therefore **direct `@priors/x402` consumers that build an options object and spread it**, e.g.
`payer.resend(url, signedHeaders, { ...opts, redirect: opts.redirect })` where `opts.redirect` is unset — an
ordinary shape in JavaScript.

## Suggested fix

The same change already applied to `sdk/float.mjs`, so both copies match:

```diff
-const asRequest = (input, init) => new Request(input, { redirect: "manual", ...(init || {}) });
+const asRequest = (input, init) => new Request(input, { ...(init || {}), redirect: (init || {}).redirect ?? "manual" });
```

Worth adding the PoC to `npm test` so a third copy cannot drift again, and a comment on both sites noting the
other. A regression test asserting `redirect === "manual"` for `{ redirect: undefined }` is the minimum.

## Severity assessment, and where I may be wrong

I assess **Medium**: it is live in the current published release, the in-scope packages are named in
`BOUNTY.md` for exactly this class, and the sibling fix shows the intent was unconditional.

I can see the argument for lower, and I would rather name it than have you find it:

- **Trigger is caller-side.** It needs a consumer to pass `redirect: undefined`. No attacker can force that; a
  hostile merchant cannot reach it. It is a latent footgun in a library default, not an attacker-controlled path.
- **Possible duplicate.** `P-3` is rated Medium and is described as `pay_url` "followed redirects anywhere with the
  signed header". This is the same defect class in a sibling file that `P-3`'s fix missed. You may reasonably
  close it as a P-3 residual with public credit and no award, and I would not argue hard against that.
- **Bounded impact.** As noted, the signed `payTo` cannot be redirected.

If you rate it Low or Informational I will not contest it — you know the code and the history better than I do.
