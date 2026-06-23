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

    // ---- Re-entrancy test hook (for the per-id recovery-guard regression) ----
    // When armed, the FIRST icrc1_transfer this ledger receives calls BACK into
    // the redemption canister's forceRefund(id) *before* returning, deterministically
    // creating the concurrent-recovery interleave from inside the system (the
    // outer recovery call is parked at its transfer await, holding the per-id
    // guard, when the re-entrant call runs). One-shot, so the re-entrant call's
    // own transfer (on the buggy wasm) does not recurse. `transferCount` lets the
    // test assert exactly ONE refund transfer settled (guard) vs TWO (no guard).
    type RedemptionActor = actor {
        forceRefund : (Nat) -> async { #ok : Nat; #err : Text };
    };
    var reentrantTarget : ?Principal = null;
    var reentrantId : Nat = 0;
    var reentrantArmed : Bool = false;
    var transferCount : Nat = 0;

    public func setReentrantForceRefund(redemption : Principal, id : Nat) : async () {
        reentrantTarget := ?redemption;
        reentrantId := id;
        reentrantArmed := true;
    };
    public query func getTransferCount() : async Nat { transferCount };
    public func resetTransferCount() : async () { transferCount := 0 };

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
    public shared func icrc1_transfer(_ : TransferArg) : async TransferResult {
        transferCount += 1;
        if (reentrantArmed) {
            switch (reentrantTarget) {
                case (?p) {
                    reentrantArmed := false; // one-shot
                    let r : RedemptionActor = actor (Principal.toText(p));
                    // Re-enter while the outer recovery call is parked here.
                    ignore await r.forceRefund(reentrantId);
                };
                case null {};
            };
        };
        transferResult();
    };
    public shared func icrc2_transfer_from(_ : TransferFromArg) : async TransferResult { #Ok(0) };
    public shared func icrc2_approve(_ : ApproveArg) : async ApproveResult { #Ok(0) };
};
