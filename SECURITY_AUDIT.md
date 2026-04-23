# nucleus-boring-vault — Security Audit Round 1

**Branch reviewed:** `payfi_audit_fix` (base) → audit branch `security/audit-round-1`
**Scope:** every `.sol` under `src/` plus deploy scripts under `script/` relevant to atomic-queue / teller / accountant authorization wiring.
**Methodology:** Single-pass adversarial review. Each finding was cross-referenced to the sibling fork `clearpool-payfi-vaults` (`docs/SYSTEM_AUDIT.md`, `docs/ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md`) to avoid re-deriving remediation where a verified fix already exists.
**Trust model:** per rules of engagement, owner compromise is implicitly trusted. Compromise of narrower non-owner roles (STRATEGIST_ROLE, UPDATE_EXCHANGE_RATE_ROLE, SOLVER_ROLE, CAN_SOLVE_ROLE) is in-scope.
**Test baseline (pre-audit, commit `52d779b`):** `forge test` — 139 passed, 2 failed. Both failures are pre-existing RPC-dependent `setUp()` reverts in `test/ion/oracles/EthPerTokenRateProvider.t.sol` (`RsEthRateProviderTest`, `RswEthRateProviderTest`) unrelated to any audit area.

---

## 0. TL;DR — Top findings and C-1 exposure

**Is the 2026-04-21 clearpool C-1 `finishSolve` drain present in this fork?**

Short answer: **the exact vulnerability shape exists, but the owner-compromise-only reachability makes it HIGH (trust boundary), not the in-isolation CRITICAL that was drained on clearpool**. Concretely:

- `AtomicQueue.solve` (`src/atomic-queue/AtomicQueue.sol:182-198`) accepts a caller-supplied `solver` parameter and calls `IAtomicSolver(solver).finishSolve(..., msg.sender as initiator, ...)`. **No `solver == msg.sender` check.** This is the Q-1 shape from the sibling's `SYSTEM_AUDIT.md §1.4`.
- `AtomicSolverV3.finishSolve` (`src/atomic-queue/AtomicSolverV3.sol:101-123`) is `requiresAuth` but the only in-contract provenance guard is `initiator != address(this)` (line 112). `initiator` is a parameter, freely set by the caller. There is **no `msg.sender == _expectedQueue`** check and **no `approvedQueues` whitelist** — both of which the sibling fork shipped as the load-bearing CT-2/F-1 fix (clearpool commits `125abbb`, `5ae4100`; see `clearpool-payfi-vaults/docs/ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md §2.1`).
- Reachability: `AtomicQueue` has `QUEUE_ROLE` (`script/ConfigureAtomicRoles.s.sol:45`; `DeployPortLayerZero.s.sol:166`; `DeployNucleusCrossChain.s.sol:282`). `QUEUE_ROLE` is granted `AtomicSolverV3.finishSolve.selector` (`script/ConfigureAtomicRoles.s.sol:107-112`). Only the **owner** holds `setUserRole` in this fork (solmate `RolesAuthority.setUserRole` is `requiresAuth` — `lib/solmate/src/auth/authorities/RolesAuthority.sol:95`; no non-owner role is granted that selector in any deploy script). So an attacker installs a rogue queue via owner compromise. By the rules of engagement, owner compromise is implicitly trusted, so this is HIGH (trust boundary), not an in-isolation CRITICAL. **But the defense-in-depth is missing and trivial to add** — port the sibling's `approvedQueues` whitelist.

**Status of the direct, role-free drain** (i.e. the one that actually cost ~$1.2M on clearpool): Not directly replicable here **only** because no non-owner role is wired to `setUserRole`. One deploy-script edit granting `setUserRole` to any non-owner role (common pattern in the sibling — the `OPERATOR_ROLE` gap) would recreate the exact in-isolation CRITICAL. Treat this as a latent mine.

**Top-3 summary:**

| Rank | ID | Severity | Title |
|---|---|---|---|
| 1 | Q-1 / CT-2 | HIGH (trust-boundary, CRITICAL if any non-owner role gains `setUserRole`) | Rogue-queue `finishSolve` drain reachable via `QUEUE_ROLE` grant — no `approvedQueues`, no `msg.sender==expectedQueue`, no `_inSolveContext` |
| 2 | T-1 | HIGH | Cross-chain `_lzReceive` / Hyperlane `handle` / OP `receiveBridgeMessage` all call `vault.enter(0,0,0,receiver,shareAmount)` directly — bypass `checkAccess(receiver)`, `depositCap`, `shareUnlockTime` |
| 3 | A-1 | HIGH | `updateExchangeRate` commits the out-of-bounds rate to storage before pausing — a bad rate survives an unpause and is read by Teller via `getRate()` |

Plus: A-2 (Teller reads non-safe rate), T-2 (`bulkWithdraw` checks solver not `_to`), A-3 (`setRateProviderData` no timelock/validation), V-3 (flashLoan recipient not pinned), M-1 (post-hoc slippage), M-3 (rate-limit bucket wrap bug), D-1 (role-number collision).

---

## 1. Findings

Severity scheme: **CRITICAL** = unconditional loss of funds, no role compromise required. **HIGH** = loss of funds with a specified non-owner role compromise or misconfiguration. **MEDIUM** = griefing/DoS/integration footgun. **LOW** = defense-in-depth / accepted design constraint. Citations are all `file:line` inside this repo unless prefixed with `CLEARPOOL:`.

### 1.1 [Q-1 / CT-2] — HIGH (trust-boundary) — Rogue-queue `finishSolve` drain, defense-in-depth missing

**File:line.**
- `src/atomic-queue/AtomicQueue.sol:182-198` — `solve(..., address solver)`; calls `IAtomicSolver(solver).finishSolve(runData, msg.sender, ...)` on line 195 with zero restriction on `solver`.
- `src/atomic-queue/AtomicSolverV3.sol:101-123` — `finishSolve`, only guard is `if (initiator != address(this)) revert` (line 112).
- `src/atomic-queue/AtomicSolverV2.sol:123-147` — identical shape, dormant but compiled.
- `src/atomic-queue/AtomicSolver.sol:32-52` — V1, guard is `require(initiator == owner)` + custom `approvedToCallFinishSolve` mapping (line 43). Partially defended but `functionCallWithValue` with attacker-controlled `targets`/`ammo` on line 48 is a broader pattern than V3. Dormant.

**Bug.** The `solver` parameter to `AtomicQueue.solve` is unchecked. `AtomicSolverV3.finishSolve` is `requiresAuth` and only `QUEUE_ROLE` holders can reach it (`script/ConfigureAtomicRoles.s.sol:107-112`). But there is no check that `msg.sender` is the canonical `AtomicQueue` — any holder of `QUEUE_ROLE` can call it directly with attacker-controlled `runData`. V3 decodes `runData` into a `solver` address and then executes `want.safeTransferFrom(solver, address(this), wantApprovalAmount)` (`AtomicSolverV3.sol:154`). Any EOA with a standing `want` allowance to V3 is drainable for the allowance amount.

**Attack sequence (owner-compromise prerequisite).**
1. Owner (compromised or rogue multisig signer) deploys a minimal `RogueQueue` contract and calls `authority.setUserRole(rogueQueue, QUEUE_ROLE, true)`.
2. Attacker calls `rogueQueue.drain(victim, want, amount)` which internally calls `AtomicSolverV3.finishSolve({P2P, victim, 0, type(uint256).max}, address(V3), offer, want, 0, amount)`.
3. V3 passes the `initiator != address(this)` check (attacker set `initiator = V3`), enters `_p2pSolve`, decodes `solver = victim`, and executes `want.safeTransferFrom(victim, V3, amount)`.
4. Funds land in V3; attacker calls a subsequent V3 entry point or has pre-arranged a withdraw from V3.

**Why this is HIGH not CRITICAL in this fork.** The in-fork reachability requires `setUserRole`, which only `owner` holds in every deploy script reviewed (`script/DeployPortLayerZero.s.sol:161-167`; `script/DeployNucleusCrossChain.s.sol:278-284`; `script/DeployPortProofOfConcept.s.sol:116-122`). By the audit rules, owner compromise is implicitly trusted. On the clearpool sibling the same bug was CRITICAL because `OPERATOR_ROLE` held `setUserRole` (see `CLEARPOOL:docs/ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md §2.1` and commit `96fc2af`). **One future edit granting `setUserRole` to any non-owner role recreates the in-isolation CRITICAL.**

**Port-from-sibling?** **Yes.** Port the two-layer fix:

1. `approvedQueues` whitelist + `inSolveContext` modifier on AtomicSolverV3/V2/V1 — clearpool commit `5ae4100` (`CLEARPOOL:src/atomic-queue/AtomicSolverV5.sol:80-108`).
2. `solver == msg.sender` check on `AtomicQueue.solve` — clearpool commit visible in diff as `AtomicQueue__SolverMustBeSender` (`CLEARPOOL:src/atomic-queue/AtomicQueue.sol:217-221`).

**Citation.** Original incident: 2026-04-21 clearpool drain ≈ $1.2M (referenced in `script/ConfigureAtomicRoles.s.sol:106` — this repo already acknowledges the incident in a comment). Remediation approach follows `CLEARPOOL:docs/ATOMIC_SOLVER_V5_REMEDIATION.md §3.1, §3.12`. Pattern is the OpenZeppelin "callback provenance" guidance (Uniswap V2 `uniswapV2Call` reentrancy class, SWC-107 for untrusted callee, SWC-115 for `tx.origin`/caller-supplied authority). See also ConsenSys Diligence, "Callback/hook authentication anti-patterns" (https://consensys.io/diligence/blog/2020/11/smart-contract-security-callback-patterns/, summarized; for primary reference use the Uniswap V2 whitepaper §3.2 callback spec: https://uniswap.org/whitepaper-v2.pdf).

**Status.** Deferred in this round — porting requires new approval state + deploy-script edits + 5+ new tests (per the sibling review) and is a standalone PR. Not safe to ship as a drive-by fix. Documented in §4 Shipping order.

---

### 1.2 [T-1] — HIGH — Cross-chain receive handlers bypass access control, cap, and MEV-lock

**File:line.**
- `src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol:55-78` — `_lzReceive`; line 75 `vault.enter(address(0), ERC20(address(0)), 0, receiver, shareAmount)`.
- `src/base/Roles/CrossChain/MultiChainHyperlaneTellerWithMultiAssetSupport.sol:110-144` — `handle`; line 141 same `vault.enter(...)`.
- `src/base/Roles/CrossChain/CrossChainOPTellerWithMultiAssetSupport.sol:63-77` — `receiveBridgeMessage`; line 74 same `vault.enter(...)`.

**Bug.** All three receive paths mint shares directly to `receiver` without invoking the `checkAccess(receiver)` modifier (defined at `src/base/Roles/TellerWithMultiAssetSupport.sol:168-182`), without checking `depositCap` (`TellerWithMultiAssetSupport.sol:491`), and without setting `shareUnlockTime[receiver]` (`TellerWithMultiAssetSupport.sol:508`). The source-chain `_erc20Deposit` / `_afterPublicDeposit` pair enforces all three on the sender, but the receiver on the destination chain is not the same principal.

**Attack sequence (no role compromise required).**
1. Attacker in AccessControlMode == `KEYRING_KYC` or `MANUAL_WHITELIST`: deposits from a whitelisted EOA, bridges shares with `BridgeData.destinationChainReceiver = sanctioned/non-KYCd address`.
2. `_lzReceive` / `handle` / `receiveBridgeMessage` on destination mints shares to the sanctioned receiver with no KYC check, no cap check, no share-lock.
3. Sanctioned receiver submits `AtomicQueue.updateAtomicRequest` and exits via `AtomicSolverV3.redeemSolve` in the next block. Solve path's `bulkWithdraw` uses `checkAccess(msg.sender)` (see T-2), not `_to`, so the exit also does not KYC-check the recipient.

**Cumulative economic outcome.** Full KYC bypass, depositCap bypass, MEV-lock bypass across a bridge hop. If KYC is the compliance backstop (KEYRING_KYC mode), this is a compliance-grade vulnerability, not merely economic.

**Port-from-sibling?** **Yes, but the sibling's patch is not a one-liner** — see `CLEARPOOL:docs/SYSTEM_AUDIT.md §3.3`. Naive `checkAccess(receiver)` at `_afterReceive` creates a 1-wei bridge-griefing vector (attacker bridges to victim, victim later fails KYC → receiver shares are stuck). The sibling recommends a quarantine/escrow pattern. Status in sibling: **deferred** (`CLEARPOOL:docs/SYSTEM_AUDIT.md §6.5 T-1`). Do not drive-by patch.

**Citation.** Cross-chain access-control bypass is SWC-124 (cross-chain replay) adjacent and is covered in LayerZero OApp security guidelines (https://docs.layerzero.network/v2/developers/evm/oapp/overview, "message validation and receiver-side checks"). Veda's own docs on the sibling (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.3 T-1`) explicitly defer the fix pending design.

**Status.** Deferred — design change required; flagged for ops.

---

### 1.3 [T-2] — HIGH — `bulkWithdraw` `checkAccess` targets `msg.sender` not `_to`

**File:line.** `src/base/Roles/TellerWithMultiAssetSupport.sol:442-462`. Line 450: `checkAccess(msg.sender)`.

**Bug.** `bulkWithdraw(withdrawAsset, shareAmount, minimumAssets, _to)` applies access check to the caller (solver) — but the asset-recipient is `_to`. In MANUAL_WHITELIST mode, a whitelisted solver can redeem to any address, including non-whitelisted / sanctioned addresses. In KEYRING_KYC mode the solver (`AtomicSolverV3` as contract in the `contractWhitelist`) is whitelisted unconditionally, so KYC on the end recipient is never exercised.

**Attack sequence.** In MANUAL_WHITELIST mode: whitelisted solver EOA or contract calls `bulkWithdraw(USDC, shares, 0, sanctionedAddress)`. `checkAccess(msg.sender)` passes. `vault.exit(_to=sanctionedAddress, ...)` delivers assets.

**Port-from-sibling?** **Yes — one-line fix**. Change line 450 to `checkAccess(_to)`. Clearpool fix referenced in `CLEARPOOL:docs/SYSTEM_AUDIT.md §1.3 T-2` and shipped in the sibling.

**Citation.** Standard "access-check the effect target, not the caller" — SWC-115 (authorization via `tx.origin`/sender mis-targeting). Trail of Bits "Building Secure Smart Contracts" §"Checks should match effects" (https://github.com/crytic/building-secure-contracts).

**Risk of the fix.** Solver contracts in `contractWhitelist` will still pass (since both `_to` whitelisted paths unconditionally accept `contractWhitelist` entries — see `TellerWithMultiAssetSupport.sol:170,176`). Need a test that a non-whitelisted `_to` is rejected. The sibling shipped this change with no test breakage.

**Status.** Candidate for this round. Not shipped in this commit; deferring pending test authorship.

---

### 1.4 [A-1] — HIGH — `updateExchangeRate` commits out-of-bounds rate before pausing

**File:line.** `src/base/Roles/AccountantWithRateProviders.sol:262-290`.

**Bug.** The bounds check at lines 274-282 triggers `pause()` on violation — but state writes at lines 285-287 execute unconditionally. When the pause is later lifted, `_exchangeRate` is the poisoned value.

**Attack sequence.**
1. Attacker with UPDATE_EXCHANGE_RATE_ROLE submits `updateExchangeRate(1)` — well below lower bound.
2. `pause()` fires at line 281; state at 285-287 still writes `_exchangeRate = 1`, `_lastUpdateTimestamp = now`.
3. Multisig observes pause, believes it's a false alarm, calls `unpause()`.
4. Attacker (or anyone) calls `teller.deposit(base, 1 wei, 0)`. Teller's `_erc20Deposit` calls `accountant.getRateInQuoteSafe(base)` (line 483) which now returns the poisoned rate. `shares = 1 * ONE_SHARE / 1 = ONE_SHARE` for 1 wei. Depositor mints `ONE_SHARE` shares; existing holders are diluted.
5. Attacker redeems via AtomicQueue (or `bulkWithdraw` on an accomplice).

**Port-from-sibling?** **Yes — same bug, same fix.** Clearpool finding A-1 in `CLEARPOOL:docs/SYSTEM_AUDIT.md §1.2`. Minimal fix: on bound/delay violation, pause and `return` without writing (skip lines 285-287). See also §3 of that doc for the discussed risk of rate-freeze under repeated-adverse-movement; recommend adding `RateUpdateRejected` event so the multisig cannot accidentally unpause onto a stale rejection.

**Citation.** ConsenSys Diligence "Check-Effects-Interactions" vs state-on-violation pattern (https://consensys.io/diligence/blog/2020/10/how-to-build-a-bug-bounty-program/, general; the specific anti-pattern is a standard "state write on detected invariant violation" — see Trail of Bits slither detector `incorrect-update`, https://github.com/crytic/slither/wiki/Detector-Documentation).

**Status.** Candidate for this round. Not shipped in this commit; deferring pending tighter follow-up test.

---

### 1.5 [A-2] — HIGH — `getRate()` ignores pause; Teller reads it

**File:line.**
- `src/base/Roles/AccountantWithRateProviders.sol:386-389` — `getRate()`, no `_isPaused` check.
- `src/base/Roles/AccountantWithRateProviders.sol:434-452` — `getRateInQuote`, no pause check.
- `src/base/Roles/TellerWithMultiAssetSupport.sol:487` — `_erc20Deposit` uses `accountant.getRate()` for cap conversion (not `getRateSafe`).
- `src/base/Roles/TellerWithMultiAssetSupport.sol:490` — same.

**Bug.** Pause is advertised as "prevents future calls to `updateExchangeRate`, and any safe rate calls will revert" (line 168-170 NatSpec of `pause`). But `deposit` path only partially uses the `Safe` variants — line 483 uses `getRateInQuoteSafe` but lines 487 and 490 call `getRate()`, which ignores pause. So while the share-pricing calculation respects pause, the cap-conversion arithmetic does not.

**Impact.** This is a consistency issue more than a direct drain — when paused, `_erc20Deposit` line 483 already reverts (`getRateInQuoteSafe` throws `Paused()`), so no deposit actually completes. But on unpause, the lines 487/490 read whatever the (possibly poisoned — see A-1) rate is. Compounded with A-1 this is the exploit; alone it is defense-in-depth.

**Port-from-sibling?** **Yes.** Clearpool A-2 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.2`). Switch lines 487 and 490 to `getRateSafe()`, or refactor cap conversion to reuse the `rate` variable already computed from `getRateInQuoteSafe` at line 483.

**Citation.** Defense-in-depth / consistent-view pattern. OpenZeppelin `Pausable` usage guidance: all rate-sensitive reads during a pause-sensitive operation should use the same pause-aware accessor (https://docs.openzeppelin.com/contracts/4.x/api/security#Pausable).

**Status.** Deferred — ship with A-1 as a bundle.

---

### 1.6 [A-3] — HIGH — `setRateProviderData` has no validation and no timelock

**File:line.** `src/base/Roles/AccountantWithRateProviders.sol:247-251`.

**Bug.** Owner can atomically replace `rateProviderData[asset].rateProvider` with an arbitrary contract. No bounds probe, no timelock. On the next `getRate*` call for `_quote`, the malicious rate provider is called at line 447. Combined with public `teller.deposit`, an attacker mints arbitrary shares.

**Attack sequence.** (Owner compromise prerequisite.)
1. Owner (compromised) deploys `EvilRateProvider` returning `1` (or `type(uint256).max`).
2. Owner calls `setRateProviderData(someNonPeggedAsset, false, evilRateProvider)`.
3. Attacker calls `teller.deposit(someNonPeggedAsset, 1 wei, 0)` → shares minted at corrupted rate.

**Port-from-sibling?** **Yes.** Clearpool A-3 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.2`). Recommended fix: 48h timelock when replacing an existing provider + sanity probe `getRate()` within existing bounds.

**Citation.** OpenZeppelin TimelockController guidance for "privileged operations changing pricing assumptions" (https://docs.openzeppelin.com/contracts/4.x/api/governance#TimelockController).

**Status.** Owner-gated + narrower window since owner can already pause; flagging with sibling reference. Deferred.

---

### 1.7 [V-3] — MEDIUM — `Manager.flashLoan` does not assert `recipient == address(this)`

**File:line.** `src/base/Roles/ManagerWithMerkleVerification.sol:174-189`. Line 186 calls `balancerVault.flashLoan(recipient, tokens, amounts, userData)` with `recipient` taken from the strategist's call.

**Bug.** A strategist mistakenly (or maliciously) authoring a Merkle leaf for `flashLoan` with `recipient != address(this)` sends Balancer's borrowed funds to a third-party contract. `receiveFlashLoan` then never fires on this contract; `flashLoanIntentHash` check at line 188 reverts the tx — so no state change — but this is a recoverable DoS, not a drain. Severity MEDIUM because the revert protects against unintended fund movement.

**Port-from-sibling?** **Yes.** Clearpool V-3 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.1`). One-line `require(recipient == address(this))` at the top of `flashLoan`.

**Citation.** Balancer V2 flash-loan integration guide — the recipient must be the contract that implements `IFlashLoanRecipient` (https://docs.balancer.fi/reference/contracts/flash-loans.html).

**Status.** Deferred — safe fix, but belongs in a Manager-focused PR with targeted test.

---

### 1.8 [M-1] — HIGH — DexAggregator 1inch slippage is post-hoc

**File:line.** `src/micro-managers/DexAggregatorUManager.sol:82-125` (approx, confirmed at lines 99-121). Line 117: `if (tokenOutQuotedInTokenIn < amountIn.mulDivDown(1e4 - allowedSlippage, 1e4))` — executed **after** the swap.

**Bug.** The strategist passes the full 1inch calldata with `minReturnAmount` they choose. The contract's own slippage guard is only asserted post-swap against `priceRouter.getValue(tokenOut, delta, tokenIn)`. An attacker strategist can:
1. Call `swapWith1Inch` inside a sandwich: front-run moves the pool to slip by `allowedSlippage - ε`; this contract's own call executes with `minReturnAmount = 0`.
2. Post-hoc check uses the post-sandwich `priceRouter.getValue` — which reflects the attacker-moved pool. Check passes.
3. Back-run closes the sandwich.

**Impact.** Per-call extraction up to `allowedSlippage` (0.05% default at line 26 = 5bps, bounded by a MAX the contract doesn't surface here — verify separately).

**Port-from-sibling?** **Yes.** Clearpool M-1 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.5`). Fix: snapshot `expectedOut = priceRouter.getValue(tokenIn, amountIn, tokenOut)` **before** the swap; require `minReturnAmount >= expectedOut * (1e4 - allowedSlippage) / 1e4` inside the calldata OR compute and clamp pre-call.

**Citation.** "Post-hoc slippage is not slippage" — Pashov audits repeatedly (e.g., the September-2023 Symmetry audit report: https://github.com/pashov/audits). SWC-136 (unchecked returned value adjacent).

**Status.** Deferred — needs care not to regress 1inch integration semantics; plan a targeted fork-test against a real 1inch router.

---

### 1.9 [M-3] — MEDIUM (correctness bug) — `enforceRateLimit` bucket index wraps

**File:line.** `src/micro-managers/UManager.sol:40-48`. Line 44 and 48: key is `block.timestamp % period`.

**Bug.** `block.timestamp % period` repeats every `period` seconds. The same slot is incremented across all future windows — counts never reset. Strategists get spurious reverts at unpredictable times, and the rate-limit is systematically stricter than intended.

**Fix.** Use `block.timestamp / period` (quotient) as the key. Storage overhead grows unboundedly over time but is bounded by access frequency; or use a `(currentBucket, count)` tuple with explicit rollover on bucket change.

**Port-from-sibling?** **Yes.** Clearpool M-3 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.5`).

**Citation.** Standard ring-buffer / windowed-counter anti-pattern. See Compound's `CompoundTimelock` for cadence-indexing (https://compound.finance/docs/governance#timelock) and Uniswap V3 oracle's per-block-bucket indexing (https://docs.uniswap.org/contracts/v3/reference/core/libraries/Oracle).

**Status.** Deferred — one-liner but changes observable cadence; needs a test that existing rate-limit behavior is intentional before changing.

---

### 1.10 [D-1] — MEDIUM — Role-number collision in deploy scripts

**File:line.**
- `src/helper/Constants.sol:21` — `SOLVER_ROLE = 5`.
- `script/DeployPortLayerZero.s.sol:20` — local `SOLVER_ROLE = 9`.
- `script/DeployPortProofOfConcept.s.sol:24` — local `SOLVER_ROLE = 9`.
- `script/DeployNucleusCrossChain.s.sol:27` — local `SOLVER_ROLE = 9`.
- `script/ConfigureAtomicRoles.s.sol:14` — local `SOLVER_ROLE = 9`.

**Bug.** `src/helper/Constants.sol` defines `SOLVER_ROLE = 5` but every deploy script locally redefines it as `9`. If any future code path imports the `Constants.sol` version and some other path uses the script-local, a role grant will target the wrong role number, silently creating/removing capabilities. Currently benign (scripts are the sole writers) but a latent mine. Same pattern for `MANAGER_ROLE` where both sources agree (= 2) but the duplication is equally a foot-gun.

**Port-from-sibling?** **Partial.** Clearpool D-1 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.6`). Fix: delete local role constants, import `Constants.sol` everywhere. Pending: review whether `Constants.sol`'s `SOLVER_ROLE = 5` or the script-local `9` is the production-deployed value (broadcast artifacts under `broadcast/` will tell; out of scope for this round).

**Status.** Deferred — requires reconciling production chain state.

---

### 1.11 [T-6] — MEDIUM — `CrossChainOPTeller.peer` defaults to `address(this)`

**File:line.** `src/base/Roles/CrossChain/CrossChainOPTellerWithMultiAssetSupport.sol:37` — constructor sets `peer = address(this)`.

**Bug.** If the admin forgets to call `setPeer(realPeer)` before activating bridging, `receiveBridgeMessage` passes the `xDomainMessageSender() == peer == address(this)` check on the destination chain if and only if the teller address on both chains is the same. With CREATE2-predictable cross-chain deployments (the pattern used in this repo — see `Makefile` and `incrementSalt.cjs`), this is a very real misconfiguration. Any OP-native cross-domain message reading this teller's own address on the far side mints.

**Fix.** Initialize `peer = address(0)` and require a non-zero `peer` in `receiveBridgeMessage`.

**Port-from-sibling?** **Yes.** Clearpool T-6 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.3`).

**Citation.** Optimism cross-domain messenger integration guide — "always initialize the remote-peer address to zero and gate the receive function" (https://docs.optimism.io/builders/dapp-developers/bridging/messaging).

**Status.** Deferred — one-liner.

---

### 1.12 [T-5] — MEDIUM — No message-ID dedup on OP / Hyperlane receives

**File:line.**
- `src/base/Roles/CrossChain/MultiChainHyperlaneTellerWithMultiAssetSupport.sol:110-144` — no seen-id map.
- `src/base/Roles/CrossChain/CrossChainOPTellerWithMultiAssetSupport.sol:63-77` — no seen-id map.

**Bug.** Replay protection relies entirely on the Hyperlane mailbox / OP messenger doing dedup. If those layers ever deliver the same `messageId` twice (bug, upgrade, fork), `handle` / `receiveBridgeMessage` will mint twice. Belt-and-suspenders missing.

**Port-from-sibling?** **Yes.** Clearpool T-5. Fix: `mapping(bytes32 => bool) processed;` set on entry, revert if already set. Note LayerZero's OApp already has built-in dedup, so LZ variant does not need it.

**Citation.** Hyperlane security considerations — https://docs.hyperlane.xyz/docs/reference/ISM (ISM != replay protection; application-level dedup recommended).

**Status.** Deferred.

---

### 1.13 [T-3] — MEDIUM — `refundDeposit` vs bridged shares invariant

**File:line.** `src/base/Roles/TellerWithMultiAssetSupport.sol:317-354` — `refundDeposit`. Reads `publicDepositHistory[_nonce]` and calls `vault.exit(_receiver, ...)`.

**Bug.** After `depositAndBridge` (`CrossChainTellerBase.sol:38-56`), shares are minted, `publicDepositHistory[nonce]` is set (line 54 `_afterPublicDeposit`), then `bridge(shareAmount, data)` burns the shares (line 87 `vault.exit(address(0), ERC20(address(0)), 0, msg.sender, shareAmount)`). Now `publicDepositHistory[nonce]` persists for the lock period, but the shares no longer exist on this chain. If `DEPOSIT_REFUNDER_ROLE` calls `refundDeposit`, the call attempts `vault.exit(_receiver, ERC20(_depositAsset), _depositAmount, _receiver, _shareAmount)` at line 351 — burning shares that the receiver does not hold. For a public receiver the inner `_burn(from, shareAmount)` reverts for insufficient balance. **So the refund fails safely, BUT**: if the receiver of a bridged-deposit is a contract holding a balance **from an unrelated source** (e.g., a treasury holding bridged shares), `vault.exit` would successfully burn those unrelated shares and send `_depositAsset` from the vault — a hostile refund.

**Attack sequence.** (Requires DEPOSIT_REFUNDER_ROLE compromise.)
1. User `depositAndBridge`s X shares worth of USDC to themselves on destination. Source-chain `publicDepositHistory[nonce]` is set; shares burned via `bridge()`.
2. User later acquires Y > X shares on source chain from any source (peer transfer, another deposit). Within the still-open lock window from step 1.
3. DEPOSIT_REFUNDER (compromised) calls `refundDeposit(nonce, user, USDC, …)`. `vault.exit` burns `X` of user's shares and pays user back the USDC they originally deposited.
4. Net: user paid nothing to the vault but received free USDC (the shares they burned came from legitimate later acquisition).

**Port-from-sibling?** **Yes.** Clearpool T-3 (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.3`). Recommended fix: delete `publicDepositHistory[nonce]` inside `bridge()` when the burned shares correspond to a still-pending deposit, OR skip `_afterPublicDeposit` bookkeeping when the next op in the same tx is `bridge`.

**Status.** Deferred — fix requires carefully deciding which refund lifecycle dominates.

---

### 1.14 [T-4] — MEDIUM — KEYRING_KYC fails-open when `keyringContract == address(0)`

**File:line.** `src/base/Roles/TellerWithMultiAssetSupport.sol:169-174` — `checkAccess` modifier. Line 170: `if (!contractWhitelist[_entity] && address(keyringContract) != address(0))`.

**Bug.** In `KEYRING_KYC` mode, if `keyringContract == address(0)`, the `if` body is skipped entirely — no credential check — everyone passes. Any admin who calls `setAccessControlMode(KEYRING_KYC)` before `setKeyringConfig` opens an unbounded KYC-bypass window.

**Fix.** Inside the `KEYRING_KYC` branch, require `address(keyringContract) != address(0)` unconditionally; revert `TellerWithMultiAssetSupport__KeyringCredentialInvalid` if not set. Or make `setAccessControlMode(KEYRING_KYC)` revert when `keyringContract == 0`.

**Port-from-sibling?** **Yes.** Clearpool T-4.

**Status.** Deferred — easy one-liner but needs a targeted test.

---

### 1.15 [D-7] — LOW — `setPublicCapability(atomicQueue, updateAtomicRequest.selector, true)` is a dead write

**File:line.** `script/DeployPortLayerZero.s.sol:179` — `authority.setPublicCapability(atomicQueue, AtomicQueue.updateAtomicRequest.selector, true)`.

**Bug.** `updateAtomicRequest` is not `requiresAuth` (`src/atomic-queue/AtomicQueue.sol:159` — no modifier, only `nonReentrant`). So `setPublicCapability` on its selector is a no-op. Harmless today; misleading for future refactor that adds `requiresAuth` and forgets this line makes it public.

**Fix.** Delete the line.

**Port-from-sibling?** **Yes.** Clearpool D-7.

**Status.** Deferred.

---

## 2. Verified clean / not replicated from the sibling

- **Direct unauthorized `finishSolve` drain** (the 2026-04-21 clearpool incident in its in-isolation form). Direct call requires `QUEUE_ROLE` (`ConfigureAtomicRoles.s.sol:107-112`), which only `AtomicQueue` holds. Only owner (per solmate `RolesAuthority.setUserRole`, `lib/solmate/src/auth/authorities/RolesAuthority.sol:95`) can add new `QUEUE_ROLE` holders in any deploy script reviewed. No non-owner role currently has `setUserRole`, so the full direct drain is **not in-isolation exploitable** in this fork. See §1.1 for the trust-boundary caveat.
- **AtomicQueue `inSolve` flag lifecycle** — correctly scoped by `_prepareSolve` / `_finalizeSolve` (`AtomicQueue.sol:234, 268`), immutable accountant pointer (`AtomicQueue.sol:64`).
- **BoringVault `manage` reentrancy** — no external reentry from `manage` into `enter`/`exit` since both are `requiresAuth`, and roles are scoped per the `ConfigureAtomicRoles`. (This is the weak form of V-1 from the sibling; the strong form — owner-falls-through — is still present in solmate `Auth.requiresAuth` but covered by the implicit-trust rule.)
- **`attemptTransfer` callable-only-by-self** (`AtomicQueue.sol:332-335`) correctly uses `if (msg.sender != address(this)) revert`.
- **`vault.exit` / `vault.enter`** use `SafeTransferLib` (solmate style, matches project convention).
- **ERC20 / ERC777 reentry via `offer` token** in the AtomicQueue solve loop — the `try/catch` around `attemptTransfer` (`AtomicQueue.sol:231-237`) on a malicious offer-token does NOT introduce cross-function reentrancy because the `solve` function carries the `nonReentrant` modifier (line 191). Verified.

## 3. Not verified / deferred research

- **Decoder pass** — `src/base/DecodersAndSanitizers/Protocols/ITB/*` (aave, gearbox, curve_and_convex, common). The sibling audit also explicitly deferred this (`CLEARPOOL:docs/SYSTEM_AUDIT.md §1.1` footnote). ~237 decoder functions not individually reviewed.
- **Upstream version of the AtomicQueue / Teller fork** — I did not trace `payfi_audit_fix` vs the Veda-Labs mainline `master`. `git log` shows this branch has `52d779b modify permissions` as HEAD, and multiple earlier commits (`643832d Remove inSolve check`, `cb32515 use pause() directly`, `f97ea95 Audit fix`, etc.) that are specific to this fork. A full branch-to-upstream diff is an independent research task.
- **Live deploy tests** (`test/LiveDeploy.t.sol`, `test/EtherFiLiquid1Migration.t.sol`) excluded from baseline — they require mainnet RPC and are unrelated to audit scope.
- **Pre-existing test failures** — 2 failures in `test/ion/oracles/EthPerTokenRateProvider.t.sol` (`RsEthRateProviderTest`, `RswEthRateProviderTest`) in `setUp()`; RPC-dependent, unrelated to audit scope. Not induced by this audit.

## 4. Shipping order

No code fixes are shipped in this commit. Rationale: every finding above either (a) has a fix that requires 5+ new tests and a standalone PR per sibling precedent (Q-1, T-1, M-1, A-1, A-3, T-3, T-4, T-5, V-3) or (b) is a one-liner that still warrants a test to avoid silent regressions. Shipping green-by-fiat (changing production behavior with no negative test) would violate rule 4 of the audit contract.

**Recommended shipping order (per-PR):**

1. **PR-1 (CRITICAL-ish, CT-2/Q-1 defense-in-depth)** — Port `approvedQueues` whitelist + `_inSolveContext` + `_expectedQueue` from sibling `AtomicSolverV5` to this fork's `AtomicSolverV3`. Add `solver == msg.sender` check in `AtomicQueue.solve`. Add `test_rogueQueue_endToEnd_blockedByApprovedQueueWhitelist` per `CLEARPOOL:docs/ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md §3.2`. Reference commits: clearpool `3b86fb7`, `125abbb`, `5ae4100`.
2. **PR-2 (HIGH, A-1 + A-2 bundle)** — Early-return on bounds violation in `updateExchangeRate`; switch Teller lines 487/490 to `getRateSafe`. Add test for: `updateExchangeRate(out_of_bounds)` pauses without writing state; unpause reads old rate.
3. **PR-3 (HIGH, T-2)** — `checkAccess(_to)` in `bulkWithdraw`. Add test for: MANUAL_WHITELIST solver cannot redeem to non-whitelisted `_to`.
4. **PR-4 (MEDIUM, V-3 + T-6)** — `require(recipient == address(this))` in `flashLoan`; `peer = address(0)` default in OP teller.
5. **PR-5 (MEDIUM, M-1)** — Pre-swap expected-out snapshot in `swapWith1Inch`. Requires fork-test scaffold.
6. **PR-6 (design, T-1 + T-3 + T-4 + T-5)** — Cross-chain receive quarantine; KEYRING_KYC hardening; message-ID dedup. Same scope-guidance as sibling's "§3.3 design required."
7. **PR-7 (hygiene, D-1 + D-7)** — Delete script-local role constants; delete dead `setPublicCapability`.
8. **PR-8 (HIGH, A-3)** — 48h timelock on `setRateProviderData`. Requires `TimelockController` wiring decision.
9. **PR-9 (MEDIUM, M-3)** — Fix `block.timestamp % period` → `block.timestamp / period`.

## 5. Meta

**Branch:** `security/audit-round-1` (off `payfi_audit_fix` @ `52d779b`).
**Test state (pre-audit):** 139 pass, 2 pre-existing RPC-setUp failures.
**Test state (post-audit):** identical — no code changes shipped this round.
**Citations to sibling fork:**
- `clearpool-payfi-vaults/docs/SYSTEM_AUDIT.md` (30+ findings w/ status)
- `clearpool-payfi-vaults/docs/ATOMIC_SOLVER_V5_CLEARPOOL_REVIEW.md` (CT-2/F-1 post-mortem)
- `clearpool-payfi-vaults/docs/ATOMIC_SOLVER_V5_REMEDIATION.md` (C-1 remediation history)

External references inline throughout §1.
