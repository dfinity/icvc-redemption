"""Candid encoding helpers for the ICRC-1 ledger and the redemption canister.

These mirror the init args used by scripts/deploy.sh for -e local, so the
PocketIC harness can install the same ledger code with the same shape as a
real local deploy. Amounts and balances are parameterised so individual
tests can shrink the ICP pool to exercise the InsufficientIcpPool path.
"""

from ic.candid import Types
from ic.principal import Principal


# ---- Account type (used by ICRC-1 records) --------------------------------

def _account_type():
    return Types.Record({
        "owner": Types.Principal,
        "subaccount": Types.Opt(Types.Vec(Types.Nat8)),
    })


def _account_value(owner: Principal, subaccount: bytes | None = None):
    return {
        "owner": owner.bytes,
        "subaccount": [subaccount] if subaccount is not None else [],
    }


# Two distinct minting subaccounts so the ICVC and ICP ledgers don't share one,
# matching scripts/deploy.sh.
ICVC_MINTING_SUBACCOUNT = b"\x00" * 31 + b"\x01"
ICP_MINTING_SUBACCOUNT = b"\x00" * 31 + b"\x02"


# ---- Archive options ------------------------------------------------------

def _archive_options_type():
    return Types.Record({
        "num_blocks_to_archive": Types.Nat64,
        "max_transactions_per_response": Types.Opt(Types.Nat64),
        "trigger_threshold": Types.Nat64,
        "max_message_size_bytes": Types.Opt(Types.Nat64),
        "cycles_for_archive_creation": Types.Opt(Types.Nat64),
        "node_max_memory_size_bytes": Types.Opt(Types.Nat64),
        "controller_id": Types.Principal,
        "more_controller_ids": Types.Opt(Types.Vec(Types.Principal)),
    })


def _archive_options_value(controller: Principal):
    return {
        "num_blocks_to_archive": 1000,
        "max_transactions_per_response": [],
        "trigger_threshold": 2000,
        "max_message_size_bytes": [],
        "cycles_for_archive_creation": [10_000_000_000_000],
        "node_max_memory_size_bytes": [],
        "controller_id": controller.bytes,
        "more_controller_ids": [],
    }


# ---- Init args for the ICRC-1 ledger --------------------------------------
#
# Variant { Init = record { … } }. We only ever use the Init variant in the
# PocketIC tests; the Upgrade variant is for future schema migrations on a
# live ledger and isn't exercised here.

def _init_args_record_type():
    return Types.Record({
        "minting_account": _account_type(),
        "fee_collector_account": Types.Opt(_account_type()),
        "transfer_fee": Types.Nat,
        "decimals": Types.Opt(Types.Nat8),
        "max_memo_length": Types.Opt(Types.Nat16),
        "token_symbol": Types.Text,
        "token_name": Types.Text,
        "metadata": Types.Vec(Types.Tuple(Types.Text, Types.Text)),
        "initial_balances": Types.Vec(Types.Tuple(_account_type(), Types.Nat)),
        "feature_flags": Types.Opt(Types.Record({"icrc2": Types.Bool})),
        "maximum_number_of_accounts": Types.Opt(Types.Nat64),
        "accounts_overflow_trim_quantity": Types.Opt(Types.Nat64),
        "archive_options": _archive_options_type(),
    })


def _ledger_arg_variant_type():
    return Types.Variant({
        "Init": _init_args_record_type(),
        "Upgrade": Types.Opt(Types.Null),
    })


def icrc1_init_args(
    *,
    minting_owner: Principal,
    minting_subaccount: bytes,
    controller: Principal,
    initial_balances: list[tuple[Principal, int]],
    token_symbol: str,
    token_name: str,
    transfer_fee: int = 10_000,
) -> list:
    """Return list-form (encoded by pocket-ic's install_code) for the
    LedgerArg variant on the official ICRC-1 ledger."""
    return [{
        "type": _ledger_arg_variant_type(),
        "value": {
            "Init": {
                "minting_account": _account_value(minting_owner, minting_subaccount),
                "fee_collector_account": [],
                "transfer_fee": transfer_fee,
                "decimals": [8],
                "max_memo_length": [256],
                "token_symbol": token_symbol,
                "token_name": token_name,
                "metadata": [],
                "initial_balances": [
                    (_account_value(owner), amount)
                    for owner, amount in initial_balances
                ],
                "feature_flags": [{"icrc2": True}],
                "maximum_number_of_accounts": [],
                "accounts_overflow_trim_quantity": [],
                "archive_options": _archive_options_value(controller),
            },
        },
    }]


# ---- Init args for the redemption canister --------------------------------

def redemption_init_args(
    *,
    icvc_ledger: Principal,
    icp_ledger: Principal,
    admin: Principal,
) -> list:
    """Return list-form for the redemption canister's InitArgs record.

    The exchange rate is no longer an init arg — it is derived on-chain from
    the fair-value backing constants (see #27)."""
    return [{
        "type": Types.Record({
            "icvc_ledger_id": Types.Principal,
            "icp_ledger_id": Types.Principal,
            "admin": Types.Principal,
        }),
        "value": {
            "icvc_ledger_id": icvc_ledger.bytes,
            "icp_ledger_id": icp_ledger.bytes,
            "admin": admin.bytes,
        },
    }]
