;; Decomposition Monitoring Contract
;; Tracks composting process efficiency and metrics

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_INVALID_BATCH (err u201))
(define-constant ERR_INVALID_METRICS (err u202))
(define-constant ERR_BATCH_NOT_FOUND (err u203))
(define-constant ERR_BATCH_COMPLETED (err u204))

;; Data Variables
(define-data-var next-batch-id uint u1)
(define-data-var monitoring-reward uint u5)

;; Data Maps
(define-map compost-batches
  { batch-id: uint }
  {
    start-block: uint,
    end-block: uint,
    initial-weight: uint,
    current-weight: uint,
    temperature-celsius: uint,
    moisture-percent: uint,
    ph-level: uint,
    stage: (string-ascii 20),
    efficiency-score: uint,
    monitor-address: principal,
    completed: bool
  }
)

(define-map batch-measurements
  { batch-id: uint, measurement-id: uint }
  {
    block-height: uint,
    temperature: uint,
    moisture: uint,
    ph: uint,
    weight: uint,
    notes: (string-ascii 200),
    monitor: principal
  }
)

(define-map batch-measurement-count
  { batch-id: uint }
  { count: uint }
)

(define-map monitor-stats
  { monitor: principal }
  {
    total-batches: uint,
    total-measurements: uint,
    accuracy-score: uint,
    tokens-earned: uint
  }
)

;; Public Functions

;; Start new compost batch
(define-public (start-batch (initial-weight uint) (monitor-address principal))
  (let
    (
      (batch-id (var-get next-batch-id))
    )
    (asserts! (> initial-weight u0) ERR_INVALID_METRICS)
    (map-set compost-batches
      { batch-id: batch-id }
      {
        start-block: block-height,
        end-block: u0,
        initial-weight: initial-weight,
        current-weight: initial-weight,
        temperature-celsius: u20,
        moisture-percent: u50,
        ph-level: u70,
        stage: "initial",
        efficiency-score: u0,
        monitor-address: monitor-address,
        completed: false
      }
    )
    (map-set batch-measurement-count
      { batch-id: batch-id }
      { count: u0 }
    )
    (var-set next-batch-id (+ batch-id u1))
    (ok batch-id)
  )
)

;; Update batch metrics
(define-public (update-metrics (batch-id uint) (temperature uint) (moisture uint) (ph uint) (weight uint) (notes (string-ascii 200)))
  (let
    (
      (batch-data (unwrap! (map-get? compost-batches { batch-id: batch-id }) ERR_BATCH_NOT_FOUND))
      (measurement-count-data (unwrap! (map-get? batch-measurement-count { batch-id: batch-id }) ERR_BATCH_NOT_FOUND))
      (measurement-id (get count measurement-count-data))
      (caller tx-sender)
      (new-stage (determine-stage temperature moisture ph))
      (efficiency (calculate-efficiency batch-data temperature moisture ph weight))
    )
    (asserts! (not (get completed batch-data)) ERR_BATCH_COMPLETED)
    (asserts! (and (>= temperature u0) (<= temperature u80)) ERR_INVALID_METRICS)
    (asserts! (and (>= moisture u0) (<= moisture u100)) ERR_INVALID_METRICS)
    (asserts! (and (>= ph u0) (<= ph u140)) ERR_INVALID_METRICS)

    ;; Record measurement
    (map-set batch-measurements
      { batch-id: batch-id, measurement-id: measurement-id }
      {
        block-height: block-height,
        temperature: temperature,
        moisture: moisture,
        ph: ph,
        weight: weight,
        notes: notes,
        monitor: caller
      }
    )

    ;; Update batch data
    (map-set compost-batches
      { batch-id: batch-id }
      (merge batch-data {
        current-weight: weight,
        temperature-celsius: temperature,
        moisture-percent: moisture,
        ph-level: ph,
        stage: new-stage,
        efficiency-score: efficiency
      })
    )

    ;; Update measurement count
    (map-set batch-measurement-count
      { batch-id: batch-id }
      { count: (+ measurement-id u1) }
    )

    ;; Update monitor stats
    (update-monitor-stats caller)

    (ok efficiency)
  )
)

;; Complete batch
(define-public (complete-batch (batch-id uint))
  (let
    (
      (batch-data (unwrap! (map-get? compost-batches { batch-id: batch-id }) ERR_BATCH_NOT_FOUND))
      (caller tx-sender)
    )
    (asserts! (is-eq caller (get monitor-address batch-data)) ERR_UNAUTHORIZED)
    (asserts! (not (get completed batch-data)) ERR_BATCH_COMPLETED)
    (map-set compost-batches
      { batch-id: batch-id }
      (merge batch-data {
        end-block: block-height,
        completed: true
      })
    )
    (ok true)
  )
)

;; Read-only Functions

;; Get batch information
(define-read-only (get-batch (batch-id uint))
  (map-get? compost-batches { batch-id: batch-id })
)

;; Get batch measurement
(define-read-only (get-measurement (batch-id uint) (measurement-id uint))
  (map-get? batch-measurements { batch-id: batch-id, measurement-id: measurement-id })
)

;; Get batch measurement count
(define-read-only (get-measurement-count (batch-id uint))
  (map-get? batch-measurement-count { batch-id: batch-id })
)

;; Calculate decomposition efficiency
(define-read-only (calculate-efficiency-score (batch-id uint))
  (match (map-get? compost-batches { batch-id: batch-id })
    batch-data (ok (get efficiency-score batch-data))
    ERR_BATCH_NOT_FOUND
  )
)

;; Get monitor statistics
(define-read-only (get-monitor-stats (monitor principal))
  (map-get? monitor-stats { monitor: monitor })
)

;; Predict completion time
(define-read-only (predict-completion (batch-id uint))
  (match (map-get? compost-batches { batch-id: batch-id })
    batch-data (let
      (
        (current-stage (get stage batch-data))
        (efficiency (get efficiency-score batch-data))
        (blocks-elapsed (- block-height (get start-block batch-data)))
      )
      (ok (estimate-remaining-blocks current-stage efficiency blocks-elapsed))
    )
    ERR_BATCH_NOT_FOUND
  )
)

;; Private Functions

;; Determine composting stage based on metrics
(define-private (determine-stage (temperature uint) (moisture uint) (ph uint))
  (if (and (>= temperature u40) (<= temperature u70) (>= moisture u40) (<= moisture u60))
    "active"
    (if (and (>= temperature u20) (<= temperature u40) (>= moisture u30) (<= moisture u50))
      "curing"
      (if (and (<= temperature u30) (>= ph u65) (<= ph u75))
        "mature"
        "initial"
      )
    )
  )
)

;; Calculate efficiency based on optimal ranges
(define-private (calculate-efficiency (batch-data { start-block: uint, end-block: uint, initial-weight: uint, current-weight: uint, temperature-celsius: uint, moisture-percent: uint, ph-level: uint, stage: (string-ascii 20), efficiency-score: uint, monitor-address: principal, completed: bool }) (temperature uint) (moisture uint) (ph uint) (weight uint))
  (let
    (
      (temp-score (if (and (>= temperature u40) (<= temperature u70)) u30 u10))
      (moisture-score (if (and (>= moisture u40) (<= moisture u60)) u30 u10))
      (ph-score (if (and (>= ph u65) (<= ph u75)) u30 u10))
      (weight-reduction (if (> (get initial-weight batch-data) u0)
                          (/ (* (- (get initial-weight batch-data) weight) u10) (get initial-weight batch-data))
                          u0))
    )
    (+ temp-score moisture-score ph-score weight-reduction)
  )
)

;; Update monitor statistics
(define-private (update-monitor-stats (monitor principal))
  (let
    (
      (current-stats (default-to { total-batches: u0, total-measurements: u0, accuracy-score: u100, tokens-earned: u0 }
                                  (map-get? monitor-stats { monitor: monitor })))
      (reward (var-get monitoring-reward))
    )
    (map-set monitor-stats
      { monitor: monitor }
      {
        total-batches: (get total-batches current-stats),
        total-measurements: (+ (get total-measurements current-stats) u1),
        accuracy-score: (get accuracy-score current-stats),
        tokens-earned: (+ (get tokens-earned current-stats) reward)
      }
    )
  )
)

;; Estimate remaining blocks for completion
(define-private (estimate-remaining-blocks (stage (string-ascii 20)) (efficiency uint) (blocks-elapsed uint))
  (if (is-eq stage "mature")
    u0
    (if (is-eq stage "curing")
      u1000
      (if (is-eq stage "active")
        u2000
        u3000
      )
    )
  )
)
