module {
    public type Account = {
        owner : Principal;
        subaccount : ?Blob;
    };

    public type TransferArg = {
        from_subaccount : ?Blob;
        to : Account;
        amount : Nat;
        fee : ?Nat;
        memo : ?Blob;
        created_at_time : ?Nat64;
    };

    public type TransferFromArg = {
        spender_subaccount : ?Blob;
        from : Account;
        to : Account;
        amount : Nat;
        fee : ?Nat;
        memo : ?Blob;
        created_at_time : ?Nat64;
    };

    public type TransferResult = {
        #Ok : Nat;
        #Err : TransferError;
    };

    public type TransferError = {
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

    public type ApproveArg = {
        from_subaccount : ?Blob;
        spender : Account;
        amount : Nat;
        expected_allowance : ?Nat;
        expires_at : ?Nat64;
        fee : ?Nat;
        memo : ?Blob;
        created_at_time : ?Nat64;
    };

    public type ApproveResult = {
        #Ok : Nat;
        #Err : ApproveError;
    };

    public type ApproveError = {
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

    public type AllowanceArg = {
        account : Account;
        spender : Account;
    };

    public type Allowance = {
        allowance : Nat;
        expires_at : ?Nat64;
    };

    public type ICRC1Interface = actor {
        icrc1_balance_of : shared query (Account) -> async Nat;
        icrc1_transfer : shared (TransferArg) -> async TransferResult;
        icrc1_fee : shared query () -> async Nat;
        icrc1_minting_account : shared query () -> async ?Account;
    };

    public type ICRC2Interface = actor {
        icrc2_approve : shared (ApproveArg) -> async ApproveResult;
        icrc2_transfer_from : shared (TransferFromArg) -> async TransferResult;
        icrc2_allowance : shared query (AllowanceArg) -> async Allowance;
    };

    public type LedgerInterface = actor {
        icrc1_balance_of : shared query (Account) -> async Nat;
        icrc1_transfer : shared (TransferArg) -> async TransferResult;
        icrc1_fee : shared query () -> async Nat;
        icrc1_minting_account : shared query () -> async ?Account;
        icrc2_approve : shared (ApproveArg) -> async ApproveResult;
        icrc2_transfer_from : shared (TransferFromArg) -> async TransferResult;
        icrc2_allowance : shared query (AllowanceArg) -> async Allowance;
    };
};
