#!/bin/sh
# Turns a fresh anvil fork of Base Sepolia into a VORQ stack: clean role accounts, the three
# registries, a funded client. Runs inside the foundry image with the contracts checkout at
# /contracts and the published state at /state. Talks to anvil directly: it needs anvil_*.
set -eu
: "${RPC:?}" "${USDC:?}" "${DEPLOYER_PK:?}" "${TREASURY_PK:?}" "${CURATION_PK:?}" "${PROVIDER_PK:?}" "${CLIENT_PK:?}"

# Every forge and cast call below waits on anvil, and on a cold fork anvil answers a first touch
# of an account only after fetching it from the upstream RPC — which, rate-limited, can take
# longer than foundry's 45 s default, and forge then abandons the deploy half-simulated.
export ETH_RPC_TIMEOUT=600

CLIENT_FUNDS=1000000000000 # 1,000,000 USDC at 6 decimals
DEAD=0x000000000000000000000000000000000000dEaD

for MOUNT in /contracts /state; do
  if ! touch "$MOUNT/.vorq-write-probe" 2>/dev/null; then
    echo "bootstrap: $MOUNT is not writable by uid $(id -u)" >&2
    exit 1
  fi
  rm -f "$MOUNT/.vorq-write-probe"
done

addr() { cast wallet address --private-key "$1"; }
DEPLOYER=$(addr "$DEPLOYER_PK")
CLIENT=$(addr "$CLIENT_PK")

# The deployer starts at nonce 0 (below), so the registries land at fixed addresses and the
# JobRegistry's is this one. Code there means this chain is already bootstrapped — but only
# together with a published book, and only because the book is erased below before this run
# touches the chain. /state outlives the chain (it is a host directory, the chain is a
# container), so a book left by an EARLIER run would otherwise vouch for a deploy that died
# half-way through this one, and the stack would come up against a chain nothing finished.
JOB_REGISTRY=$(cast compute-address "$DEPLOYER" --nonce 1 | awk '{print $NF}')
if [ "$(cast code "$JOB_REGISTRY" --rpc-url "$RPC")" != "0x" ]; then
  if [ -f /state/addresses.json ] && [ -f /state/abi/JobRegistry.json ]; then
    echo "bootstrap: $JOB_REGISTRY already has code and /state is published - nothing to do"
    exit 0
  fi
  echo "bootstrap: $JOB_REGISTRY has code but /state is empty. Recreate the stack." >&2
  exit 1
fi

# Past the guard, so nothing that follows can be vouched for by somebody else's book. From
# here a published /state means exactly one thing: the run that wrote it reached the end.
rm -f /state/addresses.json
rm -rf /state/abi

# Anvil starts with mining off. Every mined block writes one slot of the EIP-2935 history
# contract, and a fork fetches that slot's old value upstream first; one failed fetch there
# panics anvil. So the ring's 8191 slots are filled locally before the first block, and only
# then does mining start, at Base's 2 s. Block hashes from before the fork read as zero here;
# no VORQ contract reads them.
HISTORY=0x0000F90827F1C53a10cb7A02335B175320002935
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
seq 0 8190 | xargs -P 32 -I{} sh -c "cast rpc anvil_setStorageAt $HISTORY \$(cast to-uint256 {}) $ZERO --rpc-url $RPC >/dev/null"
[ "$(cast storage "$HISTORY" 8190 --rpc-url "$RPC")" = "$ZERO" ] \
  || { echo "bootstrap: the block-hash history was not filled" >&2; exit 1; }
cast rpc evm_setIntervalMining 2 --rpc-url "$RPC" >/dev/null

# Anvil's mnemonic is public, so on a fork of a real network these accounts arrive with history:
# EIP-7702 delegation code, used nonces, stray USDC. USDC validates a signature from an account
# with code through ERC-1271, so a delegated client could never pay. Make them fresh.
for PK in "$DEPLOYER_PK" "$TREASURY_PK" "$CURATION_PK" "$PROVIDER_PK" "$CLIENT_PK"; do
  A=$(addr "$PK")
  cast rpc anvil_setBalance "$A" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null # 10000 ETH
  cast rpc anvil_setCode "$A" 0x --rpc-url "$RPC" >/dev/null
  BAL=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$A" --rpc-url "$RPC" | awk '{print $1}')
  if [ "$BAL" != "0" ]; then
    cast rpc anvil_impersonateAccount "$A" --rpc-url "$RPC" >/dev/null
    cast send "$USDC" 'transfer(address,uint256)' "$DEAD" "$BAL" --from "$A" --unlocked --rpc-url "$RPC" >/dev/null
    cast rpc anvil_stopImpersonatingAccount "$A" --rpc-url "$RPC" >/dev/null
  fi
  cast rpc anvil_setNonce "$A" 0x0 --rpc-url "$RPC" >/dev/null
done

cd /contracts

# A fork's clock is the PINNED BLOCK's, not this machine's, so the chain boots however old that
# block is and stays there — and both the +/-600 s window on a signed op's issuedAt and an order's
# expiresAt are compared against block.timestamp, so every op and every post would be refused.
cast rpc anvil_setTime "$(date +%s)" --rpc-url "$RPC" >/dev/null
cast rpc anvil_mine 0x1 --rpc-url "$RPC" >/dev/null

# Explicit, because forge's own fork of anvil (the script's simulation) does not read
# ETH_RPC_TIMEOUT: it gave up after 45 s on a predeploy's storage on 2026-09-30.
forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --no-storage-caching \
  --rpc-timeout 600 --fork-retries 10

# Fund the client the way the issuer would: the master minter grants the deployer an allowance,
# and the deployer mints. Two transactions, both on the fork only.
MASTER=$(cast call "$USDC" 'masterMinter()(address)' --rpc-url "$RPC")
cast rpc anvil_setBalance "$MASTER" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_impersonateAccount "$MASTER" --rpc-url "$RPC" >/dev/null
cast send "$USDC" 'configureMinter(address,uint256)' "$DEPLOYER" "$CLIENT_FUNDS" --from "$MASTER" --unlocked --rpc-url "$RPC" >/dev/null
cast rpc anvil_stopImpersonatingAccount "$MASTER" --rpc-url "$RPC" >/dev/null
cast send "$USDC" 'mint(address,uint256)' "$CLIENT" "$CLIENT_FUNDS" --private-key "$DEPLOYER_PK" --rpc-url "$RPC" >/dev/null
[ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$CLIENT" --rpc-url "$RPC" | awk '{print $1}')" = "$CLIENT_FUNDS" ] \
  || { echo "bootstrap: the client was not funded" >&2; exit 1; }

mkdir -p /state/abi
for SPEC in src/JobRegistry.sol:JobRegistry src/ProviderRegistry.sol:ProviderRegistry src/AskRegistry.sol:AskRegistry; do
  forge inspect "$SPEC" abi --json > "/state/abi/${SPEC#*:}.json"
done
cp out-addresses/addresses.json /state/addresses.json
echo "bootstrap: published /state/addresses.json and /state/abi"
