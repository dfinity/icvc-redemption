import Principal "mo:base/Principal";
import Buffer "mo:base/Buffer";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Result "mo:base/Result";
import Array "mo:base/Array";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Int "mo:base/Int";
import Text "mo:base/Text";

import Types "Types";
import Ledger "Ledger";
import Pure "Pure";

persistent actor class RedemptionCanister(init : Types.InitArgs) = self {

    // ====================================================================
    // Constants
    // ====================================================================
    transient let MIN_REDEMPTION : Nat = 10 * 100_000_000;      // 10 ICVC minimum (~0.62 ICP)
    transient let REDEEM_LOCK_TTL_NS : Int = 60 * 1_000_000_000;

    // ====================================================================
    // Fair-value backing inputs (the redemption rate is DERIVED from these)
    // ====================================================================
    // The exchange rate is not a hand-picked constant; it is the ICVC DAO
    // treasury's backing per ICVC token: (treasury ICP + treasury nICP valued
    // in ICP) / total ICVC supply. The four inputs below are pulled from
    // on-chain truth and baked in as constants. Changing them requires a code
    // upgrade (visible on-chain via the new module hash) — there is no runtime
    // setter, preserving the H2 immutability property. See `fairValueRate()`.
    //
    // Snapshot pulled 2026-06-18 COB (nanoseconds since epoch below):
    //   ICVC total supply  : icrc1_total_supply on ICVC ledger m6xut-mqaaa-aaaaq-aadua-cai
    //   Treasury ICP       : icrc1_balance_of(governance ntzq5-…) on ICP ledger ryjl3-…
    //   Treasury nICP      : icrc1_balance_of(governance ntzq5-…) on nICP ledger buwm7-7yaaa-aaaar-qagva-cai
    //   nICP per ICP (e8s) : get_info.exchange_rate on WaterNeuron tsbvt-pyaaa-aaaar-qafva-cai
    //
    // Update vs the prior 2026-06-02 snapshot: treasury ICP and nICP are
    // unchanged, and ICVC total supply moved by ~0.0009 ICVC (rounding noise).
    // The only material change is the WaterNeuron rate (79_545_698 → 79_295_072).
    // The derived redemption rate therefore barely moves:
    //   5_753_022 → 5_758_856 e8s  (+0.10%)  =  0.05753022 → 0.05758856 ICP per ICVC.
    transient let ICVC_TOTAL_SUPPLY_E8S : Nat = 1_999_998_744_410_000;
    transient let TREASURY_ICP_E8S : Nat = 78_145_768_936_670;
    transient let TREASURY_NICP_E8S : Nat = 29_363_979_466_056;
    transient let NICP_PER_ICP_E8S : Nat = 79_295_072;
    transient let FAIR_VALUE_INPUTS_RECORDED_AT_NS : Int = 1_781_740_800_000_000_000; // 2026-06-18 00:00 UTC

    /// Derive the redemption rate (ICP e8s per 1 ICVC) from the fair-value
    /// backing constants above. Used to initialise `exchange_rate_e8s` on
    /// install and to recompute it on upgrade. Defined here (before the var
    /// that consumes it) because Motoko evaluates value initialisers in order;
    /// the pure logic lives in Pure.mo for unit testing.
    func fairValueRate() : Nat {
        Pure.computeFairValueRate(
            ICVC_TOTAL_SUPPLY_E8S,
            TREASURY_ICP_E8S,
            TREASURY_NICP_E8S,
            NICP_PER_ICP_E8S,
        );
    };

    // ====================================================================
    // External ledgers (set once at install from init args)
    // ====================================================================
    transient let icvc_ledger : Ledger.LedgerInterface = actor (Principal.toText(init.icvc_ledger_id));
    transient let icp_ledger : Ledger.LedgerInterface = actor (Principal.toText(init.icp_ledger_id));

    // ====================================================================
    // Authorisation
    // ====================================================================
    /// Admin allowlist. Seeded from init.admin on first install; thereafter
    /// mutated only via addAdmin / removeAdmin. removeAdmin refuses to leave
    /// the list empty so a misclick cannot lock the canister out.
    var admins : [Principal] = [init.admin];

    // ====================================================================
    // Configuration (admin-settable)
    // ====================================================================
    // Redemption rate, derived from the fair-value backing inputs above. Kept
    // as a stable `var` (rather than a transient computed `let`) so the stable
    // schema is unchanged across this feature; it is (re)computed from the
    // constants on install and on every upgrade (see postupgrade), so an
    // upgrade that bumps the inputs takes effect immediately.
    var exchange_rate_e8s : Nat = fairValueRate();
    var paused : Bool = false;

    // ====================================================================
    // Pool accounting
    // ====================================================================
    var totalIcvcRedeemed : Nat = 0;
    var totalIcpDistributed : Nat = 0;
    var nextRedemptionId : Nat = 0;

    // ====================================================================
    // Burn accounting
    // ====================================================================
    // Redeemed ICVC is destroyed (sent to the ledger's minting account), not
    // held or recycled, so the redeemed supply leaves circulation for good.
    // The burn happens as the LAST step of a *successful* redeem — never at
    // pull time — because burning is irreversible and the canister has no
    // minting authority to undo it; doing it after the ICP send means a failed
    // swap is still refundable (the ICVC is still in the canister). Burning the
    // exact redeemed `amount` (not the raw balance) is also robust to any other
    // ICVC the canister might hold.
    var totalIcvcBurned : Nat = 0;
    // Per-redemption burns that did not confirm inline: (redemptionId, amount,
    // dedup created_at). `sweepBurn` retries each with the SAME dedup tuple, so
    // a burn whose response was lost (but committed) returns Duplicate rather
    // than burning twice. Invariant: totalIcvcRedeemed = totalIcvcBurned +
    // sum(pendingBurns.amount).
    var pendingBurns : [(Nat, Nat, Nat64)] = [];
    // Cached ICVC minting account (the burn destination), looked up lazily from
    // the ledger. Transient: re-fetched after an upgrade, never persisted.
    transient var icvcMintingAccount : ?Ledger.Account = null;

    // ====================================================================
    // Persisted state (stable backing for Buffer / HashMap collections)
    // ====================================================================
    var stableRedemptions : [(Nat, Types.RedemptionRecord)] = [];
    /// Saga journal stable backing. The dedup `created_at_time` lives inside
    /// each entry (`icvc_dedup_created_at`). The legacy `dedupKeys` parallel
    /// map and `stableFailedRefunds` buffer were folded into here by
    /// `Migration.migrate` on the upgrade that landed this PR.
    var stableInFlight : [Types.InFlightRedemption] = [];

    // ====================================================================
    // Runtime collections (transient, restored from stable in postupgrade)
    // ====================================================================
    transient let redemptions = Buffer.Buffer<Types.RedemptionRecord>(0);
    /// Saga journal: entries written before the first ledger-mutating await,
    /// updated as the flow progresses, removed on clean completion. A trap
    /// or upgrade leaves entries here so admin (or the user via retryRefund)
    /// can reconcile.
    transient let inFlight = Buffer.Buffer<Types.InFlightRedemption>(0);

    // ====================================================================
    // Locks (transient, intentionally not persisted across upgrades)
    // ====================================================================
    // Per-caller redeem lock. Value is acquisition time in ns. A trapping
    // redeem can leave the lock orphaned; REDEEM_LOCK_TTL_NS bounds the
    // window during which a stuck principal is locked out.
    transient let pendingRedemptions = HashMap.HashMap<Principal, Int>(16, Principal.equal, Principal.hash);

    // ---- Ingress filter ----
    //
    // `canister_inspect_message` runs on a single replica without consensus,
    // so it is **not a security boundary** (per the canister-security skill):
    // every method below still validates `caller` in its body. The point is
    // to cheaply drop obviously-bad ingress messages (anonymous callers on
    // update methods that require authentication) before they cost full
    // update-call cycles. `getStats` stays open to anonymous calls because
    // the frontend reads it without auth.
    system func inspect({
        caller : Principal;
        arg : Blob;
        msg : {
            #addAdmin : () -> (newAdmin : Principal);
            #forceCloseInFlight : () -> (id : Nat);
            #forceRefund : () -> (id : Nat);
            #getDedupKey : () -> (id : Nat);
            #getExchangeRate : () -> ();
            #getFairValueInputs : () -> ();
            #getInFlight : () -> ();
            #getPendingBurns : () -> ();
            #getMyInFlight : () -> ();
            #getRedemptionHistory : () -> (offset : Nat, limit : Nat);
            #getRedemptionLog : () -> (offset : Nat, limit : Nat);
            #getStats : () -> ();
            #getUserRedemptions :
                () -> (user : Principal, offset : Nat, limit : Nat);
            #listAdmins : () -> ();
            #pause : () -> ();
            #redeem : () -> (amount : Nat);
            #removeAdmin : () -> (toRemove : Principal);
            #retryRefund : () -> (id : Nat);
            #sweepBurn : () -> ();
            #forceBurn : () -> ();
            #unpause : () -> ();
        };
    }) : Bool {
        ignore arg;
        if (not Principal.isAnonymous(caller)) return true;
        // For anonymous callers, drop only the **update** methods that the
        // canister body rejects anyway. Queries pass through so their bodies
        // can return their normal error variants (`#NotAuthorized`, etc.) —
        // those are useful diagnostics for clients and cheap to produce.
        // `getStats` is anonymous-readable (the frontend depends on it).
        switch (msg) {
            case (#redeem _) false;
            case (#retryRefund _) false;
            case (#sweepBurn _) false;
            case (#forceBurn _) false;
            case (#forceCloseInFlight _) false;
            case (#forceRefund _) false;
            case (#pause _) false;
            case (#unpause _) false;
            case (#addAdmin _) false;
            case (#removeAdmin _) false;
            case _ true;
        };
    };

    // ---- Upgrade hooks ----
    system func preupgrade() {
        stableRedemptions := Array.tabulate<(Nat, Types.RedemptionRecord)>(
            redemptions.size(),
            func(i) = (i, redemptions.get(i))
        );
        stableInFlight := Buffer.toArray(inFlight);
        // pendingRedemptions is intentionally not persisted: in-flight locks
        // are meaningless after an upgrade drains messages.
    };

    system func postupgrade() {
        for ((_, r) in stableRedemptions.vals()) {
            redemptions.add(r);
        };
        for (entry in stableInFlight.vals()) {
            inFlight.add(entry);
        };
        stableRedemptions := [];
        stableInFlight := [];
        // Recompute the rate from the (possibly bumped) backing constants. The
        // persisted value is intentionally discarded: the constants in this
        // wasm are the source of truth, so an upgrade that changes them takes
        // effect here rather than being shadowed by the old stable value.
        exchange_rate_e8s := fairValueRate();
    };

    // ---- Helpers ----
    func selfAccount() : Ledger.Account {
        { owner = Principal.fromActor(self); subaccount = null };
    };

    func callerAccount(caller : Principal) : Ledger.Account {
        { owner = caller; subaccount = null };
    };

    func isAdmin(p : Principal) : Bool {
        for (a in admins.vals()) {
            if (Principal.equal(a, p)) return true;
        };
        false;
    };

    /// Local wrapper so the actor body reads naturally; the real logic lives
    /// in Pure.mo where it can be unit-tested without a replica.
    func calculateIcpPayout(icvc_amount : Nat) : Nat {
        Pure.calculateIcpPayout(icvc_amount, exchange_rate_e8s);
    };

    /// The ICVC ledger's minting account (burn destination), cached after the
    /// first lookup. Returns null only if the ledger reports no minting account.
    func mintingAccount() : async ?Ledger.Account {
        switch (icvcMintingAccount) {
            case (?a) ?a;
            case null {
                let acct = await icvc_ledger.icrc1_minting_account();
                icvcMintingAccount := acct;
                acct;
            };
        };
    };

    /// Burn `amount` ICVC by transferring it from the canister to the ledger's
    /// minting account (an ICRC-1 burn: no fee). `created_at_time` is pinned to
    /// the redemption's dedup timestamp and the memo to `burn-<id>`, so a retry
    /// after a lost response shares the dedup tuple and the ledger returns
    /// Duplicate instead of burning twice. Returns the burn tx id (or the
    /// duplicate's id) on success.
    func burnIcvc(amount : Nat, id : Nat, createdAt : Nat64) : async Result.Result<Nat, Text> {
        let mint = switch (await mintingAccount()) {
            case (?a) a;
            case null { return #err("ICVC ledger has no minting account; cannot burn"); };
        };
        let result = await icvc_ledger.icrc1_transfer({
            from_subaccount = null;
            to = mint;
            amount = amount;
            fee = null; // burns to the minting account are fee-less
            memo = ?Text.encodeUtf8("burn-" # Nat.toText(id));
            created_at_time = ?createdAt;
        });
        switch (result) {
            case (#Ok(txId)) #ok(txId);
            // An earlier attempt with the same dedup tuple already burned these
            // tokens; the response was lost. Treat as success — do not re-burn.
            case (#Err(#Duplicate({ duplicate_of }))) #ok(duplicate_of);
            case (#Err(err)) #err(debug_show (err));
        };
    };

    /// Best-effort per-caller lock. Returns false if a non-expired lock
    /// is already held by `caller`. Stale locks (older than the TTL) are
    /// taken over, so a trapping redeem auto-recovers.
    func tryAcquireRedeemLock(caller : Principal) : Bool {
        let now = Time.now();
        switch (pendingRedemptions.get(caller)) {
            case (?acquiredAt) {
                if (now - acquiredAt < REDEEM_LOCK_TTL_NS) return false;
            };
            case null { };
        };
        pendingRedemptions.put(caller, now);
        true;
    };

    func releaseRedeemLock(caller : Principal) {
        pendingRedemptions.delete(caller);
    };

    func findInFlightIndex(id : Nat) : ?Nat {
        let size = inFlight.size();
        if (size == 0) return null;
        for (i in Iter.range(0, size - 1)) {
            if (inFlight.get(i).id == id) return ?i;
        };
        null;
    };

    func removeInFlightAt(idx : Nat) {
        let arr = Buffer.toArray(inFlight);
        inFlight.clear();
        var i : Nat = 0;
        while (i < arr.size()) {
            if (i != idx) inFlight.add(arr[i]);
            i += 1;
        };
    };

    func removeInFlightById(id : Nat) {
        switch (findInFlightIndex(id)) {
            case (?idx) { removeInFlightAt(idx); };
            case null { };
        };
    };

    /// Update status of an existing in-flight entry, stamping `last_updated`.
    /// No-op if not found.
    func setInFlightStatus(id : Nat, newStatus : Types.InFlightStatus) {
        switch (findInFlightIndex(id)) {
            case (?idx) {
                let entry = inFlight.get(idx);
                inFlight.put(idx, { entry with status = newStatus; last_updated = Time.now() });
            };
            case null { };
        };
    };

    /// Record that a refund transfer is being issued for an entry: bumps the
    /// attempt counter and `last_updated`. No-op if not found.
    func bumpRefundAttempt(id : Nat) {
        switch (findInFlightIndex(id)) {
            case (?idx) {
                let entry = inFlight.get(idx);
                inFlight.put(idx, { entry with refund_attempts = entry.refund_attempts + 1; last_updated = Time.now() });
            };
            case null { };
        };
    };

    /// Lookup the dedup `created_at_time` for an in-flight redemption.
    /// Returns `null` if the id is not in the journal, `?0` for entries
    /// that pre-date Phase 2.6's dedup-key tracking (migrated rows).
    func lookupDedupKey(id : Nat) : ?Nat64 {
        switch (findInFlightIndex(id)) {
            case (?idx) ?inFlight.get(idx).icvc_dedup_created_at;
            case null null;
        };
    };

    // ---- Redeem internals ----
    //
    // The redeem flow is three ledger calls (transfer_from, transfer, optional
    // refund) interleaved with saga-journal updates. Each step is extracted
    // into its own helper so the top-level redeem reads as a narrative and so
    // the journal state transitions are concentrated where they happen.

    /// Step 1: pull ICVC from `caller` into the canister. Updates the saga
    /// journal status from #Started to #IcvcPulled on success; drops the
    /// entry on failure (no ledger state change to recover from). Returns
    /// the ledger transaction id on success.
    func pullIcvc(
        redemptionId : Nat,
        caller : Principal,
        amount : Nat,
        memoBlob : Blob,
        createdAt : Nat64,
    ) : async Result.Result<Nat, Types.RedemptionError> {
        let result = await icvc_ledger.icrc2_transfer_from({
            spender_subaccount = null;
            from = callerAccount(caller);
            to = selfAccount();
            amount = amount;
            fee = null;
            memo = ?memoBlob;
            created_at_time = ?createdAt;
        });
        switch (result) {
            case (#Ok(id)) {
                setInFlightStatus(redemptionId, #IcvcPulled({ icvc_tx_id = id }));
                #ok(id);
            };
            case (#Err(err)) {
                removeInFlightById(redemptionId);
                #err(#TransferFromFailed(debug_show(err)));
            };
        };
    };

    /// Step 2: send the ICP payout to `caller`. Pure ledger call; the saga
    /// journal is updated by the calling site so success and failure can
    /// share the same try/finally lock release.
    func sendIcp(
        caller : Principal,
        payout : Nat,
        fee : Nat,
        memoBlob : Blob,
        createdAt : Nat64,
    ) : async Result.Result<Nat, Text> {
        let result = await icp_ledger.icrc1_transfer({
            from_subaccount = null;
            to = callerAccount(caller);
            amount = payout;
            fee = ?fee;
            memo = ?memoBlob;
            created_at_time = ?createdAt;
        });
        switch (result) {
            case (#Ok(id)) #ok(id);
            case (#Err(err)) #err(debug_show(err));
        };
    };

    /// Step 2b: ICP send failed. Attempt the in-line ICVC refund; on success
    /// drop the journal entry and return #IcpTransferFailed. On failure (or
    /// when the amount is below the refund fee), promote the entry to
    /// #RefundPending and return #NeedsRefund so the caller (or admin) can
    /// retry via retryRefund.
    ///
    /// The refund's `created_at_time` is pinned to the journal entry's
    /// `icvc_dedup_created_at` (the same timestamp the pull used). This makes
    /// every refund attempt for a given redemption — in-line or via retry —
    /// share the same ICRC-1 dedup key, so a retry after a lost response
    /// returns Duplicate instead of double-refunding.
    func attemptRefundAndJournal(
        redemptionId : Nat,
        caller : Principal,
        amount : Nat,
        icvc_tx_id : Nat,
        icpErrText : Text,
        memoBlob : Blob,
        dedupCreatedAt : Nat64,
    ) : async Types.RedemptionError {
        let refundFee = await icvc_ledger.icrc1_fee();
        let refundAmount : Nat = if (amount > refundFee) { amount - refundFee } else { 0 };

        if (refundAmount == 0) {
            setInFlightStatus(redemptionId, #RefundPending({
                icvc_tx_id = icvc_tx_id;
                icp_error = icpErrText;
                refund_error = "amount <= refund fee";
            }));
            return #NeedsRefund(redemptionId);
        };

        bumpRefundAttempt(redemptionId);
        let result = await icvc_ledger.icrc1_transfer({
            from_subaccount = null;
            to = callerAccount(caller);
            amount = refundAmount;
            fee = ?refundFee;
            memo = ?memoBlob;
            created_at_time = ?dedupCreatedAt;
        });
        switch (result) {
            case (#Ok(_)) {
                removeInFlightById(redemptionId);
                #IcpTransferFailed(icpErrText);
            };
            // An earlier refund attempt with the same dedup key actually
            // committed; the ledger is rejecting this submission as a
            // duplicate. The user has their funds — close the saga.
            case (#Err(#Duplicate(_))) {
                removeInFlightById(redemptionId);
                #IcpTransferFailed(icpErrText);
            };
            case (#Err(refundErr)) {
                setInFlightStatus(redemptionId, #RefundPending({
                    icvc_tx_id = icvc_tx_id;
                    icp_error = icpErrText;
                    refund_error = debug_show(refundErr);
                }));
                #NeedsRefund(redemptionId);
            };
        };
    };

    // ---- Public API ----

    /// Redeem ICVC tokens for ICP. Caller must have approved this canister on
    /// the ICVC ledger first. The flow journals each step in `inFlight` and
    /// is recoverable across canister traps and upgrades (see RECOVERY.md).
    public shared ({ caller }) func redeem(amount : Nat) : async Result.Result<Types.RedemptionRecord, Types.RedemptionError> {
        // Early validation — no state changes, no awaits.
        if (Principal.isAnonymous(caller)) return #err(#NotAuthorized);
        if (paused) return #err(#Paused);
        if (amount < MIN_REDEMPTION) return #err(#BelowMinimum);
        let icp_payout = calculateIcpPayout(amount);
        if (icp_payout == 0) return #err(#BelowMinimum);

        // Per-caller reentrancy lock; released by `finally` even on trap.
        if (not tryAcquireRedeemLock(caller)) return #err(#ConcurrentRedemption);

        try {
            // Allocate id and dedup keys BEFORE the first ledger-mutating
            // await so the values are stable across the flow and across any
            // canister-internal retry.
            let redemptionId = nextRedemptionId;
            nextRedemptionId += 1;
            let memoBlob = Pure.memoFromId(redemptionId);
            let createdAt = Pure.nowNat64();

            // Pre-check pool balance (informational; the ledger transfer is
            // the authoritative gate, but failing fast here saves a wasted
            // approval and gives the caller a clearer error).
            let icp_balance = await icp_ledger.icrc1_balance_of(selfAccount());
            let icp_fee = await icp_ledger.icrc1_fee();
            if (icp_balance < icp_payout + icp_fee) return #err(#InsufficientIcpPool);

            // Open the saga journal entry before any ledger-mutating call.
            // `icvc_dedup_created_at` records the ledger dedup key inline so
            // a future reconciliation tool can query the ledger to determine
            // whether the pull executed if we trap before writing #IcvcPulled.
            inFlight.add({
                id = redemptionId;
                user = caller;
                icvc_amount = amount;
                icp_amount = icp_payout;
                status = #Started;
                started_at = Time.now();
                icvc_dedup_created_at = createdAt;
                last_updated = Time.now();
                refund_attempts = 0;
            });

            // Step 1: pull ICVC.
            let icvc_tx_id = switch (await pullIcvc(redemptionId, caller, amount, memoBlob, createdAt)) {
                case (#err(e)) return #err(e);
                case (#ok(id)) id;
            };

            // Mark the ICP send as in-flight BEFORE the await. This is the
            // committed journal state while icrc1_transfer runs, so a trap that
            // loses the reply leaves #IcpSendPending (ICP outcome unknown) rather
            // than a state that recovery might blind-refund. A clean ICP failure
            // is handled below and never persists as #IcpSendPending.
            setInFlightStatus(redemptionId, #IcpSendPending({ icvc_tx_id }));

            // Step 2: send ICP. On success: bookkeep, drop journal entry.
            // On failure: invoke the refund helper.
            switch (await sendIcp(caller, icp_payout, icp_fee, memoBlob, createdAt)) {
                case (#ok(icp_tx_id)) {
                    let record : Types.RedemptionRecord = {
                        id = redemptionId;
                        user = caller;
                        icvc_amount = amount;
                        icp_amount = icp_payout;
                        timestamp = Time.now();
                        icvc_tx_id = icvc_tx_id;
                        icp_tx_id = icp_tx_id;
                    };
                    redemptions.add(record);
                    totalIcvcRedeemed += amount;
                    totalIcpDistributed += icp_payout;
                    removeInFlightById(redemptionId);
                    // Final step: burn the redeemed ICVC. The user already has
                    // their ICP, so this is best-effort — a failure does not
                    // fail the redeem; the amount is parked in pendingBurns and
                    // flushed later by sweepBurn (dedup-safe, no double burn).
                    switch (await burnIcvc(amount, redemptionId, createdAt)) {
                        case (#ok(_)) { totalIcvcBurned += amount; };
                        case (#err(_)) {
                            pendingBurns := Array.append(pendingBurns, [(redemptionId, amount, createdAt)]);
                        };
                    };
                    #ok(record);
                };
                case (#err(icpErrText)) {
                    #err(await attemptRefundAndJournal(
                        redemptionId, caller, amount, icvc_tx_id, icpErrText, memoBlob, createdAt,
                    ));
                };
            };
        } finally {
            releaseRedeemLock(caller);
        };
    };

    /// Retry the refund for an in-flight redemption that did not complete.
    /// Original user or admin may invoke. Auto-refunds ONLY #RefundPending
    /// entries (a clean ICP failure, so the ICP definitely did not go out).
    /// #IcpSendPending / #IcvcPulled have an unknown ICP outcome and are
    /// refused here to avoid double-paying — they need ledger reconciliation
    /// (see RECOVERY.md). On success the journal entry is removed; on failure
    /// the entry's status is updated with the latest refund error.
    public shared ({ caller }) func retryRefund(id : Nat) : async Result.Result<Nat, Text> {
        if (Principal.isAnonymous(caller)) return #err("Anonymous callers not permitted");

        let idx = switch (findInFlightIndex(id)) {
            case (?i) i;
            case null { return #err("No in-flight redemption with id " # Nat.toText(id)); };
        };
        let entry = inFlight.get(idx);
        if (not Principal.equal(caller, entry.user) and not isAdmin(caller)) {
            return #err("Not authorized to retry this redemption");
        };

        // Snapshot the prior icvc_tx_id and icp_error so we can persist them
        // back into #RefundPending if this attempt also fails.
        //
        // Only #RefundPending is auto-refundable here: it is reached solely via
        // a *clean* ICP failure (sendIcp returned #Err), so we KNOW the ICP did
        // not go out. #IcpSendPending / #IcvcPulled mean the ICP send was in
        // flight and its outcome is UNKNOWN — blind-refunding could double-pay a
        // user whose ICP actually settled. Those require ledger reconciliation
        // (see RECOVERY.md), not retryRefund.
        let (icvc_tx_id, priorIcpError) = switch (entry.status) {
            case (#RefundPending(d)) (d.icvc_tx_id, d.icp_error);
            case (#IcpSendPending(_) or #IcvcPulled(_)) {
                return #err(
                    "Entry is in #IcpSendPending: the ICP payout outcome is unknown, so refunding here could double-pay. "
                    # "Reconcile the ICP ledger first (getDedupKey(id) -> look up memo redemption-" # Nat.toText(id)
                    # " + created_at on the ICP ledger). If the ICP was sent, forceCloseInFlight(id); if not, refund out-of-band. See RECOVERY.md."
                );
            };
            case (#Started) {
                return #err("Entry is in #Started state; no ledger change to refund. Use forceCloseInFlight.");
            };
        };

        let fee = await icvc_ledger.icrc1_fee();
        let payAmount : Nat = if (entry.icvc_amount > fee) { entry.icvc_amount - fee } else { 0 };
        if (payAmount == 0) return #err("Owed amount is below the ledger fee; cannot refund");

        // Pin created_at_time to the journal entry's dedup key so retries
        // share an ICRC-1 dedup tuple with any prior (in-line or retry)
        // refund attempt for this id. The ledger will return Duplicate
        // instead of double-refunding if an earlier attempt committed.
        bumpRefundAttempt(id);
        let result = await icvc_ledger.icrc1_transfer({
            from_subaccount = null;
            to = callerAccount(entry.user);
            amount = payAmount;
            fee = ?fee;
            memo = ?Pure.memoFromId(entry.id);
            created_at_time = ?entry.icvc_dedup_created_at;
        });

        switch (result) {
            case (#Ok(txId)) {
                removeInFlightById(id);
                #ok(txId);
            };
            // An earlier refund attempt with the same dedup key actually
            // committed (its response was lost in transit). The user has
            // their funds — close the saga and report the original tx id.
            case (#Err(#Duplicate({ duplicate_of }))) {
                removeInFlightById(id);
                #ok(duplicate_of);
            };
            case (#Err(err)) {
                setInFlightStatus(id, #RefundPending({
                    icvc_tx_id = icvc_tx_id;
                    icp_error = priorIcpError;
                    refund_error = debug_show(err);
                }));
                #err("Refund still failing: " # debug_show(err));
            };
        };
    };

    /// Admin escape hatch: drop an in-flight entry without performing a refund.
    /// Use only after manually verifying the ledger state (e.g., a #Started
    /// entry whose transfer_from never executed). Misuse can lose user funds.
    public shared ({ caller }) func forceCloseInFlight(id : Nat) : async Result.Result<(), Text> {
        if (not isAdmin(caller)) return #err("Not authorized");
        switch (findInFlightIndex(id)) {
            case (?_) { removeInFlightById(id); #ok(()); };
            case null { #err("No in-flight entry with id " # Nat.toText(id)); };
        };
    };

    /// Admin: force a refund for a stuck entry using a FRESH `created_at_time`,
    /// which deliberately bypasses the ~24h ICRC-1 dedup window that makes
    /// `retryRefund` return `TooOld`. This is the in-canister resolution for:
    ///   - a reconciled `#IcpSendPending`/`#IcvcPulled` entry that `retryRefund`
    ///     refuses (ICP outcome unknown), and
    ///   - a `#RefundPending` entry past the dedup window.
    ///
    /// DANGER: because the timestamp is fresh, the ledger's dedup will NOT catch
    /// a prior refund or payout. The admin MUST first reconcile the ICP and ICVC
    /// ledgers (memo `redemption-<id>`) and confirm that neither the payout nor a
    /// refund already settled — otherwise this double-pays. See RECOVERY.md.
    public shared ({ caller }) func forceRefund(id : Nat) : async Result.Result<Nat, Text> {
        if (not isAdmin(caller)) return #err("Not authorized");
        let idx = switch (findInFlightIndex(id)) {
            case (?i) i;
            case null { return #err("No in-flight redemption with id " # Nat.toText(id)); };
        };
        let entry = inFlight.get(idx);
        switch (entry.status) {
            case (#Started) {
                return #err("Entry is in #Started state; no ICVC was pulled to refund. Use forceCloseInFlight after verifying the pull never executed.");
            };
            case (_) {};
        };
        let fee = await icvc_ledger.icrc1_fee();
        let payAmount : Nat = if (entry.icvc_amount > fee) { entry.icvc_amount - fee } else { 0 };
        if (payAmount == 0) return #err("Owed amount is below the ledger fee; cannot refund");

        bumpRefundAttempt(id);
        let result = await icvc_ledger.icrc1_transfer({
            from_subaccount = null;
            to = callerAccount(entry.user);
            amount = payAmount;
            fee = ?fee;
            memo = ?Pure.memoFromId(entry.id);
            created_at_time = ?Pure.nowNat64(); // fresh on purpose — bypasses TooOld
        });
        switch (result) {
            case (#Ok(txId)) { removeInFlightById(id); #ok(txId); };
            // Idempotency for repeated forceRefund within the dedup window.
            case (#Err(#Duplicate({ duplicate_of }))) { removeInFlightById(id); #ok(duplicate_of); };
            case (#Err(err)) { #err("forceRefund failed: " # debug_show (err)); };
        };
    };

    /// Admin: flush any redeemed-but-unburned ICVC (the rare case where an
    /// inline burn failed). Retries each pending burn with its original dedup
    /// tuple, so a burn whose response was lost returns Duplicate rather than
    /// burning twice. Allowed while paused (it is recovery, like retryRefund).
    /// Returns the total ICVC burned by this call. Pending entries that still
    /// fail are kept for a later sweep.
    public shared ({ caller }) func sweepBurn() : async Result.Result<Nat, Text> {
        if (not isAdmin(caller)) return #err("Not authorized");
        var burnedThisCall : Nat = 0;
        // Track the ids we actually burn. We MUST NOT rebuild pendingBurns from
        // this loop's snapshot: each `await burnIcvc` yields, and a concurrent
        // `redeem` (different caller — the redeem lock is per-caller and this
        // method holds no lock) can append a freshly-failed burn to pendingBurns
        // during the yield. Overwriting with a snapshot-derived array would
        // silently drop those entries (breaking the burn invariant). Instead,
        // reconcile against the CURRENT pendingBurns afterwards, removing only
        // the ids we burned and preserving any concurrent appends.
        let burnedIds = Buffer.Buffer<Nat>(0);
        for ((id, amount, createdAt) in pendingBurns.vals()) {
            switch (await burnIcvc(amount, id, createdAt)) {
                case (#ok(_)) {
                    totalIcvcBurned += amount;
                    burnedThisCall += amount;
                    burnedIds.add(id);
                };
                case (#err(_)) {};
            };
        };
        pendingBurns := Array.filter<(Nat, Nat, Nat64)>(
            pendingBurns,
            func(e : (Nat, Nat, Nat64)) : Bool { not Buffer.contains<Nat>(burnedIds, e.0, Nat.equal) },
        );
        #ok(burnedThisCall);
    };

    /// Admin: force-flush pending burns using a FRESH `created_at_time`, which
    /// bypasses the ~24h dedup window that makes `sweepBurn` return `TooOld` on
    /// a long-stuck entry. The burn analog of `forceRefund`.
    ///
    /// DANGER: a fresh timestamp means the ledger's dedup will NOT catch a burn
    /// that already committed, so this can DOUBLE-burn (destroying more ICVC than
    /// was redeemed, beyond what this redemption pulled). The admin MUST first
    /// confirm on the ICVC ledger (memo `burn-<id>`) that the original burn never
    /// settled. Returns the total burned this call; entries that still fail stay
    /// queued. See RECOVERY.md.
    public shared ({ caller }) func forceBurn() : async Result.Result<Nat, Text> {
        if (not isAdmin(caller)) return #err("Not authorized");
        var burnedThisCall : Nat = 0;
        // Same concurrency-safe reconciliation as sweepBurn: track burned ids and
        // filter the CURRENT pendingBurns at the end, rather than overwriting it
        // with a stale snapshot (which would drop burns appended by a concurrent
        // redeem during the awaits).
        let burnedIds = Buffer.Buffer<Nat>(0);
        for ((id, amount, _) in pendingBurns.vals()) {
            switch (await burnIcvc(amount, id, Pure.nowNat64())) { // fresh — bypasses TooOld
                case (#ok(_)) {
                    totalIcvcBurned += amount;
                    burnedThisCall += amount;
                    burnedIds.add(id);
                };
                case (#err(_)) {};
            };
        };
        pendingBurns := Array.filter<(Nat, Nat, Nat64)>(
            pendingBurns,
            func(e : (Nat, Nat, Nat64)) : Bool { not Buffer.contains<Nat>(burnedIds, e.0, Nat.equal) },
        );
        #ok(burnedThisCall);
    };

    /// Public view of the redeemed-but-unburned queue (entries a `sweepBurn`
    /// would retry). Normally empty; non-empty means one or more inline burns
    /// failed. The sum of `amount` equals `icvc_pending_burn` in getStats.
    public query func getPendingBurns() : async [Types.PendingBurn] {
        Array.map<(Nat, Nat, Nat64), Types.PendingBurn>(
            pendingBurns,
            func((id, amount, createdAt)) = { id; amount; created_at = createdAt },
        );
    };

    /// List the caller's own in-flight redemptions (Started / IcvcPulled / RefundPending).
    public query ({ caller }) func getMyInFlight() : async [Types.InFlightRedemption] {
        let matching = Buffer.Buffer<Types.InFlightRedemption>(0);
        for (entry in inFlight.vals()) {
            if (Principal.equal(entry.user, caller)) matching.add(entry);
        };
        Buffer.toArray(matching);
    };

    /// Public view of every in-flight redemption (the saga journal). Open by
    /// design: the principals and amounts are already public via
    /// getRedemptionHistory and the on-chain ledger transfers, and exposing the
    /// operational status aids auditing the wind-down. State-mutating recovery
    /// (retryRefund / forceCloseInFlight / sweepBurn) stays auth-gated.
    public query func getInFlight() : async [Types.InFlightRedemption] {
        Buffer.toArray(inFlight);
    };

    /// Admin: return the ledger dedup key for an in-flight entry, so a future
    /// reconciliation tool can query the ledger and decide whether a #Started
    /// entry's transfer_from actually executed before a trap.
    public query ({ caller }) func getDedupKey(id : Nat) : async Result.Result<?Nat64, Types.RedemptionError> {
        if (not isAdmin(caller)) return #err(#NotAuthorized);
        #ok(lookupDedupKey(id));
    };

    /// Get pool statistics
    public shared func getStats() : async Types.Stats {
        let icp_remaining = await icp_ledger.icrc1_balance_of(selfAccount());
        {
            icp_remaining = icp_remaining;
            total_icvc_redeemed = totalIcvcRedeemed;
            total_icp_distributed = totalIcpDistributed;
            total_redemptions = redemptions.size();
            exchange_rate_e8s = exchange_rate_e8s;
            paused = paused;
            total_icvc_burned = totalIcvcBurned;
            icvc_pending_burn = totalIcvcRedeemed - totalIcvcBurned;
        };
    };

    /// Maximum number of records the history queries will return in a
    /// single call. Caller-supplied `limit` is clamped to this value so
    /// no single query can blow up the response size or query cycles.
    transient let MAX_PAGE_SIZE : Nat = 100;

    /// Get paginated redemption history (newest first). `limit` is clamped
    /// to MAX_PAGE_SIZE.
    public query func getRedemptionHistory(offset : Nat, limit : Nat) : async [Types.RedemptionRecord] {
        let size = redemptions.size();
        if (offset >= size) return [];
        let effective_limit = Nat.min(limit, MAX_PAGE_SIZE);
        let end = Nat.min(offset + effective_limit, size);
        Array.tabulate<Types.RedemptionRecord>(end - offset, func(i) = redemptions.get(size - 1 - offset - i));
    };

    /// Get a paginated slice of one user's redemptions, newest first.
    /// `offset` skips that many matches before the slice starts; `limit`
    /// caps the slice and is itself clamped to MAX_PAGE_SIZE. Walks the
    /// full `redemptions` buffer in worst case but returns at most
    /// MAX_PAGE_SIZE entries.
    public query func getUserRedemptions(user : Principal, offset : Nat, limit : Nat) : async [Types.RedemptionRecord] {
        let size = redemptions.size();
        let effective_limit = Nat.min(limit, MAX_PAGE_SIZE);
        if (size == 0 or effective_limit == 0) return [];

        let result = Buffer.Buffer<Types.RedemptionRecord>(0);
        var skipped : Nat = 0;
        var i : Nat = size;  // we iterate i-1 inside the loop so we can decrement safely

        label scan while (i > 0 and result.size() < effective_limit) {
            i -= 1;
            let r = redemptions.get(i);
            if (Principal.equal(r.user, user)) {
                if (skipped < offset) {
                    skipped += 1;
                } else {
                    result.add(r);
                };
            };
        };
        Buffer.toArray(result);
    };

    /// Complete redemption log (public, paginated, newest first): every
    /// redemption, completed AND in-flight, merged into one list with a uniform
    /// status. This is the single view for incident triage — a `#IcvcPulled`
    /// row (icvc_tx_id set, icp_tx_id null) is "ICVC received, ICP not
    /// distributed". Completed and in-flight ids are disjoint (an id is one or
    /// the other), so there are no duplicates. `limit` is clamped to
    /// MAX_PAGE_SIZE. Note: redemptions that failed and were refunded/closed
    /// are removed from in-flight and do not appear here; their on-chain trail
    /// (ledger transfers tagged `redemption-<id>`) is the permanent record.
    public query func getRedemptionLog(offset : Nat, limit : Nat) : async [Types.RedemptionLogEntry] {
        let all = Buffer.Buffer<Types.RedemptionLogEntry>(redemptions.size() + inFlight.size());
        for (r in redemptions.vals()) {
            all.add({
                id = r.id;
                user = r.user;
                icvc_amount = r.icvc_amount;
                icp_amount = r.icp_amount;
                status = #Completed;
                timestamp = r.timestamp;
                icvc_tx_id = ?r.icvc_tx_id;
                icp_tx_id = ?r.icp_tx_id;
            });
        };
        for (e in inFlight.vals()) {
            let (st, icvcTx) : (Types.RedemptionStatus, ?Nat) = switch (e.status) {
                case (#Started) (#Started, null);
                case (#IcvcPulled(d)) (#IcvcPulled, ?d.icvc_tx_id);
                case (#IcpSendPending(d)) (#IcpSendPending, ?d.icvc_tx_id);
                case (#RefundPending(d)) (#RefundPending, ?d.icvc_tx_id);
            };
            all.add({
                id = e.id;
                user = e.user;
                icvc_amount = e.icvc_amount;
                icp_amount = e.icp_amount;
                status = st;
                timestamp = e.started_at;
                icvc_tx_id = icvcTx;
                icp_tx_id = null;
            });
        };
        let sorted = Array.sort<Types.RedemptionLogEntry>(
            Buffer.toArray(all),
            func(a, b) = Nat.compare(b.id, a.id),
        );
        let size = sorted.size();
        if (offset >= size) return [];
        let effective_limit = Nat.min(limit, MAX_PAGE_SIZE);
        let end = Nat.min(offset + effective_limit, size);
        Array.tabulate<Types.RedemptionLogEntry>(end - offset, func(i) = sorted[offset + i]);
    };

    /// Get the current exchange rate
    public query func getExchangeRate() : async Nat {
        exchange_rate_e8s;
    };

    /// Get the treasury-backing inputs the exchange rate is derived from,
    /// together with the derived intermediates and the resulting rate. Anyone
    /// can read this (anonymous-readable, like getStats) to verify the rate
    /// against on-chain treasury truth. The inputs change only via upgrade.
    public query func getFairValueInputs() : async Types.FairValueInputs {
        let nicp_as_icp_e8s = Pure.nicpToIcp(TREASURY_NICP_E8S, NICP_PER_ICP_E8S);
        {
            icvc_total_supply_e8s = ICVC_TOTAL_SUPPLY_E8S;
            treasury_icp_e8s = TREASURY_ICP_E8S;
            treasury_nicp_e8s = TREASURY_NICP_E8S;
            nicp_per_icp_e8s = NICP_PER_ICP_E8S;
            nicp_as_icp_e8s = nicp_as_icp_e8s;
            backing_icp_e8s = TREASURY_ICP_E8S + nicp_as_icp_e8s;
            inputs_recorded_at = FAIR_VALUE_INPUTS_RECORDED_AT_NS;
            exchange_rate_e8s = exchange_rate_e8s;
        };
    };

    // ---- Admin ----

    public shared ({ caller }) func pause() : async Result.Result<(), Types.RedemptionError> {
        if (not isAdmin(caller)) return #err(#NotAuthorized);
        paused := true;
        #ok(());
    };

    public shared ({ caller }) func unpause() : async Result.Result<(), Types.RedemptionError> {
        if (not isAdmin(caller)) return #err(#NotAuthorized);
        paused := false;
        #ok(());
    };

    // The exchange rate is DERIVED from the fair-value backing constants by
    // fairValueRate() — computed on install and recomputed in postupgrade.
    // There is no runtime setter; changing the rate requires a code upgrade
    // that edits the constants, which is visible on-chain via the new
    // module_hash. getFairValueInputs() exposes the inputs + the derived rate.

    // ---- Admin allowlist management ----

    /// Add a principal to the admin allowlist. Idempotent: adding an existing
    /// admin returns an error rather than silently succeeding, so callers see
    /// the misconception.
    public shared ({ caller }) func addAdmin(newAdmin : Principal) : async Result.Result<(), Text> {
        if (not isAdmin(caller)) return #err("Not authorized");
        if (Principal.isAnonymous(newAdmin)) return #err("Cannot add the anonymous principal as admin");
        if (isAdmin(newAdmin)) return #err("Already an admin");
        admins := Array.append(admins, [newAdmin]);
        #ok(());
    };

    /// Remove a principal from the admin allowlist. Refuses to remove the
    /// last remaining admin so the canister can always be administered.
    /// A misconfigured allowlist is recoverable only via a backup controller,
    /// so the lockout guard is the primary defence.
    public shared ({ caller }) func removeAdmin(toRemove : Principal) : async Result.Result<(), Text> {
        if (not isAdmin(caller)) return #err("Not authorized");
        if (not isAdmin(toRemove)) return #err("Not an admin");
        if (admins.size() <= 1) return #err("Cannot remove the last admin");
        admins := Array.filter<Principal>(admins, func(a) = not Principal.equal(a, toRemove));
        #ok(());
    };

    /// List of current admin principals. Public for transparency: anyone can
    /// see who controls the canister.
    public query func listAdmins() : async [Principal] {
        admins;
    };
};
