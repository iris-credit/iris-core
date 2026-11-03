# devnet

Shared staging network: a long-lived anvil fork of Ethereum mainnet at chain id 9991
(the SDK's `ChainId.VNet`), consumed as a plain RPC URL by iris-rfq, iris-indexer,
iris-ui, and the iris-bots services.

- **Public RPC** (rfq, UI, wallets): `https://devnet.iris.credit`, and `wss://devnet.iris.credit`
  for `eth_subscribe`. It is Cloudflare-proxied and rate-limited to 50 req/10s per IP (a
  WebSocket counts once, when it connects). `devnet-proxy` (`proxy/`) serves it and forwards
  only standard JSON-RPC (reads, `eth_call`, `eth_estimateGas`, `eth_simulateV1`,
  `eth_sendRawTransaction`, …), checking every WebSocket message the same way. Cheatcodes,
  `eth_sendTransaction`, signing and tracing get a `-32601` error. Batches are capped at 1000
  calls.
- **Admin RPC** (`replay.sh`, `fund.sh`, scriptMaster's `VNET_RPC_URL`, the faucet's server):
  `https://devnet.iris.credit/admin/<ADMIN_TOKEN>` (and `wss://` on the same path) passes every
  method through, cheatcodes included. Treat the URL as a secret. The rate-limit rule matches
  only `/`, so this path skips it.
- **Internal RPC** (indexer, cron, bots; same Railway project): `http://devnet.railway.internal:8545`
  (`ws://` for subscriptions) is anvil's own port. It bypasses Cloudflare, the rate limit and
  the proxy entirely.

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
   - `FORK_BLOCK_NUMBER` (optional, normally unset): an epoch forks the head block, and the
     entrypoint records that block in `/data/fork-block`. Every later boot of the epoch
     forks the same block. Unpinned, anvil would re-fork the new head and lay the old
     snapshot over it, which mixes two mainnet heights: venue math reverts, and logs
     below the new fork block disappear. Set this only to force a specific block, and
     unset it before bumping `DEVNET_EPOCH`, or the new epoch reuses it.
   - `PORT` (set to `8545`): anvil's port, kept stable so project-internal consumers
     can address `devnet.railway.internal:8545`.
   - `ADMIN_TOKEN` (required for the admin RPC, 24+ characters): opens
     `/admin/<ADMIN_TOKEN>`. Unset or too short, that path is closed.
   - `PROXY_PORT` (optional, default `8080`): the proxy's port, which the custom domain
     targets.
4. Resource limits: cap the service's memory (anvil holds the forked state in RAM, and
   RAM is what Railway bills for) and keep a workspace usage limit set. The volume itself
   costs next to nothing.
5. Networking: add the custom domain `devnet.iris.credit` with **target port `8080`** (the
   proxy, never anvil's `8545`; `railway domain update devnet.iris.credit --port 8080`).
   Use a Cloudflare-proxied CNAME with zone SSL `Full`, then delete the Railway-generated
   domain so Cloudflare is the only door. The zone's rate-limit rule matches `http.request.uri.path eq "/"`
   — all JSON-RPC lands on `/`, and the free plan lacks per-hostname matching, so
   the rule is zone-wide; revisit if another `iris.credit` property hammers its root.
   Project-internal consumers use the Railway-internal hostname and skip all of this.

## Reset and rebuild

1. Set `DEVNET_EPOCH` to a new value and redeploy. The entrypoint deletes the state
   file and the recorded fork block, and anvil forks the current mainnet head. That block
   is recorded. Every boot moves the clock to now (never behind the last block): anvil
   otherwise restarts it at the fork block's timestamp and mines blocks back in time. A plain restart or
   redeploy keeps the state and the fork block, and so does a volume with no epoch marker
   yet (`/data/epoch`): it adopts the current epoch. A state file cut short mid-write is
   moved aside, rather than crash-looping the service; the recorded fork block stays.
2. From this repo, rebuild Iris and fund the staging actors:

   ```bash
   RPC_URL=https://devnet.iris.credit/admin/<ADMIN_TOKEN> SOLVER=0x… KEEPERS="0x… 0x… 0x…" ./devnet/replay.sh
   ```

   It deploys every contract at its recorded address (it explains how in its header)
   and stops if any address comes out different. It is idempotent: on a fork that
   already has Iris it does nothing.
3. Redeploy the liquidation bot's Executor, a CREATE2 contract with a fixed address:
   iris-bots' `pnpm --filter @repo/contracts run deploy:executor`, signed with an anvil
   default key.
4. Re-index: point the indexer at the new deploy blocks (iris-indexer `ponder/src/chains.ts`)
   and redeploy it. A rebuild on the same fork block, with nothing sent before
   `replay.sh`, lands on the same block numbers and needs only the redeploy.

`RPC_URL=<admin RPC> ./devnet/fund.sh <address> [eth] [usdc] [usdt]` sets balances for
any test account.

## Consumers

Point `RPC_URL` (rfq CDK env) and the UI's network config at the public URL. The
indexer's `PONDER_RPC_URL_9991` / `PONDER_WS_URL_9991`, the cron's `RPC_URL_9991`, and
each bot's `RPC_URL_9991` use the internal hostname. Devnet transactions and EIP-712
signatures are invalid on mainnet and vice versa: nothing signed here can be replayed there.

## Rules of the road

- **Throwaway keys only.** The hostname is public knowledge (Cloudflare's cert put it in
  CT logs). The public RPC refuses cheatcodes, but anyone can still send signed
  transactions, including from anvil's well-known default accounts. Never sign with a
  real key. Anyone holding the admin URL has god-mode: rotate `ADMIN_TOKEN` if it leaks.
  The proxy's allowlist names exact methods, never the whole `eth_*` prefix, because
  `eth_sendTransaction` under `--auto-impersonate` is an unauthenticated arbitrary-sender
  write.
- The fork inherits mainnet state **as of its creation block**. Mainnet config done
  later does not appear here. Mirror it via scriptMaster's VNet arm, or reset.
