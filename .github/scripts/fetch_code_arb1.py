#!/usr/bin/env python3
"""Fetch on-chain runtime bytecode over JSON-RPC with retries across many endpoints."""
import json
import subprocess
import sys
import time

# Arbitrum One. Used for IDOSToken, which IS live here.
ENDPOINTS = [
    "https://arb1.arbitrum.io/rpc",
    "https://arbitrum-one-rpc.publicnode.com",
    "https://arbitrum.drpc.org",
    "https://arbitrum.llamarpc.com",
    "https://rpc.ankr.com/arbitrum",
    "https://arbitrum.meowrpc.com",
    "https://1rpc.io/arb",
    "https://arbitrum.gateway.tenderly.co",
]


def fetch(url: str, addr: str) -> str:
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [addr, "latest"]}
    )
    try:
        out = subprocess.run(
            ["curl", "-s", "--max-time", "20", "-X", "POST", url,
             "-H", "Content-Type: application/json", "--data", payload],
            capture_output=True, text=True, timeout=30,
        ).stdout
        return (json.loads(out).get("result") or "")
    except Exception:  # noqa: BLE001
        return ""


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: fetch_code.py <address> <outfile>")
        return 2
    addr, outfile = sys.argv[1], sys.argv[2]

    for attempt in range(1, 4):
        for url in ENDPOINTS:
            code = fetch(url, addr)
            if len(code) > 1000:
                with open(outfile, "w") as fh:
                    fh.write(code[2:] if code.startswith("0x") else code)
                print(f"fetched from {url} on attempt {attempt}")
                print(f"runtime size: {len(code[2:]) // 2} bytes")
                print(f"trailing metadata: {code[-12:]}")
                return 0
            print(f"  miss {url} ({len(code)} chars)", file=sys.stderr)
        print(f"attempt {attempt} exhausted, backing off", file=sys.stderr)
        time.sleep(10 * attempt)

    print("FAILED: could not fetch on-chain bytecode from any endpoint", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())