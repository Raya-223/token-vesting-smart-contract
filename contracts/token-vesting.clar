;; Token Vesting Smart Contract
;; Manages token vesting schedules with cliff periods and linear vesting

;; Contract owner
(define-constant contract-owner tx-sender)

;; Error codes
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-invalid-params (err u104))
(define-constant err-no-tokens-to-release (err u105))
(define-constant err-cliff-not-reached (err u106))
(define-constant err-insufficient-balance (err u107))
(define-constant err-vesting-ended (err u108))
(define-constant err-transfer-failed (err u109))

;; Token trait (assuming SIP-010 fungible token)
(define-trait ft-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
    (get-decimals () (response uint uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
  )
)

;; Data structures
(define-map vesting-schedules
  { beneficiary: principal, schedule-id: uint }
  {
    token-contract: principal,
    total-amount: uint,
    start-time: uint,
    cliff-duration: uint,
    vesting-duration: uint,
    released-amount: uint,
    revoked: bool,
    revocable: bool,
    created-by: principal,
    created-at: uint
  }
)

(define-map beneficiary-schedule-count
  { beneficiary: principal }
  { count: uint }
)

(define-map total-vested-tokens
  { token-contract: principal }
  { amount: uint }
)

;; Contract state
(define-data-var schedule-counter uint u0)
(define-data-var contract-paused bool false)

;; Helper functions
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (is-contract-paused)
  (var-get contract-paused)
)

(define-read-only (get-schedule-count)
  (var-get schedule-counter)
)

(define-read-only (get-beneficiary-schedule-count (beneficiary principal))
  (default-to u0 (get count (map-get? beneficiary-schedule-count { beneficiary: beneficiary })))
)

;; Calculate vested amount based on time
(define-private (calculate-vested-amount 
  (total-amount uint)
  (start-time uint)
  (cliff-duration uint)
  (vesting-duration uint)
  (current-time uint)
)
  (let
    (
      (cliff-time (+ start-time cliff-duration))
      (end-time (+ start-time vesting-duration))
    )
    (if (< current-time cliff-time)
      u0 ;; Before cliff, no tokens vested
      (if (>= current-time end-time)
        total-amount ;; After vesting period, all tokens vested
        ;; Linear vesting between cliff and end
        (let
          (
            (time-since-cliff (- current-time cliff-time))
            (vesting-time-after-cliff (- vesting-duration cliff-duration))
          )
          (/ (* total-amount time-since-cliff) vesting-time-after-cliff)
        )
      )
    )
  )
)

;; Calculate releasable amount
(define-private (calculate-releasable-amount (beneficiary principal) (schedule-id uint))
  (match (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id })
    schedule
    (let
      (
        (vested-amount (calculate-vested-amount
          (get total-amount schedule)
          (get start-time schedule)
          (get cliff-duration schedule)
          (get vesting-duration schedule)
          stacks-block-height
        ))
        (already-released (get released-amount schedule))
      )
      (if (> vested-amount already-released)
        (- vested-amount already-released)
        u0
      )
    )
    u0
  )
)

;; Public functions

;; Create a vesting schedule
(define-public (create-vesting-schedule
  (beneficiary principal)
  (token-contract principal)
  (total-amount uint)
  (start-time uint)
  (cliff-duration uint)
  (vesting-duration uint)
  (revocable bool)
)
  (let
    (
      (new-schedule-id (+ (get-beneficiary-schedule-count beneficiary) u1))
      (current-time stacks-block-height)
    )
    (asserts! (not (is-contract-paused)) err-unauthorized)
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (> total-amount u0) err-invalid-params)
    (asserts! (>= start-time current-time) err-invalid-params)
    (asserts! (< cliff-duration vesting-duration) err-invalid-params)
    (asserts! (> vesting-duration u0) err-invalid-params)
    
    ;; Create the vesting schedule
    (map-set vesting-schedules
      { beneficiary: beneficiary, schedule-id: new-schedule-id }
      {
        token-contract: token-contract,
        total-amount: total-amount,
        start-time: start-time,
        cliff-duration: cliff-duration,
        vesting-duration: vesting-duration,
        released-amount: u0,
        revoked: false,
        revocable: revocable,
        created-by: tx-sender,
        created-at: current-time
      }
    )
    
    ;; Update beneficiary schedule count
    (map-set beneficiary-schedule-count
      { beneficiary: beneficiary }
      { count: new-schedule-id }
    )
    
    ;; Update total vested tokens for this token contract
    (map-set total-vested-tokens
      { token-contract: token-contract }
      { amount: (+ (default-to u0 (get amount (map-get? total-vested-tokens { token-contract: token-contract }))) total-amount) }
    )
    
    ;; Update global schedule counter
    (var-set schedule-counter (+ (var-get schedule-counter) u1))
    
    (ok new-schedule-id)
  )
)

;; Release vested tokens
(define-public (release-tokens (beneficiary principal) (schedule-id uint) (token-contract <ft-trait>))
  (let
    (
      (schedule (unwrap! (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id }) err-not-found))
      (releasable-amount (calculate-releasable-amount beneficiary schedule-id))
    )
    (asserts! (not (is-contract-paused)) err-unauthorized)
    (asserts! (not (get revoked schedule)) err-vesting-ended)
    (asserts! (> releasable-amount u0) err-no-tokens-to-release)
    (asserts! (>= stacks-block-height (+ (get start-time schedule) (get cliff-duration schedule))) err-cliff-not-reached)
    
    ;; Transfer tokens to beneficiary
    (try! (contract-call? token-contract transfer releasable-amount (as-contract tx-sender) beneficiary none))
    
    ;; Update released amount
    (map-set vesting-schedules
      { beneficiary: beneficiary, schedule-id: schedule-id }
      (merge schedule { released-amount: (+ (get released-amount schedule) releasable-amount) })
    )
    
    (ok releasable-amount)
  )
)

;; Revoke vesting schedule (only for revocable schedules)
(define-public (revoke-vesting (beneficiary principal) (schedule-id uint) (token-contract <ft-trait>))
  (let
    (
      (schedule (unwrap! (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id }) err-not-found))
      (releasable-amount (calculate-releasable-amount beneficiary schedule-id))
      (unvested-amount (- (get total-amount schedule) (get released-amount schedule) releasable-amount))
    )
    (asserts! (not (is-contract-paused)) err-unauthorized)
    (asserts! (is-contract-owner) err-owner-only)
    (asserts! (get revocable schedule) err-unauthorized)
    (asserts! (not (get revoked schedule)) err-vesting-ended)
    
    ;; Release any vested tokens first
    (if (> releasable-amount u0)
      (try! (contract-call? token-contract transfer releasable-amount (as-contract tx-sender) beneficiary none))
      true
    )
    
    ;; Return unvested tokens to contract owner
    (if (> unvested-amount u0)
      (try! (contract-call? token-contract transfer unvested-amount (as-contract tx-sender) contract-owner none))
      true
    )
    
    ;; Mark as revoked
    (map-set vesting-schedules
      { beneficiary: beneficiary, schedule-id: schedule-id }
      (merge schedule { 
        revoked: true,
        released-amount: (+ (get released-amount schedule) releasable-amount)
      })
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get vesting schedule details
(define-read-only (get-vesting-schedule (beneficiary principal) (schedule-id uint))
  (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id })
)

;; Get vested amount (total amount that has vested so far)
(define-read-only (get-vested-amount (beneficiary principal) (schedule-id uint))
  (match (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id })
    schedule
    (calculate-vested-amount
      (get total-amount schedule)
      (get start-time schedule)
      (get cliff-duration schedule)
      (get vesting-duration schedule)
      stacks-block-height
    )
    u0
  )
)

;; Get releasable amount (vested but not yet released)
(define-read-only (get-releasable-amount (beneficiary principal) (schedule-id uint))
  (calculate-releasable-amount beneficiary schedule-id)
)

;; Get released amount
(define-read-only (get-released-amount (beneficiary principal) (schedule-id uint))
  (match (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id })
    schedule (get released-amount schedule)
    u0
  )
)

;; Check if cliff period has passed
(define-read-only (is-cliff-passed (beneficiary principal) (schedule-id uint))
  (match (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id })
    schedule
    (>= stacks-block-height (+ (get start-time schedule) (get cliff-duration schedule)))
    false
  )
)

;; Check if vesting is complete
(define-read-only (is-vesting-complete (beneficiary principal) (schedule-id uint))
  (match (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id })
    schedule
    (>= stacks-block-height (+ (get start-time schedule) (get vesting-duration schedule)))
    false
  )
)

;; Get total vested tokens for a token contract
(define-read-only (get-total-vested-tokens (token-contract principal))
  (default-to u0 (get amount (map-get? total-vested-tokens { token-contract: token-contract })))
)

;; Admin functions

;; Pause/unpause contract
(define-public (toggle-contract-pause)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (ok (var-set contract-paused (not (var-get contract-paused))))
  )
)

;; Emergency withdraw (only for contract owner)
(define-public (emergency-withdraw (token-contract <ft-trait>) (amount uint))
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (contract-call? token-contract transfer amount (as-contract tx-sender) tx-sender none)
  )
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-schedules: (var-get schedule-counter),
    contract-paused: (var-get contract-paused),
    contract-owner: contract-owner,
    current-block: stacks-block-height
  }
)

;; Get vesting schedule summary
(define-read-only (get-schedule-summary (beneficiary principal) (schedule-id uint))
  (match (map-get? vesting-schedules { beneficiary: beneficiary, schedule-id: schedule-id })
    schedule
    (let
      (
        (vested (get-vested-amount beneficiary schedule-id))
        (released (get-released-amount beneficiary schedule-id))
        (releasable (get-releasable-amount beneficiary schedule-id))
      )
      (some {
        beneficiary: beneficiary,
        schedule-id: schedule-id,
        token-contract: (get token-contract schedule),
        total-amount: (get total-amount schedule),
        vested-amount: vested,
        released-amount: released,
        releasable-amount: releasable,
        remaining-amount: (- (get total-amount schedule) vested),
        cliff-passed: (is-cliff-passed beneficiary schedule-id),
        vesting-complete: (is-vesting-complete beneficiary schedule-id),
        revoked: (get revoked schedule),
        revocable: (get revocable schedule)
      })
    )
    none
  )
)