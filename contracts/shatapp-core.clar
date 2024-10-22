;; Title: ShatApp Core Contract
;; Version: 1.2.0
;; Description: Advanced core functionality for ShatApp decentralized chat application

;; Error codes
(define-constant ERR_NOT_FOUND (err u100))
(define-constant ERR_ALREADY_EXISTS (err u101))
(define-constant ERR_UNAUTHORIZED (err u102))
(define-constant ERR_INVALID_INPUT (err u103))
(define-constant ERR_BLOCKED (err u104))
(define-constant ERR_DEACTIVATED (err u105))
(define-constant ERR_RATE_LIMITED (err u106))
(define-constant ERR_BATCH_FULL (err u107))
(define-constant ERR_BATCH_EXPIRED (err u108))

;; Constants
(define-constant STATUS_DEACTIVATED u0)
(define-constant STATUS_ACTIVE u1)
(define-constant STATUS_SUSPENDED u2)

(define-constant FRIENDSHIP_PENDING u0)
(define-constant FRIENDSHIP_ACTIVE u1)
(define-constant FRIENDSHIP_BLOCKED u2)

;; Rate limiting constants
(define-constant MAX_ACTIONS_PER_DAY u100)
(define-constant MAX_FRIEND_REQUESTS_PER_DAY u20)
(define-constant MAX_STATUS_UPDATES_PER_DAY u24)
(define-constant RATE_LIMIT_RESET_PERIOD u86400) ;; 24 hours in seconds

;; Batch processing constants
(define-constant MIN_BATCH_SIZE u10)
(define-constant MAX_BATCH_SIZE u100)
(define-constant BATCH_EXPIRY_PERIOD u3600) ;; 1 hour in seconds

;; Data structures
(define-map Users 
    principal 
    {
        name: (string-ascii 64),
        status: uint,
        timestamp: uint,
        metadata: (optional (string-utf8 256)),
        deactivation-time: (optional uint),
        encryption-key: (optional (buff 32)),
        profile-image: (optional (string-utf8 256))
    }
)

(define-map UserPrivacy
    principal
    {
        friend-list-visible: bool,
        status-visible: bool,
        metadata-visible: bool,
        last-seen-visible: bool,
        profile-image-visible: bool,
        encryption-enabled: bool,
        last-updated: uint
    }
)

(define-map RateLimits
    principal
    {
        daily-actions: uint,
        friend-requests: uint,
        status-updates: uint,
        last-reset: uint
    }
)

(define-map UserBatches
    principal
    {
        message-counter: uint,
        last-batch-timestamp: uint,
        batch-size: uint,
        current-batch-items: uint,
        total-batches: uint
    }
)

(define-map UserActivity
    principal
    {
        last-seen: uint,
        login-count: uint,
        total-actions: uint,
        last-action: uint
    }
)

;; Private functions
(define-private (check-rate-limit (user principal) (action-type uint))
    (let
        (
            (rate-data (default-to 
                {
                    daily-actions: u0,
                    friend-requests: u0,
                    status-updates: u0,
                    last-reset: (unwrap-panic (get-block-info? time u0))
                }
                (map-get? RateLimits user)
            ))
            (current-time (unwrap-panic (get-block-info? time u0)))
            (should-reset (> (- current-time (get last-reset rate-data)) RATE_LIMIT_RESET_PERIOD))
        )
        (if should-reset
            ;; Reset counters if period expired
            (begin
                (map-set RateLimits user
                    {
                        daily-actions: u1,
                        friend-requests: (if (is-eq action-type u1) u1 u0),
                        status-updates: (if (is-eq action-type u2) u1 u0),
                        last-reset: current-time
                    }
                )
                true
            )
            ;; Check limits
            (and
                (< (get daily-actions rate-data) MAX_ACTIONS_PER_DAY)
                (or 
                    (not (is-eq action-type u1))
                    (< (get friend-requests rate-data) MAX_FRIEND_REQUESTS_PER_DAY)
                )
                (or
                    (not (is-eq action-type u2))
                    (< (get status-updates rate-data) MAX_STATUS_UPDATES_PER_DAY)
                )
            )
        )
    )
)

(define-private (update-rate-limit (user principal) (action-type uint))
    (let
        (
            (rate-data (unwrap-panic (map-get? RateLimits user)))
        )
        (map-set RateLimits user
            (merge rate-data {
                daily-actions: (+ (get daily-actions rate-data) u1),
                friend-requests: (+ (get friend-requests rate-data) (if (is-eq action-type u1) u1 u0)),
                status-updates: (+ (get status-updates rate-data) (if (is-eq action-type u2) u1 u0))
            })
        )
    )
)

(define-private (update-user-activity (user principal))
    (let
        (
            (current-time (unwrap-panic (get-block-info? time u0)))
            (activity (default-to
                {
                    last-seen: current-time,
                    login-count: u0,
                    total-actions: u0,
                    last-action: current-time
                }
                (map-get? UserActivity user)
            ))
        )
        (map-set UserActivity user
            (merge activity {
                last-seen: current-time,
                total-actions: (+ (get total-actions activity) u1),
                last-action: current-time
            })
        )
    )
)

;; Batch management functions
(define-public (optimize-batch-size (user principal))
    (let
        (
            (batch-data (unwrap-panic (map-get? UserBatches user)))
            (current-time (unwrap-panic (get-block-info? time u0)))
            (time-since-last-batch (- current-time (get last-batch-timestamp batch-data)))
            (current-batch-size (get batch-size batch-data))
            (items-in-current-batch (get current-batch-items batch-data))
        )
        (if (> time-since-last-batch BATCH_EXPIRY_PERIOD)
            ;; Batch expired, reset and adjust size
            (begin
                (map-set UserBatches user
                    (merge batch-data {
                        batch-size: (max MIN_BATCH_SIZE (/ current-batch-size u2)),
                        current-batch-items: u0,
                        last-batch-timestamp: current-time
                    })
                )
                (ok true)
            )
            ;; Adjust based on usage
            (begin
                (map-set UserBatches user
                    (merge batch-data {
                        batch-size: (min MAX_BATCH_SIZE 
                            (if (>= items-in-current-batch (/ current-batch-size u2))
                                (* current-batch-size u2)
                                current-batch-size
                            ))
                    })
                )
                (ok true)
            )
        )
    )
)

;; Enhanced privacy functions
(define-public (update-advanced-privacy-settings
    (friend-list-visible bool)
    (status-visible bool)
    (metadata-visible bool)
    (last-seen-visible bool)
    (profile-image-visible bool)
    (encryption-enabled bool))
    (let
        (
            (caller tx-sender)
        )
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        (asserts! (check-rate-limit caller u2) ERR_RATE_LIMITED)
        
        (map-set UserPrivacy
            caller
            {
                friend-list-visible: friend-list-visible,
                status-visible: status-visible,
                metadata-visible: metadata-visible,
                last-seen-visible: last-seen-visible,
                profile-image-visible: profile-image-visible,
                encryption-enabled: encryption-enabled,
                last-updated: (unwrap-panic (get-block-info? time u0))
            }
        )
        
        (update-rate-limit caller u2)
        (update-user-activity caller)
        
        (print {
            event: "privacy-updated",
            user: caller,
            timestamp: (unwrap-panic (get-block-info? time u0))
        })
        (ok true)
    )
)

;; Enhanced user profile functions
(define-public (update-user-profile
    (name (optional (string-ascii 64)))
    (metadata (optional (string-utf8 256)))
    (encryption-key (optional (buff 32)))
    (profile-image (optional (string-utf8 256))))
    (let
        (
            (caller tx-sender)
            (user (unwrap-panic (map-get? Users caller)))
        )
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        (asserts! (check-rate-limit caller u2) ERR_RATE_LIMITED)
        
        (map-set Users caller
            (merge user {
                name: (default-to (get name user) name),
                metadata: (if (is-some metadata) metadata (get metadata user)),
                encryption-key: (if (is-some encryption-key) encryption-key (get encryption-key user)),
                profile-image: (if (is-some profile-image) profile-image (get profile-image user))
            })
        )
        
        (update-rate-limit caller u2)
        (update-user-activity caller)
        
        (print {
            event: "profile-updated",
            user: caller,
            timestamp: (unwrap-panic (get-block-info? time u0))
        })
        (ok true)
    )
)

;; Batch management public functions
(define-public (set-batch-size (new-size uint))
    (let
        (
            (caller tx-sender)
            (batch-data (unwrap-panic (map-get? UserBatches caller)))
        )
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        (asserts! (and (>= new-size MIN_BATCH_SIZE) (<= new-size MAX_BATCH_SIZE)) ERR_INVALID_INPUT)
        
        (map-set UserBatches caller
            (merge batch-data {
                batch-size: new-size
            })
        )
        
        (print {
            event: "batch-size-updated",
            user: caller,
            new-size: new-size,
            timestamp: (unwrap-panic (get-block-info? time u0))
        })
        (ok true)
    )
)

;; Activity tracking
(define-public (record-login)
    (let
        (
            (caller tx-sender)
            (activity (default-to
                {
                    last-seen: (unwrap-panic (get-block-info? time u0)),
                    login-count: u0,
                    total-actions: u0,
                    last-action: (unwrap-panic (get-block-info? time u0))
                }
                (map-get? UserActivity caller)
            ))
        )
        (map-set UserActivity caller
            (merge activity {
                last-seen: (unwrap-panic (get-block-info? time u0)),
                login-count: (+ (get login-count activity) u1)
            })
        )
        
        (print {
            event: "user-login",
            user: caller,
            timestamp: (unwrap-panic (get-block-info? time u0))
        })
        (ok true)
    )
)
