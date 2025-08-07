# Critical Changes in Payfi Boring Vault Implementation

## AtomicQueue - Complete Redesign
### From Limit Orders → NAV Redemption Queue
- **REMOVED**: `atomicPrice` field - users can no longer set desired prices
- **ADDED**: Direct integration with `AccountantWithRateProviders` for NAV
- **All redemptions at current NAV** - no price negotiation
- Protects users from setting bad prices but removes price control

## AccountantWithRateProviders - New Features
### Lending Rate Mechanism
- Auto-compounding interest via `lendingRate`
- Separate management fees from vault growth
- Real-time NAV calculation: `getRate()` includes accrued interest
- Checkpoint system for accurate fee accounting

### New Functions
- `getBorrowerRate()`: Total rate (lending + management)
- `checkpoint()`: Force interest/fee accrual
- `previewFeesOwed()`: View unclaimed fees

## TellerWithMultiAssetSupport - Enhanced Access Control
### Three Modes
1. **DISABLED** (0): Open access
2. **KEYRING_KYC** (1): KYC verification required
3. **MANUAL_WHITELIST** (2): Explicit whitelisting

### New Features
- `depositCap`: Global deposit limit
- `contractWhitelist`: Special whitelist for protocols/AMMs
- Separate from `manualWhitelist` for EOAs

