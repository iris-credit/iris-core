#!/usr/bin/env bash
# Shared helpers for Iris scripts, sourced by scriptMaster.sh.

error()   { printf '\033[0;31m[error]\033[0m %s\n' "$1" >&2; }
success() { printf '\033[0;32m[ok]\033[0m %s\n'    "$1"; }
info()    { printf '\033[0;34m[info]\033[0m %s\n'   "$1"; }

ANVIL_RPC="http://127.0.0.1:8545"
# Anvil's first default account, funded on every anvil instance; used as the staging deployer.
ANVIL_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Translate the environment into forge flags. All modes broadcast; they differ only in the target:
#   staging    -> local forked anvil (chain-id 31337)  -> deployments/31337.json
#   vnet       -> persistent vnet fork (chain-id 9991) -> deployments/9991.json
#   production -> the real chain ("ethereum" alias)    -> deployments/1.json
# Keeping every fork on its own chain-id is what stops simulated addresses leaking into production's book.
rpcArgs() {
  local flags
  if [[ "$ENVIRONMENT" == "production" ]]; then
    flags="--rpc-url ethereum --broadcast"
    [[ "${VERIFY:-false}" == "true" ]] && flags="$flags --verify"
  elif [[ "$ENVIRONMENT" == "vnet" ]]; then
    flags="--rpc-url vnet --broadcast"
  else
    flags="--rpc-url $ANVIL_RPC --broadcast"
  fi
  if [[ "${USE_LEDGER:-false}" == "true" ]]; then
    flags="$flags --ledger --sender ${ETH_FROM:-}"
  else
    flags="$flags --private-key ${PRIVATE_KEY:-}"
  fi
  echo "$flags"
}

# Start a mainnet-forked anvil at chain-id 31337 for staging (idempotent). Its book is deployments/31337.json.
# Reuse only an anvil already serving chain-id 31337 at ANVIL_RPC (probe the RPC, not the process name, so an
# unrelated local anvil is not mistaken for the staging fork). A fresh fork has no deployed contracts, so its
# stale book is cleared first and Deploy redeploys instead of loading dead addresses.
runAnvil() {
  local chainId
  chainId="$(cast chain-id --rpc-url "$ANVIL_RPC" 2>/dev/null || true)"
  if [[ -n "$chainId" ]]; then
    [[ "$chainId" == "31337" ]] || { error "$ANVIL_RPC already serves chain-id $chainId (expected 31337); stop it first"; exit 1; }
    info "reusing anvil at $ANVIL_RPC (chain-id 31337)"
    return 0
  fi
  info "starting forked anvil (chain-id 31337)..."
  rm -f deployments/31337.json # fresh fork has no contracts; drop the stale staging book
  anvil --fork-url "https://eth-mainnet.g.alchemy.com/v2/${API_KEY_ALCHEMY}" --chain-id 31337 \
    >"${TMPDIR:-/tmp}/iris-anvil.log" 2>&1 &
  local n=0
  until cast block-number --rpc-url "$ANVIL_RPC" >/dev/null 2>&1; do
    sleep 1
    n=$((n + 1))
    [ "$n" -gt 60 ] && { error "anvil failed to start (see ${TMPDIR:-/tmp}/iris-anvil.log)"; exit 1; }
  done
  info "anvil ready"
}

killAnvil() { pkill -x anvil 2>/dev/null && info "stopped anvil"; return 0; }

# Record a governance value into config, but only when the preceding op ACTUALLY broadcast in production.
# After the timelock handoff, ownerExec only prints calldata (no on-chain change), so we must not record it.
# $OPLOG holds the last op's output; the "broadcast owner call" line is ownerExec's broadcast marker.
maybeSave() { # key value
  [[ "$ENVIRONMENT" == "production" ]] || return 0
  if grep -q "broadcast owner call" "$OPLOG"; then
    saveConfig "$1" "$2"
  else
    info "owner is the timelock - not recording $1; queue the printed calldata, then update config/${CHAIN:-ethereum}.json by hand once the timelock executes it"
  fi
}

# Write key=value into the active chain's config file (chain-aware, mirrors the Solidity _chain()).
saveConfig() { # key value
  local f="config/${CHAIN:-ethereum}.json"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  success "saved $1 = $2 to $f"
}
