# nucleus-boring-vault — Security Audit Round 2 Validation

**Branch:** `security/audit-round-1` @ `3336edc` (off `payfi_audit_fix @ 52d779b`).
**Test baseline:** `forge test` excluding `test/ion/**`, `test/LiveDeploy*`, `test/EtherFiLiquid*`: **112 passed, 0 failed** (~21s). Fork-dependent suites excluded — environmental.

---

## Q-1 — Rogue-queue `finishSolve` drain

### Code confirmed
- `AtomicQueue.sol:182-198` — `solve(..., address solver)` calls `IAtomicSolver(solver).finishSolve(runData, msg.sender, …)` at line 195 with **no `solver == msg.sender` check** and no solver whitelist.
- `AtomicSolverV3.sol:101-123` — `finishSolve` only guards `if (initiator != address(this)) revert` at line 112. `initiator` is a caller-supplied parameter; no `msg.sender == _expectedQueue`, no `approvedQueues`, no `_inSolveContext`.

### Reachability — R1 **UNDERCOUNTED**. Three deploy scripts disagree:

- `ConfigureAtomicRoles.s.sol:104-106` makes `finishSolve` a **`setPublicCapability`** — anyone can call it directly:

```solidity
authority.setPublicCapability(atomicSolver, finishSolve.selector, true);
```

- `DeployPortLayerZero.s.sol:161` and `DeployNucleusCrossChain.s.sol:269, 304` gate it to `QUEUE_ROLE` (role-gated, as R1 claimed).
- `DeployPortProofOfConcept.s.sol` — no `finishSolve` grant.

**Two different production topologies exist.** In any deployment that runs `ConfigureAtomicRoles.s.sol` (the script literally named for atomic-queue role setup), `finishSolve` is publicly callable. **Q-1 becomes a direct-call CRITICAL**: attacker crafts `runData` with `initiator = address(AtomicSolverV3)`, `solver = victim`; `finishSolve` → `_p2pSolve` → `want.safeTransferFrom(victim, AtomicSolverV3, amount)` on any EOA with a standing `want` allowance to V3. No role compromise, no owner compromise.

In the LayerZero / NucleusCrossChain topology, Q-1 remains HIGH (trust-boundary) as R1 analyzed: `setUserRole` is owner-only (`lib/solmate/src/auth/authorities/RolesAuthority.sol:95`) and no non-owner role holds it across the reviewed scripts.

### Severity revision
R1: HIGH. R2: **CRITICAL if `ConfigureAtomicRoles.s.sol` is live, HIGH otherwise.** Ops must verify `broadcast/` artifacts before accepting R1's severity. Immediate config-only hotfix is trivial: change line 104 from `setPublicCapability` to `setRoleCapability(QUEUE_ROLE, …)`.

### Sibling fix portability — confirmed
Commits `3b86fb7` (`_inSolveContext`), `125abbb` (`_expectedQueue` + `AtomicQueue__SolverMustBeSender`), `5ae4100` (owner-gated `approvedQueues` whitelist) exist in `clearpool-payfi-vaults` and are mechanical ports: three state vars, one modifier, one owner setter, one extra check in `solve`. R1's deferral to a standalone PR holds.

---

## T-1 — Cross-chain receive bypasses KYC/cap/lock

### Code confirmed
- `MultiChainLayerZeroTellerWithMultiAssetSupport.sol:75` — `vault.enter(address(0), ERC20(address(0)), 0, receiver, shareAmount)`.
- `MultiChainHyperlaneTellerWithMultiAssetSupport.sol:141` — same shape (after `receiver != 0` sanity check).
- `CrossChainOPTellerWithMultiAssetSupport.sol:74` — same shape (after messenger + peer checks).
- `_afterReceive` in `CrossChainTellerBase.sol:137-139` only emits an event.

**No `checkAccess(receiver)`, no `depositCap`, no `shareUnlockTime[receiver]`.**

### Attack sequence — viable with ConfigureAtomicRoles wiring, no role compromise
1. Attacker deposits from whitelisted EOA on source chain (MANUAL_WHITELIST / KEYRING_KYC).
2. `depositAndBridge(..., destinationChainReceiver = sanctioned_addr, …)`.
3. Destination `_lzReceive` mints to `sanctioned_addr` with no check and no share-lock.
4. `sanctioned_addr` calls `AtomicQueue.updateAtomicRequest` (public, no `requiresAuth` at `AtomicQueue.sol:159`).
5. Solver's `redeemSolve` → `teller.bulkWithdraw(want, …, solver)`. `bulkWithdraw` does `checkAccess(msg.sender)` (T-2), and `AtomicSolverV3` is in `contractWhitelist` (`ConfigureAtomicRoles.s.sol:113-115`) — passes. Solver forwards assets to `sanctioned_addr`.

No KYC ever exercised on the end recipient. Compliance-grade bypass.

### Severity — R1 correct at HIGH
Sibling defers (quarantine/escrow design required; naive `checkAccess(receiver)` at `_afterReceive` creates a griefing vector). Defer stands.

---

## A-1 — Bad rate committed before pause

### Code confirmed (`AccountantWithRateProviders.sol:262-290`)
- Line 270: `_checkpointInterestAndFees()` runs **before** the bounds check — rejected rate advances `_lastAccrualTime`. Sibling commit `b258483` moves this below the bounds check.
- Lines 274-282: bounds/delay check → `pause()` on violation.
- Lines 285-287: **unconditional writes** of `_exchangeRate`, `_totalSharesLastUpdate`, `_lastUpdateTimestamp` after the pause call.

On governance unpause the attacker's rate survives. `getRate()` never checks pause (A-2), and `_erc20Deposit` mixes `getRateInQuoteSafe` (line 483) with `getRate` (lines 487, 490).

### Sibling fix — confirmed, one-commit portable
`b258483` shows the full pattern: internal `_pause()` + early-return without writes + `ExchangeRateUpdateRejected` event + `_checkpointInterestAndFees` below bounds. Also bundles A-4 (`MAX_UPPER_BOUND`/`MIN_LOWER_BOUND`) and A-7 (split `pause` external/internal). Clean port.

### Severity — R1 correct at HIGH
`UPDATE_EXCHANGE_RATE_ROLE` is held by `exchangeRateBot` (a hot key, `DeployNucleusCrossChain.s.sol:285, 320`). HIGH stands.

---

## Cross-cutting

1. **R1's largest miss**: the `setPublicCapability` on `finishSolve` at `ConfigureAtomicRoles.s.sol:104-106`. This inverts Q-1's severity if that script is production. Must be verified against `broadcast/` artifacts.
2. **Inconsistent role wiring** across the three deploy scripts (same contract, different capability regime) — add to R1 §1.10 D-1.
3. **No code shipped this round; no regression possible.** PR-1 should lead the shipping order and be re-scoped to include the `setPublicCapability → setRoleCapability` config fix as an immediate hotfix, independent of the full sibling port.
