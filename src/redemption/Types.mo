import Principal "mo:base/Principal";

module {
    public type Timestamp = Int;

    public type RedemptionRecord = {
        id : Nat;
        user : Principal;
        icvc_amount : Nat;
        icp_amount : Nat;
        timestamp : Timestamp;
        icvc_tx_id : Nat;
        icp_tx_id : Nat;
    };

    public type Stats = {
        // Note: the live ICP pool balance is NOT a field here. `getStats` is a
        // pure query; clients read the pool balance directly via
        // `icrc1_balance_of` on the ICP ledger (the on-chain truth). The
        // frontend computes the progress denominator as
        // `icrc1_balance_of(canister) + total_icp_distributed`.
        total_icvc_redeemed : Nat;
        total_icp_distributed : Nat;
        total_redemptions : Nat;
        exchange_rate_e8s : Nat;
        paused : Bool;
        /// Cumulative ICVC burned (sent to the ledger minting account) after
        /// successful redemptions. Redeemed ICVC is destroyed, not recycled.
        total_icvc_burned : Nat;
        /// Redeemed-but-not-yet-burned ICVC (= total_icvc_redeemed -
        /// total_icvc_burned). Normally 0; grows only if an inline burn failed,
        /// and is flushed by the admin `sweepBurn`.
        icvc_pending_burn : Nat;
    };

    public type RedemptionError = {
        #InsufficientAllowance;
        #InsufficientIcpPool;
        #TransferFromFailed : Text;
        #IcpTransferFailed : Text;
        /// ICP transfer failed AND the automatic refund also failed.
        /// The Nat is the failed-refund id; the caller (or admin) can invoke
        /// retryRefund(id) once the ledger is healthy.
        #NeedsRefund : Nat;
        #Paused;
        #BelowMinimum;
        #NotAuthorized;
        /// Another redeem call from the same caller is still in flight.
        #ConcurrentRedemption;
    };

    /// Saga journal status. An in-flight entry is written before the first
    /// ledger-mutating await and updated as the flow progresses, so a trap
    /// or upgrade leaves a recoverable trail.
    public type InFlightStatus = {
        /// Journal entry written, no ledger state change confirmed yet. If
        /// found after a trap the transfer_from MAY still have executed (its
        /// reply was lost), so reconcile via the dedup key before assuming no
        /// refund is needed.
        #Started;
        /// transfer_from succeeded; about to attempt (or attempting) the ICP
        /// send. Transient; superseded by #IcpSendPending in the same message
        /// slice. Retained for backward compatibility with pre-upgrade entries.
        #IcvcPulled : { icvc_tx_id : Nat };
        /// ICVC pulled and the ICP send is in flight — its outcome is UNKNOWN.
        /// This is the committed state while `icrc1_transfer` runs, so if it
        /// persists after a trap the ICP payout MAY have executed. Do NOT
        /// blind-refund: reconcile the ICP ledger (memo `redemption-<id>` +
        /// the dedup `created_at`) first. A *clean* ICP failure never lands
        /// here — it goes to #RefundPending.
        #IcpSendPending : { icvc_tx_id : Nat };
        /// ICP send failed (known) and the in-line refund also failed. Safe to
        /// retryRefund(id) once the ledger is healthy — the ICP definitely did
        /// not go out.
        #RefundPending : { icvc_tx_id : Nat; icp_error : Text; refund_error : Text };
    };

    public type InFlightRedemption = {
        id : Nat;
        user : Principal;
        icvc_amount : Nat;
        icp_amount : Nat;
        status : InFlightStatus;
        started_at : Timestamp;
        /// created_at_time passed to icrc2_transfer_from for this attempt.
        /// Embedded so a future reconciliation tool can use the ledger's
        /// dedup index (memo + created_at_time) to determine whether the
        /// pull actually executed before a trap. Zero is the sentinel for
        /// entries that pre-date the dedup-key tracking (migrated rows).
        icvc_dedup_created_at : Nat64;
        /// Wall-clock time of the last status transition / refund attempt.
        /// Lets triage gauge how long an entry has been stuck (vs `started_at`,
        /// which is fixed at creation).
        last_updated : Timestamp;
        /// Number of refund transfers issued for this entry (in-line +
        /// retryRefund). On a `#RefundPending` entry this is how many refund
        /// attempts have failed so far.
        refund_attempts : Nat;
    };

    /// Snapshot of the treasury-backing inputs the redemption rate is derived
    /// from, plus the derived rate itself. The inputs are compile-time
    /// constants in the canister (changed only via upgrade, visible on-chain
    /// via the module hash); `inputs_recorded_at` is the wall-clock time the
    /// data was pulled from the ledgers / WaterNeuron, baked in alongside.
    public type FairValueInputs = {
        icvc_total_supply_e8s : Nat;
        treasury_icp_e8s : Nat;
        treasury_nicp_e8s : Nat;
        /// WaterNeuron `get_info.exchange_rate`: nICP minted per 1 ICP, e8s.
        nicp_per_icp_e8s : Nat;
        /// Derived: treasury nICP valued in ICP e8s at `nicp_per_icp_e8s`.
        nicp_as_icp_e8s : Nat;
        /// Derived: total treasury backing in ICP e8s (ICP + nICP-as-ICP).
        backing_icp_e8s : Nat;
        /// Nanoseconds since the epoch; when the inputs were pulled on-chain.
        inputs_recorded_at : Timestamp;
        /// Derived: ICP e8s per 1 ICVC. Equals getExchangeRate().
        exchange_rate_e8s : Nat;
    };

    /// Unified status for the complete redemption log (getRedemptionLog).
    /// Completed entries come from the history; the rest mirror the saga
    /// journal's in-flight states.
    public type RedemptionStatus = {
        /// ICVC pulled and ICP sent — fully settled.
        #Completed;
        /// Journal entry written; the ICVC pull is not yet confirmed.
        #Started;
        /// ICVC pulled; about to send ICP (transient legacy state).
        #IcvcPulled;
        /// ICVC received, ICP send in flight — outcome unknown; reconcile before
        /// refunding (ICVC received but ICP not distributed).
        #IcpSendPending;
        /// ICP send failed and the auto-refund also failed; needs retryRefund.
        #RefundPending;
    };

    /// One row of the complete redemption log: every redemption, completed or
    /// in-flight, with a uniform status. `icvc_tx_id`/`icp_tx_id` are present
    /// only for the legs that actually executed, so e.g. status `#IcvcPulled`
    /// with `icvc_tx_id = ?_` and `icp_tx_id = null` reads as "ICVC received,
    /// ICP not distributed".
    public type RedemptionLogEntry = {
        id : Nat;
        user : Principal;
        icvc_amount : Nat;
        icp_amount : Nat;
        status : RedemptionStatus;
        timestamp : Timestamp;
        icvc_tx_id : ?Nat;
        icp_tx_id : ?Nat;
    };

    /// A redeemed-but-not-yet-burned amount awaiting `sweepBurn`. `created_at`
    /// is the pinned ICRC-1 dedup timestamp the retry must reuse.
    public type PendingBurn = {
        id : Nat;
        amount : Nat;
        created_at : Nat64;
    };

    public type InitArgs = {
        icvc_ledger_id : Principal;
        icp_ledger_id : Principal;
        admin : Principal;
    };

    /// Durable audit record of a privileged admin/recovery action. Appended by
    /// the canister whenever an authorised caller invokes a state-mutating
    /// admin method (pause/unpause, admin-allowlist changes, and the force/
    /// recovery actions). Public (anonymous-readable) for accountability:
    /// anyone can audit who did what, when. `id`/`detail` are best-effort
    /// context (affected redemption id, target principal).
    public type RecoveryLogEntry = {
        timestamp : Timestamp;
        caller : Principal;
        action : Text;
        id : ?Nat;
        detail : Text;
    };
};
