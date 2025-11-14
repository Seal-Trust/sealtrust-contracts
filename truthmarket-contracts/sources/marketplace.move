// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// TruthMarket Marketplace Contract
///
/// Flow:
/// 1. Seller uploads encrypted dataset to Walrus
/// 2. Seller gets Nautilus TEE verification (hash + signature)
/// 3. Seller creates marketplace listing with DatasetNFT
/// 4. Buyer purchases listing (pays in SUI)
/// 5. Buyer gets Seal subscription for decryption
module truthmarket::marketplace;

use std::string::String;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::clock::Clock;
use app::truthmarket::DatasetNFT;

/// Errors
const EInvalidPrice: u64 = 1;
const EInsufficientPayment: u64 = 2;
const ENotSeller: u64 = 3;
const EListingNotActive: u64 = 4;
const EWrongVersion: u64 = 5;

const VERSION: u64 = 1;

/// Package version for Seal integration
public struct PackageVersion has key {
    id: UID,
    version: u64,
}

public struct PackageVersionCap has key {
    id: UID,
}

/// Marketplace shared object
public struct Marketplace has key {
    id: UID,
    /// Listing ID => Listing
    listings: Table<ID, Listing>,
    /// Platform fee (basis points, e.g., 250 = 2.5%)
    platform_fee_bps: u64,
    /// Platform earnings
    platform_balance: Balance<SUI>,
}

/// Individual dataset listing
public struct Listing has store {
    /// Unique listing ID
    listing_id: ID,
    /// Seller address
    seller: address,
    /// Dataset metadata
    name: String,
    description: String,
    /// Walrus blob ID (encrypted dataset)
    blob_id: vector<u8>,
    /// Nautilus verified hash
    dataset_hash: vector<u8>,
    /// Dataset format (CSV, JSON, Parquet, etc.)
    format: String,
    /// Schema version
    schema_version: String,
    /// Verification timestamp from Nautilus
    verification_timestamp: u64,
    /// Nautilus enclave ID that verified this
    enclave_id: ID,
    /// Price in MIST (1 SUI = 1,000,000,000 MIST)
    price: u64,
    /// Subscription TTL in milliseconds
    subscription_ttl: u64,
    /// Is listing active?
    active: bool,
    /// Sales count
    sales_count: u64,
}

/// Proof of purchase - buyer receives this after payment
/// Acts as Seal subscription for decryption access
public struct PurchaseReceipt has key {
    id: UID,
    /// Reference to listing
    listing_id: ID,
    /// Reference to seller
    seller: address,
    /// Buyer address
    buyer: address,
    /// Purchase timestamp
    purchased_at: u64,
    /// Subscription expiry
    expires_at: u64,
    /// Walrus blob ID for download
    blob_id: vector<u8>,
}

/// Capability for marketplace admin
public struct MarketplaceCap has key {
    id: UID,
}

/// One-time witness
public struct MARKETPLACE has drop {}

/// Initialize marketplace
fun init(_otw: MARKETPLACE, ctx: &mut TxContext) {
    // Create package version for Seal integration
    transfer::share_object(PackageVersion {
        id: object::new(ctx),
        version: VERSION,
    });
    transfer::transfer(
        PackageVersionCap { id: object::new(ctx) },
        ctx.sender()
    );

    // Create marketplace
    transfer::share_object(Marketplace {
        id: object::new(ctx),
        listings: table::new(ctx),
        platform_fee_bps: 250, // 2.5% platform fee
        platform_balance: balance::zero(),
    });

    // Transfer admin cap
    transfer::transfer(
        MarketplaceCap { id: object::new(ctx) },
        ctx.sender()
    );
}

/// Create a new listing (seller)
/// Requires a DatasetNFT from Nautilus verification - provides cryptographic proof
/// The NFT is transferred to the marketplace for verification, then returned to seller
public fun create_listing(
    marketplace: &mut Marketplace,
    nft: DatasetNFT,
    name: String,
    description: String,
    blob_id: vector<u8>,
    price: u64,
    subscription_ttl: u64,
    ctx: &mut TxContext,
): ID {
    assert!(price > 0, EInvalidPrice);

    // Extract verified data from the DatasetNFT
    // This proves the dataset was verified by Nautilus
    let dataset_hash = app::truthmarket::dataset_hash(&nft);
    let format = app::truthmarket::format(&nft);
    let schema_version = app::truthmarket::schema_version(&nft);
    let verification_timestamp = app::truthmarket::verification_timestamp(&nft);
    let enclave_id = app::truthmarket::enclave_id(&nft);

    let listing_id = object::new(ctx);
    let listing_id_value = object::uid_to_inner(&listing_id);

    let listing = Listing {
        listing_id: listing_id_value,
        seller: ctx.sender(),
        name,
        description,
        blob_id,
        dataset_hash: *dataset_hash,
        format: *format,
        schema_version: *schema_version,
        verification_timestamp,
        enclave_id,
        price,
        subscription_ttl,
        active: true,
        sales_count: 0,
    };

    marketplace.listings.add(listing_id_value, listing);
    object::delete(listing_id);

    // Transfer NFT back to seller as proof of ownership
    transfer::public_transfer(nft, ctx.sender());

    listing_id_value
}

/// Purchase a listing (buyer)
/// Returns PurchaseReceipt which acts as Seal subscription
public fun purchase_listing(
    marketplace: &mut Marketplace,
    listing_id: ID,
    mut payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): PurchaseReceipt {
    let listing = marketplace.listings.borrow_mut(listing_id);

    assert!(listing.active, EListingNotActive);
    assert!(coin::value(&payment) >= listing.price, EInsufficientPayment);

    // Calculate platform fee
    let total_amount = coin::value(&payment);
    let platform_fee = (total_amount * marketplace.platform_fee_bps) / 10000;

    // Split payment
    let platform_coin = coin::split(&mut payment, platform_fee, ctx);
    balance::join(&mut marketplace.platform_balance, coin::into_balance(platform_coin));

    // Transfer to seller
    transfer::public_transfer(payment, listing.seller);

    // Update listing
    listing.sales_count = listing.sales_count + 1;

    // Create purchase receipt (Seal subscription)
    let current_time = clock.timestamp_ms();
    let receipt = PurchaseReceipt {
        id: object::new(ctx),
        listing_id,
        seller: listing.seller,
        buyer: ctx.sender(),
        purchased_at: current_time,
        expires_at: current_time + listing.subscription_ttl,
        blob_id: listing.blob_id,
    };

    receipt
}

/// Internal approval logic - checks if buyer has valid subscription
fun approve_internal(
    id: &vector<u8>,
    pkg_version: &PackageVersion,
    receipt: &PurchaseReceipt,
    listing: &Listing,
    clock: &Clock,
): bool {
    // Check package version
    if (pkg_version.version != VERSION) {
        return false
    };

    // Check receipt matches listing
    if (receipt.listing_id != listing.listing_id) {
        return false
    };

    // Check subscription not expired
    if (clock.timestamp_ms() > receipt.expires_at) {
        return false
    };

    // Check if ID has listing prefix (similar to subscription pattern)
    let namespace = object::id_to_bytes(&receipt.listing_id);
    let mut i = 0;
    if (namespace.length() > id.length()) {
        return false
    };
    while (i < namespace.length()) {
        if (*namespace.borrow(i) != *id.borrow(i)) {
            return false
        };
        i = i + 1;
    };

    true
}

/// Seal approve function - public entry point for Seal SDK
/// This is called by Seal SDK during decryption
/// Returns true if access is granted, aborts on invalid version
public fun seal_approve(
    id: vector<u8>,
    pkg_version: &PackageVersion,
    receipt: &PurchaseReceipt,
    listing: &Listing,
    clock: &Clock,
): bool {
    // Version check must abort (critical security)
    assert!(pkg_version.version == VERSION, EWrongVersion);

    // Access checks can return false (user-facing)
    approve_internal(&id, pkg_version, receipt, listing, clock)
}

/// Update listing status (seller only)
public fun update_listing_status(
    marketplace: &mut Marketplace,
    listing_id: ID,
    active: bool,
    ctx: &TxContext,
) {
    let listing = marketplace.listings.borrow_mut(listing_id);
    assert!(listing.seller == ctx.sender(), ENotSeller);
    listing.active = active;
}

/// Update listing price (seller only)
public fun update_listing_price(
    marketplace: &mut Marketplace,
    listing_id: ID,
    new_price: u64,
    ctx: &TxContext,
) {
    assert!(new_price > 0, EInvalidPrice);
    let listing = marketplace.listings.borrow_mut(listing_id);
    assert!(listing.seller == ctx.sender(), ENotSeller);
    listing.price = new_price;
}

/// Withdraw platform earnings (admin only)
public fun withdraw_platform_earnings(
    _cap: &MarketplaceCap,
    marketplace: &mut Marketplace,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(amount <= balance::value(&marketplace.platform_balance), EInsufficientPayment);
    coin::from_balance(balance::split(&mut marketplace.platform_balance, amount), ctx)
}

/// Getters
public fun listing_seller(listing: &Listing): address {
    listing.seller
}

public fun listing_name(listing: &Listing): &String {
    &listing.name
}

public fun listing_price(listing: &Listing): u64 {
    listing.price
}

public fun listing_blob_id(listing: &Listing): &vector<u8> {
    &listing.blob_id
}

public fun listing_dataset_hash(listing: &Listing): &vector<u8> {
    &listing.dataset_hash
}

public fun listing_active(listing: &Listing): bool {
    listing.active
}

public fun receipt_listing_id(receipt: &PurchaseReceipt): ID {
    receipt.listing_id
}

public fun receipt_expires_at(receipt: &PurchaseReceipt): u64 {
    receipt.expires_at
}

public fun receipt_blob_id(receipt: &PurchaseReceipt): &vector<u8> {
    &receipt.blob_id
}

public fun listing_sales_count(listing: &Listing): u64 {
    listing.sales_count
}

#[test_only]
/// Test-only: Get listing from marketplace by ID
public fun test_get_listing(marketplace: &Marketplace, listing_id: ID): &Listing {
    marketplace.listings.borrow(listing_id)
}

#[test_only]
/// Test-only: Get platform balance
public fun test_platform_balance(marketplace: &Marketplace): u64 {
    balance::value(&marketplace.platform_balance)
}

// ========== TESTS ==========

#[test_only]
use sui::test_scenario::{Self as ts, Scenario};
#[test_only]
use sui::test_utils;
#[test_only]
use sui::clock;

#[test_only]
/// Create a test marketplace (also creates PackageVersion and Cap)
public fun create_test_marketplace(scenario: &mut Scenario) {
    let ctx = ts::ctx(scenario);
    let sender = ctx.sender();

    transfer::share_object(Marketplace {
        id: object::new(ctx),
        listings: table::new(ctx),
        platform_fee_bps: 250, // 2.5%
        platform_balance: balance::zero(),
    });

    // Create PackageVersion for seal_approve tests
    let ctx2 = ts::ctx(scenario);
    transfer::share_object(PackageVersion {
        id: object::new(ctx2),
        version: 1,
    });

    // Create and transfer Cap to sender (admin)
    let ctx3 = ts::ctx(scenario);
    transfer::transfer(MarketplaceCap {
        id: object::new(ctx3),
    }, sender);
}

#[test_only]
/// Create test clock
public fun create_test_clock(ctx: &mut TxContext): Clock {
    clock::create_for_testing(ctx)
}

#[test_only]
/// Create and share test PackageVersion
public fun create_test_package_version(scenario: &mut Scenario) {
    let ctx = ts::ctx(scenario);
    transfer::share_object(PackageVersion {
        id: object::new(ctx),
        version: 1,
    });
}

#[test_only]
/// Helper: Create test listing with minimal parameters
public fun create_test_listing_simple(
    marketplace: &mut Marketplace,
    name: vector<u8>,
    price: u64,
    ttl: u64,
    ctx: &mut TxContext,
): ID {
    let nft = app::truthmarket::test_create_dataset_nft(
        b"test_hash",
        b"https://example.com/data.csv",
        b"CSV",
        b"v1.0",
        1700000000000,
        object::id_from_address(@0xE1C1A0E),
        ctx
    );

    create_listing(
        marketplace,
        nft,
        std::string::utf8(name),
        std::string::utf8(b"Test description"),
        b"test_blob_id",
        price,
        ttl,
        ctx,
    )
}
