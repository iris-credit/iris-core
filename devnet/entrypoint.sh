#!/bin/sh
set -e

: "${FORK_URL:?FORK_URL is required (archive-capable mainnet RPC, e.g. Alchemy)}"

# Chain id stays 1 so @iris-credit/core-sdk addresses and signature domains
# work unchanged. Throwaway keys only — never a real key against this URL.
exec anvil \
  --host 0.0.0.0 \
  --port "${PORT:-8545}" \
  --chain-id 1 \
  --fork-url "$FORK_URL" \
  ${FORK_BLOCK_NUMBER:+--fork-block-number "$FORK_BLOCK_NUMBER"} \
  --state /data/state.json \
  --state-interval 60 \
  --auto-impersonate
