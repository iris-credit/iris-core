#!/usr/bin/env bash
# Interactive entrypoint for Iris deploy + maintenance. Run from anywhere: ./script/scriptMaster.sh
set -euo pipefail

cd "$(dirname "$0")/.."
source script/helperFunctions.sh

# Required tools: gum (menus), jq (config), forge/cast/anvil (deploy + the staging fork).
for tool in gum jq forge cast anvil; do
  command -v "$tool" >/dev/null || { error "$tool is required but not installed"; exit 1; }
done

[[ -f .env ]] || { error ".env not found (copy .env.example to .env and fill it in)"; exit 1; }
source .env

CHAIN="ethereum"
OPLOG="$(mktemp)"
# Remove the op-log on exit. In staging the forked anvil is intentionally left running for reuse by the next run.
cleanup() {
  rm -f "$OPLOG"
  if [[ "${ENVIRONMENT:-}" == "staging" ]]; then
    info "staging anvil (chain-id 31337) left running for reuse; stop it with: pkill -x anvil"
  fi
}
trap cleanup EXIT

# Production broadcasts to mainnet; staging broadcasts to a local forked anvil (chain-id 31337) so its
# deployment book (deployments/31337.json) stays isolated from production's deployments/1.json.
if [[ "${PRODUCTION:-false}" == "true" ]]; then
  ENVIRONMENT="production"
  gum confirm "PRODUCTION run against Ethereum mainnet. Continue?" || exit 1
else
  ENVIRONMENT="staging"
  info "staging: forked anvil at chain-id 31337"
  runAnvil
  PRIVATE_KEY="$ANVIL_PK" # funded anvil account; staging never uses the production key or a Ledger
  USE_LEDGER="false"
fi
export ENVIRONMENT CHAIN PRIVATE_KEY="${PRIVATE_KEY:-}" USE_LEDGER="${USE_LEDGER:-false}" VERIFY="${VERIFY:-false}"

forge build

ACTION=$(gum choose \
  "Deploy (Pod, Iris, adapters, BLMs)" \
  "Add / upgrade venue" \
  "Enable market" \
  "Enable bond LLTV" \
  "Enable BLM" \
  "Configure BLM params" \
  "Whitelist solver (WhitelistBlm)" \
  "Set fee" \
  "Set fee recipient" \
  "Transfer ownership to timelock")

# Every owner op lives in SetConfig.s.sol, selected by --sig.
case "$ACTION" in
  "Deploy"*)
    forge script script/Deploy.s.sol $(rpcArgs)
    ;;
  "Add / upgrade venue")
    VENUE=$(jq -r '.venues | keys_unsorted[]' "config/$CHAIN.json" | gum choose --header "Venue (label -> id)")
    VENUE_ID=$(jq -r --arg v "$VENUE" '.venues[$v].id' "config/$CHAIN.json")
    ADAPTER=$(jq -r --arg v "$VENUE" '.venues[$v].adapter' "config/$CHAIN.json")
    info "$VENUE -> id $VENUE_ID, adapter $ADAPTER"
    VENUE_ID="$VENUE_ID" ADAPTER="$ADAPTER" forge script script/SetConfig.s.sol --sig "addVenue()" $(rpcArgs)
    ;;
  "Enable market")
    VENUE=$(jq -r '.venues | keys_unsorted[]' "config/$CHAIN.json" | gum choose --header "Venue")
    MK=$(jq -r --arg v "$VENUE" '.venues[$v].markets | keys_unsorted[]' "config/$CHAIN.json" | gum choose --header "Market")
    MARKET=$(jq -r --arg v "$VENUE" --arg n "$MK" '.venues[$v].markets[$n]' "config/$CHAIN.json")
    info "$VENUE / $MK -> data '${MARKET:-(empty -> keccak256(\"\"))}'"
    MARKET="$MARKET" forge script script/SetConfig.s.sol --sig "enableMarket()" $(rpcArgs)
    ;;
  "Enable bond LLTV")
    BOND_LLTV=$(gum input --placeholder "lltv in wad (e.g. 945000000000000000)")
    BOND_LLTV="$BOND_LLTV" forge script script/SetConfig.s.sol --sig "enableBondLltv()" $(rpcArgs)
    ;;
  "Enable BLM")
    BLM=$(gum choose "Blm" "WhitelistBlm")
    BLM="$BLM" forge script script/SetConfig.s.sol --sig "enableBlm()" $(rpcArgs)
    ;;
  "Configure BLM params")
    BLM=$(gum choose "Blm" "WhitelistBlm")
    TOKEN_NAME=$(jq -r '.tokens | keys_unsorted[]' "config/$CHAIN.json" | gum choose --header "Debt token")
    TOKEN=$(jq -r --arg t "$TOKEN_NAME" '.tokens[$t]' "config/$CHAIN.json")
    SLOPE=$(gum input --placeholder "slope in wad (!= 0, < WAD)")
    INTERCEPT=$(gum input --placeholder "intercept in wad (< WAD)")
    BLM="$BLM" TOKEN="$TOKEN" SLOPE="$SLOPE" INTERCEPT="$INTERCEPT" \
      forge script script/SetConfig.s.sol --sig "setBlmParams()" $(rpcArgs)
    ;;
  "Whitelist solver (WhitelistBlm)")
    ACCOUNT=$(gum input --placeholder "solver address (0x..)")
    WHITELISTED=$(gum choose "true" "false")
    BLM="WhitelistBlm" ACCOUNT="$ACCOUNT" WHITELISTED="$WHITELISTED" \
      forge script script/SetConfig.s.sol --sig "setBlmWhitelist()" $(rpcArgs)
    ;;
  "Set fee")
    FEE=$(gum input --placeholder "fee in wad, multiple of BP (0 = none)")
    FEE="$FEE" forge script script/SetConfig.s.sol --sig "setFee()" $(rpcArgs) | tee "$OPLOG"
    maybeSave fee "$FEE"
    ;;
  "Set fee recipient")
    FEE_RECIPIENT=$(gum input --placeholder "fee recipient address (0x..)")
    FEE_RECIPIENT="$FEE_RECIPIENT" forge script script/SetConfig.s.sol --sig "setFeeRecipient()" $(rpcArgs) | tee "$OPLOG"
    maybeSave feeRecipient "$FEE_RECIPIENT"
    ;;
  "Transfer ownership to timelock")
    OWNER=$(gum input --placeholder "timelock address (0x..)")
    gum confirm "Transfer Iris ownership to $OWNER?" || exit 1
    OWNER="$OWNER" forge script script/SetConfig.s.sol --sig "transferOwnership()" $(rpcArgs) | tee "$OPLOG"
    maybeSave owner "$OWNER"
    ;;
esac
