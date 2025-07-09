;; Distribution Management Contract
;; Manages finished compost allocation and distribution

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_INVALID_REQUEST (err u301))
(define-constant ERR_INSUFFICIENT_COMPOST (err u302))
(define-constant ERR_REQUEST_NOT_FOUND (err u303))
(define-constant ERR_ALREADY_DISTRIBUTED (err u304))

;; Data Variables
(define-data-var next-request-id uint u1)
(define-data-var total-compost-available uint u0)
(define-data-var distribution-reward uint u3)

;; Data Maps
(define-map compost-requests
  { request-id: uint }
  {
    requester: principal,
    amount-kg: uint,
    priority-score: uint,
    request-block: uint,
    status: (string-ascii 20),
    allocated-amount: uint,
    distribution-block: uint,
    quality-rating: uint
  }
)

(define-map participant-allocations
  { participant: principal }
  {
    total-contributed: uint,
    total-allocated: uint,
    pending-requests: uint,
    satisfaction-score: uint,
    last-distribution: uint
  }
)

(define-map compost-inventory
  { batch-id: uint }
  {
    total-amount: uint,
    available-amount: uint,
    quality-score: uint,
    completion-block: uint,
    distributed: bool
  }
)

(define-map distribution-records
  { distribution-id: uint }
  {
    request-id: uint,
    batch-id: uint,
    amount: uint,
    recipient: principal,
    distribution-block: uint,
    quality-delivered: uint
  }
)

(define-data-var next-distribution-id uint u1)

;; Public Functions

;; Add compost to inventory
(define-public (add-compost-inventory (batch-id uint) (amount-kg uint) (quality-score uint))
  (let
    (
      (caller tx-sender)
    )
    (asserts! (> amount-kg u0) ERR_INVALID_REQUEST)
    (asserts! (and (>= quality-score u0) (<= quality-score u100)) ERR_INVALID_REQUEST)
    (map-set compost-inventory
      { batch-id: batch-id }
      {
        total-amount: amount-kg,
        available-amount: amount-kg,
        quality-score: quality-score,
        completion-block: block-height,
        distributed: false
      }
    )
    (var-set total-compost-available (+ (var-get total-compost-available) amount-kg))
    (ok true)
  )
)

;; Request compost allocation
(define-public (request-compost (amount-kg uint) (contribution-weight uint))
  (let
    (
      (request-id (var-get next-request-id))
      (caller tx-sender)
      (priority (calculate-priority contribution-weight amount-kg))
    )
    (asserts! (> amount-kg u0) ERR_INVALID_REQUEST)
    (map-set compost-requests
      { request-id: request-id }
      {
        requester: caller,
        amount-kg: amount-kg,
        priority-score: priority,
        request-block: block-height,
        status: "pending",
        allocated-amount: u0,
        distribution-block: u0,
        quality-rating: u0
      }
    )
    (update-participant-allocation caller contribution-weight u0 true)
    (var-set next-request-id (+ request-id u1))
    (ok request-id)
  )
)

;; Distribute compost to requester
(define-public (distribute-compost (request-id uint) (batch-id uint))
  (let
    (
      (request-data (unwrap! (map-get? compost-requests { request-id: request-id }) ERR_REQUEST_NOT_FOUND))
      (inventory-data (unwrap! (map-get? compost-inventory { batch-id: batch-id }) ERR_INVALID_REQUEST))
      (requested-amount (get amount-kg request-data))
      (available-amount (get available-amount inventory-data))
      (distribution-amount (if (<= requested-amount available-amount) requested-amount available-amount))
      (distribution-id (var-get next-distribution-id))
    )
    (asserts! (is-eq (get status request-data) "pending") ERR_ALREADY_DISTRIBUTED)
    (asserts! (> available-amount u0) ERR_INSUFFICIENT_COMPOST)

    ;; Update request status
    (map-set compost-requests
      { request-id: request-id }
      (merge request-data {
        status: "distributed",
        allocated-amount: distribution-amount,
        distribution-block: block-height,
        quality-rating: (get quality-score inventory-data)
      })
    )

    ;; Update inventory
    (map-set compost-inventory
      { batch-id: batch-id }
      (merge inventory-data {
        available-amount: (- available-amount distribution-amount)
      })
    )

    ;; Record distribution
    (map-set distribution-records
      { distribution-id: distribution-id }
      {
        request-id: request-id,
        batch-id: batch-id,
        amount: distribution-amount,
        recipient: (get requester request-data),
        distribution-block: block-height,
        quality-delivered: (get quality-score inventory-data)
      }
    )

    ;; Update participant allocation
    (update-participant-allocation (get requester request-data) u0 distribution-amount false)

    ;; Update totals
    (var-set total-compost-available (- (var-get total-compost-available) distribution-amount))
    (var-set next-distribution-id (+ distribution-id u1))

    (ok distribution-amount)
  )
)

;; Rate distribution quality
(define-public (rate-distribution (request-id uint) (rating uint))
  (let
    (
      (request-data (unwrap! (map-get? compost-requests { request-id: request-id }) ERR_REQUEST_NOT_FOUND))
      (caller tx-sender)
    )
    (asserts! (is-eq caller (get requester request-data)) ERR_UNAUTHORIZED)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR_INVALID_REQUEST)
    (asserts! (is-eq (get status request-data) "distributed") ERR_INVALID_REQUEST)
    (map-set compost-requests
      { request-id: request-id }
      (merge request-data {
        quality-rating: rating
      })
    )
    (ok true)
  )
)

;; Read-only Functions

;; Get compost request
(define-read-only (get-request (request-id uint))
  (map-get? compost-requests { request-id: request-id })
)

;; Get participant allocation info
(define-read-only (get-allocation-info (participant principal))
  (map-get? participant-allocations { participant: participant })
)

;; Get compost inventory
(define-read-only (get-inventory (batch-id uint))
  (map-get? compost-inventory { batch-id: batch-id })
)

;; Get distribution record
(define-read-only (get-distribution (distribution-id uint))
  (map-get? distribution-records { distribution-id: distribution-id })
)

;; Get total available compost
(define-read-only (get-total-available)
  (ok (var-get total-compost-available))
)

;; Calculate allocation eligibility
(define-read-only (calculate-allocation-eligibility (participant principal) (requested-amount uint))
  (match (map-get? participant-allocations { participant: participant })
    allocation-data (let
      (
        (contribution-ratio (if (> (get total-allocated allocation-data) u0)
                              (/ (get total-contributed allocation-data) (get total-allocated allocation-data))
                              u100))
        (satisfaction (get satisfaction-score allocation-data))
      )
      (ok {
        eligible: (and (>= contribution-ratio u1) (>= satisfaction u3)),
        priority-score: (+ contribution-ratio satisfaction),
        max-allocation: (/ (get total-contributed allocation-data) u2)
      })
    )
    (ok {
      eligible: false,
      priority-score: u0,
      max-allocation: u0
    })
  )
)

;; Private Functions

;; Calculate request priority based on contribution and amount
(define-private (calculate-priority (contribution-weight uint) (requested-amount uint))
  (let
    (
      (contribution-score (if (> contribution-weight u0) (/ contribution-weight u10) u1))
      (amount-factor (if (<= requested-amount u10) u10 (if (<= requested-amount u25) u5 u1)))
    )
    (+ contribution-score amount-factor)
  )
)

;; Update participant allocation data
(define-private (update-participant-allocation (participant principal) (contributed uint) (allocated uint) (is-request bool))
  (let
    (
      (current-data (default-to { total-contributed: u0, total-allocated: u0, pending-requests: u0, satisfaction-score: u5, last-distribution: u0 }
                                 (map-get? participant-allocations { participant: participant })))
    )
    (map-set participant-allocations
      { participant: participant }
      {
        total-contributed: (+ (get total-contributed current-data) contributed),
        total-allocated: (+ (get total-allocated current-data) allocated),
        pending-requests: (if is-request
                            (+ (get pending-requests current-data) u1)
                            (if (> (get pending-requests current-data) u0)
                              (- (get pending-requests current-data) u1)
                              u0)),
        satisfaction-score: (get satisfaction-score current-data),
        last-distribution: (if (> allocated u0) block-height (get last-distribution current-data))
      }
    )
  )
)
