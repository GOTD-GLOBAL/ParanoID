use base64::{engine::general_purpose::STANDARD, Engine};
use litesvm::LiteSVM;
use paranoid_devnet_client::{command, GENESIS, PROGRAM};
use serde_json::{json, Value};
use solana_address::Address;
use solana_transaction::Transaction;
use std::str::FromStr;

#[test]
fn mobile_core_signs_transaction_executed_by_sbf_and_verifies_runtime_records() {
    // PUBLIC zero-entropy vector, virtual lamports only; never fund this key on any cluster.
    let mut vm = LiteSVM::new();
    let program = Address::from_str(PROGRAM).unwrap();
    let elf = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../registry/target/deploy/paranoid_devnet_registry.so"
    ))
    .unwrap();
    vm.add_program(program, &elf).unwrap();
    let public: Value = serde_json::from_str(&command(
        &json!({"op":"identity","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="})
            .to_string(),
    ))
    .unwrap();
    let owner = Address::from_str(public["owner"].as_str().unwrap()).unwrap();
    vm.airdrop(&owner, 100_000_000).unwrap();
    let built:Value=serde_json::from_str(&command(&json!({"op":"register","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","name":"Alice_Test","blockhash":vm.latest_blockhash().to_string(),"genesis":GENESIS}).to_string())).unwrap();
    let tx: Transaction = bincode::deserialize(
        &STANDARD
            .decode(built["transaction"].as_str().unwrap())
            .unwrap(),
    )
    .unwrap();
    let result = vm.send_transaction(tx).unwrap();
    println!(
        "Actual SBF compute units: {}",
        result.compute_units_consumed
    );
    let id = vm
        .get_account(&Address::from_str(built["identity"].as_str().unwrap()).unwrap())
        .unwrap();
    let nick = vm
        .get_account(&Address::from_str(built["nickname"].as_str().unwrap()).unwrap())
        .unwrap();
    let verified:Value=serde_json::from_str(&command(&json!({"op":"verify","owner":owner.to_string(),"name":"alice_test","identity_data":STANDARD.encode(id.data),"nickname_data":STANDARD.encode(nick.data),"identity_program":id.owner.to_string(),"nickname_program":nick.owner.to_string(),"genesis":GENESIS}).to_string())).unwrap();
    assert_eq!(verified["verified"], true);
}
