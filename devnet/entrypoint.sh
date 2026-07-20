#!/bin/sh
set -e

: "${FORK_URL:?FORK_URL is required (archive-capable mainnet RPC, e.g. Alchemy)}"

# Chain id 9991 (the SDK's ChainId.VNet) so @iris-credit/core-sdk addresses
# resolve unchanged while devnet transactions and EIP-712 signatures stay invalid on
# mainnet — no cross-replay. Throwaway keys only — never a real key against this URL.
exec anvil \
  --host 0.0.0.0 \
  --port "${PORT:-8545}" \
  --chain-id 9991 \
  --fork-url "$FORK_URL" \
  ${FORK_BLOCK_NUMBER:+--fork-block-number "$FORK_BLOCK_NUMBER"} \
  --state /data/state.json \
  --state-interval 60 \
  --prune-history \
  --auto-impersonate
