import { test } "mo:test";

import Pure "../src/redemption/Pure";

// ============================================================================
// calculateIcpPayout
// ============================================================================

test("payout: 1 ICVC at the launch rate yields 0.06229244 ICP", func() {
    let oneIcvc : Nat = 100_000_000;
    let launchRate : Nat = 6_229_244;
    assert Pure.calculateIcpPayout(oneIcvc, launchRate) == 6_229_244;
});

test("payout: zero ICVC yields zero ICP", func() {
    assert Pure.calculateIcpPayout(0, 6_229_244) == 0;
});

test("payout: a whole 19,999,900 ICVC pool at the stored e8s rate", func() {
    // 19_999_900 ICVC = 1_999_990_000_000_000 e8s ICVC
    // payout = pool * 6_229_244 / 1e8 = 124_584_257_075_600 e8s ICP
    //        ~= 1_245_842.57 ICP
    //
    // Note: the launch math was 1_245_838.69 / 19_999_900 = 0.06229244...,
    // which is itself rounded to 6_229_244 e8s. Applying the rounded rate
    // back to the whole pool produces a slightly different total than the
    // original 1_245_838.69 figure; the discrepancy is the rounding cost.
    let pool : Nat = 1_999_990_000_000_000;
    assert Pure.calculateIcpPayout(pool, 6_229_244) == 124_584_257_075_600;
});

test("payout: sub-cent dust truncates downward (favors the canister)", func() {
    // 1 ICVC e8s * 6_229_244 / 1e8 = 0 (integer truncation)
    // Anti-dust: the MIN_REDEMPTION guard in the actor prevents this case
    // from ever reaching the ledger, but the math itself must round down so
    // a malicious caller can't tease out fractional ICP.
    assert Pure.calculateIcpPayout(1, 6_229_244) == 0;
});

// ============================================================================
// nicpToIcp
// ============================================================================

test("nicpToIcp: treasury nICP at the 2026-06-02 protocol rate", func() {
    // 29_363_979_466_056 nICP e8s * 1e8 / 79_545_698 = 36_914_604_063_259 e8s
    assert Pure.nicpToIcp(29_363_979_466_056, 79_545_698) == 36_914_604_063_259;
});

test("nicpToIcp: zero rate is guarded (returns 0, no trap)", func() {
    assert Pure.nicpToIcp(29_363_979_466_056, 0) == 0;
});

test("nicpToIcp: zero nICP yields zero ICP", func() {
    assert Pure.nicpToIcp(0, 79_545_698) == 0;
});

// ============================================================================
// computeFairValueRate
// ============================================================================

test("fairValue: 2026-06-02 treasury snapshot derives 5_753_022 e8s", func() {
    // (78_145_768_936_670 ICP + 36_914_604_063_259 nICP-as-ICP) * 1e8
    //   / 1_999_998_744_500_000 ICVC supply = 5_753_022 (0.05753022 ICP/ICVC)
    let rate = Pure.computeFairValueRate(
        1_999_998_744_500_000,  // ICVC total supply
        78_145_768_936_670,     // treasury ICP
        29_363_979_466_056,     // treasury nICP
        79_545_698,             // nICP per ICP (e8s)
    );
    assert rate == (5_753_022 : Nat);
});

test("fairValue: nICP-free treasury reduces to ICP backing per ICVC", func() {
    // With no nICP, rate = treasury_icp * 1e8 / supply
    let rate = Pure.computeFairValueRate(1_999_998_744_500_000, 78_145_768_936_670, 0, 79_545_698);
    assert rate == (3_907_290 : Nat);
});

test("fairValue: zero ICVC supply is guarded (returns 0, no divide-by-zero)", func() {
    assert Pure.computeFairValueRate(0, 78_145_768_936_670, 29_363_979_466_056, 79_545_698) == 0;
});

test("fairValue: zero backing yields zero rate", func() {
    assert Pure.computeFairValueRate(1_999_998_744_500_000, 0, 0, 79_545_698) == 0;
});

test("fairValue: derived rate tracks its inputs (hypothetical future snapshot)", func() {
    // Documents that the rate is a function of the backing inputs, not a
    // baked-in constant: a different (round, illustrative) snapshot yields a
    // different rate. Here 20M ICVC backed by 1M ICP + 1M nICP @ 1.25 ICP/nICP:
    //   nicp_as_icp = 1_000_000e8 * 1e8 / 80_000_000 = 1_250_000e8
    //   backing     = 1_000_000e8 + 1_250_000e8     = 2_250_000e8
    //   rate        = 2_250_000e8 * 1e8 / 20_000_000e8 = 11_250_000 (0.1125 ICP/ICVC)
    let rate = Pure.computeFairValueRate(
        2_000_000_000_000_000,  // 20,000,000 ICVC supply
        100_000_000_000_000,    // 1,000,000 ICP treasury
        100_000_000_000_000,    // 1,000,000 nICP treasury
        80_000_000,             // 0.8 nICP per ICP  (1 nICP = 1.25 ICP)
    );
    assert rate == (11_250_000 : Nat);
});

// ============================================================================
// memoFromId
// ============================================================================

test("memo: format is 'redemption-<id>' utf-8", func() {
    let memo = Pure.memoFromId(42);
    assert memo == ("\72\65\64\65\6d\70\74\69\6f\6e\2d\34\32" : Blob);  // "redemption-42"
});

test("memo: distinct ids yield distinct memos", func() {
    assert Pure.memoFromId(0) != Pure.memoFromId(1);
});

test("memo: large id still encodes", func() {
    let memo = Pure.memoFromId(1_000_000);
    // 18 bytes: "redemption-1000000"
    assert memo.size() == 18;
});

// ============================================================================
// intToNat64
// ============================================================================

test("intToNat64: positive timestamp round-trips", func() {
    let t : Int = 1_700_000_000_000_000_000;
    assert Pure.intToNat64(t) == (1_700_000_000_000_000_000 : Nat64);
});

test("intToNat64: zero", func() {
    assert Pure.intToNat64(0) == (0 : Nat64);
});
