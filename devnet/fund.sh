#!/usr/bin/env bash
# Fund a devnet account with ETH, USDC and USDT (the devnet's faucet).
#   RPC_URL=https://devnet.iris.credit/admin/<ADMIN_TOKEN> ./devnet/fund.sh 0xYourAddress [eth=100] [usdc=1000000] [usdt=1000000]
# It needs the admin RPC: the public one refuses cheatcodes.
# Amounts are whole tokens and SET the balance rather than adding to it. Balances are written straight
# into each token's balance mapping: anvil_dealERC20 cannot locate the slot behind USDC's proxy.
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
WHO="${1:?usage: fund.sh <address> [eth] [usdc] [usdt]}"
ETH="${2:-100}"
USDC_AMOUNT="${3:-1000000}"
USDT_AMOUNT="${4:-1000000}"

USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 # FiatToken: balanceAndBlacklistStates at slot 9
USDT=0xdAC17F958D2ee523a2206206994597C13D831ec7 # TetherToken: balances at slot 2

[[ "$(cast chain-id --rpc-url "$RPC_URL")" == 9991 ]] || { echo "$RPC_URL is not the devnet (chain 9991)" >&2; exit 1; }

setTokenBalance() { # token slot amount(6 decimals); 0 leaves the balance alone
  local key value
  (($3 > 0)) || return 0
  key="$(cast index address "$WHO" "$2")"
  value="$(cast to-uint256 "$(($3 * 1000000))")"
  cast rpc anvil_setStorageAt "$1" "$key" "$value" --rpc-url "$RPC_URL" >/dev/null
}

cast rpc anvil_setBalance "$WHO" "$(cast to-hex "$(cast to-wei "$ETH")")" --rpc-url "$RPC_URL" >/dev/null
setTokenBalance "$USDC" 9 "$USDC_AMOUNT"
setTokenBalance "$USDT" 2 "$USDT_AMOUNT"

tokenBalance() { # token
  cast format-units "$(cast call "$1" 'balanceOf(address)(uint256)' "$WHO" --rpc-url "$RPC_URL" | cut -d' ' -f1)" 6
}
echo "$WHO: $(cast balance "$WHO" --ether --rpc-url "$RPC_URL") ETH, $(tokenBalance "$USDC") USDC, $(tokenBalance "$USDT") USDT"
