# Reproducible build & on-chain verification

This document explains how anyone can verify that the **redemption** canister
running on the IC was built from a specific commit in this repository, with no
trust in the deployer required.

The guarantee chain is:

```
this commit's source ──(deterministic build)──▶ wasm ──(sha256)──▶ hash
                                                                     │
                                            equals?  ◀───────────────┤
                                                                     │
   on-chain canister ──(read_state module_hash)──▶ hash  ◀──────────┘
```

If the rebuilt hash equals the committed hash **and** the on-chain
`module_hash`, then the live canister provably runs this source.

## Current mainnet deployment status

> **⚠️ A fix is committed but not yet deployed.** The committed reproducible
> hash (`redemption.wasm.sha256`, what `Dockerfile.build` / the
> `reproducible-build` CI job produce) is **`0ede0a2c…`** — source including the
> `sweepBurn`/`forceBurn` TOCTOU fix. The **live** mainnet redemption canister
> (`yofbu-hiaaa-aaaae-agaeq-cai`) still runs the previous build
> **`491dc324…`**. So a rebuild will *not* match the on-chain hash until the
> next redeploy:
>
> ```
> docker build --platform=linux/amd64 -f Dockerfile.build -t b .
> docker run --rm --platform=linux/amd64 -v "$PWD:/out" b cp /work/redemption.wasm /out/redemption.wasm
> sha256sum redemption.wasm                                   # 0ede0a2c…  (committed source)
> dfx canister info yofbu-hiaaa-aaaae-agaeq-cai --network ic  # Module hash: 0x491dc324…  (still live)
> ```
>
> This `0ede0a2c… (source) ≠ 491dc324… (live)` gap is expected and re-aligns on
> the next `scripts/deploy.sh -e ic`, which builds via `Dockerfile.build` and
> hash-gates against `redemption.wasm.sha256` before install.
>
> History of on-chain hashes: `eb1fedc3…` (original macOS arm64 build, not
> Linux-reproducible) → `491dc324…` (re-deployed from the Linux build to make it
> verifiable; **current live**) → `0ede0a2c…` (TOCTOU fix; committed, awaiting
> deploy).

> Scope: this covers the **redemption** canister, the only one whose source
> lives in this repo. The ledger, asset, and Internet Identity canisters ship
> as pre-built WASMs whose SHA-256s are pinned directly in
> [`icp.yaml`](./icp.yaml) (`type: pre-built` + `sha256:`); verifying those
> means matching them against the upstream DFINITY release artifacts.

## Why the build is reproducible

The output wasm is a pure function of a small, fully-pinned set of inputs:

| Input | Pinned by |
|---|---|
| **Platform (Linux x86_64)** | `Dockerfile.build` base image — see warning below |
| Motoko compiler (`moc 1.8.2`) | `mops.toml` `[toolchain]` |
| Base library (`base 0.12.1`) | `mops.toml` `[dependencies]` (exact version) |
| `ic-mops` CLI (resolves `mops sources`) | `Dockerfile.build` (`ic-mops@1.2.0`) |
| Source | the git commit |

> **⚠️ Platform is part of the contract.** `mops` fetches a *platform-specific*
> `moc` binary, and the macOS and Linux builds of the same `moc` version emit
> **different wasm** (different baked-in Motoko runtime), hence a different
> SHA-256. Reproducibility holds *within* a platform, not across. The committed
> hash and the deployed canister use **Linux x86_64** as the canonical
> reference. Verify on Linux x86_64, or — recommended — via `Dockerfile.build`,
> which pins the platform for you. A macOS host build will print a different
> hash; that is expected, not a tampering signal.

Given a fixed platform, `moc` is a deterministic compiler: it embeds no
timestamps, build paths, or randomness in its output, so two rebuilds of the
same source with the same `moc` produce byte-identical wasm. The redemption
wasm is installed **uncompressed**
(`scripts/deploy.sh` passes `--wasm .icp/cache/artifacts/redemption`, a raw
`.wasm`), so the IC `module_hash` is just the plain SHA-256 of that file — no
gzip normalization needed.

The expected hash is committed in [`redemption.wasm.sha256`](./redemption.wasm.sha256)
and re-asserted on every push/PR by the `reproducible-build` CI job.

## Verifying locally (host toolchain)

Fastest path if you already have `mops` installed **and are on Linux x86_64**
(on macOS the hash will differ by design — use the Docker path below):

```bash
bash scripts/verify-wasm.sh            # rebuild + compare to redemption.wasm.sha256
bash scripts/verify-wasm.sh --onchain  # also diff against the mainnet module_hash
```

The script prints the platform it ran on; if it is not `Linux x86_64`, a
mismatch against the committed hash is expected.

`--onchain` reads the live `module_hash` via `dfx canister info` (an anonymous
`read_state` call — no controller rights needed) and compares it to your
rebuild.

## Verifying hermetically (Docker — recommended for third parties)

This removes the "but my machine is different" variable:

```bash
git checkout <commit-or-tag>
docker build -f Dockerfile.build -t icvc-redemption-build .
docker run --rm icvc-redemption-build      # prints the wasm SHA-256
```

Compare the printed hash to:

1. `redemption.wasm.sha256` in this repo at that commit, and
2. the on-chain module hash (next section).

All three must be equal.

## Reading the on-chain module hash

Anyone can read a canister's module hash anonymously (it does not require being
a controller):

```bash
dfx canister info yofbu-hiaaa-aaaae-agaeq-cai --network ic
# -> Module hash: 0x<64 hex chars>
```

(`yofbu-hiaaa-aaaae-agaeq-cai` is the mainnet redemption canister; see
[`canister_ids.json`](./canister_ids.json).) Strip the `0x` and compare against
the rebuilt SHA-256.

## When the hash legitimately changes

Any source change to `src/redemption/` (or a `moc` / `base` version bump) will
change the hash. That is expected — refresh the committed hash in the same
commit:

```bash
bash scripts/verify-wasm.sh --write
git add redemption.wasm.sha256
```

Reviewers can then confirm the new hash reproduces, and after the next
mainnet upgrade the on-chain `module_hash` should match it. The hash changing
without a corresponding source change is the red flag the CI job exists to
catch.

## Residual caveats

- **Determinism is per-platform.** `moc` is deterministic for a fixed platform,
  but the `moc` binary itself differs across OS/arch (macOS vs Linux produce
  different wasm from identical source — confirmed: macOS gave
  `eb1fedc3…`, Linux x86_64 gives `491dc324…`). Always verify on the canonical
  platform (Linux x86_64 / `Dockerfile.build`). A cross-platform mismatch is
  expected and is **not** evidence of tampering; a *same-platform* mismatch is.
- **`Dockerfile.build` pins the base image by immutable `@sha256` digest**, so a
  retagged or compromised upstream `node` image cannot change the build
  environment (or run code at build time) underneath CI / mainnet builds. To
  refresh the base image for a security update, re-resolve the digest (the
  Dockerfile header has the two commands) and re-run `verify-wasm.sh --write` on
  Linux to update `redemption.wasm.sha256`.
- This verifies the **code** (module hash), not the canister's stable state or
  its controller set. Check controllers separately via the same
  `dfx canister info` output.
