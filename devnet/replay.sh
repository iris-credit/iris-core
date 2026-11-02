#!/usr/bin/env bash
# Rebuild the Iris deployment on a fresh devnet fork at the exact addresses in deployments/9991.json
# (mirrored by @iris-credit/core-sdk's CHAIN_ADDRESSES[VNet]), so a devnet reset needs no SDK release.
# Run once after the devnet starts on a new DEVNET_EPOCH:
#   RPC_URL=https://devnet.iris.credit/admin/<ADMIN_TOKEN> SOLVER=0x… KEEPERS="0x… 0x…" ./devnet/replay.sh
#
# How the addresses come back:
# - Iris, Blm, WhitelistBlm and EthereumGeneralAdapter1 were CREATEd by DEPLOYER at nonces 0, 1, 2 and 15.
#   DEPLOYER has never sent a mainnet transaction, so on a fresh fork its nonce is 0 again, and replaying
#   the same scripts in the same order lands on the same addresses.
# - PodImpl, Bundler3 and the two venue adapters came from other deployers. None of them holds storage
#   (only immutables), so a copy deployed anywhere is planted at the recorded address with anvil_setCode.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
BOOK=deployments/9991.json
CONFIG=config/ethereum.json
DEPLOYER=0x006a43B0c6f1CE018023Cd384D4B98FA2C7e19Fa # VNet deployer and Iris owner
PLANTER=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720  # anvil default account 9; any account but DEPLOYER

info() { printf '\033[0;34m[info]\033[0m %s\n' "$1"; }
die() {
  printf '\033[0;31m[error]\033[0m %s\n' "$1" >&2
  exit 1
}
rpc() { cast rpc "$@" --rpc-url "$RPC_URL" >/dev/null; }

[[ "$(cast chain-id --rpc-url "$RPC_URL")" == 9991 ]] || die "$RPC_URL is not the devnet (chain 9991)"
if [[ "$(cast code "$(jq -r .Iris "$BOOK")" --rpc-url "$RPC_URL")" != 0x ]]; then
  info "Iris is already deployed; nothing to do"
  exit 0
fi
nonce="$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")"
[[ "$nonce" == 0 ]] || die "deployer nonce is $nonce, not 0: the CREATE addresses would not match $BOOK"

# The scripts deploy whatever the book is missing, so run them against a book holding only the planted
# contracts, then require the rebuilt book to equal the committed one.
cp "$BOOK" "$BOOK.committed"
trap 'mv "$BOOK.committed" "$BOOK"' EXIT
jq '{PodImpl, Bundler3, AaveV3Adapter, MorphoBlueAdapter}' "$BOOK.committed" >"$BOOK"

forge build

plant() { # book-name contract [constructor args...]
  local target copy args=()
  target="$(jq -r ".$1" "$BOOK")"
  (($# > 2)) && args=(--constructor-args "${@:3}")
  copy="$(forge create "$2" --rpc-url "$RPC_URL" --unlocked --from "$PLANTER" --broadcast --json \
    ${args[@]+"${args[@]}"} | jq -r .deployedTo)"
  rpc anvil_setCode "$target" "$(cast code "$copy" --rpc-url "$RPC_URL")"
  info "planted $1 at $target"
}
plant PodImpl src/Pod.sol:Pod
plant Bundler3 src/periphery/Bundler3.sol:Bundler3
plant AaveV3Adapter src/adapters/AaveV3Adapter.sol:AaveV3Adapter "$(jq -r .venues.aaveV3.address "$CONFIG")"
plant MorphoBlueAdapter src/adapters/MorphoBlueAdapter.sol:MorphoBlueAdapter "$(jq -r .venues.morphoBlue.address "$CONFIG")"

rpc anvil_setBalance "$DEPLOYER" "$(cast to-hex "$(cast to-wei 100)")"
export ETH_FROM="$DEPLOYER" PRIVATE_KEY="" USE_LEDGER=false
run() { forge script "$@" --rpc-url "$RPC_URL" --broadcast --slow --unlocked --sender "$DEPLOYER"; }

# Nonces 0-2: Iris, Blm, WhitelistBlm.
run script/Deploy.s.sol
# Nonces 3-12: venues, markets, bond LLTV, BLM, fee recipient, fee (the inputs scriptMaster passes).
VENUE_IDS="$(jq -r '[.venues[].id | tostring] | join(",")' "$CONFIG")" \
  ADAPTERS="$(jq -r '[.venues[].adapter] | join(",")' "$CONFIG")" \
  MARKET_DATA="$(jq -r --arg empty "$(cast keccak "")" \
    '[.venues[].markets[] | if . == "" then $empty else . end] | join(",")' "$CONFIG")" \
  BOND_LLTV=800000000000000000 BLM=Blm \
  FEE="$(jq -r .fee "$CONFIG")" FEE_RECIPIENT="$(jq -r .feeRecipient "$CONFIG")" \
  run script/RedeployIris.s.sol
# Nonces 13-14: the BLM params VNet ran with.
BLM=Blm TOKEN="$(jq -r .tokens.USDC "$CONFIG")" SLOPE=101840000000000 INTERCEPT=1500000000000 \
  run script/SetConfig.s.sol --sig 'setBlmParams()'
BLM=Blm TOKEN="$(jq -r .tokens.USDT "$CONFIG")" SLOPE=80690000000000 INTERCEPT=49400000000000 \
  run script/SetConfig.s.sol --sig 'setBlmParams()'
# Nonce 15: EthereumGeneralAdapter1.
nonce="$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")"
[[ "$nonce" == 15 ]] || die "deployer nonce is $nonce before DeployPeriphery, expected 15 (did $CONFIG change?)"
run script/DeployPeriphery.s.sol

if ! diff <(jq -S . "$BOOK") <(jq -S . "$BOOK.committed"); then
  die "the rebuilt book (<) differs from the committed one (>)"
fi
info "all 8 contracts are at their recorded addresses"

# Optional staging actors: SOLVER gets ETH, USDC and USDT plus its standing max allowance to Iris
# (the bond funding the solver bot expects); each of KEEPERS gets ETH for gas.
iris="$(jq -r .Iris "$BOOK")"
if [[ -n "${SOLVER:-}" ]]; then
  RPC_URL="$RPC_URL" ./devnet/fund.sh "$SOLVER"
  for token in USDC USDT; do
    cast send --unlocked --from "$SOLVER" "$(jq -r ".tokens.$token" "$CONFIG")" \
      'approve(address,uint256)' "$iris" "$(cast max-uint)" --rpc-url "$RPC_URL" >/dev/null
  done
  info "solver $SOLVER funded and approved Iris"
fi
for keeper in ${KEEPERS:-}; do
  RPC_URL="$RPC_URL" ./devnet/fund.sh "$keeper" 10 0 0
done
