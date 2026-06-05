import Debug "mo:base/Debug";
import Principal "mo:base/Principal";

/// General fault-injecting ICRC-1/2 ledger for PocketIC recovery tests. Unlike
/// `mock_icp_ledger.mo` (init-only, ICP role), this implements the full surface
/// the redemption canister calls on EITHER ledger and lets a test flip the
/// `icrc1_transfer` behavior at runtime via `setTransferFailMode`, so a refund
/// or burn can be made to fail first and then succeed on retry.
///
///   transferFailMode: 0 = ok (#Ok 0), 1 = err (#TemporarilyUnavailable), 2 = trap
///
/// `icrc2_transfer_from` (the pull) and `icrc2_approve` always succeed and move
/// nothing — these tests don't track real balances; they drive the saga's
/// success/failure branches. `icrc1_minting_account` returns a non-null account
/// so the burn path reaches the (mode-controlled) transfer.
persistent actor class MockLedger(initTransferFailMode : Nat) = self {
    var transferFailMode : Nat = initTransferFailMode;

    type Account = { owner : Principal; subaccount : ?Blob };
    type TransferArg = {
        from_subaccount : ?Blob; to : Account; amount : Nat; fee : ?Nat;
        memo : ?Blob; created_at_time : ?Nat64;
    };
    type TransferFromArg = {
        spender_subaccount : ?Blob; from : Account; to : Account; amount : Nat;
        fee : ?Nat; memo : ?Blob; created_at_time : ?Nat64;
    };
    type TransferError = {
        #BadFee : { expected_fee : Nat };
        #BadBurn : { min_burn_amount : Nat };
        #InsufficientFunds : { balance : Nat };
        #InsufficientAllowance : { allowance : Nat };
        #TooOld;
        #CreatedInFuture : { ledger_time : Nat64 };
        #Duplicate : { duplicate_of : Nat };
        #TemporarilyUnavailable;
        #GenericError : { error_code : Nat; message : Text };
    };
    type TransferResult = { #Ok : Nat; #Err : TransferError };
    type ApproveArg = {
        from_subaccount : ?Blob; spender : Account; amount : Nat;
        expected_allowance : ?Nat; expires_at : ?Nat64; fee : ?Nat;
        memo : ?Blob; created_at_time : ?Nat64;
    };
    type ApproveError = {
        #BadFee : { expected_fee : Nat };
        #InsufficientFunds : { balance : Nat };
        #AllowanceChanged : { current_allowance : Nat };
        #Expired : { ledger_time : Nat64 };
        #TooOld;
        #CreatedInFuture : { ledger_time : Nat64 };
        #Duplicate : { duplicate_of : Nat };
        #TemporarilyUnavailable;
        #GenericError : { error_code : Nat; message : Text };
    };
    type ApproveResult = { #Ok : Nat; #Err : ApproveError };

    /// Test control: flip the icrc1_transfer behavior at runtime.
    public func setTransferFailMode(m : Nat) : async () { transferFailMode := m };

    func transferResult() : TransferResult {
        if (transferFailMode == 2) { Debug.trap("mock ledger: injected trap on transfer") };
        if (transferFailMode == 1) { return #Err(#TemporarilyUnavailable) };
        #Ok(0);
    };

    public query func icrc1_balance_of(_ : Account) : async Nat { 1_000_000_000_000_000 };
    public query func icrc1_fee() : async Nat { 10_000 };
    public query func icrc1_minting_account() : async ?Account {
        ?{ owner = Principal.fromActor(self); subaccount = null };
    };
    public shared func icrc1_transfer(_ : TransferArg) : async TransferResult { transferResult() };
    public shared func icrc2_transfer_from(_ : TransferFromArg) : async TransferResult { #Ok(0) };
    public shared func icrc2_approve(_ : ApproveArg) : async ApproveResult { #Ok(0) };
};
