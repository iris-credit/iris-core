#!/usr/bin/env bash
# Add SparkLend to the devnet as venue 2. Idempotent: replay.sh runs it on every rebuild, and a devnet that already
# has Iris needs one run:
#   RPC_URL=https://devnet.iris.credit/admin/<ADMIN_TOKEN> ./devnet/sparklend.sh
#
# 1. SparkLendAdapter holds only an immutable (its pool), so like the other venue adapters it is planted at its
#    recorded address. Until deployments/9991.json records one, a first copy is deployed and recorded: commit the
#    book, then mirror the address in @iris-credit/core-sdk's CHAIN_ADDRESSES[VNet].
# 2. SparkLend prices ETH and BTC assets with Chronicle/Chainlink/RedStone medians that revert once every source is
#    older than 25 h. A fork's feeds stop at its block, so a day in, SparkLend's take, withdraw and liquidation would
#    revert. Aave's sources keep answering their last round, so SparkLend's oracle is pointed at them.
# 3. Once Iris exists, the adapter is registered on it (the deployer owns Iris on the devnet). A venue id that is
#    live with another adapter is never repointed from here.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
BOOK=deployments/9991.json
CONFIG=config/ethereum.json
DEPLOYER=0x006a43B0c6f1CE018023Cd384D4B98FA2C7e19Fa    # VNet deployer and Iris owner
PLANTER=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720     # anvil default account 9; any account but DEPLOYER
SPARK_ADMIN=0x3300f198988e4C9C63F75dF86De36421f06af8c4 # Spark's governance executor, SparkLend's pool admin

info() { printf '\033[0;34m[info]\033[0m %s\n' "$1"; }
die() {
  printf '\033[0;31m[error]\033[0m %s\n' "$1" >&2
  exit 1
}
call() { cast call "$@" --rpc-url "$RPC_URL"; }

[[ "$(cast chain-id --rpc-url "$RPC_URL")" == 9991 ]] || die "$RPC_URL is not the devnet (chain 9991)"
pool="$(jq -r .venues.sparkLend.address "$CONFIG")"
venue_id="$(jq -r .venues.sparkLend.id "$CONFIG")"

# 1. The adapter.
copy() {
  forge create src/adapters/AaveV3Adapter.sol:AaveV3Adapter --rpc-url "$RPC_URL" --unlocked --from "$PLANTER" \
    --broadcast --json --constructor-args "$pool" | jq -r .deployedTo
}
adapter="$(jq -r '.SparkLendAdapter // empty' "$BOOK")"
if [[ -z "$adapter" ]]; then
  adapter="$(copy)"
  jq --arg adapter "$adapter" '.SparkLendAdapter = $adapter' "$BOOK" >"$BOOK.tmp" && mv "$BOOK.tmp" "$BOOK"
  info "deployed SparkLendAdapter at $adapter: commit $BOOK and mirror it in core-sdk's CHAIN_ADDRESSES[VNet]"
elif [[ "$(cast code "$adapter" --rpc-url "$RPC_URL")" == 0x ]]; then
  cast rpc anvil_setCode "$adapter" "$(cast code "$(copy)" --rpc-url "$RPC_URL")" --rpc-url "$RPC_URL" >/dev/null
  info "planted SparkLendAdapter at $adapter"
fi
[[ "$(call "$adapter" 'POOL()(address)')" == "$pool" ]] || die "SparkLendAdapter at $adapter does not wrap $pool"

# 2. The prices.
oracle_of() { call "$(call "$1" 'ADDRESSES_PROVIDER()(address)')" 'getPriceOracle()(address)'; }
spark_oracle="$(oracle_of "$pool")"
aave_oracle="$(oracle_of "$(jq -r .venues.aaveV3.address "$CONFIG")")"
assets=()
aave_sources=()
for token in WETH wstETH WBTC cbBTC; do
  asset="$(jq -r ".tokens.$token" "$CONFIG")"
  aave_source="$(call "$aave_oracle" 'getSourceOfAsset(address)(address)' "$asset")"
  if [[ "$(call "$spark_oracle" 'getSourceOfAsset(address)(address)' "$asset")" != "$aave_source" ]]; then
    assets+=("$asset")
    aave_sources+=("$aave_source")
  fi
done
if ((${#assets[@]})); then
  cast rpc anvil_setBalance "$SPARK_ADMIN" "$(cast to-hex "$(cast to-wei 1)")" --rpc-url "$RPC_URL" >/dev/null
  cast send --unlocked --from "$SPARK_ADMIN" "$spark_oracle" 'setAssetSources(address[],address[])' \
    "[$(IFS=,; echo "${assets[*]}")]" "[$(IFS=,; echo "${aave_sources[*]}")]" --rpc-url "$RPC_URL" >/dev/null
  info "pointed SparkLend's price source for ${#assets[@]} ETH and BTC asset(s) at Aave's"
fi

# 3. The venue.
iris="$(jq -r '.Iris // empty' "$BOOK")"
if [[ -z "$iris" || "$(cast code "$iris" --rpc-url "$RPC_URL")" == 0x ]]; then
  info "Iris is not deployed yet: venue $venue_id is left for the next run"
  exit 0
fi
live="$(call "$iris" 'venueAdapter(uint256)(address)' "$venue_id")"
if [[ "$live" == "$adapter" ]]; then
  info "venue $venue_id is already SparkLendAdapter"
elif [[ "$live" != 0x0000000000000000000000000000000000000000 ]]; then
  die "venue $venue_id is live with $live: repoint it deliberately, not from here"
else
  cast send --unlocked --from "$DEPLOYER" "$iris" 'setVenueAdapter(uint256,address)' "$venue_id" "$adapter" \
    --rpc-url "$RPC_URL" >/dev/null
  info "registered SparkLendAdapter as venue $venue_id"
fi
