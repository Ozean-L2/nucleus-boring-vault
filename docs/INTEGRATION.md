# BoringVault Integration Documentation for LP Providers

> For architectural details and security design, see the main [README](../README.md)

## Overview

This guide covers integration for LP providers. For background on MEV protection and the merkle verification system, refer to the [Arctic Architecture](../README.md#arctic-architecture) section.

As an external LP provider, you'll interact with the BoringVault through public deposit functions and the AtomicQueue for withdrawals. The bulk functions are reserved for protocol-controlled operations.
...

## Safety Features

The vault implements multiple MEV protection mechanisms (detailed in [TellerWithMultiAssetSupport](../README.md#tellerwithmultiassetsupport)):

- Share lock periods prevent flash loan attacks
- AtomicQueue prevents sandwich attacks
- Rate bounds prevent manipulation

## Key Changes from Standard BoringVault

### 1. **Lending Rate Mechanism**

The AccountantWithRateProviders now includes:

- **Lending Rate**: Continuously accruing interest that increases vault NAV
- **Management Fee**: Charged on top of lending rate
- **Auto-compounding**: Interest accrues in real-time

```solidity
// Total rate paid by borrowers (generates your yield)
getBorrowerRate() = lendingRate + managementFee

// Real-time NAV with accrued interest
getRate() returns current exchange rate including interest
```

### 2. **Access Control (Check with Protocol Team)**

The vault has three possible access control modes:

- **DISABLED (Mode 0)**: No restrictions - anyone can deposit/withdraw
- **KEYRING_KYC (Mode 1)**: Requires KYC verification through Keyring
- **MANUAL_WHITELIST (Mode 2)**: Requires explicit whitelisting

**Important**: Check current mode with protocol team or query:

```solidity
uint256 currentMode = teller.accessControlMode();
// 0 = DISABLED (no restrictions)
// 1 = KEYRING_KYC
// 2 = MANUAL_WHITELIST
```

If mode is **not DISABLED**, you'll need whitelisting:

- **Contract Whitelist**: For smart contracts/protocols (recommended for Plume Nest vault)
- **Manual Whitelist**: For EOA addresses
- Contact protocol admin for whitelisting if required


# BoringVault Key Features

## Lending Rate Mechanism
The vault generates yield through a lending rate system:
- **Lending Rate**: Continuously accruing interest that increases vault NAV
- **Management Fee**: Additional fee charged on top of lending rate
- **Auto-compounding**: Interest accrues in real-time without requiring transactions

```solidity
// Total rate paid by borrowers (generates LP yield)
getBorrowerRate() = lendingRate + managementFee

// Real-time NAV including accrued interest
getRate() // returns current exchange rate with interest
```

## Access Control Modes
The vault supports three access control configurations:

| Mode | Name | Requirements |
|------|------|-------------|
| 0 | `DISABLED` | Open access - no restrictions |
| 1 | `KEYRING_KYC` | Requires KYC verification via Keyring |
| 2 | `MANUAL_WHITELIST` | Requires explicit whitelisting |

```solidity
// Check current mode
uint256 mode = teller.accessControlMode();

// Check whitelist status (if mode ≠ 0)
bool isWhitelisted = teller.contractWhitelist(yourContract);  // For contracts
bool isWhitelisted = teller.manualWhitelist(yourEOA);        // For EOAs
```

## NAV-Based Withdrawal Queue
The AtomicQueue processes all withdrawals at current NAV (not limit orders):
- No price setting - redemptions at real-time vault NAV
- Fair value for all users
- Protection against MEV attacks

```solidity
// Request withdrawal (no price parameter)
atomicQueue.updateAtomicRequest(
    vaultShares,  // your shares
    USDC,         // desired asset
    deadline,     // expiry
    amount        // share amount
);
// Receives: amount * currentNAV / 1e18
```

## Deposit Integration for LPs

### Public Deposit Function

```solidity
function deposit(
    ERC20 depositAsset,
    uint256 depositAmount,
    uint256 minimumMint
) external returns (uint256 shares)
```

**Integration Steps:**

1. Check access control mode (may need whitelisting)
2. Approve BoringVault to spend your deposit asset
3. Call `deposit` with slippage protection

**Example Integration:**

```solidity
// 1. Check if whitelisting needed
uint256 mode = teller.accessControlMode();
if (mode != 0) {
    // Coordinate with protocol team for whitelisting
    require(teller.contractWhitelist(address(this)), "Not whitelisted");
}

// 2. Approve the vault (not the teller)
USDC.approve(boringVaultAddress, amount);

// 3. Calculate minimum shares (with 0.5% slippage)
uint256 expectedShares = amount * 1e18 / accountant.getRateInQuote(USDC);
uint256 minimumMint = expectedShares * 995 / 1000;

// 4. Deposit through teller
uint256 shares = teller.deposit(USDC, amount, minimumMint);
```

### Deposit with Permit (Gas Efficient)

```solidity
function depositWithPermit(
    ERC20 depositAsset,
    uint256 depositAmount,
    uint256 minimumMint,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) external returns (uint256 shares)
```

### Important: Share Lock Period

- After deposit, shares are locked for `shareLockPeriod` (max 3 days)
- During lock period:
  - Cannot transfer shares
  - Deposit can be refunded by protocol (protection mechanism)
- Check current period: `teller.shareLockPeriod()`

## Withdrawal Integration for LPs

### Using AtomicQueue (Recommended for LPs)

Since `bulkWithdraw` is admin-only, LPs should use the AtomicQueue:

```solidity
// 1. Approve AtomicQueue to spend your vault shares
boringVault.approve(atomicQueueAddress, shareAmount);

// 2. Create withdrawal request
atomicQueue.updateAtomicRequest(
    boringVault,     // offer asset (your vault shares)
    USDC,           // want asset (what you want back)
    deadline,       // unix timestamp when request expires
    shareAmount     // amount of shares to withdraw
);

// 3. Wait for solver to fulfill
// Solvers will execute when liquidity is available
```

**Monitoring Your Request:**

```solidity
AtomicRequest memory request = atomicQueue.getUserAtomicRequest(
    yourAddress,
    boringVault,
    USDC
);
// Check request.offerAmount to see pending amount
```

## Rate Monitoring

### Reading Current Rates

```solidity
// Get NAV in base asset (includes accrued interest)
uint256 rate = accountant.getRate();

// Get NAV in your deposit asset (e.g., USDC)
uint256 rateInUSDC = accountant.getRateInQuote(USDC);

// Check yield-generating rate (in basis points)
uint256 borrowerRate = accountant.getBorrowerRate();
// Example: 500 = 5% APY

// Calculate your share value
uint256 myShareValue = myShares * rateInUSDC / 1e18;
```

## Integration Checklist for Plume

### Pre-Integration Setup:

- [ ] **Check access control mode**: `teller.accessControlMode()`
- [ ] If not DISABLED (0), coordinate with protocol team for whitelisting
- [ ] Verify your deposit asset is supported: `teller.isSupported(asset)`
- [ ] Check deposit cap not exceeded: `teller.depositCap()`
- [ ] Note the share lock period: `teller.shareLockPeriod()`

### For Deposits:

- [ ] Confirm access (check mode or whitelist status if applicable)
- [ ] Approve BoringVault (not Teller) for deposit amount
- [ ] Call `deposit()` or `depositWithPermit()`
- [ ] Use appropriate `minimumMint` for slippage protection
- [ ] Account for share lock period in your liquidity planning

### For Withdrawals:

- [ ] Approve AtomicQueue to spend vault shares
- [ ] Create request via `updateAtomicRequest()`
- [ ] Set reasonable deadline (not too short)
- [ ] Monitor request status and fulfillment

### For Yield Tracking:

- [ ] Poll `accountant.getRateInQuote(yourAsset)` for NAV
- [ ] Track `getBorrowerRate()` for APY estimates
- [ ] Monitor your position: `shares * rate / 1e18`

## Key Functions Reference

### TellerWithMultiAssetSupport (Public Functions)

```solidity
// Access control check
function accessControlMode() returns (uint256)  // 0=DISABLED, 1=KEYRING_KYC, 2=MANUAL_WHITELIST
function contractWhitelist(address) returns (bool)  // Check if contract is whitelisted
function manualWhitelist(address) returns (bool)  // Check if address is whitelisted

// Deposits (access control may apply based on mode)
function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint) returns (uint256 shares)
function depositWithPermit(...) returns (uint256 shares)

// View functions
function isSupported(ERC20) returns (bool)
function depositCap() returns (uint256)
function shareLockPeriod() returns (uint64)
function isPaused() returns (bool)
```

### AccountantWithRateProviders (Read Functions)

```solidity
function getRate() returns (uint256)  // NAV in base asset
function getRateInQuote(ERC20 quote) returns (uint256)  // NAV in specific asset
function getBorrowerRate() returns (uint256)  // Total rate in basis points
function previewFeesOwed() returns (uint256)  // Accrued management fees
```

### AtomicQueue (Withdrawal Functions)

```solidity
function updateAtomicRequest(ERC20 offer, ERC20 want, uint64 deadline, uint96 offerAmount)
function getUserAtomicRequest(address user, ERC20 offer, ERC20 want) returns (AtomicRequest)
```

## Access Control Architecture

The protocol uses a `RolesAuthority` contract to manage permissions:

- **Protocol Admin**: Controls all aspects including access mode
- **Access Control Modes**: Can be changed by admin
- **Whitelisted Contracts**: Can deposit on behalf of users (when mode requires)
- **Solvers**: Execute AtomicQueue requests

**Note**: Access requirements depend on current mode setting. Coordinate with protocol team to understand current configuration.

## Safety Considerations

1. **Share Locks**: Plan liquidity around lock periods
2. **Rate Bounds**: NAV updates are bounded to prevent manipulation
3. **Pause Mechanism**: Protocol can pause during emergencies
4. **Slippage Protection**: Always set `minimumMint`/`minimumAssets`
5. **AtomicQueue Deadlines**: Set reasonable deadlines for withdrawal requests

## Contract Addresses & ABIs

ABIs can be found in /out folder

## Support

For access control status, whitelisting needs, and integration support, contact the protocol admin team.
