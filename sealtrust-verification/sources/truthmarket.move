// Copyright (c) SealTrust
// SPDX-License-Identifier: Apache-2.0
//
// SealTrust Dataset Verification Contract
// Module name kept as 'truthmarket' for backward compatibility with deployed contracts

module app::truthmarket;

use std::string::{Self, String};
use sui::address;
use enclave::enclave::{Self, Enclave};

const DATASET_INTENT: u8 = 0;
const EInvalidSignature: u64 = 1;

/// NFT representing a verified dataset with encrypted storage
public struct DatasetNFT has key, store {
    id: UID,
    // Core verification data
    original_hash: vector<u8>,        // Hash of UNENCRYPTED file
    metadata_hash: vector<u8>,        // Hash of metadata struct

    // Storage references
    walrus_blob_id: String,           // Where encrypted blob is stored
    seal_policy_id: String,           // Access control policy ID
    seal_allowlist_id: Option<ID>,   // Optional: Allowlist object ID for access control

    // Metadata
    name: String,                     // Dataset name
    dataset_url: String,              // Original URL (if applicable)
    format: String,
    size: u64,                        // File size in bytes
    schema_version: String,

    // Verification proof
    verification_timestamp: u64,
    enclave_id: ID,
    tee_signature: vector<u8>,       // TEE attestation signature

    // Ownership
    owner: address,
}

/// MUST match Rust DatasetVerification struct exactly for BCS serialization
public struct DatasetVerification has copy, drop {
    dataset_id: vector<u8>,          // Unique dataset ID
    name: vector<u8>,                // Dataset name
    description: vector<u8>,          // Dataset description
    format: vector<u8>,              // File format
    size: u64,                       // File size in bytes
    original_hash: vector<u8>,       // Hash of UNENCRYPTED file
    walrus_blob_id: vector<u8>,      // Walrus storage ID
    seal_policy_id: vector<u8>,      // Seal access policy ID
    timestamp: u64,                  // Verification timestamp
    uploader: vector<u8>,            // Uploader address
}

/// Witness for one-time init
public struct TRUTHMARKET has drop {}

fun init(otw: TRUTHMARKET, ctx: &mut TxContext) {
    let cap = enclave::new_cap(otw, ctx);

    // Create enclave config with zero PCRs (will update with real values later)
    cap.create_enclave_config(
        std::string::utf8(b"sealtrust dataset enclave"),
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        ctx,
    );

    transfer::public_transfer(cap, ctx.sender())
}

/// Register a dataset with Nautilus verification and encrypted storage
/// Returns a DatasetNFT that serves as proof of authenticity and storage location
public fun register_dataset<T>(
    // Metadata fields
    dataset_id: vector<u8>,
    name: vector<u8>,
    description: vector<u8>,
    format: vector<u8>,
    size: u64,
    // Verification data
    original_hash: vector<u8>,      // Hash of UNENCRYPTED file
    metadata_hash: vector<u8>,      // Hash of metadata struct
    // Storage references
    walrus_blob_id: String,         // Where encrypted blob is stored
    seal_policy_id: String,         // Seal access control policy
    seal_allowlist_id: Option<ID>,  // Optional: Allowlist object ID for access control
    // Attestation
    timestamp_ms: u64,
    tee_signature: &vector<u8>,
    // Enclave reference
    enclave: &Enclave<T>,
    ctx: &mut TxContext
): DatasetNFT {
    // Reconstruct the exact DatasetVerification struct that was signed
    let verification_data = DatasetVerification {
        dataset_id,
        name,
        description,
        format,
        size,
        original_hash,
        walrus_blob_id: *walrus_blob_id.as_bytes(),
        seal_policy_id: *seal_policy_id.as_bytes(),
        timestamp: timestamp_ms,
        uploader: address::to_bytes(ctx.sender()),
    };

    // Verify the signature from the Nautilus enclave
    let is_valid = enclave::verify_signature<T, DatasetVerification>(
        enclave,
        DATASET_INTENT,
        timestamp_ms,
        verification_data,
        tee_signature
    );

    assert!(is_valid, EInvalidSignature);

    // Create NFT with verified data
    DatasetNFT {
        id: object::new(ctx),
        // Core verification data
        original_hash: verification_data.original_hash,
        metadata_hash,
        // Storage references
        walrus_blob_id,
        seal_policy_id,
        seal_allowlist_id,
        // Metadata
        name: string::utf8(verification_data.name),
        dataset_url: string::utf8(b""), // Optional, can be empty
        format: string::utf8(verification_data.format),
        size: verification_data.size,
        schema_version: string::utf8(b"v1.0"), // Default version
        // Verification proof
        verification_timestamp: timestamp_ms,
        enclave_id: object::id(enclave),
        tee_signature: *tee_signature,
        // Ownership
        owner: ctx.sender(),
    }
}

/// DEV ONLY: Register dataset using EnclaveConfig (for testing without real enclave)
/// WARNING: This skips signature verification! Only use for development/demo
public fun register_dataset_dev<T>(
    // Metadata fields
    name: vector<u8>,
    format: vector<u8>,
    size: u64,
    // Verification data
    original_hash: vector<u8>,
    metadata_hash: vector<u8>,
    // Storage references
    walrus_blob_id: String,
    seal_policy_id: String,
    seal_allowlist_id: Option<ID>,  // Optional: Allowlist object ID for access control
    // Attestation
    timestamp_ms: u64,
    tee_signature: &vector<u8>,
    enclave_config: &enclave::EnclaveConfig<T>,
    ctx: &mut TxContext
): DatasetNFT {
    // Create NFT without signature verification (DEV ONLY!)
    DatasetNFT {
        id: object::new(ctx),
        // Core verification data
        original_hash,
        metadata_hash,
        // Storage references
        walrus_blob_id,
        seal_policy_id,
        seal_allowlist_id,
        // Metadata
        name: string::utf8(name),
        dataset_url: string::utf8(b""),
        format: string::utf8(format),
        size,
        schema_version: string::utf8(b"v1.0"),
        // Verification proof
        verification_timestamp: timestamp_ms,
        enclave_id: object::id(enclave_config),
        tee_signature: *tee_signature,
        // Ownership
        owner: ctx.sender(),
    }
}

/// Getters for DatasetNFT - Core verification data
public fun original_hash(nft: &DatasetNFT): &vector<u8> {
    &nft.original_hash
}

public fun metadata_hash(nft: &DatasetNFT): &vector<u8> {
    &nft.metadata_hash
}

/// Getters for storage references (Seal & Walrus integration)
public fun walrus_blob_id(nft: &DatasetNFT): &String {
    &nft.walrus_blob_id
}

public fun seal_policy_id(nft: &DatasetNFT): &String {
    &nft.seal_policy_id
}

public fun seal_allowlist_id(nft: &DatasetNFT): Option<ID> {
    nft.seal_allowlist_id
}

/// Getters for metadata
public fun name(nft: &DatasetNFT): &String {
    &nft.name
}

public fun dataset_url(nft: &DatasetNFT): &String {
    &nft.dataset_url
}

public fun format(nft: &DatasetNFT): &String {
    &nft.format
}

public fun size(nft: &DatasetNFT): u64 {
    nft.size
}

public fun schema_version(nft: &DatasetNFT): &String {
    &nft.schema_version
}

/// Getters for verification proof
public fun verification_timestamp(nft: &DatasetNFT): u64 {
    nft.verification_timestamp
}

public fun enclave_id(nft: &DatasetNFT): ID {
    nft.enclave_id
}

public fun tee_signature(nft: &DatasetNFT): &vector<u8> {
    &nft.tee_signature
}

public fun owner(nft: &DatasetNFT): address {
    nft.owner
}

// ========== TESTS ==========

#[test_only]
use std::bcs;
#[test_only]
use sui::test_scenario::{Self as ts};
#[test_only]
use sui::test_utils;

#[test]
fun test_dataset_verification_struct() {
    // Test DatasetVerification struct creation
    let payload = DatasetVerification {
        dataset_id: b"test-123",
        name: b"test.csv",
        description: b"Test dataset",
        format: b"CSV",
        size: 1024,
        original_hash: vector[0x12, 0x34, 0x56, 0x78],
        walrus_blob_id: b"blob-123",
        seal_policy_id: b"policy-123",
        timestamp: 1700000000000,
        uploader: b"0xA",
    };

    // Verify fields
    assert!(payload.original_hash == vector[0x12, 0x34, 0x56, 0x78]);
    assert!(payload.timestamp == 1700000000000);
    assert!(payload.size == 1024);
}

#[test]
fun test_dataset_nft_creation() {
    // Test DatasetNFT getters
    let user = @0xA;
    let mut scenario = ts::begin(user);

    ts::next_tx(&mut scenario, user);
    {
        let ctx = ts::ctx(&mut scenario);

        let nft = DatasetNFT {
            id: object::new(ctx),
            original_hash: b"test_hash",
            metadata_hash: b"metadata_hash",
            walrus_blob_id: string::utf8(b"blob-123"),
            seal_policy_id: string::utf8(b"policy-123"),
            seal_allowlist_id: option::some(object::id_from_address(@0xA110111)),
            name: string::utf8(b"test.csv"),
            dataset_url: string::utf8(b"https://example.com/data.csv"),
            format: string::utf8(b"CSV"),
            size: 1024,
            schema_version: string::utf8(b"v1.0"),
            verification_timestamp: 1700000000000,
            enclave_id: object::id_from_address(@0xE1C1A0E),
            tee_signature: b"signature",
            owner: user,
        };

        // Test getters
        assert!(original_hash(&nft) == &b"test_hash");
        assert!(metadata_hash(&nft) == &b"metadata_hash");
        assert!(verification_timestamp(&nft) == 1700000000000);
        assert!(dataset_url(&nft) == &string::utf8(b"https://example.com/data.csv"));
        assert!(format(&nft) == &string::utf8(b"CSV"));
        assert!(walrus_blob_id(&nft) == &string::utf8(b"blob-123"));
        assert!(seal_policy_id(&nft) == &string::utf8(b"policy-123"));
        assert!(size(&nft) == 1024);
        assert!(owner(&nft) == user);

        test_utils::destroy(nft);
    };

    ts::end(scenario);
}

#[test]
fun test_constant_values() {
    // Test that constants are defined correctly
    assert!(DATASET_INTENT == 0, EInvalidSignature);
}

#[test_only]
/// Helper function to create test DatasetNFT for integration tests
public fun test_create_dataset_nft(
    original_hash: vector<u8>,
    metadata_hash: vector<u8>,
    walrus_blob_id: String,
    seal_policy_id: String,
    seal_allowlist_id: Option<ID>,
    name: vector<u8>,
    format: vector<u8>,
    size: u64,
    schema_version: vector<u8>,
    verification_timestamp: u64,
    enclave_id: ID,
    tee_signature: vector<u8>,
    owner: address,
    ctx: &mut TxContext
): DatasetNFT {
    DatasetNFT {
        id: object::new(ctx),
        original_hash,
        metadata_hash,
        walrus_blob_id,
        seal_policy_id,
        seal_allowlist_id,
        name: string::utf8(name),
        dataset_url: string::utf8(b""),
        format: string::utf8(format),
        size,
        schema_version: string::utf8(schema_version),
        verification_timestamp,
        enclave_id,
        tee_signature,
        owner,
    }
}

#[test]
fun test_bcs_serialization_consistency() {
    // CRITICAL: This MUST produce IDENTICAL bytes to Rust test in nautilus-app/src/lib.rs
    // Compare output with: cargo test --lib test_serde -- --nocapture
    let payload = DatasetVerification {
        dataset_id: b"test-123",
        name: b"test.csv",
        description: b"Test dataset",
        format: b"CSV",
        size: 1024,
        original_hash: b"abc123",
        walrus_blob_id: b"blob-123",
        seal_policy_id: b"policy-123",
        timestamp: 1700000000000,
        uploader: b"0xA",
    };

    let bytes = bcs::to_bytes(&payload);

    // Print for manual comparison with Rust output
    std::debug::print(&bytes);

    // Verify basic properties
    assert!(bytes.length() > 0, 1);
}
