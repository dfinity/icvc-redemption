// IDL factories for the redemption canister and ICRC ledgers.
// Exported as a builder function because the runtime `IDL` object is loaded
// dynamically from `dfinity.js`; callers pass it in once at startup.
export function buildIdlFactories(IDL) {
    const Account = IDL.Record({ owner: IDL.Principal, subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)) });

    const TransferArg = IDL.Record({
        from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)), to: Account,
        amount: IDL.Nat, fee: IDL.Opt(IDL.Nat), memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
        created_at_time: IDL.Opt(IDL.Nat64),
    });
    const TransferError = IDL.Variant({
        BadFee: IDL.Record({ expected_fee: IDL.Nat }), BadBurn: IDL.Record({ min_burn_amount: IDL.Nat }),
        InsufficientFunds: IDL.Record({ balance: IDL.Nat }), TooOld: IDL.Null,
        CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }), TemporarilyUnavailable: IDL.Null,
        Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
        GenericError: IDL.Record({ error_code: IDL.Nat, message: IDL.Text }),
    });
    const ApproveArg = IDL.Record({
        from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)), spender: Account, amount: IDL.Nat,
        expected_allowance: IDL.Opt(IDL.Nat), expires_at: IDL.Opt(IDL.Nat64),
        fee: IDL.Opt(IDL.Nat), memo: IDL.Opt(IDL.Vec(IDL.Nat8)), created_at_time: IDL.Opt(IDL.Nat64),
    });
    const ApproveError = IDL.Variant({
        GenericError: IDL.Record({ message: IDL.Text, error_code: IDL.Nat }),
        TemporarilyUnavailable: IDL.Null, Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
        BadFee: IDL.Record({ expected_fee: IDL.Nat }), AllowanceChanged: IDL.Record({ current_allowance: IDL.Nat }),
        CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }), TooOld: IDL.Null,
        Expired: IDL.Record({ ledger_time: IDL.Nat64 }), InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
    });

    const ledgerIdl = ({ IDL: _IDL }) => IDL.Service({
        icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ["query"]),
        icrc1_fee: IDL.Func([], [IDL.Nat], ["query"]),
        icrc1_transfer: IDL.Func([TransferArg], [IDL.Variant({ Ok: IDL.Nat, Err: TransferError })], []),
        icrc2_approve: IDL.Func([ApproveArg], [IDL.Variant({ Ok: IDL.Nat, Err: ApproveError })], []),
    });

    const RedemptionRecord = IDL.Record({
        id: IDL.Nat, user: IDL.Principal, icvc_amount: IDL.Nat, icp_amount: IDL.Nat,
        timestamp: IDL.Int, icvc_tx_id: IDL.Nat, icp_tx_id: IDL.Nat,
    });
    const Stats = IDL.Record({
        icp_remaining: IDL.Nat,
        total_icvc_redeemed: IDL.Nat, total_icp_distributed: IDL.Nat,
        total_redemptions: IDL.Nat, exchange_rate_e8s: IDL.Nat, paused: IDL.Bool,
        total_icvc_burned: IDL.Nat, icvc_pending_burn: IDL.Nat,
    });
    const FairValueInputs = IDL.Record({
        icvc_total_supply_e8s: IDL.Nat, treasury_icp_e8s: IDL.Nat,
        treasury_nicp_e8s: IDL.Nat, nicp_per_icp_e8s: IDL.Nat,
        nicp_as_icp_e8s: IDL.Nat, backing_icp_e8s: IDL.Nat,
        inputs_recorded_at: IDL.Int, exchange_rate_e8s: IDL.Nat,
    });
    const RedemptionError = IDL.Variant({
        InsufficientAllowance: IDL.Null, InsufficientIcpPool: IDL.Null,
        TransferFromFailed: IDL.Text, IcpTransferFailed: IDL.Text,
        NeedsRefund: IDL.Nat,
        Paused: IDL.Null, BelowMinimum: IDL.Null, NotAuthorized: IDL.Null,
        ConcurrentRedemption: IDL.Null,
    });

    const redemptionIdl = ({ IDL: _IDL }) => IDL.Service({
        redeem: IDL.Func([IDL.Nat], [IDL.Variant({ ok: RedemptionRecord, err: RedemptionError })], []),
        getStats: IDL.Func([], [Stats], []),
        getRedemptionHistory: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Vec(RedemptionRecord)], ["query"]),
        getUserRedemptions: IDL.Func([IDL.Principal, IDL.Nat, IDL.Nat], [IDL.Vec(RedemptionRecord)], ["query"]),
        getExchangeRate: IDL.Func([], [IDL.Nat], ["query"]),
        getFairValueInputs: IDL.Func([], [FairValueInputs], ["query"]),
    });

    return { ledgerIdl, redemptionIdl };
}
