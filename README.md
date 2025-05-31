# Token Vesting Contract

A smart contract for managing token vesting schedules on the Stacks blockchain.

## What it does

This contract lets you lock up tokens and release them over time to beneficiaries. Perfect for employee stock options, investor lockups, or any time-based token distribution.

## Key Features

- **Cliff Periods**: Tokens don't vest until after a cliff period
- **Linear Vesting**: After the cliff, tokens vest gradually over time
- **Multiple Schedules**: Each person can have multiple vesting schedules
- **Revocable Options**: Choose if schedules can be cancelled
- **Admin Controls**: Pause contract or emergency withdraw

## How it works

1. **Create Schedule**: Admin creates a vesting schedule for a beneficiary
2. **Wait for Cliff**: No tokens are available until the cliff period ends
3. **Linear Release**: After cliff, tokens become available gradually
4. **Claim Tokens**: Beneficiary calls `release-tokens` to claim available tokens

## Main Functions

### For Admins

- `create-vesting-schedule` - Set up a new vesting schedule
- `revoke-vesting` - Cancel a revocable schedule
- `toggle-contract-pause` - Pause/unpause the contract
- `emergency-withdraw` - Emergency token withdrawal

### For Beneficiaries

- `release-tokens` - Claim available vested tokens

### For Everyone (Read-Only)

- `get-schedule-summary` - Get complete schedule info
- `get-releasable-amount` - Check how many tokens can be claimed
- `get-vested-amount` - Check total vested so far
- `is-cliff-passed` - Check if cliff period is over

## Example Usage

```clarity
;; Create a 4-year vesting schedule with 1-year cliff
(contract-call? .token-vesting create-vesting-schedule
  'SP1ABC...  ;; beneficiary
  .my-token   ;; token contract
  u1000000    ;; 1M tokens
  u1000       ;; starts at block 1000
  u52560      ;; 1 year cliff (52560 blocks)
  u210240     ;; 4 year total vesting (210240 blocks)
  true        ;; revocable
)

;; Beneficiary claims tokens
(contract-call? .token-vesting release-tokens
  'SP1ABC...  ;; beneficiary
  u1          ;; schedule ID
  .my-token   ;; token contract
)
```

## Schedule Parameters

- **beneficiary**: Who gets the tokens
- **token-contract**: Which token to vest
- **total-amount**: Total tokens to vest
- **start-time**: When vesting starts (block height)
- **cliff-duration**: Blocks until first vesting
- **vesting-duration**: Total vesting period in blocks
- **revocable**: Can the schedule be cancelled?

## Time Calculations

- Uses Stacks block height for timing
- ~10 minutes per block on average
- 1 day ≈ 144 blocks
- 1 year ≈ 52,560 blocks

## Security Features

- Only contract owner can create/revoke schedules
- Beneficiaries can only claim their own tokens
- Emergency pause stops all operations
- Revocation releases any vested tokens first

## Requirements

- SIP-010 compatible fungible tokens
- Tokens must be transferred to the contract before vesting
- Contract deployer becomes the owner

## Error Codes

- `u100` - Owner only function
- `u101` - Schedule not found
- `u102` - Unauthorized action
- `u104` - Invalid parameters
- `u105` - No tokens to release
- `u106` - Cliff period not reached
-
