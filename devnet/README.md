# devnet

Shared staging network: a long-lived anvil fork of Ethereum mainnet, consumed as
a plain RPC URL by iris-rfq, iris-indexer, and iris-ui.

- **Public RPC** (rfq, UI, solvers, scriptMaster's `VNET_RPC_URL`):
  `https://devnet.iris.credit` — Cloudflare-proxied, rate-limited 50 req/10s per IP.
- **Internal RPC** (indexer only; same Railway project): `http://devnet.railway.internal:8545`
  (`ws://` for subscriptions) — bypasses Cloudflare and its rate limit entirely.

Because it forks mainnet, the already-deployed Iris contracts (plus Aave, Morpho,
and every token in `CHAIN_ADDRESSES[ChainId.VNet]`, which mirrors mainnet)
exist on it from the first block — there is no deploy step. To test unreleased contract code, run a `forge script` from
this repo against the fork's URL like any other network.

## Railway setup (one-time)

1. New service from this repo, **root directory `devnet/`** (config is read from
   `railway.json`; watch paths keep contract-only pushes from redeploying it).
2. Attach a **volume mounted at `/data`** — anvil snapshots its state there
   (`--state`, every 60s), so restarts and redeploys keep staging history.
3. Environment variables:
   - `FORK_URL` (required): archive-capable mainnet RPC, e.g. a free Alchemy key.
   - `FORK_BLOCK_NUMBER` (optional): pin the fork base block for determinism.
     Unset = fork at whatever the head block is when the service boots. If set, it
     must be ≥ `25_572_166` (the Jul 20 redeploy) so the current contracts exist.
   - `PORT` (set to `8545`): keeps the listening port stable so project-internal
     consumers can address `devnet.railway.internal:8545`.
4. Networking: add the custom domain `devnet.iris.credit` (Cloudflare-proxied
   CNAME, zone SSL `Full`), then delete the Railway-generated domain so Cloudflare
   is the only door. The zone's rate-limit rule matches `http.request.uri.path eq "/"`
   — all JSON-RPC lands on `/`, and the free plan lacks per-hostname matching, so
   the rule is zone-wide; revisit if another `iris.credit` property hammers its root.
   The indexer uses the Railway-internal hostname and skips all of this.

## Consumers

Point `RPC_URL` (rfq CDK env) and the UI's network config at the public URL; the
indexer's `PONDER_RPC_URL_9991` / `PONDER_WS_URL_9991` / `RPC_URL_9991` use the
internal hostname. Chain id is 9991 — the SDK's `ChainId.VNet` — so
`CHAIN_ADDRESSES` resolve unchanged while devnet transactions and EIP-712 signatures
are invalid on mainnet and vice versa: nothing signed here can be replayed there.

## Rules of the road

- **Throwaway keys only.** The endpoint exposes anvil cheatcodes
  (`--auto-impersonate`, `anvil_setBalance`, …) — god-mode is the feature, and the
  hostname is public knowledge (Cloudflare's cert put it in CT logs), gated only by
  the rate limit. Assume strangers can read and mutate staging state; never sign
  with a real key. If unexplained state changes start happening, the planned fix is
  a Cloudflare Worker method filter (public: `eth_*` reads + `eth_sendRawTransaction`;
  cheatcodes behind a token path).
- The fork inherits mainnet state **as of its creation block**. Mainnet config done
  later (enable ops, BLM params, solver whitelisting) does not appear here — mirror
  it via scriptMaster's VNet arm, or reset state to re-fork from head.
- Test balances come from RPC calls against this endpoint (the UI's dev faucet
  button, `cast rpc anvil_setBalance …`); there is no faucet service. For ERC20s,
  impersonate a whale and `transfer` — the path that also works for stETH.
- State is disposable by design: to reset staging, delete `/data/state.json` and
  restart the service.
