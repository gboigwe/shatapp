;; Title: ShatApp Core Contract
;; Version: 1.1.0
;; Description: Enhanced core functionality for ShatApp decentralized chat application

;; Error codes
(define-constant ERR_NOT_FOUND (err u100))
(define-constant ERR_ALREADY_EXISTS (err u101))
(define-constant ERR_UNAUTHORIZED (err u102))
(define-constant ERR_INVALID_INPUT (err u103))
(define-constant ERR_BLOCKED (err u104))
(define-constant ERR_DEACTIVATED (err u105))

;; Constants for user status
(define-constant STATUS_DEACTIVATED u0)
(define-constant STATUS_ACTIVE u1)
(define-constant STATUS_SUSPENDED u2)

;; Constants for friendship status
(define-constant FRIENDSHIP_PENDING u0)
(define-constant FRIENDSHIP_ACTIVE u1)
(define-constant FRIENDSHIP_BLOCKED u2)

;; Data structures
(define-map Users 
    principal 
    {
        name: (string-ascii 64),
        status: uint,  ;; 0: deactivated, 1: active, 2: suspended
        timestamp: uint,
        metadata: (optional (string-utf8 256)),
        deactivation-time: (optional uint)
    }
)

(define-map UserPrivacy
    principal
    {
        friend-list-visible: bool,
        status-visible: bool,
        metadata-visible: bool,
        last-updated: uint
    }
)

(define-map BlockedUsers
    {blocker: principal, blocked: principal}
    {
        timestamp: uint,
        reason: (optional (string-ascii 64))
    }
)

(define-map UserBatches
    principal
    {
        message-counter: uint,
        last-batch-timestamp: uint,
        batch-size: uint
    }
)

(define-map Friendships
    {user1: principal, user2: principal}
    {
        status: uint,  ;; 0: pending, 1: active, 2: blocked
        timestamp: uint,
        last-interaction: uint
    }
)

;; Private functions
(define-private (check-active-user (user principal))
    (match (map-get? Users user)
        user-data (and 
            (is-eq (get status user-data) STATUS_ACTIVE)
            (is-none (get deactivation-time user-data))
        )
        false
    )
)

(define-private (check-blocked (user1 principal) (user2 principal))
    (is-some (map-get? BlockedUsers {blocker: user1, blocked: user2}))
)

;; Read-only functions
(define-read-only (get-user (user principal))
    (let
        (
            (caller tx-sender)
            (user-data (map-get? Users user))
            (privacy (default-to 
                {friend-list-visible: true, status-visible: true, metadata-visible: true, last-updated: u0}
                (map-get? UserPrivacy user)
            ))
        )
        (if (or 
            (is-eq caller user)
            (and
                (get status-visible privacy)
                (not (check-blocked user caller))
            ))
            (ok user-data)
            (err ERR_UNAUTHORIZED)
        )
    )
)

(define-read-only (get-friendship-status (user1 principal) (user2 principal))
    (let
        (
            (friendship1 (map-get? Friendships {user1: user1, user2: user2}))
            (friendship2 (map-get? Friendships {user1: user2, user2: user1}))
        )
        (ok {
            forward: friendship1,
            reverse: friendship2
        })
    )
)

;; Public functions
(define-public (register-user (name (string-ascii 64)) (metadata (optional (string-utf8 256))))
    (let
        (
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
                deactivation-time: none
            }
        )
        
        ;; Set default privacy settings
        (map-set UserPrivacy
            caller
            {
                friend-list-visible: true,
                status-visible: true,
                metadata-visible: true,
                last-updated: (unwrap-panic (get-block-info? time u0))
            }
        )
        
        ;; Initialize batch tracking
        (map-set UserBatches
            caller
            {
                message-counter: u0,
                last-batch-timestamp: (unwrap-panic (get-block-info? time u0)),
                batch-size: u50
            }
        )
        
        (print {event: "user-registered", user: caller})
        (ok true)
    )
)

(define-public (deactivate-account)
    (let
        (
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

(define-public (reactivate-account)
    (let
        (
            (caller tx-sender)
            (user (map-get? Users caller))
        )
        (asserts! (is-some user) ERR_NOT_FOUND)
        (asserts! (is-eq (get status (unwrap-panic user)) STATUS_DEACTIVATED) ERR_UNAUTHORIZED)
        
        (map-set Users 
            caller
            (merge (unwrap-panic user) {
                status: STATUS_ACTIVE,
                deactivation-time: none
            })
        )
        
        (print {event: "account-reactivated", user: caller})
        (ok true)
    )
)

(define-public (update-privacy-settings (friend-list-visible bool) (status-visible bool) (metadata-visible bool))
    (let
        (
            (caller tx-sender)
            (user (map-get? Users caller))
        )
        (asserts! (is-some user) ERR_NOT_FOUND)
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        
        (map-set UserPrivacy
            caller
            {
                friend-list-visible: friend-list-visible,
                status-visible: status-visible,
                metadata-visible: metadata-visible,
                last-updated: (unwrap-panic (get-block-info? time u0))
            }
        )
        
        (print {
            event: "privacy-updated",
            user: caller,
            settings: {
                friend-list-visible: friend-list-visible,
                status-visible: status-visible,
                metadata-visible: metadata-visible
            }
        })
        (ok true)
    )
)

(define-public (block-user (user principal))
    (let
        (
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
        
        (print {event: "user-blocked", blocker: caller, blocked: user})
        (ok true)
    )
)

(define-public (unblock-user (user principal))
    (let
        (
            (caller tx-sender)
            (block-data (map-get? BlockedUsers {blocker: caller, blocked: user}))
        )
        (asserts! (is-some block-data) ERR_NOT_FOUND)
        
        (map-delete BlockedUsers {blocker: caller, blocked: user})
        
        (print {event: "user-unblocked", blocker: caller, blocked: user})
        (ok true)
    )
)

(define-public (cancel-friendship (friend principal))
    (let
        (
            (caller tx-sender)
        )
        (asserts! (not (is-eq caller friend)) ERR_INVALID_INPUT)
        (asserts! (check-active-user caller) ERR_DEACTIVATED)
        
        ;; Remove friendship in both directions
        (map-delete Friendships {user1: caller, user2: friend})
        (map-delete Friendships {user1: friend, user2: caller})
        
        (print {event: "friendship-cancelled", user1: caller, user2: friend})
        (ok true)
    )
)

;; Contract initialization
(define-public (initialize-contract)
    (ok true)
)
