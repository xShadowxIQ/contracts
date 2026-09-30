// PoC: @priors/x402 follows redirects with a signed payment header when the caller's
// `init` carries `redirect: undefined`.
//
// packages/x402/src/payer.mjs builds every request it signs with:
//
//     const asRequest = (input, init) => new Request(input, { redirect: "manual", ...(init || {}) });
//
// The object spread comes AFTER the default, so an `init` that *mentions* redirect but
// leaves it undefined overwrites "manual" with `undefined`, and `new Request` then applies
// the platform default, "follow". The signed PAYMENT-SIGNATURE header is then sent to
// whatever host the redirect names.
//
// sdk/float.mjs, the sibling copy of this loop, was fixed for exactly this in commit 32e0e8d
// ("float keeps redirect 'manual' for `redirect: undefined'"), by moving the default AFTER
// the spread and coalescing: `{ ...init, redirect: init.redirect ?? "manual" }`.
// This PoC shows the fix did not reach packages/x402/src/payer.mjs.
//
//   node scripts/test-x402-redirect-guard.mjs
//
// Exits non-zero if the payer does not hold `manual`.

import assert from "node:assert/strict";
import { createPayer } from "../packages/x402/src/payer.mjs";

const PAYMENT = { "PAYMENT-SIGNATURE": "c2lnbmVkLXBheW1lbnQ" }; // any signed header

const signer = {
  getAddress: async () => "0x1111111111111111111111111111111111111111",
  signTypedData: async () => "0x" + "11".repeat(65),
  provider: {},
};

/** What the payer handed to fetch: its `redirect` mode and whether the payment rode along. */
async function probe(init) {
  const seen = [];
  const fetchImpl = async (req) => {
    seen.push({ url: req.url, redirect: req.redirect, leaked: req.headers.get("PAYMENT-SIGNATURE") });
    return new Response(null, { status: 200 });
  };
  const payer = createPayer({ signer, fetchImpl, pendingRetries: 0 });
  await payer.resend("https://merchant.example/resource", PAYMENT, init);
  assert.equal(seen.length, 1, "expected exactly one request");
  return seen[0];
}

const results = [];
let failed = 0;

async function check(name, init, expected) {
  const got = await probe(init);
  const ok = got.redirect === expected;
  if (!ok) failed++;
  results.push(`  ${ok ? "ok  " : "FAIL"} ${name}\n         redirect = ${JSON.stringify(got.redirect)} (expected ${JSON.stringify(expected)}), payment header on request: ${got.leaked ? "yes" : "no"}`);
}

console.log("@priors/x402 redirect guard\n");

// 1. The documented default: no `redirect` key at all -> manual. This one is fine today.
await check("init without a `redirect` key", { method: "GET" }, "manual");

// 2. The defect: `redirect` present but undefined -> the platform default, "follow".
await check("init with `redirect: undefined`", { method: "GET", redirect: undefined }, "manual");

// 3. An explicit choice is honoured (the guard must not break deliberate callers).
await check("init with `redirect: \"manual\"`", { method: "GET", redirect: "manual" }, "manual");

// 4. pay()'s own payment request passes no init at all, so it re-asserts "manual" on an
//    already-built Request and is NOT affected. Recorded so the report states the surface exactly.
await check("init omitted (the path pay() itself uses)", undefined, "manual");

console.log(results.join("\n"));
console.log("");

if (failed === 0) {
  console.log("PASS: the payer held redirect:manual in every case.");
  process.exit(0);
}

console.log(`FAIL: ${failed} case(s) lost the redirect guard.`);
console.log("");
console.log("Why this matters: with redirect=follow, a 302 from the merchant sends the");
console.log("PAYMENT-SIGNATURE header - a live EIP-3009 authorization - to a host the");
console.log("caller never named, inside its validBefore window. That is the redirect half of");
console.log("P-3 (\"followed redirects anywhere with the signed header\", rated Medium); the MCP");
console.log("pay_url tool is unaffected because it passes redirect:\"manual\" explicitly, but");
console.log("every direct @priors/x402 consumer that spreads its options object is.");
process.exit(1);
