;; Title: ShatApp Core Contract
;; Version: 1.3.0
;; Description: Complete core functionality for ShatApp decentralized chat application

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
(define-constant ERR_CANT_MESSAGE (err u109))

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
(define-constant RATE_LIMIT_RESET_PERIOD u86400) ;; 24 hours
(define-constant ONLINE_THRESHOLD u300) ;; 5 minutes for online status

;; Batch processing constants
(define-constant MIN_BATCH_SIZE u10)
(define-constant MAX_BATCH_SIZE u100)
(define-constant BATCH_EXPIRY_PERIOD u3600)

;; Data Maps
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

(define-map BlockedUsers
    {blocker: principal, blocked: principal}
    {
        timestamp: uint,
        reason: (optional (string-ascii 64))
    }
)

(define-map Friendships
    {user1: principal, user2: principal}
    {
        status: uint,
        timestamp: uint,
        last-interaction: uint
    }
)

;; Utility Functions

;; Basic utilities
(define-private (max-uint (a uint) (b uint))
    (if (>= a b) a b)
)

(define-private (min-uint (a uint) (b uint))
    (if (<= a b) a b)
)

;; User status utilities
(define-private (check-active-user (user principal))
    (match (map-get? Users user)
        user-data (and 
            (is-eq (get status user-data) STATUS_ACTIVE)
            (is-none (get deactivation-time user-data))
        )
        false
    )
)

(define-private (user-exists (user principal))
    (is-some (map-get? Users user))
)

(define-private (is-user-online (user principal))
    (match (map-get? UserActivity user)
        activity (< (- (unwrap-panic (get-block-info? time u0)) 
                      (get last-seen activity)) 
                   ONLINE_THRESHOLD)
        false
    )
)

(define-private (get-user-status-type (user principal))
    (match (map-get? Users user)
        user-data (get status user-data)
        u0
    )
)

;; Rate limiting utilities
(define-private (check-rate-limit (user principal) (action-type uint))
    (let (
        (current-time (unwrap-panic (get-block-info? time u0)))
        (rate-data (default-to 
            {
                daily-actions: u0,
                friend-requests: u0,
                status-updates: u0,
                last-reset: current-time
            }
            (map-get? RateLimits user)
        ))
        (time-since-reset (- current-time (get last-reset rate-data)))
    )
        (if (> time-since-reset RATE_LIMIT_RESET_PERIOD)
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
    (let (
        (rate-data (unwrap-panic (map-get? RateLimits user)))
    )
        (map-set RateLimits user
            (merge rate-data {
                daily-actions: (+ (get daily-actions rate-data) u1),
                friend-requests: (+ (get friend-requests rate-data) 
                    (if (is-eq action-type u1) u1 u0)),
                status-updates: (+ (get status-updates rate-data) 
                    (if (is-eq action-type u2) u1 u0))
            })
        )
    )
)

;; Activity tracking utilities
(define-private (update-user-activity (user principal))
    (let (
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

;; Message utilities
(define-private (can-send-message (sender principal) (receiver principal))
    (and
        (check-active-user sender)
        (check-active-user receiver)
        (are-friends sender receiver)
        (not (is-blocked sender receiver))
        (not (is-blocked receiver sender))
    )
)

(define-private (get-readable-time (timestamp uint))
    (mod timestamp u100000000)
)

(define-private (is-batch-valid (user principal))
    (let (
        (batch-data (default-to 
            {
                message-counter: u0,
                last-batch-timestamp: u0,
                batch-size: u50,
                current-batch-items: u0,
                total-batches: u0
            }
            (map-get? UserBatches user)
        ))
    )
        (< (get current-batch-items batch-data) (get batch-size batch-data))
    )
)

;; Friendship utilities
(define-private (are-friends (user1 principal) (user2 principal))
    (match (map-get? Friendships {user1: user1, user2: user2})
        friendship (is-eq (get status friendship) FRIENDSHIP_ACTIVE)
        false
    )
)

(define-private (is-blocked (blocker principal) (blocked principal))
    (is-some (map-get? BlockedUsers {blocker: blocker, blocked: blocked}))
)

;; Privacy utilities
(define-private (get-privacy-settings (user principal))
    (default-to
        {
            friend-list-visible: true,
            status-visible: true,
            metadata-visible: true,
            last-seen-visible: true,
            profile-image-visible: true,
            encryption-enabled: false,
            last-updated: (unwrap-panic (get-block-info? time u0))
        }
        (map-get? UserPrivacy user)
    )
)

(define-private (can-view-user-details (viewer principal) (target principal))
    (let (
        (privacy-settings (get-privacy-settings target))
    )
        (or
            (is-eq viewer target)
            (and
                (get metadata-visible privacy-settings)
                (not (is-blocked target viewer))
            )
        )
    )
)

(define-private (can-view-last-seen (viewer principal) (target principal))
    (let (
        (privacy-settings (get-privacy-settings target))
    )
        (and
            (get last-seen-visible privacy-settings)
            (or
                (are-friends viewer target)
                (get status-visible privacy-settings)
            )
        )
    )
)

;; Public Functions

;; User registration and management
(define-public (register-user (name (string-ascii 64)) (metadata (optional (string-utf8 256))))
    (let (
        (caller tx-sender)
        (existing-user (map-get? Users caller))
    )
        (asserts! (is-none existing-user) ERR_ALREADY_EXISTS)
        (asserts! (> (len name) u0) ERR_INVALID_INPUT)
        
        (map-set Users 
            caller
            {
                name: name,
                status: STATUS_ACTIVE,
                timestamp: (unwrap-panic (get-block-info? time u0)),
                metadata: metadata,
                deactivation-time: none,
                encryption-key: none,
                profile-image: none
            }
        )
        
        (map-set UserPrivacy
            caller
            {
                friend-list-visible: true,
                status-visible: true,
                metadata-visible: true,
                last-seen-visible: true,
                profile-image-visible: true,
                encryption-enabled: false,
                last-updated: (unwrap-panic (get-block-info? time u0))
            }
        )
        
        (map-set UserBatches
            caller
            {
                message-counter: u0,
                last-batch-timestamp: (unwrap-panic (get-block-info? time u0)),
                batch-size: u50,
                current-batch-items: u0,
                total-batches: u0
            }
        )
        
        (print {event: "user-registered", user: caller})
        (ok true)
    )
)

;; Account status management
(define-public (deactivate-account)
    (let (
        (caller tx-sender)
        (user (map-get? Users caller))
    )
        (asserts! (is-some user) ERR_NOT_FOUND)
        (asserts! (is-eq (get status (unwrap-panic user)) STATUS_ACTIVE) ERR_UNAUTHORIZED)
        
        (map-set Users 
            caller
            (merge (unwrap-panic user) {
                status: STATUS_DEACTIVATED,
                deactivation-time: (some (unwrap-panic (get-block-info? time u0)))
            })
        )
        
        (print {event: "account-deactivated", user: caller})
        (ok true)
    )
)

;; Privacy settings
(define-public (update-privacy-settings
    (friend-list-visible bool)
    (status-visible bool)
    (metadata-visible bool)
    (last-seen-visible bool)
    (profile-image-visible bool)
    (encryption-enabled bool))
    (let (
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
        
        (print {event: "privacy-updated", user: caller})
        (ok true)
    )
)

;; Batch management
(define-public (optimize-batch-size (user principal))
    (let (
        (batch-data (unwrap-panic (map-get? UserBatches user)))
        (current-time (unwrap-panic (get-block-info? time u0)))
        (time-since-last-batch (- current-time (get last-batch-timestamp batch-data)))
        (current-batch-size (get batch-size batch-data))
        (items-in-current-batch (get current-batch-items batch-data))
    )
        (if (> time-since-last-batch BATCH_EXPIRY_PERIOD)
            (begin
                (map-set UserBatches user
                    (merge batch-data {
                        batch-size: (max-uint MIN_BATCH_SIZE (/ current-batch-size u2)),
                        current-batch-items: u0,
                        last-batch-timestamp: current-time
                    })
                )
                (ok true)
            )
            (begin
                (map-set UserBatches user
                    (merge batch-data {
                        batch-size: (min-uint MAX_BATCH_SIZE 
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

;; Activity tracking
(define-public (record-login)
    (let (
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
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        
        (map-set UserActivity caller
            (merge activity {
                last-seen: (unwrap-panic (get-block-info? time u0)),
                login-count: (+ (get login-count activity) u1),
                last-action: (unwrap-panic (get-block-info? time u0))
            })
        )
        
        (print {event: "user-login", user: caller})
        (ok true)
    )
)

;; Friend management
(define-public (send-friend-request (friend principal))
    (let (
        (caller tx-sender)
        (current-time (unwrap-panic (get-block-info? time u0)))
    )
        (asserts! (not (is-eq caller friend)) ERR_INVALID_INPUT)
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        (asserts! (check-active-user friend) ERR_DEACTIVATED)
        (asserts! (check-rate-limit caller u1) ERR_RATE_LIMITED)
        (asserts! (not (is-blocked friend caller)) ERR_BLOCKED)
        (asserts! (not (are-friends caller friend)) ERR_ALREADY_EXISTS)
        
        (map-set Friendships 
            {user1: caller, user2: friend}
            {
                status: FRIENDSHIP_PENDING,
                timestamp: current-time,
                last-interaction: current-time
            }
        )
        
        (update-rate-limit caller u1)
        (update-user-activity caller)
        
        (print {event: "friend-request-sent", from: caller, to: friend})
        (ok true)
    )
)

(define-public (accept-friend-request (friend principal))
    (let (
        (caller tx-sender)
        (current-time (unwrap-panic (get-block-info? time u0)))
        (request (map-get? Friendships {user1: friend, user2: caller}))
    )
        (asserts! (is-some request) ERR_NOT_FOUND)
        (asserts! (is-eq (get status (unwrap-panic request)) FRIENDSHIP_PENDING) ERR_UNAUTHORIZED)
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        (asserts! (check-rate-limit caller u1) ERR_RATE_LIMITED)
        
        ;; Accept the request
        (map-set Friendships 
            {user1: friend, user2: caller}
            {
                status: FRIENDSHIP_ACTIVE,
                timestamp: current-time,
                last-interaction: current-time
            }
        )
        
        ;; Create reverse friendship
        (map-set Friendships 
            {user1: caller, user2: friend}
            {
                status: FRIENDSHIP_ACTIVE,
                timestamp: current-time,
                last-interaction: current-time
            }
        )
        
        (update-rate-limit caller u1)
        (update-user-activity caller)
        
        (print {event: "friend-request-accepted", by: caller, from: friend})
        (ok true)
    )
)

(define-public (remove-friend (friend principal))
    (let (
        (caller tx-sender)
    )
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        (asserts! (are-friends caller friend) ERR_NOT_FOUND)
        
        ;; Remove both friendship entries
        (map-delete Friendships {user1: caller, user2: friend})
        (map-delete Friendships {user1: friend, user2: caller})
        
        (update-user-activity caller)
        
        (print {event: "friend-removed", by: caller, removed: friend})
        (ok true)
    )
)

;; User profile management
(define-public (update-profile 
    (name (optional (string-ascii 64)))
    (metadata (optional (string-utf8 256)))
    (profile-image (optional (string-utf8 256))))
    (let (
        (caller tx-sender)
        (user-data (unwrap! (map-get? Users caller) ERR_NOT_FOUND))
    )
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        (asserts! (check-rate-limit caller u2) ERR_RATE_LIMITED)
        
        (map-set Users caller
            (merge user-data {
                name: (default-to (get name user-data) name),
                metadata: (if (is-some metadata) metadata (get metadata user-data)),
                profile-image: (if (is-some profile-image) profile-image (get profile-image user-data))
            })
        )
        
        (update-rate-limit caller u2)
        (update-user-activity caller)
        
        (print {event: "profile-updated", user: caller})
        (ok true)
    )
)

;; Block management
(define-public (block-user (user principal))
    (let (
        (caller tx-sender)
    )
        (asserts! (not (is-eq caller user)) ERR_INVALID_INPUT)
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        
        ;; Remove any existing friendship
        (map-delete Friendships {user1: caller, user2: user})
        (map-delete Friendships {user1: user, user2: caller})
        
        ;; Add to blocked users
        (map-set BlockedUsers
            {blocker: caller, blocked: user}
            {
                timestamp: (unwrap-panic (get-block-info? time u0)),
                reason: none
            }
        )
        
        (update-user-activity caller)
        
        (print {event: "user-blocked", blocker: caller, blocked: user})
        (ok true)
    )
)

(define-public (unblock-user (user principal))
    (let (
        (caller tx-sender)
    )
        (asserts! (is-blocked caller user) ERR_NOT_FOUND)
        
        (map-delete BlockedUsers {blocker: caller, blocked: user})
        
        (update-user-activity caller)
        
        (print {event: "user-unblocked", blocker: caller, blocked: user})
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-user-profile (user principal))
    (let (
        (caller tx-sender)
    )
        (asserts! (or 
            (is-eq caller user)
            (can-view-user-details caller user)
        ) ERR_UNAUTHORIZED)
        
        (ok (map-get? Users user))
    )
)

(define-read-only (get-friend-list (user principal))
    (let (
        (caller tx-sender)
        (privacy-settings (get-privacy-settings user))
    )
        (asserts! (or 
            (is-eq caller user)
            (and 
                (get friend-list-visible privacy-settings)
                (not (is-blocked user caller))
            )
        ) ERR_UNAUTHORIZED)
        
        (ok (map-get? Friendships {user1: user, user2: caller}))
    )
)

(define-read-only (get-online-status (user principal))
    (let (
        (caller tx-sender)
    )
        (asserts! (can-view-last-seen caller user) ERR_UNAUTHORIZED)
        (ok (is-user-online user))
    )
)

;; Contract initialization
(define-public (initialize-contract)
    (ok true)
)
