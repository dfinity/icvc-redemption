"""Shared pytest fixtures for the PocketIC test harness.

PocketIC is a deterministic IC runtime that lets tests advance time
programmatically, install canisters in-process, and inspect state without
a live replica. We use it for the test gaps the bash integration suite
cannot deterministically cover (cooldown rounding, pool drain, refund
recovery).

The PocketIC server binary path defaults to the one bundled with dfx 0.30.2;
override with POCKET_IC_BIN.
"""

from __future__ import annotations

import dataclasses
import os
import pathlib
import subprocess

import pytest
from ic.candid import Types
from ic.principal import Principal
from pocket_ic import PocketIC

from ledgers import (
    ICP_MINTING_SUBACCOUNT,
    ICVC_MINTING_SUBACCOUNT,
    icrc1_init_args,
    redemption_init_args,
)


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
REDEMPTION_WASM = REPO_ROOT / ".icp/cache/artifacts/redemption"
ICRC1_LEDGER_WASM = REPO_ROOT / "ledger/ic-icrc1-ledger.wasm.gz"
DEFAULT_POCKET_IC_BIN = (
    pathlib.Path.home() / ".cache/dfinity/versions/0.30.2/pocket-ic"
)


# Test principals. The deployer is the admin the canister is installed
# with; the rest are regular users. All five are self-authenticating
# (i.e., non-anonymous) so the canister's `inspect_message` ingress
# filter and `Principal.isAnonymous(caller)` body checks treat them as
# legitimate identities.
DEPLOYER = Principal.self_authenticating(b"deployer-test-key-material-32b!!")
ALICE = Principal.from_str(
    "xccpo-hebie-npm75-p2f5b-pfess-6zyf2-tou33-dcd7t-tvivj-6fvap-gqe"
)
BOB = Principal.self_authenticating(b"bob-test-user-key-material-32b!!")
CAROL = Principal.self_authenticating(b"carol-test-user-key-material-32!")
DAVE = Principal.self_authenticating(b"dave-test-user-key-material-32!!")


def _ensure_pocket_ic_bin() -> None:
    if "POCKET_IC_BIN" in os.environ:
        return
    if DEFAULT_POCKET_IC_BIN.exists():
        os.environ["POCKET_IC_BIN"] = str(DEFAULT_POCKET_IC_BIN)
        return
    raise RuntimeError(
        "PocketIC server binary not found. Either install dfx (which bundles "
        "it at ~/.cache/dfinity/versions/<version>/pocket-ic) or set "
        "POCKET_IC_BIN to the path of the standalone binary."
    )


def _ensure_wasm(path: pathlib.Path, build_hint: str) -> None:
    if path.exists():
        return
    raise RuntimeError(f"Required wasm not found at {path}. {build_hint}")


@pytest.fixture
def pic() -> PocketIC:
    """Fresh PocketIC instance per test. State is wiped between cases."""
    _ensure_pocket_ic_bin()
    _ensure_wasm(REDEMPTION_WASM, "Run `icp build` from the repo root.")
    _ensure_wasm(
        ICRC1_LEDGER_WASM,
        "Should be committed at ledger/ic-icrc1-ledger.wasm.gz.",
    )
    return PocketIC()


@pytest.fixture
def redemption_wasm() -> bytes:
    return REDEMPTION_WASM.read_bytes()


@pytest.fixture
def icrc1_wasm() -> bytes:
    return ICRC1_LEDGER_WASM.read_bytes()


# ---- Deployment fixture ---------------------------------------------------

@dataclasses.dataclass
class Deployment:
    """Handle to a fully wired PocketIC deployment: both ledgers + redemption."""
    pic: PocketIC
    icvc_ledger: Principal
    icp_ledger: Principal
    redemption: Principal
    deployer: Principal


def _make_deployment(
    pic: PocketIC,
    redemption_wasm: bytes,
    icrc1_wasm: bytes,
    *,
    icvc_initial: int,
    icp_initial: int,
) -> Deployment:
    """Install ICVC + ICP ledgers and the redemption canister.

    Each ledger is initialised with the redemption canister as the recipient
    of `*_initial` e8s, mirroring the production deploy where the canister
    is pre-funded via ledger init args.
    """
    icvc_id = pic.create_canister()
    icp_id = pic.create_canister()
    redemption_id = pic.create_canister()

    for cid in (icvc_id, icp_id, redemption_id):
        pic.add_cycles(cid, 10_000_000_000_000)

    pic.install_code(
        canister_id=icvc_id,
        wasm_module=icrc1_wasm,
        arg=icrc1_init_args(
            minting_owner=DEPLOYER,
            minting_subaccount=ICVC_MINTING_SUBACCOUNT,
            controller=DEPLOYER,
            initial_balances=[(redemption_id, icvc_initial)],
            token_symbol="ICVC",
            token_name="ICVC Token",
        ),
    )

    pic.install_code(
        canister_id=icp_id,
        wasm_module=icrc1_wasm,
        arg=icrc1_init_args(
            minting_owner=DEPLOYER,
            minting_subaccount=ICP_MINTING_SUBACCOUNT,
            controller=DEPLOYER,
            initial_balances=[(redemption_id, icp_initial)],
            token_symbol="ICP",
            token_name="Internet Computer (Play)",
        ),
    )

    pic.install_code(
        canister_id=redemption_id,
        wasm_module=redemption_wasm,
        arg=redemption_init_args(
            icvc_ledger=icvc_id,
            icp_ledger=icp_id,
            admin=DEPLOYER,
        ),
    )

    return Deployment(
        pic=pic,
        icvc_ledger=icvc_id,
        icp_ledger=icp_id,
        redemption=redemption_id,
        deployer=DEPLOYER,
    )


@pytest.fixture
def deployment(pic, redemption_wasm, icrc1_wasm) -> Deployment:
    """Standard deployment: ICVC ledger pre-funds redemption with 20M ICVC
    (the faucet supply), ICP ledger pre-funds with 1000 ICP."""
    return _make_deployment(
        pic, redemption_wasm, icrc1_wasm,
        icvc_initial=2_000_000_000_000_000,   # 20M ICVC e8s
        icp_initial=100_000_000_000,          # 1000 ICP e8s
    )


@pytest.fixture
def small_pool_deployment(pic, redemption_wasm, icrc1_wasm) -> Deployment:
    """Deployment with a deliberately tiny ICP pool so the
    InsufficientIcpPool path is easy to exercise."""
    return _make_deployment(
        pic, redemption_wasm, icrc1_wasm,
        icvc_initial=2_000_000_000_000_000,   # 20M ICVC, plenty for redeems
        icp_initial=10_000_000,               # 0.1 ICP only
    )


# ICP cost of redeeming 100 ICVC at the fair-value derived rate, including the
# 10_000 e8s ICP ledger fee paid on the outbound transfer. Lets boundary tests
# size the pool to exactly one redeem.
ONE_REDEEM_ICP_COST_E8S = 100 * 5_753_022 + 10_000


@pytest.fixture
def boundary_pool_deployment(pic, redemption_wasm, icrc1_wasm) -> Deployment:
    """Deployment with ICP pool sized to exactly one redeem's payout + fee.
    First redeem must succeed (boundary inclusive); a second must reject."""
    return _make_deployment(
        pic, redemption_wasm, icrc1_wasm,
        icvc_initial=2_000_000_000_000_000,
        icp_initial=ONE_REDEEM_ICP_COST_E8S,
    )


# Three faucet calls' worth of ICVC plus their fees, sized to drain exactly.
# Each faucet sends 10_000 ICVC e8s = 10^12; ICVC ledger fee is 10_000 e8s.
TINY_FAUCET_ICVC_E8S = 3 * (10_000 * 100_000_000) + 3 * 10_000


@pytest.fixture
def tiny_faucet_deployment(pic, redemption_wasm, icrc1_wasm) -> Deployment:
    """Deployment with ICVC supply sized to exactly three faucet payouts
    plus their fees. The fourth faucet caller must hit the ICVC ledger's
    InsufficientFunds path."""
    return _make_deployment(
        pic, redemption_wasm, icrc1_wasm,
        icvc_initial=TINY_FAUCET_ICVC_E8S,
        icp_initial=100_000_000_000,  # normal ICP pool, unused in faucet tests
    )


# ---- Fault-injecting ICP ledger (for refund / #IcpSendPending tests) -------

MOCK_ICP_LEDGER_MO = pathlib.Path(__file__).parent / "mock_icp_ledger.mo"
MOCK_ICP_LEDGER_WASM = pathlib.Path(__file__).parent / "mock_icp_ledger.wasm"


def _build_mock_icp_ledger() -> bytes:
    """Compile the fault-injecting mock ICP ledger with moc (cached by mtime).

    Uses the same moc + base-lib sources mops gives the production build, so it
    stays in step with the toolchain. The .wasm is a gitignored build artifact.
    """
    src, wasm = MOCK_ICP_LEDGER_MO, MOCK_ICP_LEDGER_WASM
    if (not wasm.exists()) or wasm.stat().st_mtime < src.stat().st_mtime:
        moc = subprocess.run(
            ["mops", "toolchain", "bin", "moc"],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
        sources = subprocess.run(
            ["mops", "sources"],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True,
        ).stdout.split()
        subprocess.run(
            [moc, str(src), *sources, "-o", str(wasm)],
            cwd=REPO_ROOT, check=True,
        )
    return wasm.read_bytes()


@pytest.fixture
def mock_icp_wasm() -> bytes:
    return _build_mock_icp_ledger()


def make_faulty_icp_deployment(
    pic: PocketIC,
    redemption_wasm: bytes,
    icrc1_wasm: bytes,
    mock_icp_wasm: bytes,
    *,
    fail_mode: int,
) -> Deployment:
    """Real ICVC ledger + a fault-injecting mock ICP ledger.

    `fail_mode`: 0 = icrc1_transfer returns #Err (clean failure -> in-line
    refund); 1 = icrc1_transfer traps (lost reply -> entry stuck #IcpSendPending).
    """
    icvc_id = pic.create_canister()
    icp_id = pic.create_canister()
    redemption_id = pic.create_canister()
    for cid in (icvc_id, icp_id, redemption_id):
        pic.add_cycles(cid, 10_000_000_000_000)

    pic.install_code(
        canister_id=icvc_id,
        wasm_module=icrc1_wasm,
        arg=icrc1_init_args(
            minting_owner=DEPLOYER,
            minting_subaccount=ICVC_MINTING_SUBACCOUNT,
            controller=DEPLOYER,
            initial_balances=[(redemption_id, 2_000_000_000_000_000)],
            token_symbol="ICVC",
            token_name="ICVC Token",
        ),
    )
    pic.install_code(
        canister_id=icp_id,
        wasm_module=mock_icp_wasm,
        arg=[{"type": Types.Nat, "value": fail_mode}],
    )
    pic.install_code(
        canister_id=redemption_id,
        wasm_module=redemption_wasm,
        arg=redemption_init_args(
            icvc_ledger=icvc_id, icp_ledger=icp_id, admin=DEPLOYER,
        ),
    )
    return Deployment(
        pic=pic, icvc_ledger=icvc_id, icp_ledger=icp_id,
        redemption=redemption_id, deployer=DEPLOYER,
    )


# ---- General fault-injecting ledger (both roles, runtime-toggleable) -------

MOCK_LEDGER_MO = pathlib.Path(__file__).parent / "mock_ledger.mo"
MOCK_LEDGER_WASM = pathlib.Path(__file__).parent / "mock_ledger.wasm"


def _build_mock_ledger() -> bytes:
    """Compile the general mock ledger with moc (cached by mtime)."""
    src, wasm = MOCK_LEDGER_MO, MOCK_LEDGER_WASM
    if (not wasm.exists()) or wasm.stat().st_mtime < src.stat().st_mtime:
        moc = subprocess.run(
            ["mops", "toolchain", "bin", "moc"],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
        sources = subprocess.run(
            ["mops", "sources"],
            cwd=REPO_ROOT, capture_output=True, text=True, check=True,
        ).stdout.split()
        subprocess.run([moc, str(src), *sources, "-o", str(wasm)], cwd=REPO_ROOT, check=True)
    return wasm.read_bytes()


@pytest.fixture
def mock_ledger_wasm() -> bytes:
    return _build_mock_ledger()


def make_mock_deployment(
    pic: PocketIC,
    redemption_wasm: bytes,
    mock_ledger_wasm: bytes,
    *,
    icvc_transfer_mode: int,
    icp_transfer_mode: int,
) -> Deployment:
    """Both ledgers are the general mock. `*_transfer_mode`: 0=ok, 1=err, 2=trap
    (controls icrc1_transfer; transfer_from/approve always succeed). Tests can
    flip a ledger's mode mid-run via `setTransferFailMode`."""
    icvc_id = pic.create_canister()
    icp_id = pic.create_canister()
    redemption_id = pic.create_canister()
    for cid in (icvc_id, icp_id, redemption_id):
        pic.add_cycles(cid, 10_000_000_000_000)

    pic.install_code(
        canister_id=icvc_id, wasm_module=mock_ledger_wasm,
        arg=[{"type": Types.Nat, "value": icvc_transfer_mode}],
    )
    pic.install_code(
        canister_id=icp_id, wasm_module=mock_ledger_wasm,
        arg=[{"type": Types.Nat, "value": icp_transfer_mode}],
    )
    pic.install_code(
        canister_id=redemption_id, wasm_module=redemption_wasm,
        arg=redemption_init_args(icvc_ledger=icvc_id, icp_ledger=icp_id, admin=DEPLOYER),
    )
    return Deployment(
        pic=pic, icvc_ledger=icvc_id, icp_ledger=icp_id,
        redemption=redemption_id, deployer=DEPLOYER,
    )
