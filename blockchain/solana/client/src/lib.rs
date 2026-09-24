//! Separate Devnet key domain. Never accepts arbitrary transaction bytes to sign.
use base64::{engine::general_purpose::STANDARD, Engine};
use bip39::{Language, Mnemonic};
use ed25519_dalek_bip32::{DerivationPath, ExtendedSigningKey};
use serde::Deserialize;
use serde_json::{json, Value};
use solana_address::Address;
use std::str::FromStr;
use zeroize::Zeroizing;

pub const PROGRAM: &str = "C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas";
pub const GENESIS: &str = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";
pub const RPC: &str = "https://api.devnet.solana.com";

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Prepare {
        owner: String,
        name: String,
        blockhash: String,
        genesis: String,
    },
    ProgramInfo {},
    Verify {
        owner: String,
        name: String,
        identity_data: String,
        nickname_data: String,
        identity_program: String,
        nickname_program: String,
        genesis: String,
    },
    Lookup {
        owner: String,
        name: String,
    },
    Identity {
        entropy: String,
    },
    ExportMnemonic {
        entropy: String,
    },
    Recover {
        mnemonic: String,
    },
    Register {
        entropy: String,
        name: String,
        blockhash: String,
        genesis: String,
    },
}

fn entropy(encoded: &str) -> Result<Zeroizing<[u8; 32]>, &'static str> {
    let bytes = Zeroizing::new(STANDARD.decode(encoded).map_err(|_| "invalid_entropy")?);
    if bytes.len() != 32 || STANDARD.encode(bytes.as_slice()) != encoded {
        return Err("invalid_entropy");
    }
    let mut result = Zeroizing::new([0u8; 32]);
    result.copy_from_slice(&bytes);
    Ok(result)
}
fn mnemonic(bytes: &[u8; 32]) -> Result<Mnemonic, &'static str> {
    Mnemonic::from_entropy_in(Language::English, bytes).map_err(|_| "invalid_entropy")
}
fn secret(bytes: &[u8; 32]) -> Result<Zeroizing<[u8; 32]>, &'static str> {
    let phrase = mnemonic(bytes)?;
    let seed = Zeroizing::new(phrase.to_seed_normalized(""));
    let path = DerivationPath::from_str("m/44'/501'/0'/0'").map_err(|_| "derivation")?;
    let child = ExtendedSigningKey::from_seed(seed.as_slice())
        .and_then(|k| k.derive(&path))
        .map_err(|_| "derivation")?;
    Ok(Zeroizing::new(child.signing_key.to_bytes()))
}
fn public(bytes: &[u8; 32]) -> Result<Address, &'static str> {
    let seed = secret(bytes)?;
    let key = solana_keypair::Keypair::new_from_array(*seed);
    use solana_signer::Signer;
    Ok(key.pubkey())
}
fn canonical_name(input: &str) -> Result<String, &'static str> {
    let n = input.to_ascii_lowercase();
    let b = n.as_bytes();
    if !(3..=24).contains(&b.len())
        || !b[0].is_ascii_lowercase()
        || !b
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
    {
        return Err("invalid_name");
    }
    Ok(n)
}
fn addresses(owner: &Address, name: &str) -> (Address, u8, Address, u8) {
    let program = Address::from_str(PROGRAM).expect("compiled program");
    let (id, ib) =
        Address::find_program_address(&[b"paranoid-identity-v1", owner.as_ref()], &program);
    let (nick, nb) =
        Address::find_program_address(&[b"paranoid-name-v1", name.as_bytes()], &program);
    (id, ib, nick, nb)
}
fn registration_message(
    owner: Address,
    name: &str,
    hash: &solana_hash::Hash,
) -> solana_message::Message {
    use solana_instruction::{AccountMeta, Instruction};
    let (id, _, nick, _) = addresses(&owner, name);
    let mut data = vec![1, name.len() as u8];
    data.extend(name.as_bytes());
    let ix = Instruction {
        program_id: Address::from_str(PROGRAM).expect("compiled program"),
        accounts: vec![
            AccountMeta::new(owner, true),
            AccountMeta::new_readonly(owner, true),
            AccountMeta::new(id, false),
            AccountMeta::new(nick, false),
            AccountMeta::new_readonly(Address::default(), false),
        ],
        data,
    };
    solana_message::Message::new_with_blockhash(&[ix], Some(&owner), hash)
}
fn run(input: Command) -> Result<Value, &'static str> {
    match input {
        Command::Prepare {
            owner,
            name,
            blockhash,
            genesis,
        } => {
            if genesis != GENESIS {
                return Err("wrong_cluster");
            }
            let owner = Address::from_str(&owner).map_err(|_| "invalid_owner")?;
            let name = canonical_name(&name)?;
            let hash = solana_hash::Hash::from_str(&blockhash).map_err(|_| "invalid_blockhash")?;
            let message = registration_message(owner, &name, &hash);
            Ok(json!({"message":STANDARD.encode(message.serialize()),"name":name}))
        }
        Command::ProgramInfo {} => {
            let program = Address::from_str(PROGRAM).map_err(|_| "compiled_pin")?;
            let loader = Address::from_str("BPFLoaderUpgradeab1e11111111111111111111111")
                .map_err(|_| "compiled_pin")?;
            let authority = Address::from_str("5jD3zwcQPiLoM41eHZXSL8bZnWn16WuZ7kBqBjMUwndm")
                .map_err(|_| "compiled_pin")?;
            let (pd, _) = Address::find_program_address(&[program.as_ref()], &loader);
            Ok(json!({"program":PROGRAM,"genesis":GENESIS,"rpc":RPC,
                "loader":loader.to_string(),"programdata":pd.to_string(),
                "programdata_bytes":STANDARD.encode(pd.as_ref()),
                "authority":authority.to_string(),"authority_bytes":STANDARD.encode(authority.as_ref()),
                "sbf_size":73800,"sbf_sha256":"ab3517cb30be9832344f46638373bfd305f954619f3a95a6513d4981a4f93efa"}))
        }
        Command::Lookup { owner, name } => {
            let owner = Address::from_str(&owner).map_err(|_| "invalid_owner")?;
            let name = canonical_name(&name)?;
            let (id, _, nick, _) = addresses(&owner, &name);
            Ok(json!({"identity":id.to_string(),"nickname":nick.to_string(),"name":name}))
        }
        Command::Verify {
            owner,
            name,
            identity_data,
            nickname_data,
            identity_program,
            nickname_program,
            genesis,
        } => {
            if genesis != GENESIS {
                return Err("wrong_cluster");
            }
            if identity_program != PROGRAM || nickname_program != PROGRAM {
                return Err("wrong_program_owner");
            }
            let owner = Address::from_str(&owner).map_err(|_| "invalid_owner")?;
            let name = canonical_name(&name)?;
            let (id, ib, nick, nb) = addresses(&owner, &name);
            for (encoded, magic, bump, other) in [
                (&identity_data, b"PNDID001", ib, nick),
                (&nickname_data, b"PNDNAME1", nb, id),
            ] {
                let data = STANDARD.decode(encoded).map_err(|_| "invalid_record")?;
                let mut expected = [0u8; 128];
                expected[..8].copy_from_slice(magic);
                expected[8] = 1;
                expected[9] = bump;
                expected[10..42].copy_from_slice(owner.as_ref());
                expected[42..74].copy_from_slice(other.as_ref());
                expected[74] = name.len() as u8;
                expected[75..75 + name.len()].copy_from_slice(name.as_bytes());
                if data != expected || STANDARD.encode(&data) != *encoded {
                    return Err("record_mismatch");
                }
            }
            Ok(
                json!({"verified":true,"identity":id.to_string(),"nickname":nick.to_string(),"name":name,"owner":owner.to_string()}),
            )
        }
        Command::Register {
            entropy: e,
            name,
            blockhash,
            genesis,
        } => {
            if genesis != GENESIS {
                return Err("wrong_cluster");
            }
            let name = canonical_name(&name)?;
            let encoded = Zeroizing::new(e);
            let bytes = entropy(&encoded)?;
            let seed = secret(&bytes)?;
            let key = solana_keypair::Keypair::new_from_array(*seed);
            use solana_signer::Signer;
            let owner = key.pubkey();
            let (id, _, nick, _) = addresses(&owner, &name);
            let hash = solana_hash::Hash::from_str(&blockhash).map_err(|_| "invalid_blockhash")?;
            let message = registration_message(owner, &name, &hash);
            let tx = solana_transaction::Transaction::new(&[&key], message, hash);
            tx.verify().map_err(|_| "signature")?;
            let wire = bincode::serialize(&tx).map_err(|_| "transaction")?;
            if wire.len() > 1232 {
                return Err("transaction_limit");
            }
            Ok(
                json!({"transaction":STANDARD.encode(&wire),"message":STANDARD.encode(tx.message_data()),"signature":tx.signatures[0].to_string(),"owner":owner.to_string(),"identity":id.to_string(),"nickname":nick.to_string(),"name":name}),
            )
        }
        Command::ExportMnemonic { entropy: e } => {
            let encoded = Zeroizing::new(e);
            let bytes = entropy(&encoded)?;
            Ok(json!({"mnemonic":mnemonic(&bytes)?.to_string()}))
        }
        Command::Identity { entropy: e } => {
            let encoded = Zeroizing::new(e);
            let bytes = entropy(&encoded)?;
            Ok(
                json!({"owner":public(&bytes)?.to_string(),"identity":addresses(&public(&bytes)?,"aaa").0.to_string(),"program":PROGRAM,"genesis":GENESIS,"rpc":RPC}),
            )
        }
        Command::Recover { mnemonic: m } => {
            let text = Zeroizing::new(m);
            let phrase = Mnemonic::parse_in_normalized(Language::English, &text)
                .map_err(|_| "invalid_mnemonic")?;
            if phrase.word_count() != 24 {
                return Err("invalid_mnemonic");
            }
            let bytes = Zeroizing::new(phrase.to_entropy());
            Ok(json!({"entropy":STANDARD.encode(bytes.as_slice())}))
        }
    }
}
pub fn command(input: &str) -> String {
    if input.len() > 8192 {
        return json!({"error":"input_limit"}).to_string();
    }
    let result = serde_json::from_str(input)
        .map_err(|_| "invalid_request")
        .and_then(run);
    result
        .unwrap_or_else(|error| json!({"error":error}))
        .to_string()
}

#[no_mangle]
pub extern "system" fn Java_org_paranoid_devnet_SolanaBridge_call(
    mut env: jni::JNIEnv,
    _class: jni::objects::JClass,
    input: jni::objects::JString,
) -> jni::sys::jstring {
    let response = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let text: String = env.get_string(&input).map_err(|_| ())?.into();
        let text = Zeroizing::new(text);
        Ok::<String, ()>(command(&text))
    }))
    .ok()
    .and_then(Result::ok)
    .unwrap_or_else(|| "{\"error\":\"native_failure\"}".into());
    env.new_string(response)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn registration_transaction_is_fixed_and_signature_verifies() {
        let value:Value=serde_json::from_str(&command(&json!({"op":"register", "entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "name":"alice_test", "blockhash":"11111111111111111111111111111111", "genesis":GENESIS}).to_string())).unwrap();
        let bytes = STANDARD
            .decode(
                value["transaction"]
                    .as_str()
                    .expect("registration transaction missing"),
            )
            .unwrap();
        let tx: solana_transaction::Transaction = bincode::deserialize(&bytes).unwrap();
        tx.verify().unwrap();
        assert_eq!(tx.message.instructions.len(), 1);
        let ix = &tx.message.instructions[0];
        assert_eq!(
            tx.message.account_keys[ix.program_id_index as usize].to_string(),
            PROGRAM
        );
        assert_eq!(ix.data, [vec![1, 10], b"alice_test".to_vec()].concat());
        assert_eq!(tx.signatures.len(), 1);
    }
    #[test]
    fn registry_readback_requires_both_exact_records() {
        let owner = Address::from_str("3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx").unwrap();
        let (id, ib, nick, nb) = addresses(&owner, "abc");
        let make = |magic: &[u8; 8], bump, other: Address| {
            let mut b = [0u8; 128];
            b[..8].copy_from_slice(magic);
            b[8] = 1;
            b[9] = bump;
            b[10..42].copy_from_slice(owner.as_ref());
            b[42..74].copy_from_slice(other.as_ref());
            b[74] = 3;
            b[75..78].copy_from_slice(b"abc");
            b
        };
        let a = make(b"PNDID001", ib, nick);
        let b = make(b"PNDNAME1", nb, id);
        let request = json!({"op":"verify","owner":owner.to_string(),"name":"abc","identity_data":STANDARD.encode(a),"nickname_data":STANDARD.encode(b),"identity_program":PROGRAM,"nickname_program":PROGRAM,"genesis":GENESIS});
        let reply: Value = serde_json::from_str(&command(&request.to_string())).unwrap();
        assert_eq!(reply["verified"], true);
        for pos in [0, 8, 9, 10, 42, 74, 75, 127] {
            let mut bad = a;
            bad[pos] ^= 1;
            let mut r = request.clone();
            r["identity_data"] = json!(STANDARD.encode(bad));
            let reply: Value = serde_json::from_str(&command(&r.to_string())).unwrap();
            assert!(reply.get("error").is_some());
        }
    }
    #[test]
    fn slip0010_published_vector_and_nonhardened_rejection() {
        let seed: Vec<u8> = (0..16).collect();
        let root = ExtendedSigningKey::from_seed(&seed).unwrap();
        let node = root
            .derive(&DerivationPath::from_str("m/0'/1'/2'/2'/1000000000'").unwrap())
            .unwrap();
        let public = node
            .verifying_key()
            .to_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        assert_eq!(
            public,
            "3c24da049451555d51a7014a37337aa4e12d41e485abccfa46b47dfb2af54b7a"
        );
        assert!(root
            .derive(&DerivationPath::from_str("m/0").unwrap())
            .is_err());
    }
    #[test]
    fn rejects_wrong_cluster_arbitrary_fields_mnemonic_and_names() {
        let good = json!({"op":"register","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","name":"abc","blockhash":"11111111111111111111111111111111","genesis":GENESIS});
        for (field, value) in [
            ("genesis", "mainnet"),
            ("name", "абв"),
            ("name", "ab"),
            ("name", "1abc"),
            ("blockhash", "invalid"),
            ("entropy", "AAAA"),
            ("program", "11111111111111111111111111111111"),
            ("transaction", "arbitrary"),
        ] {
            let mut bad = good.clone();
            bad[field] = json!(value);
            let out: Value = serde_json::from_str(&command(&bad.to_string())).unwrap();
            assert!(out.get("error").is_some(), "{field}");
            assert!(out.get("transaction").is_none());
        }
        for m in ["abandon abandon", "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"] {let out:Value=serde_json::from_str(&command(&json!({"op":"recover","mnemonic":m}).to_string())).unwrap();assert_eq!(out["error"],"invalid_mnemonic");}
        assert!(command(&"x".repeat(8193)).contains("input_limit"));
        assert!(
            command(r#"{"op":"identity","op":"recover","entropy":"AAAA"}"#)
                .contains("invalid_request")
        );
    }
    #[test]
    fn prepare_is_unsigned_and_matches_fixed_signed_message() {
        let req = json!({"op":"prepare","owner":"3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx","name":"test_alice","blockhash":"11111111111111111111111111111111","genesis":GENESIS});
        let prepared: Value = serde_json::from_str(&command(&req.to_string())).unwrap();
        let signed:Value=serde_json::from_str(&command(&json!({"op":"register","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","name":"test_alice","blockhash":"11111111111111111111111111111111","genesis":GENESIS}).to_string())).unwrap();
        assert_eq!(prepared["message"], signed["message"]);
        assert!(prepared.get("signature").is_none());
        assert!(prepared.get("transaction").is_none());
    }
    #[test]
    fn program_info_exposes_only_fixed_public_deployment_pins() {
        let out: Value = serde_json::from_str(&command(r#"{"op":"program_info"}"#)).unwrap();
        assert_eq!(out["program"], PROGRAM);
        let loader = Address::from_str("BPFLoaderUpgradeab1e11111111111111111111111").unwrap();
        let program = Address::from_str(PROGRAM).unwrap();
        let (pd, _) = Address::find_program_address(&[program.as_ref()], &loader);
        assert_eq!(out["programdata"], pd.to_string());
        assert_eq!(out["programdata_bytes"], STANDARD.encode(pd.as_ref()));
        let authority = Address::from_str("5jD3zwcQPiLoM41eHZXSL8bZnWn16WuZ7kBqBjMUwndm").unwrap();
        assert_eq!(out["authority_bytes"], STANDARD.encode(authority.as_ref()));
        assert_eq!(
            out["sbf_sha256"],
            "ab3517cb30be9832344f46638373bfd305f954619f3a95a6513d4981a4f93efa"
        );
        assert_eq!(out["sbf_size"], 73800);
        assert_eq!(out["genesis"], GENESIS);
    }
    #[test]
    fn identity_does_not_export_recovery_material() {
        let out: Value = serde_json::from_str(&command(
            &json!({"op":"identity","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="})
                .to_string(),
        ))
        .unwrap();
        assert!(out.get("mnemonic").is_none());
        assert!(out.get("entropy").is_none());
    }
    #[test]
    fn standard_public_recovery_vector() {
        let value: Value = serde_json::from_str(&command(
            &json!({"op":"identity","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="})
                .to_string(),
        ))
        .unwrap();
        assert_eq!(
            value["owner"],
            "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
        );
        let backup: Value = serde_json::from_str(&command(
            &json!({"op":"export_mnemonic","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}).to_string(),
        )).unwrap();
        assert_eq!(
            backup["mnemonic"],
            format!("{} art", vec!["abandon"; 23].join(" "))
        );
        let restored: Value = serde_json::from_str(&command(
            &json!({"op":"recover","mnemonic":backup["mnemonic"]}).to_string(),
        ))
        .unwrap();
        assert_eq!(
            restored["entropy"],
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        );
    }
}
