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

> Scope: this covers the **redemption** canister, the only one whose source
> lives in this repo. The ledger, asset, and Internet Identity canisters ship
> as pre-built WASMs whose SHA-256s are pinned directly in
> [`icp.yaml`](./icp.yaml) (`type: pre-built` + `sha256:`); verifying those
> means matching them against the upstream DFINITY release artifacts.

## Why the build is reproducible

The output wasm is a pure function of a small, fully-pinned set of inputs:

| Input | Pinned by |
|---|---|
| Motoko compiler (`moc 1.8.2`) | `mops.toml` `[toolchain]` |
| Base library (`base 0.12.1`) | `mops.toml` `[dependencies]` (exact version) |
| `ic-mops` CLI (resolves `mops sources`) | `Dockerfile.build` (`ic-mops@1.2.0`) |
| Source | the git commit |
| OS / libc (belt-and-braces) | `Dockerfile.build` base image |

`moc` is a deterministic compiler: it embeds no timestamps, build paths, or
randomness in its output. Two rebuilds of the same source with the same `moc`
produce byte-identical wasm. The redemption wasm is installed **uncompressed**
(`scripts/deploy.sh` passes `--wasm .icp/cache/artifacts/redemption`, a raw
`.wasm`), so the IC `module_hash` is just the plain SHA-256 of that file — no
gzip normalization needed.

The expected hash is committed in [`redemption.wasm.sha256`](./redemption.wasm.sha256)
and re-asserted on every push/PR by the `reproducible-build` CI job.

## Verifying locally (host toolchain)

Fastest path if you already have `mops` installed:

```bash
bash scripts/verify-wasm.sh            # rebuild + compare to redemption.wasm.sha256
bash scripts/verify-wasm.sh --onchain  # also diff against the mainnet module_hash
```

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

- **Cross-machine determinism** rests on `moc` being deterministic (it is) and
  on the toolchain versions matching. The Docker path pins these; the host
  path trusts your local `mops.toml`-resolved versions. If a host rebuild
  disagrees with the Docker rebuild, suspect a `moc` / `ic-mops` version skew.
- **`Dockerfile.build` pins the base image by tag, not digest.** For a fully
  hermetic build, pin `FROM node:...@sha256:<digest>` (noted inline in the
  Dockerfile). A moving tag changes the surrounding libc/coreutils, not `moc`,
  so it is very unlikely to affect the wasm — but digest-pinning removes the
  last variable.
- This verifies the **code** (module hash), not the canister's stable state or
  its controller set. Check controllers separately via the same
  `dfx canister info` output.
