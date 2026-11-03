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
PIN=/data/fork-block

# Without the volume every restart silently drops all staging state.
if ! grep -qs ' /data ' /proc/mounts && [ "$ALLOW_EPHEMERAL" != 1 ]; then
  echo "no volume mounted at /data (set ALLOW_EPHEMERAL=1 to run without persistence)" >&2
  exit 1
fi
mkdir -p /data

# Reset switch: changing DEVNET_EPOCH starts over from a fresh fork of the current head (then run
# devnet/replay.sh). A plain restart or redeploy keeps the state.
EPOCH="${DEVNET_EPOCH:-0}"
# A volume from before the marker existed adopts the current epoch, so a rollout never resets it.
[ -e /data/epoch ] || echo "$EPOCH" >/data/epoch
if [ "$(cat /data/epoch)" != "$EPOCH" ]; then
  rm -f "$STATE" "$PIN"
  echo "$EPOCH" >/data/epoch
  echo "devnet epoch $EPOCH: starting from a fresh fork" >&2
fi

# A dump cut short by a kill mid-write would make anvil fail on load, restart, and fail again.
# Set it aside and start fresh instead of crash-looping.
if [ -e "$STATE" ] && [ "$(tail -c 1 "$STATE")" != "}" ]; then
  mv "$STATE" "/data/state.corrupt.$(date +%s).json"
  echo "state.json was truncated; moved it aside and started from a fresh fork (run devnet/replay.sh)" >&2
fi

# Every boot of an epoch forks the same block. Unpinned, anvil re-forks the current head and lays the
# snapshot (taken against the old head) over it: two mainnet heights in one chain, with a clock behind
# the venues' last update. FORK_BLOCK_NUMBER overrides and is recorded too.
[ -n "$FORK_BLOCK_NUMBER" ] && echo "$FORK_BLOCK_NUMBER" >"$PIN"
FORK_BLOCK="$(cat "$PIN" 2>/dev/null || true)"
FRESH=
[ -e "$STATE" ] || FRESH=1
if [ -z "$FRESH" ] && [ -z "$FORK_BLOCK" ]; then
  echo "WARNING: snapshot without a recorded fork block; set FORK_BLOCK_NUMBER to the block it was forked from" >&2
fi

# Once anvil is up: record where an unpinned fork landed, and move the clock to now (never behind the last
# block). anvil restarts it at the fork block's timestamp, so new blocks would go back in time.
(
  rpc="http://127.0.0.1:${PORT:-8545}"
  i=0
  until cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 120 ] && exit 0
    sleep 1
  done
  if [ -z "$FORK_BLOCK" ]; then
    cast rpc anvil_nodeInfo --rpc-url "$rpc" | sed -n 's/.*"forkBlockNumber":\([0-9]*\).*/\1/p' >"$PIN.tmp"
    if [ -s "$PIN.tmp" ]; then mv "$PIN.tmp" "$PIN"; else rm -f "$PIN.tmp"; fi
    echo "devnet fork block pinned at $(cat "$PIN" 2>/dev/null)" >&2
  fi
  now="$(date +%s)"
  last="$(cast block latest -f timestamp --rpc-url "$rpc" 2>/dev/null || echo 0)"
  [ "$last" -ge "$now" ] && now=$((last + 1))
  cast rpc anvil_setTime "$now" --rpc-url "$rpc" >/dev/null
) &

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
# --prune-history 64 bounds memory but keeps the last 64 block states, and --preserve-historical-states
# writes them into the snapshot so they survive a restart: the indexer and keepers read pinned to a block.
exec anvil \
  --host 0.0.0.0 \
  --port "${PORT:-8545}" \
  --chain-id 9991 \
  --fork-url "$FORK_URL" \
  --fork-header "Authorization: Bearer $ALCHEMY_KEY" \
  ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} \
  --state "$STATE" \
  --state-interval 60 \
  --prune-history 64 \
  --preserve-historical-states \
  --auto-impersonate
