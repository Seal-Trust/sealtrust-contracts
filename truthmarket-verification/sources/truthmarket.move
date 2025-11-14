// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module app::truthmarket;

use std::string::{Self, String};
use enclave::enclave::{Self, Enclave};

const DATASET_INTENT: u8 = 0;
const EInvalidSignature: u64 = 1;

/// NFT representing a verified dataset
public struct DatasetNFT has key, store {
    id: UID,
    dataset_hash: vector<u8>,
    dataset_url: String,
    format: String,
    schema_version: String,
    verification_timestamp: u64,
    enclave_id: ID,
}

/// MUST match Rust DatasetVerification struct exactly for BCS serialization
public struct DatasetVerification has copy, drop {
    dataset_hash: vector<u8>,
    dataset_url: vector<u8>,
    format: vector<u8>,
    schema_version: vector<u8>,
    verification_timestamp: u64,
}

/// Witness for one-time init
public struct TRUTHMARKET has drop {}

fun init(otw: TRUTHMARKET, ctx: &mut TxContext) {
    let cap = enclave::new_cap(otw, ctx);

    // Create enclave config with zero PCRs (will update with real values later)
    cap.create_enclave_config(
        std::string::utf8(b"truthmarket dataset enclave"),
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        ctx,
    );

    transfer::public_transfer(cap, ctx.sender())
}

/// Register a dataset with Nautilus verification
/// Returns a DatasetNFT that serves as proof of authenticity
public fun register_dataset<T>(
    dataset_hash: vector<u8>,
    dataset_url: vector<u8>,
    format: vector<u8>,
    schema_version: vector<u8>,
    timestamp_ms: u64,
    sig: &vector<u8>,
    enclave: &Enclave<T>,
    ctx: &mut TxContext
): DatasetNFT {
    // Reconstruct the exact DatasetVerification struct that was signed
    let verification_data = DatasetVerification {
        dataset_hash,
        dataset_url,
        format,
        schema_version,
        verification_timestamp: timestamp_ms,
    };

    // Verify the signature from the Nautilus enclave
    let is_valid = enclave::verify_signature<T, DatasetVerification>(
        enclave,
        DATASET_INTENT,
        timestamp_ms,
        verification_data,
        sig
    );

    assert!(is_valid, EInvalidSignature);

    // Create NFT with verified data
    DatasetNFT {
        id: object::new(ctx),
        dataset_hash: verification_data.dataset_hash,
        dataset_url: string::utf8(verification_data.dataset_url),
        format: string::utf8(verification_data.format),
        schema_version: string::utf8(verification_data.schema_version),
        verification_timestamp: timestamp_ms,
        enclave_id: object::id(enclave),
    }
}

/// Getters for DatasetNFT
public fun dataset_hash(nft: &DatasetNFT): &vector<u8> {
    &nft.dataset_hash
}

public fun dataset_url(nft: &DatasetNFT): &String {
    &nft.dataset_url
}

public fun format(nft: &DatasetNFT): &String {
    &nft.format
}

public fun schema_version(nft: &DatasetNFT): &String {
    &nft.schema_version
}

public fun verification_timestamp(nft: &DatasetNFT): u64 {
    nft.verification_timestamp
}

public fun enclave_id(nft: &DatasetNFT): ID {
    nft.enclave_id
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
        dataset_hash: vector[0x12, 0x34, 0x56, 0x78],
        dataset_url: b"https://datasets.example.com/data.csv",
        format: b"CSV",
        schema_version: b"v1.0",
        verification_timestamp: 1700000000000,
    };

    // Verify fields
    assert!(payload.dataset_hash == vector[0x12, 0x34, 0x56, 0x78]);
    assert!(payload.verification_timestamp == 1700000000000);
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
            dataset_hash: b"test_hash",
            dataset_url: string::utf8(b"https://example.com/data.csv"),
            format: string::utf8(b"CSV"),
            schema_version: string::utf8(b"v1.0"),
            verification_timestamp: 1700000000000,
            enclave_id: object::id_from_address(@0xE1C1A0E),
        };

        // Test getters
        assert!(dataset_hash(&nft) == &b"test_hash");
        assert!(verification_timestamp(&nft) == 1700000000000);
        assert!(dataset_url(&nft) == &string::utf8(b"https://example.com/data.csv"));
        assert!(format(&nft) == &string::utf8(b"CSV"));

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
    dataset_hash: vector<u8>,
    dataset_url: vector<u8>,
    format: vector<u8>,
    schema_version: vector<u8>,
    verification_timestamp: u64,
    enclave_id: ID,
    ctx: &mut TxContext
): DatasetNFT {
    DatasetNFT {
        id: object::new(ctx),
        dataset_hash,
        dataset_url: string::utf8(dataset_url),
        format: string::utf8(format),
        schema_version: string::utf8(schema_version),
        verification_timestamp,
        enclave_id,
    }
}

#[test]
fun test_bcs_serialization_consistency() {
    // CRITICAL: This MUST produce IDENTICAL bytes to Rust test in nautilus-app/src/lib.rs
    // Compare output with: cargo test --lib test_serde -- --nocapture
    let payload = DatasetVerification {
        dataset_hash: vector[0x12, 0x34, 0x56, 0x78],
        dataset_url: b"https://datasets.example.com/data.csv",
        format: b"CSV",
        schema_version: b"v1.0",
        verification_timestamp: 1700000000000,
    };

    let bytes = bcs::to_bytes(&payload);

    // Print for manual comparison with Rust output
    std::debug::print(&bytes);

    // Verify basic properties
    assert!(bytes.length() > 0, 1);
}
