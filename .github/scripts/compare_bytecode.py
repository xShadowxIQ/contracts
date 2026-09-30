#!/usr/bin/env python3
"""Compare compiled runtime bytecode against on-chain, ignoring CBOR metadata."""
import json
import sys

MET = "a264697066735822"  # CBOR metadata prefix emitted by solc


def strip(b: str) -> str:
    i = b.rfind(MET)
    return b[:i] if i > 0 else b


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: compare_bytecode.py <artifact.json> <onchain.hex> <contractName>")
        return 2
    art_path, onchain_path, name = sys.argv[1], sys.argv[2], sys.argv[3]

    art = json.load(open(art_path))
    local = art["deployedBytecode"]["object"]
    if local.startswith("0x"):
        local = local[2:]
    onchain = open(onchain_path).read().strip()

    ls, os_ = strip(local), strip(onchain)
    print(f"contract          : {name}")
    print(f"local   runtime   : {len(local) // 2} bytes")
    print(f"on-chain runtime  : {len(onchain) // 2} bytes")
    print(f"metadata-stripped : local={len(ls) // 2}  on-chain={len(os_) // 2}")
    print(f"solc (on-chain)   : 0x{onchain[-6:]}")

    if ls == os_:
        print("RESULT: EXACT MATCH (ignoring compiler metadata).")
        print("Deployed bytecode == compiled source.")
        return 0

    print("RESULT: BYTECODE DIFFERS -> deployed contract is NOT the audited source.")
    n = min(len(ls), len(os_))
    first = next((i for i in range(n) if ls[i] != os_[i]), n)
    print(f"first divergence at byte {first // 2}")
    lo = max(0, first - 60)
    print(f"  local  : ...{ls[lo:first + 120]}")
    print(f"  onchain: ...{os_[lo:first + 120]}")
    same = sum(1 for a, b in zip(ls, os_) if a == b)
    print(f"identical nibbles before divergence: {same}/{n} ({100.0 * same / n:.2f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())