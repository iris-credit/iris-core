# devnet

Shared staging network: a long-lived anvil fork of Ethereum mainnet at chain id 9991
(the SDK's `ChainId.VNet`), consumed as a plain RPC URL by iris-rfq, iris-indexer,
iris-ui, and the iris-bots services.

- **Public RPC** (rfq, UI, solvers, scriptMaster's `VNET_RPC_URL`):
  `https://devnet.iris.credit` — Cloudflare-proxied, rate-limited 50 req/10s per IP.
- **Internal RPC** (indexer, cron, bots; same Railway project): `http://devnet.railway.internal:8545`
  (`ws://` for subscriptions) — bypasses Cloudflare and its rate limit entirely.

The Iris deployment lives at the addresses in `deployments/9991.json`, which
`@iris-credit/core-sdk` mirrors as `CHAIN_ADDRESSES[ChainId.VNet]`. A fresh fork does not
have it: run `replay.sh` once per fork (see "Reset and rebuild"). Aave, Morpho, and every
token come from mainnet. To test unreleased contract code, run a `forge script` from this
repo against the fork's URL like any other network.

## Railway setup (one-time)

1. New service from this repo, **root directory `devnet/`** (config is read from
   `railway.json`; watch paths keep contract-only pushes from redeploying it).
2. Attach a **volume mounted at `/data`**. anvil snapshots its state there (`--state`,
   every 60s, overwriting one file), so restarts and redeploys keep staging history. The
   entrypoint refuses to start without the volume (`ALLOW_EPHEMERAL=1` overrides).
3. Environment variables:
   - `ALCHEMY_KEY` (required): API key for an archive-capable mainnet RPC. Use a
     dedicated key on a free account with no payment method, so the worst case is a
     drained quota, not a bill. It is sent as an `Authorization` header: `anvil_nodeInfo`
     returns `--fork-url` verbatim to any caller, so the key must never be in the URL (the
     entrypoint rejects a `FORK_URL` that embeds one).
   - `FORK_URL` (optional): defaults to `https://eth-mainnet.g.alchemy.com/v2`.
   - `DEVNET_EPOCH` (optional): the reset switch, see below.
   - `FORK_BLOCK_NUMBER` (optional): pin the fork base block. Unset = fork at the head
     block when a new epoch starts; restarts reuse the block recorded in the state file.
   - `PORT` (set to `8545`): keeps the listening port stable so project-internal
     consumers can address `devnet.railway.internal:8545`.
4. Resource limits: cap the service's memory (anvil holds the forked state in RAM, and
   RAM is what Railway bills for) and keep a workspace usage limit set. The volume itself
   costs next to nothing.
5. Networking: add the custom domain `devnet.iris.credit` (Cloudflare-proxied
   CNAME, zone SSL `Full`), then delete the Railway-generated domain so Cloudflare
   is the only door. The zone's rate-limit rule matches `http.request.uri.path eq "/"`
   — all JSON-RPC lands on `/`, and the free plan lacks per-hostname matching, so
   the rule is zone-wide; revisit if another `iris.credit` property hammers its root.
   Project-internal consumers use the Railway-internal hostname and skip all of this.

## Reset and rebuild

1. Set `DEVNET_EPOCH` to a new value and redeploy. The entrypoint deletes the state
   file and anvil forks the current mainnet head. A plain restart or redeploy keeps the
   state. A state file cut short mid-write is moved aside the same way, rather than
   crash-looping the service.
2. From this repo, rebuild Iris and fund the staging actors:

   ```bash
   RPC_URL=https://devnet.iris.credit SOLVER=0x… KEEPERS="0x… 0x… 0x…" ./devnet/replay.sh
   ```

   It deploys every contract at its recorded address (it explains how in its header)
   and stops if any address comes out different. It is idempotent: on a fork that
   already has Iris it does nothing.
3. Redeploy the liquidation bot's Executor, a CREATE2 contract with a fixed address:
   iris-bots' `pnpm --filter @repo/contracts run deploy:executor`, signed with an anvil
   default key.
4. Re-index: point the indexer at the new fork's start block and redeploy it.

`./devnet/fund.sh <address> [eth] [usdc] [usdt]` sets balances for any test account.
It is the faucet.

## Consumers

Point `RPC_URL` (rfq CDK env) and the UI's network config at the public URL. The
indexer's `PONDER_RPC_URL_9991` / `PONDER_WS_URL_9991`, the cron's `RPC_URL_9991`, and
each bot's `RPC_URL_9991` use the internal hostname. Devnet transactions and EIP-712
signatures are invalid on mainnet and vice versa: nothing signed here can be replayed there.

## Rules of the road

- **Throwaway keys only.** The endpoint exposes anvil cheatcodes
  (`--auto-impersonate`, `anvil_setBalance`, …) — god-mode is the feature, and the
  hostname is public knowledge (Cloudflare's cert put it in CT logs), gated only by
  the rate limit. Assume strangers can read and mutate staging state; never sign
  with a real key. If unexplained state changes start happening, the planned fix is
  a Cloudflare Worker method filter: the public allowlist enumerates specific
  read-only methods plus `eth_sendRawTransaction` — never the whole `eth_*` prefix,
  because `eth_sendTransaction` under `--auto-impersonate` is an unauthenticated
  arbitrary-sender write — with cheatcodes behind a token path. Until then, recovery
  is "Reset and rebuild".
- The fork inherits mainnet state **as of its creation block**. Mainnet config done
  later does not appear here. Mirror it via scriptMaster's VNet arm, or reset.
