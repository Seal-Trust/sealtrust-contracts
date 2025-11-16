// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Based on the allowlist pattern from Seal examples
// Used for access control in TruthMarket encrypted datasets

module walrus::allowlist;

use std::string::String;
use sui::dynamic_field as df;
use walrus::utils::is_prefix;

const EInvalidCap: u64 = 0;
const ENoAccess: u64 = 1;
const EDuplicate: u64 = 2;
const MARKER: u64 = 3;

/// Shared allowlist object that stores authorized addresses
public struct Allowlist has key {
    id: UID,
    name: String,
    list: vector<address>,
}

/// Admin capability for managing the allowlist
public struct Cap has key {
    id: UID,
    allowlist_id: ID,
}

//////////////////////////////////////////
/////// Simple allowlist with an admin cap

/// Create an allowlist with an admin cap.
/// The associated key-ids are [pkg id]::[allowlist id][nonce] for any nonce (thus
/// many key-ids can be created for the same allowlist).
public fun create_allowlist(name: String, ctx: &mut TxContext): Cap {
    let allowlist = Allowlist {
        id: object::new(ctx),
        list: vector::empty(),
        name: name,
    };
    let cap = Cap {
        id: object::new(ctx),
        allowlist_id: object::id(&allowlist),
    };
    transfer::share_object(allowlist);
    cap
}

// convenience function to create a allowlist and send it back to sender (simpler ptb for cli)
entry fun create_allowlist_entry(name: String, ctx: &mut TxContext) {
    transfer::transfer(create_allowlist(name, ctx), ctx.sender());
}

/// Add an address to the allowlist (requires admin cap)
public fun add(allowlist: &mut Allowlist, cap: &Cap, account: address) {
    assert!(cap.allowlist_id == object::id(allowlist), EInvalidCap);
    assert!(!allowlist.list.contains(&account), EDuplicate);
    allowlist.list.push_back(account);
}

/// Remove an address from the allowlist (requires admin cap)
public fun remove(allowlist: &mut Allowlist, cap: &Cap, account: address) {
    assert!(cap.allowlist_id == object::id(allowlist), EInvalidCap);
    allowlist.list = allowlist.list.filter!(|x| x != account);
}

//////////////////////////////////////////////////////////
/// Access control
/// key format: [pkg id]::[allowlist id][random nonce]
/// (Alternative key format: [pkg id]::[creator address][random nonce] - see private_data.move)

/// Get the namespace for this allowlist (used as prefix for policy IDs)
public fun namespace(allowlist: &Allowlist): vector<u8> {
    allowlist.id.to_bytes()
}

/// All allowlisted addresses can access all IDs with the prefix of the allowlist
fun approve_internal(caller: address, id: vector<u8>, allowlist: &Allowlist): bool {
    // Check if the id has the right prefix
    let namespace = namespace(allowlist);
    if (!is_prefix(namespace, id)) {
        return false
    };

    // Check if user is in the allowlist
    allowlist.list.contains(&caller)
}

/// Entry function called by Seal to verify access approval
/// This is what gets executed in the approval transaction
entry fun seal_approve(id: vector<u8>, allowlist: &Allowlist, ctx: &TxContext) {
    assert!(approve_internal(ctx.sender(), id, allowlist), ENoAccess);
}

/// Encapsulate a blob into a Sui object and attach it to the allowlist
public fun publish(allowlist: &mut Allowlist, cap: &Cap, blob_id: String) {
    assert!(cap.allowlist_id == object::id(allowlist), EInvalidCap);
    df::add(&mut allowlist.id, blob_id, MARKER);
}

#[test_only]
public fun new_allowlist_for_testing(ctx: &mut TxContext): Allowlist {

    Allowlist {
        id: object::new(ctx),
        name: b"test".to_string(),
        list: vector::empty(),
    }
}

#[test_only]
public fun new_cap_for_testing(ctx: &mut TxContext, allowlist: &Allowlist): Cap {
    Cap {
        id: object::new(ctx),
        allowlist_id: object::id(allowlist),
    }
}

#[test_only]
public fun destroy_for_testing(allowlist: Allowlist, cap: Cap) {
    let Allowlist { id, .. } = allowlist;
    object::delete(id);
    let Cap { id, .. } = cap;
    object::delete(id);
}

// ========== TESTS ==========

#[test_only]
use sui::test_scenario::{Self as ts};
#[test_only]
use sui::test_utils;

#[test]
fun test_create_allowlist() {
    let admin = @0xA;
    let mut scenario = ts::begin(admin);

    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let cap = create_allowlist(b"test allowlist".to_string(), ctx);

        // Verify cap was created
        assert!(cap.allowlist_id != object::id_from_address(@0x0), 0);

        // Transfer cap to admin
        transfer::transfer(cap, admin);
    };

    ts::end(scenario);
}

#[test]
fun test_add_and_remove_user() {
    let admin = @0xA;
    let user1 = @0xB;
    let user2 = @0xC;
    let mut scenario = ts::begin(admin);

    // Create allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let cap = create_allowlist(b"test".to_string(), ctx);
        transfer::transfer(cap, admin);
    };

    // Get shared allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let mut allowlist = ts::take_shared<Allowlist>(&scenario);
        let cap = ts::take_from_sender<Cap>(&scenario);

        // Add users
        add(&mut allowlist, &cap, user1);
        add(&mut allowlist, &cap, user2);

        // Verify users were added
        assert!(allowlist.list.contains(&user1), 0);
        assert!(allowlist.list.contains(&user2), 0);
        assert!(allowlist.list.length() == 2, 0);

        ts::return_shared(allowlist);
        ts::return_to_sender(&scenario, cap);
    };

    // Remove user
    ts::next_tx(&mut scenario, admin);
    {
        let mut allowlist = ts::take_shared<Allowlist>(&scenario);
        let cap = ts::take_from_sender<Cap>(&scenario);

        // Remove user1
        remove(&mut allowlist, &cap, user1);

        // Verify user1 removed but user2 remains
        assert!(!allowlist.list.contains(&user1), 0);
        assert!(allowlist.list.contains(&user2), 0);
        assert!(allowlist.list.length() == 1, 0);

        ts::return_shared(allowlist);
        ts::return_to_sender(&scenario, cap);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EDuplicate)]
fun test_add_duplicate_user() {
    let admin = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(admin);

    // Create allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let cap = create_allowlist(b"test".to_string(), ctx);
        transfer::transfer(cap, admin);
    };

    // Try to add same user twice
    ts::next_tx(&mut scenario, admin);
    {
        let mut allowlist = ts::take_shared<Allowlist>(&scenario);
        let cap = ts::take_from_sender<Cap>(&scenario);

        add(&mut allowlist, &cap, user);
        add(&mut allowlist, &cap, user); // Should fail with EDuplicate

        ts::return_shared(allowlist);
        ts::return_to_sender(&scenario, cap);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidCap)]
fun test_invalid_cap() {
    let admin = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(admin);

    // Create allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let mut allowlist = new_allowlist_for_testing(ctx);

        // Create a cap with WRONG allowlist_id
        let wrong_cap = Cap {
            id: object::new(ctx),
            allowlist_id: object::id_from_address(@0xDEADBEEF),  // Wrong ID
        };

        // This should fail with EInvalidCap
        add(&mut allowlist, &wrong_cap, user);

        // Cleanup (won't reach here due to abort)
        test_utils::destroy(allowlist);
        test_utils::destroy(wrong_cap);
    };

    ts::end(scenario);
}

#[test]
fun test_namespace() {
    let admin = @0xA;
    let mut scenario = ts::begin(admin);

    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let allowlist = new_allowlist_for_testing(ctx);

        // Get namespace
        let ns = namespace(&allowlist);

        // Namespace should be the allowlist's UID bytes
        assert!(ns.length() > 0, 0);
        assert!(ns == allowlist.id.to_bytes(), 0);

        test_utils::destroy(allowlist);
    };

    ts::end(scenario);
}

#[test]
fun test_approve_with_correct_prefix() {
    let admin = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(admin);

    // Create allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let cap = create_allowlist(b"test".to_string(), ctx);
        transfer::transfer(cap, admin);
    };

    // Add user to allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let mut allowlist = ts::take_shared<Allowlist>(&scenario);
        let cap = ts::take_from_sender<Cap>(&scenario);

        add(&mut allowlist, &cap, user);

        ts::return_shared(allowlist);
        ts::return_to_sender(&scenario, cap);
    };

    // Test approval with correct prefix
    ts::next_tx(&mut scenario, user);
    {
        let allowlist = ts::take_shared<Allowlist>(&scenario);

        // Create policy ID with correct namespace prefix
        let ns = namespace(&allowlist);
        let nonce = x"0102030405060708090a0b0c0d0e0f10"; // 16-byte nonce
        let mut policy_id = ns;
        policy_id.append(nonce);

        // Check approval succeeds
        assert!(approve_internal(user, policy_id, &allowlist), 0);

        ts::return_shared(allowlist);
    };

    ts::end(scenario);
}

#[test]
fun test_approve_with_wrong_prefix() {
    let admin = @0xA;
    let user = @0xB;
    let mut scenario = ts::begin(admin);

    // Create allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let cap = create_allowlist(b"test".to_string(), ctx);
        transfer::transfer(cap, admin);
    };

    // Add user to allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let mut allowlist = ts::take_shared<Allowlist>(&scenario);
        let cap = ts::take_from_sender<Cap>(&scenario);

        add(&mut allowlist, &cap, user);

        ts::return_shared(allowlist);
        ts::return_to_sender(&scenario, cap);
    };

    // Test approval with WRONG prefix
    ts::next_tx(&mut scenario, user);
    {
        let allowlist = ts::take_shared<Allowlist>(&scenario);

        // Create policy ID with WRONG namespace prefix
        let wrong_prefix = x"deadbeef";
        let nonce = x"0102030405060708090a0b0c0d0e0f10";
        let mut policy_id = wrong_prefix;
        policy_id.append(nonce);

        // Check approval FAILS
        assert!(!approve_internal(user, policy_id, &allowlist), 0);

        ts::return_shared(allowlist);
    };

    ts::end(scenario);
}

#[test]
fun test_approve_unauthorized_user() {
    let admin = @0xA;
    let authorized_user = @0xB;
    let unauthorized_user = @0xC;
    let mut scenario = ts::begin(admin);

    // Create allowlist
    ts::next_tx(&mut scenario, admin);
    {
        let ctx = ts::ctx(&mut scenario);
        let cap = create_allowlist(b"test".to_string(), ctx);
        transfer::transfer(cap, admin);
    };

    // Add only authorized user
    ts::next_tx(&mut scenario, admin);
    {
        let mut allowlist = ts::take_shared<Allowlist>(&scenario);
        let cap = ts::take_from_sender<Cap>(&scenario);

        add(&mut allowlist, &cap, authorized_user);

        ts::return_shared(allowlist);
        ts::return_to_sender(&scenario, cap);
    };

    // Test unauthorized user gets denied
    ts::next_tx(&mut scenario, unauthorized_user);
    {
        let allowlist = ts::take_shared<Allowlist>(&scenario);

        // Create policy ID with correct namespace
        let ns = namespace(&allowlist);
        let nonce = x"0102030405060708090a0b0c0d0e0f10";
        let mut policy_id = ns;
        policy_id.append(nonce);

        // Check approval FAILS for unauthorized user
        assert!(!approve_internal(unauthorized_user, policy_id, &allowlist), 0);

        ts::return_shared(allowlist);
    };

    ts::end(scenario);
}
