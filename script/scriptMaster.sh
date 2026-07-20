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

# Each environment broadcasts to its own chain id, so every fork keeps an isolated deployment book:
# anvil -> deployments/31337.json, vnet -> deployments/9991.json, production -> deployments/1.json.
ENV_CHOICE=$(gum choose --header "Environment" \
  "Local anvil (chain 31337)" \
  "VNet (chain 9991)" \
  "Production (Ethereum mainnet)")

case "$ENV_CHOICE" in
  "Local anvil"*)
    ENVIRONMENT="staging"
    info "staging: forked anvil at chain-id 31337"
    runAnvil
    PRIVATE_KEY="$ANVIL_PK" # funded anvil account; staging never uses the production key or a Ledger
    USE_LEDGER="false"
    ;;
  "VNet"*)
    ENVIRONMENT="vnet"
    [[ -n "${VNET_RPC_URL:-}" ]] || { error "VNET_RPC_URL not set in .env"; exit 1; }
    # Probe the endpoint before broadcasting (mirrors runAnvil): _chain() also accepts chain-id 1,
    # so a mis-set VNET_RPC_URL pointing at mainnet would broadcast real transactions with the
    # deployer key without ever hitting the production confirm.
    chainId="$(cast chain-id --rpc-url "$VNET_RPC_URL" 2>/dev/null || true)"
    [[ -n "$chainId" ]] || { error "cannot reach VNET_RPC_URL (cast chain-id failed)"; exit 1; }
    [[ "$chainId" == "9991" ]] || { error "VNET_RPC_URL serves chain-id $chainId (expected vnet 9991)"; exit 1; }
    # Persistent anvil mainnet fork, signed with the real deployer key. Its book mirrors
    # deployments/1.json, and a recreated fork re-inherits mainnet state, so the book stays valid.
    info "vnet: broadcasting to the vnet rpc endpoint"
    ;;
  "Production"*)
    ENVIRONMENT="production"
    gum confirm "PRODUCTION run against Ethereum mainnet. Continue?" || exit 1
    ;;
esac
export ENVIRONMENT CHAIN PRIVATE_KEY="${PRIVATE_KEY:-}" USE_LEDGER="${USE_LEDGER:-false}" VERIFY="${VERIFY:-false}"

forge build

ACTION=$(gum choose \
  "Deploy (Pod, Iris, adapters, BLMs)" \
  "Redeploy Iris (one-shot venue/market/LLTV/BLM/fee setup)" \
  "Deploy periphery (Bundler3 + adapter)" \
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
  # Before the "Deploy"* arm, which would otherwise swallow this prefix.
  "Deploy periphery"*)
    # Permissionless: no Iris owner op. The script reads config itself and self-heals a stale adapter
    # binding after an Iris redeploy.
    forge script script/DeployPeriphery.s.sol $(rpcArgs)
    ;;
  "Deploy"*)
    forge script script/Deploy.s.sol $(rpcArgs)
    ;;
  "Redeploy Iris"*)
    # One shot: deploy Iris (only if absent from the book), then wire venues, markets, bond LLTV,
    # BLM, and fees against the already-deployed contracts. Config-driven; idempotent on re-run.
    VENUE_IDS=$(jq -r '[.venues[].id | tostring] | join(",")' "config/$CHAIN.json")
    ADAPTERS=$(jq -r '[.venues[].adapter] | join(",")' "config/$CHAIN.json")
    # Resolve every market to its final quote-data hash; empty (Aave-style venues ignore data) -> keccak256("").
    EMPTY_DATA=$(cast keccak "")
    MARKET_DATA=$(jq -r --arg empty "$EMPTY_DATA" \
      '[.venues[].markets[] | if . == "" then $empty else . end] | join(",")' "config/$CHAIN.json")
    BOND_LLTV=$(gum input --header "bond LLTV (wad, multiple of BP)" --value "900000000000000000")
    FEE=$(jq -r '.fee' "config/$CHAIN.json")
    FEE_RECIPIENT=$(jq -r '.feeRecipient' "config/$CHAIN.json")
    info "venues: ids [$VENUE_IDS] -> adapters [$ADAPTERS]"
    info "market data: [$MARKET_DATA]"
    info "bond lltv: $BOND_LLTV | blm: Blm | fee: $FEE -> $FEE_RECIPIENT"
    gum confirm "Redeploy Iris + apply the setup above?" || exit 1
    VENUE_IDS="$VENUE_IDS" ADAPTERS="$ADAPTERS" MARKET_DATA="$MARKET_DATA" BOND_LLTV="$BOND_LLTV" \
      BLM="Blm" FEE="$FEE" FEE_RECIPIENT="$FEE_RECIPIENT" \
      forge script script/RedeployIris.s.sol $(rpcArgs)
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
