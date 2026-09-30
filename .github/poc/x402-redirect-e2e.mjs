// End-to-end PoC: the signed payment header actually ARRIVES at a second origin.
//
// The unit-level check (`test-x402-redirect-guard.mjs`) only proves the Request is built
// with redirect:"follow". This proves the consequence: two real HTTP servers, the first
// answering 302 to the second, and the second reporting whether it received the
// PAYMENT-SIGNATURE header that was signed for a purchase at the first.
//
//   node scripts/test-x402-redirect-e2e.mjs
//
// Exits 0 if the header reached the redirect target (the finding), 1 if the guard held.

import assert from "node:assert/strict";
import http from "node:http";
import { createPayer } from "../packages/x402/src/payer.mjs";

const PAYMENT = { "PAYMENT-SIGNATURE": "SIGNED-AUTHORIZATION-FOR-ORIGIN-A" };
const signer = {
  getAddress: async () => "0x1111111111111111111111111111111111111111",
  signTypedData: async () => "0x" + "11".repeat(65),
  provider: {},
};

const listen = (server) =>
  new Promise((r) => server.listen(0, "127.0.0.1", () => r(server.address().port)));

function close(server) {
  return new Promise((r) => server.close(r));
}

async function main() {
  // Origin B: the redirect target. Records what it received.
  let leaked = null;
  const b = http.createServer((req, res) => {
    leaked = {
      paymentSignature: req.headers["payment-signature"] ?? null,
      host: req.headers.host,
    };
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok");
  });
  const bPort = await listen(b);

  // Origin A: the merchant. Answers 302 to origin B.
  const a = http.createServer((req, res) => {
    res.writeHead(302, { location: `http://127.0.0.1:${bPort}/landing` });
    res.end();
  });
  const aPort = await listen(a);

  const origin = `http://127.0.0.1:${aPort}/resource`;

  try {
    // The caller spread its options and `opts.redirect` is unset -> explicitly undefined.
    const opts = { method: "GET" };
    const payer = createPayer({ signer, pendingRetries: 0 });
    await payer.resend(origin, PAYMENT, { ...opts, redirect: opts.redirect });

    console.log(`origin A  http://127.0.0.1:${aPort}/resource`);
    console.log(`origin B  http://127.0.0.1:${bPort}/landing`);
    console.log("");
    console.log("  init passed to resend(): { method: 'GET', redirect: undefined }");
    console.log("");
    console.log(`  origin B received PAYMENT-SIGNATURE: ${leaked ? JSON.stringify(leaked.paymentSignature) : "(request never arrived)"}`);

    if (!leaked) {
      console.log("");
      console.log("PASS: the redirect was not followed; the authorization stayed on origin A.");
      return 1;
    }
    if (leaked.paymentSignature !== PAYMENT["PAYMENT-SIGNATURE"]) {
      console.log("");
      console.log("INCONCLUSIVE: origin B was reached but without the signed header.");
      return 1;
    }

    console.log("");
    console.log("FAIL: the signed authorization crossed the redirect boundary.");
    console.log("");
    console.log("  The header was signed for a purchase at origin A and arrived intact at origin B,");
    console.log("  a host the caller never named. It stays cashable until its validBefore.");
    return 0;
  } finally {
    await close(a);
    await close(b);
  }
}

process.exit(await main());
