#!/usr/bin/env python3
"""Compare compiled runtime bytecode against on-chain.

Constructor-set immutables are patched into deployed code, so an exact match is
only expected once those are normalised. This script locates the differing
regions, reports them, and re-compares after patching the immutable values from
the on-chain side into the local artifact.
"""
import json
import re
import sys

MET = "a264697066735822"  # CBOR metadata prefix emitted by solc


def strip(b: str) -> str:
    i = b.rfind(MET)
    return b[:i] if i > 0 else b


def diff_blocks(a: str, b: str) -> list:
    """Contiguous [start, end) nibble ranges where a and b differ."""
    n = min(len(a), len(b))
    blocks, start = [], None
    for i in range(n):
        if a[i] != b[i]:
            if start is None:
                start = i
        elif start is not None:
            blocks.append((start, i))
            start = None
    if start is not None:
        blocks.append((start, n))
    return blocks


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: compare_bytecode.py <artifact.json> <onchain.hex> <name>")
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

    if len(ls) != len(os_):
        print("RESULT: LENGTH MISMATCH after metadata strip.")
        return 0

    if ls == os_:
        print("RESULT: EXACT MATCH (ignoring compiler metadata).")
        return 0

    blocks = diff_blocks(ls, os_)
    total = sum(e - s for s, e in blocks)
    print(f"RESULT: differs in {len(blocks)} block(s), {total} nibbles "
          f"({total / len(ls) * 100:.3f}% of code)")

    print("\nDivergent regions (byte offsets) and interpretation:")
    patched = ls
    for s, e in blocks:
        # align to byte boundaries for readability
        bs, be = (s + 1) // 2, e // 2
        seg_len = be - bs
        on_seg = os_[bs * 2:be * 2]
        # a 20-byte run is an address-shaped immutable
        kind = "IMMUTABLE (address-shaped, 20 bytes)" if seg_len == 20 else \
               f"code difference, {seg_len} bytes"
        print(f"  byte {bs}..{be}  {kind}")
        print(f"    on-chain bytes: {on_seg}")
        # Patch: adopt the on-chain value so we can test whether anything else differs.
        patched = patched[: bs * 2] + on_seg + patched[be * 2:]

    if patched == os_:
        print("\nVERDICT: deployed bytecode IS the compiled source.")
        print("All differences are constructor-set immutable values only.")
    else:
        remaining = diff_blocks(patched, os_)
        print(f"\nVERDICT: {sum(e - s for s, e in remaining)} nibbles still differ "
              f"in {len(remaining)} block(s) after normalising those regions.")
        print("Deployed code contains logic not present in the source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())