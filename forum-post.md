# ICVC SNS Motion Proposal: Rollback of the ICVC DAO and Pro-Rata Return of Treasury Assets to Token Holders

## 1. Objective

Roll back the ICVC SNS and authorise a pro-rata return of the remaining treasury to ICVC token holders via an on-chain redemption canister. ICVC has not fulfilled its mandate as a venture investment vehicle on the Internet Computer, and the founding members do not believe it has the intent or the capability to do so going forward. The objective of this motion is to protect the value that remains and return it to token holders on equal terms. The principle is simple and final: **1 ICVC = 1 pro-rata claim on the remaining treasury.** This applies equally for liquid ICVC tokens and those locked in neurons.

The motion asks ICVC token holders to vote in favour of:

1. Rolling back the ICVC SNS.
2. Writing off non-recoverable positions (Yusan and Loka Mining).
3. Distributing the remaining treasury pro rata to ICVC token holders through a redemption canister over a defined window.
4. Burning ICVC tokens upon redemption.

## 2. Background

The ICVC DAO was launched on the SNS with a mandate to operate as a venture investment vehicle on the Internet Computer, deploying capital from ICVC token holders into ecosystem projects.

Measured against that mandate, ICVC has made a small number of investments. The current status of those investments and of the remaining treasury is as follows:

- **Loka Mining:** The position is proposed to be written off. The project did not launch a Service Nervous System (SNS), and the founding team has been non-responsive.
- **Yusan:** The position is proposed to be written off. The project did not launch via an official Service Nervous System (SNS), which was the basis on which the original investment was structured. DFINITY objected to disbursing the second tranche of the investment purely against a go-live event and proposed revised terms tying the second tranche to commercial growth KPIs. Yusan accepted the revised terms, but ICVC declined to sign the corresponding amendment.
- **Remaining treasury:** held in ICP and nICP, without an active investment process.

On the basis of this track record, the founding members propose to roll back the ICVC SNS and return the remaining treasury value to ICVC token holders on equal pro-rata terms.

A redemption mechanism has been engineered using ICP-native infrastructure: a redemption canister that accepts ICVC token deposits and pays out the pro-rata share of the remaining ICP treasury, automatically and verifiably. The redemption canister can be deployed within the next few weeks.

## 3. Why this matters

The purpose of this motion is to **protect the remaining value held on behalf of ICVC token holders** and to return it to those holders on equal pro-rata terms.

A formal, on-chain rollback:

- **Protects remaining capital** by returning it to ICVC token holders.
- **Returns value to holders** without lengthy discretionary processes or further governance overhead.
- **Closes the DAO on transparent terms**, fully on the public record of the Internet Computer.

## 4. Distribution principle

The motion adopts a single, simple distribution principle for every asset class. Each ICVC token represents an equal pro-rata claim on the treasury at rollback, computed as:

> **holder's pro-rata share = (holder's ICVC tokens) / (total ICVC supply at snapshot)**

A snapshot of all ICVC assets and token balances will be taken at the time of vote execution. That snapshot is the basis for every payout under this motion. No discretionary adjustments, no preferred classes, no carve-outs.

### 4.1 What this works out to

Expressed as a redemption rate, the pro-rata share is the treasury backing per token:

> **rate per ICVC = (treasury ICP + treasury nICP valued in ICP) / total ICVC supply**

At the most recent snapshot (2 June 2026) the inputs were:

| Input | Value |
|---|---|
| Total ICVC supply | ~19,999,987 ICVC |
| Treasury ICP | ~781,458 ICP |
| Treasury nICP | ~293,640 nICP |
| nICP valued in ICP (at the prevailing WaterNeuron rate) | ~369,140 ICP |
| **Total backing** | **~1,150,600 ICP** |
| **Implied rate** | **~0.05753 ICP per ICVC** |

These figures are illustrative; they will be refreshed from a final snapshot taken at vote execution. The final rate is then fixed in the deployed redemption canister and can change only through a code upgrade, so it is fully verifiable on-chain: the canister exposes the exact inputs through a public query, and the running code can be matched against its published module hash.

## 5. Treatment by asset class

### 5.1 Liquid ICP
All liquid ICP held by ICVC at snapshot block height is transferred to the redemption canister and distributed pro rata. For security reasons the transfer will happen in stages.

### 5.2 nICP
ICVC's nICP holdings are absorbed by DFINITY at fair value in exchange for ICVC or ICP, calculated as the prevailing ICP-equivalent valuation on the rollback date. DFINITY accepts the nICP unlock delay on its own balance sheet.

### 5.3 Yusan (write-off)
ICVC's position in Yusan is written off in full. The project did not launch via an official Service Nervous System (SNS), which was the basis on which the original investment was structured. DFINITY objected to disbursing the second tranche of the investment purely against a go-live event and proposed revised terms tying the second tranche to commercial growth KPIs. Yusan accepted the revised terms, but ICVC declined to sign the corresponding amendment. Any tokens or other consideration that may flow to ICVC under the original agreement in the future will, if received, be routed through the redemption canister on the same pro-rata basis.

### 5.4 Loka Mining (write-off)
ICVC's position in Loka Mining is written off in full. The project did not launch a Service Nervous System (SNS), and the founding team has been non-responsive. No further capital, time, or cost is to be expended on this position.

### 5.5 ICVC tokens
ICVC tokens used to redeem treasury value through the canister are burned on receipt. After the redemption window closes, any remaining ICVC supply is considered abandoned and is permanently retired.

## 6. Redemption process
1. **Deployment/snapshot.** The redemption canister is deployed under the control of the ICVC SNS. A balance snapshot of all ICVC holdings is taken and published.
2. **Treasury transfer.** Liquid assets are routed to the redemption canister. For security reasons this will happen in stages.
3. **Open redemption window.** A 30-month redemption window opens. During this window, any ICVC token holder may send ICVC tokens to the redemption canister and immediately receive their pro-rata share of treasury assets accumulated to date. ICVC neurons would need to be dissolved first before the submission to the redemption canister; the 30-month window is set to exceed the maximum SNS neuron dissolve delay, so holders with locked tokens are not timed out. 
4. **Window close.** After 30 months, the redemption window closes. Remaining undistributed assets, if any, are pending a follow-up motion on their treatment.

### Transparency and verification

- **Live preview.** A working version is already deployed on the Internet Computer against test ledgers, so holders can try the redemption flow before the vote: https://zdlf2-iaaaa-aaaae-agada-cai.icp0.io (redemption canister `yofbu-hiaaa-aaaae-agaeq-cai`). This preview uses our own copies of the ledger wasm and includes a faucet for test tokens; the production deployment removes the faucet and points at the real ICVC token and the NNS ICP ledger.
- **Source code.** The redemption canister is open-source; the repository is here: `<REPOSITORY URL TO BE ADDED>`.
- **On-chain verifiability.** The deployed module hash will be published so anyone can confirm the running canister matches the source, and the fair-value inputs behind the rate are readable on-chain at any time.

## 7. Scope of this motion

This motion authorises only the on-chain rollback of the ICVC SNS and the associated treasury actions: snapshot, transfer of liquid assets to the redemption canister, pro-rata payouts, and burning of redeemed ICVC tokens.

Any matters relating to the legal entity associated with ICVC sit outside the SNS and are out of scope of this motion.
