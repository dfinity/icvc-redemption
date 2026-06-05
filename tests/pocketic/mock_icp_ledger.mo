import Debug "mo:base/Debug";

/// Fault-injecting stand-in for the ICP ledger, used by PocketIC tests to make
/// the redemption flow's payout fail *after* the ICVC pull has already
/// committed — the one situation the bash suite (healthy ledgers) can't create.
///
/// It answers the redeem pre-check truthfully (a huge balance and a normal
/// fee, so `icp_balance < payout + fee` is false) and then fails
/// `icrc1_transfer` according to `failMode`:
///   0 = return `#Err(#TemporarilyUnavailable)` — a *clean* failure, which the
///       redeem flow handles with an in-line refund.
///   1 = trap — models a lost reply (the transfer may have committed on the
///       ledger), leaving the saga entry stuck in `#IcpSendPending`.
///
/// Only the three methods the redemption canister calls on its ICP ledger are
/// implemented (balance_of, fee, transfer); the rest of the ICRC interface is
/// never invoked on this principal.
persistent actor class MockIcpLedger(failMode : Nat) {
    type Account = { owner : Principal; subaccount : ?Blob };
    type TransferArg = {
        from_subaccount : ?Blob;
        to : Account;
        amount : Nat;
        fee : ?Nat;
        memo : ?Blob;
        created_at_time : ?Nat64;
    };
    type TransferError = {
        #BadFee : { expected_fee : Nat };
        #BadBurn : { min_burn_amount : Nat };
        #InsufficientFunds : { balance : Nat };
        #TooOld;
        #CreatedInFuture : { ledger_time : Nat64 };
        #Duplicate : { duplicate_of : Nat };
        #TemporarilyUnavailable;
        #GenericError : { error_code : Nat; message : Text };
    };
    type TransferResult = { #Ok : Nat; #Err : TransferError };

    public query func icrc1_balance_of(_ : Account) : async Nat {
        1_000_000_000_000_000; // 10M ICP — always passes the pool pre-check
    };

    public query func icrc1_fee() : async Nat { 10_000 };

    public shared func icrc1_transfer(_ : TransferArg) : async TransferResult {
        if (failMode == 1) {
            Debug.trap("mock ICP ledger: injected trap on icrc1_transfer");
        };
        #Err(#TemporarilyUnavailable);
    };
};
