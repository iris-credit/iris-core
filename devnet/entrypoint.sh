#!/bin/sh
set -e

# The Alchemy key travels in a request header, never in the URL: anvil_nodeInfo echoes
# --fork-url verbatim to anyone who calls this public endpoint, but never the fork headers.
: "${ALCHEMY_KEY:?ALCHEMY_KEY is required (Alchemy API key for an archive-capable mainnet RPC)}"
FORK_URL="${FORK_URL:-https://eth-mainnet.g.alchemy.com/v2}"
case "$FORK_URL" in
  */v2/?*)
    echo "FORK_URL embeds an API key, which anvil_nodeInfo would publish; unset it and use ALCHEMY_KEY" >&2
    exit 1
    ;;
esac

STATE=/data/state.json

# Without the volume every restart silently drops all staging state.
if ! grep -qs ' /data ' /proc/mounts && [ -z "$ALLOW_EPHEMERAL" ]; then
  echo "no volume mounted at /data (set ALLOW_EPHEMERAL=1 to run without persistence)" >&2
  exit 1
fi
mkdir -p /data

# Reset switch: changing DEVNET_EPOCH starts over from a fresh fork of the current head (then run
# devnet/replay.sh). A plain restart or redeploy keeps the state.
EPOCH="${DEVNET_EPOCH:-0}"
if [ "$(cat /data/epoch 2>/dev/null)" != "$EPOCH" ]; then
  rm -f "$STATE"
  echo "$EPOCH" >/data/epoch
  echo "devnet epoch $EPOCH: starting from a fresh fork" >&2
fi

# A dump cut short by a kill mid-write would make anvil fail on load, restart, and fail again.
# Set it aside and start fresh instead of crash-looping.
if [ -e "$STATE" ] && [ "$(tail -c 1 "$STATE")" != "}" ]; then
  mv "$STATE" "/data/state.corrupt.$(date +%s).json"
  echo "state.json was truncated; moved it aside and started from a fresh fork (run devnet/replay.sh)" >&2
fi

# The public door: devnet-proxy on PROXY_PORT (the custom domain's target port) forwards standard
# JSON-RPC and refuses cheatcodes outside /admin/<ADMIN_TOKEN>. anvil's own port stays reachable only on
# Railway's private network. Restart the proxy if it ever exits; anvil stays the main process.
export ANVIL_URL="http://127.0.0.1:${PORT:-8545}"
(while true; do
  /usr/local/bin/devnet-proxy || true
  echo "devnet-proxy exited; restarting" >&2
  sleep 1
done) &

# Chain id 9991 (the SDK's ChainId.VNet) so @iris-credit/core-sdk addresses
# resolve unchanged while devnet transactions and EIP-712 signatures stay invalid on
# mainnet — no cross-replay. Throwaway keys only — never a real key against this URL.
exec anvil \
  --host 0.0.0.0 \
  --port "${PORT:-8545}" \
  --chain-id 9991 \
  --fork-url "$FORK_URL" \
  --fork-header "Authorization: Bearer $ALCHEMY_KEY" \
  ${FORK_BLOCK_NUMBER:+--fork-block-number "$FORK_BLOCK_NUMBER"} \
  --state "$STATE" \
  --state-interval 60 \
  --prune-history \
  --auto-impersonate
