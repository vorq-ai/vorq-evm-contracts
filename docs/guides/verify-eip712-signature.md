---
title: Verify an EIP-712 signature
description: Rebuild a domain separator, struct hash and digest with cast, and check a signature against the published test vectors.
---

This walks through the `claim` case of [`vectors/signing-v3.json`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/vectors/signing-v3.json). The vectors are computed at the [local fork](./run-local-fork.md) addresses on chain id `84532`. The same steps apply to every type in [Signing](../reference/signing.md). Requires `cast` and `jq`, run from the repository root.

## 1. Rebuild the domain separator

`Claim` is verified by `JobRegistry` (`VORQ Jobs`, version `2`):

```bash
DOMAIN_TYPEHASH=$(cast keccak "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
SEP=$(cast keccak $(cast abi-encode "f(bytes32,bytes32,bytes32,uint256,address)" \
  $DOMAIN_TYPEHASH $(cast keccak "VORQ Jobs") $(cast keccak "2") 84532 \
  0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512))
echo $SEP   # 0x3f0c928d3c1e283abf4a1c86884de6c9c2d0f759a41f4b1e5482f2973768ff4d
```

Against a deployed contract, compare with its `DOMAIN_SEPARATOR()`. A mismatch means a wrong address or chain:

```bash
cast call <JobRegistry address> "DOMAIN_SEPARATOR()(bytes32)" --rpc-url <rpc>
```

## 2. Hash the struct

```bash
CLAIM_TYPEHASH=$(cast keccak "Claim(bytes32 jobId,uint64 issuedAt)")
STRUCT=$(cast keccak $(cast abi-encode "f(bytes32,bytes32,uint64)" \
  $CLAIM_TYPEHASH 0x74df3a3c4f813c80a4d5e27bd099a78751a21c05735003c6b86430aa2bbd8b40 1800000000))
```

Each member is ABI-encoded as a 32-byte word. A `bytes` member (`SetIdentity.evidence`) is encoded as its `keccak256`; an array of structs (`AskSnapshot.quotes`) as the `keccak256` of the concatenated element hashes.

## 3. Build the digest

```bash
DIGEST=$(cast keccak 0x1901${SEP#0x}${STRUCT#0x})
echo $DIGEST   # 0xde48afcd388bd3582c6c178b85d36ef841e258b2bc2b64cbe18bf0a0514118fe
```

The value must equal the case's `digest`.

## 4. Check the signature

Signatures are 65 bytes, `r || s || v`, with `v` 27 or 28:

```bash
SIG=$(jq -r '.cases[] | select(.name=="claim") | .signature' vectors/signing-v3.json)
cast wallet verify --no-hash --address 0x90F79bf6EB2c4f870365E785982E1f101E93b906 $DIGEST $SIG
```

Or verify straight from the case's typed data, which checks your wallet library's EIP-712 encoding end to end:

```bash
jq '.cases[] | select(.name=="claim") | .typed_data' vectors/signing-v3.json > claim.json
cast wallet verify --data --from-file --address 0x90F79bf6EB2c4f870365E785982E1f101E93b906 claim.json $SIG
```

The signer is the local fork's provider operator (Anvil account `#3`). Signing `claim.json` with its public dev key reproduces the case's `signature` exactly:

```bash
cast wallet sign --data --from-file \
  --private-key 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6 claim.json
```

## If a digest does not match

- Compare the type string byte for byte with [Signing](../reference/signing.md#type-strings): no spaces after commas, members in declaration order.
- For `AskSnapshot`, the encoded type is the primary type followed by `Ask(...)`; quote order changes the digest.
- `Order` has nine signed members. The Solidity struct's tenth member, `taskCid`, is not signed.
- The payment authorization is signed on the USDC domain, not a VORQ domain.
