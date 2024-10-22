;; Title: ShatApp Core Contract
;; Version: 1.0.0
;; Description: Core functionality for ShatApp decentralized chat application

;; Error codes
(define-constant ERR_NOT_FOUND (err u100))
(define-constant ERR_ALREADY_EXISTS (err u101))
(define-constant ERR_UNAUTHORIZED (err u102))
(define-constant ERR_INVALID_INPUT (err u103))

;; Data structures
(define-map Users 
    principal 
    {
        name: (string-ascii 64),
        status: uint,  ;; 0: inactive, 1: active
        timestamp: uint,
        metadata: (optional (string-utf8 256))  ;; For additional user data
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
        timestamp: uint
    }
)

;; SIP-009 NFT Interface (for potential future profile NFTs)
(impl-trait 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.nft-trait.nft-trait)

;; Read-only functions
(define-read-only (get-user (user principal))
    (ok (map-get? Users user))
)

(define-read-only (get-friendship-status (user1 principal) (user2 principal))
    (ok (map-get? Friendships {user1: user1, user2: user2}))
)

(define-read-only (get-user-batch-info (user principal))
    (ok (map-get? UserBatches user))
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
        
        (try! (map-set Users 
            caller
            {
                name: name,
                status: u1,
                timestamp: (unwrap-panic (get-block-info? time u0)),
                metadata: metadata
            }
        ))
        
        ;; Initialize batch tracking
        (try! (map-set UserBatches
            caller
            {
                message-counter: u0,
                last-batch-timestamp: (unwrap-panic (get-block-info? time u0)),
                batch-size: u50  ;; Default batch size
            }
        ))
        
        (ok true)
    )
)

(define-public (update-user-status (new-status uint))
    (let
        (
            (caller tx-sender)
            (user (map-get? Users caller))
        )
        (asserts! (is-some user) ERR_NOT_FOUND)
        (asserts! (<= new-status u2) ERR_INVALID_INPUT)
        
        (try! (map-set Users 
            caller
            (merge (unwrap-panic user) {status: new-status})
        ))
        
        (ok true)
    )
)

(define-public (update-user-metadata (new-metadata (string-utf8 256)))
    (let
        (
            (caller tx-sender)
            (user (map-get? Users caller))
        )
        (asserts! (is-some user) ERR_NOT_FOUND)
        
        (try! (map-set Users 
            caller
            (merge (unwrap-panic user) {metadata: (some new-metadata)})
        ))
        
        (ok true)
    )
)

(define-public (init-friendship (friend principal))
    (let
        (
            (caller tx-sender)
            (friendship-data {
                status: u0,  ;; pending
                timestamp: (unwrap-panic (get-block-info? time u0))
            })
        )
        (asserts! (not (is-eq caller friend)) ERR_INVALID_INPUT)
        (asserts! (is-some (map-get? Users friend)) ERR_NOT_FOUND)
        
        ;; Check if friendship already exists
        (asserts! (is-none (map-get? Friendships {user1: caller, user2: friend})) ERR_ALREADY_EXISTS)
        (asserts! (is-none (map-get? Friendships {user1: friend, user2: caller})) ERR_ALREADY_EXISTS)
        
        (try! (map-set Friendships 
            {user1: caller, user2: friend}
            friendship-data
        ))
        
        (ok true)
    )
)

(define-public (accept-friendship (friend principal))
    (let
        (
            (caller tx-sender)
            (friendship (map-get? Friendships {user1: friend, user2: caller}))
        )
        (asserts! (is-some friendship) ERR_NOT_FOUND)
        (asserts! (is-eq (get status (unwrap-panic friendship)) u0) ERR_INVALID_INPUT)
        
        (try! (map-set Friendships 
            {user1: friend, user2: caller}
            (merge (unwrap-panic friendship) {status: u1})
        ))
        
        (ok true)
    )
)

;; Contract initialization
(define-public (initialize-contract)
    (ok true)
)
