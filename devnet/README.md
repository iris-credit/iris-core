# devnet

Shared staging network: a long-lived anvil fork of Ethereum mainnet, consumed as
a plain RPC URL by iris-rfq, iris-indexer, and iris-ui.

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
4. Expose the service publicly for the UI and solvers; the indexer should use the
   Railway-internal hostname instead.

## Consumers

Point `RPC_URL` (rfq CDK env), the indexer's ponder RPC env, and the UI's network
config at the service URL. Chain id is 9991 — the SDK's `ChainId.VNet` — so
`CHAIN_ADDRESSES` resolve unchanged while devnet transactions and EIP-712 signatures
are invalid on mainnet and vice versa: nothing signed here can be replayed there.

## Rules of the road

- **Throwaway keys only.** The endpoint exposes anvil cheatcodes
  (`--auto-impersonate`, `anvil_setBalance`, …) to anyone holding the URL —
  god-mode is the feature. Keep the URL unguessable; never sign with a real key.
- Test balances come from RPC calls against this endpoint (the UI's dev faucet
  button, `cast rpc anvil_setBalance …`); there is no faucet service. For ERC20s,
  impersonate a whale and `transfer` — the path that also works for stETH.
- State is disposable by design: to reset staging, delete `/data/state.json` and
  restart the service.
