import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import Time "mo:base/Time";

/// Pure helpers extracted from the redemption actor so they can be unit-tested
/// without booting a replica. Anything in here MUST be:
///   - free of `await` (synchronous)
///   - free of actor state (no `var` reads or writes)
///   - deterministic given its inputs (no Time.now() except via the helper
///     below, which is exposed for the actor only — never call from tests)
module {
    /// Convert an ICVC amount in e8s to the corresponding ICP payout in e8s,
    /// using the canister's current `exchange_rate_e8s` (ICP e8s per 1 ICVC).
    /// Integer division truncates; sub-unit dust is rounded down (favors the
    /// pool, never the user).
    public func calculateIcpPayout(icvc_amount : Nat, exchange_rate_e8s : Nat) : Nat {
        (icvc_amount * exchange_rate_e8s) / 100_000_000;
    };

    /// Convert an nICP amount in e8s to its ICP-equivalent value in e8s.
    /// `nicp_per_icp_e8s` is WaterNeuron's exchange rate as reported by
    /// `get_info` — the number of nICP minted per 1 ICP, scaled by 1e8 (so
    /// 79_545_698 means depositing 1 ICP mints 0.79545698 nICP). Each nICP is
    /// therefore worth `1e8 / nicp_per_icp_e8s` ICP, so we invert:
    ///   icp_e8s = nicp_e8s * 1e8 / nicp_per_icp_e8s
    /// Returns 0 if the rate is 0 (defensive; never expected from a healthy
    /// WaterNeuron canister).
    public func nicpToIcp(nicp_e8s : Nat, nicp_per_icp_e8s : Nat) : Nat {
        if (nicp_per_icp_e8s == 0) return 0;
        (nicp_e8s * 100_000_000) / nicp_per_icp_e8s;
    };

    /// Derive the redemption exchange rate (ICP e8s per 1 ICVC) from the ICVC
    /// DAO's treasury backing: the live ICP balance plus the ICP-equivalent
    /// fair value of the treasury's nICP, divided across the full ICVC supply.
    ///   backing_icp_e8s = treasury_icp_e8s + nicpToIcp(treasury_nicp_e8s, ...)
    ///   rate_e8s        = backing_icp_e8s * 1e8 / icvc_total_supply_e8s
    /// All arithmetic is on `Nat` (bignum) so the `* 1e8` intermediate cannot
    /// overflow. Returns 0 if supply is 0 (defensive).
    public func computeFairValueRate(
        icvc_total_supply_e8s : Nat,
        treasury_icp_e8s : Nat,
        treasury_nicp_e8s : Nat,
        nicp_per_icp_e8s : Nat,
    ) : Nat {
        if (icvc_total_supply_e8s == 0) return 0;
        let backing_icp_e8s = treasury_icp_e8s + nicpToIcp(treasury_nicp_e8s, nicp_per_icp_e8s);
        (backing_icp_e8s * 100_000_000) / icvc_total_supply_e8s;
    };

    /// Stable per-redemption memo, used so the ledger can deduplicate retries
    /// within its transaction window.
    public func memoFromId(id : Nat) : Blob {
        Text.encodeUtf8("redemption-" # Nat.toText(id));
    };

    /// Convert a Time.now() value to the Nat64 expected by ICRC's
    /// created_at_time. The actor uses this; tests should pass a fixed Int.
    public func intToNat64(t : Int) : Nat64 {
        Nat64.fromNat(Int.abs(t));
    };

    /// nowNat64 wraps Time.now() for the actor. Not deterministic, so never
    /// call from tests; use intToNat64 with a fixed timestamp instead.
    public func nowNat64() : Nat64 {
        intToNat64(Time.now());
    };
};
