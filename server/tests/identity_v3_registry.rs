//! Negative tests for the REAL `DevnetRegistry` parser against a local lying RPC.
//! The fake serves canned finalized responses built from the live 2026-09-24 readback;
//! each case perturbs exactly one property and must fail closed.
use axum::{extract::State, routing::post, Json, Router};
use base64::{engine::general_purpose::STANDARD, Engine};
use paranoid_key_protocol::identity_v3::{base58_decode32, GENESIS, PROGRAM};
use paranoid_server::identity_v3::{DevnetRegistry, RegistryFailure, RegistryVerifier};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

const OWNER: &str = "n2NGZdM6KZFJE1bBghSapYaMqZM1sb6J1x7CLYei5QJ";
const NAME: &str = "p28_accept_0922";
const IDENTITY: &str = "504e44494430303101ff0b88ae86382590e4b1e3644efee6f96673d3a937721121837079d262c049aa2fbcce2cf8a8283f5b98b0141f86bc1315c3430dc77a9c7f1ab6c9f44d8ce6f1f10f7032385f6163636570745f303932320000000000000000000000000000000000000000000000000000000000000000000000000000";
const NICK: &str = "504e444e414d453101fe0b88ae86382590e4b1e3644efee6f96673d3a937721121837079d262c049aa2f1cf646ccaa7aecfffe67ca47d997566626b99a8403d18a3f78430dba0dd081f80f7032385f6163636570745f303932320000000000000000000000000000000000000000000000000000000000000000000000000000";
const LOADER: &str = "BPFLoaderUpgradeab1e11111111111111111111111";
const PROGRAMDATA: &str = "3WzWMcWhaZtbCGubaJHUfVRm5edgkr4amWLWdHVkQLFr";
const AUTHORITY: &str = "5jD3zwcQPiLoM41eHZXSL8bZnWn16WuZ7kBqBjMUwndm";

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect()
}

fn account(owner: &str, executable: bool, data: &[u8]) -> Value {
    json!({"owner": owner, "executable": executable, "lamports": 1, "rentEpoch": 0,
        "space": data.len(), "data": [STANDARD.encode(data), "base64"]})
}

#[derive(Clone)]
struct Chain {
    log: Arc<Mutex<Vec<&'static str>>>,
    identity: Value,
    nickname: Value,
    genesis: String,
    program: Value,
    programdata: Value,
    /// Optional oversized padding appended to the ProgramData response.
    pad: usize,
}

/// The pinned ELF is not in the repository, so this synthetic chain always fails at the
/// final artifact-hash stage. Stages are therefore distinguished by the error kind and
/// by the recorded call order; artifact parsing has its own unit tests in the crate, and
/// the real artifact hash is proven by the live read-only Devnet test.
fn honest() -> Chain {
    let mut meta = vec![3u8, 0, 0, 0];
    meta.extend_from_slice(&7u64.to_le_bytes());
    meta.push(1);
    meta.extend_from_slice(&base58_decode32(AUTHORITY).unwrap());
    meta.extend(std::iter::repeat_n(0u8, 73_800));
    let mut code = vec![2u8, 0, 0, 0];
    code.extend_from_slice(&base58_decode32(PROGRAMDATA).unwrap());
    Chain {
        log: Arc::new(Mutex::new(Vec::new())),
        identity: account(PROGRAM, false, &unhex(IDENTITY)),
        nickname: account(PROGRAM, false, &unhex(NICK)),
        genesis: GENESIS.into(),
        program: account(LOADER, true, &code),
        programdata: account(LOADER, false, &meta),
        pad: 0,
    }
}

async fn rpc(State(chain): State<Arc<Mutex<Chain>>>, Json(request): Json<Value>) -> String {
    let chain = chain.lock().unwrap().clone();
    let result = match request["method"].as_str().unwrap() {
        "getGenesisHash" => {
            chain.log.lock().unwrap().push("getGenesisHash");
            json!(chain.genesis)
        }
        "getMultipleAccounts" => {
            let keys = request["params"][0].as_array().unwrap();
            assert_eq!(request["params"][1]["commitment"], "finalized");
            assert_eq!(request["params"][1]["encoding"], "base64");
            if keys[0] == PROGRAM {
                chain.log.lock().unwrap().push("program");
                json!({"context": {"slot": 1}, "value": [chain.program, chain.programdata],
                    "pad": "x".repeat(chain.pad)})
            } else {
                chain.log.lock().unwrap().push("pair");
                json!({"context": {"slot": 1}, "value": [chain.identity, chain.nickname]})
            }
        }
        other => panic!("unexpected RPC {other}"),
    };
    json!({"jsonrpc": "2.0", "id": 1, "result": result}).to_string()
}

async fn verify(chain: Chain, owner: &str, name: &str) -> Result<(), RegistryFailure> {
    verify_logged(chain, owner, name).await.0
}

async fn verify_logged(
    chain: Chain,
    owner: &str,
    name: &str,
) -> (Result<(), RegistryFailure>, Vec<&'static str>) {
    let log = chain.log.clone();
    let state = Arc::new(Mutex::new(chain));
    let router = Router::new().route("/", post(rpc)).with_state(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let registry = DevnetRegistry::new_loopback_fixture(&url).unwrap();
    let result = registry.verify(base58_decode32(owner).unwrap(), name).await;
    task.abort();
    let calls = log.lock().unwrap().clone();
    (result, calls)
}

#[tokio::test]
async fn registry_stage_failures_are_invalid() {
    use RegistryFailure::Invalid;
    let mut c = honest();
    c.identity = Value::Null;
    assert_eq!(
        verify(c, OWNER, NAME).await,
        Err(Invalid),
        "missing identity"
    );
    let mut c = honest();
    c.nickname = Value::Null;
    assert_eq!(verify(c, OWNER, NAME).await, Err(Invalid), "partial record");
    let mut c = honest();
    c.identity["owner"] = json!(LOADER);
    assert_eq!(
        verify(c, OWNER, NAME).await,
        Err(Invalid),
        "foreign account owner"
    );
    let mut c = honest();
    c.identity["executable"] = json!(true);
    assert_eq!(
        verify(c, OWNER, NAME).await,
        Err(Invalid),
        "executable record"
    );
    let mut c = honest();
    c.nickname["data"][1] = json!("base64+zstd");
    assert_eq!(
        verify(c, OWNER, NAME).await,
        Err(Invalid),
        "compressed encoding"
    );
    let mut c = honest();
    let mut bytes = unhex(NICK);
    bytes[100] = 1;
    c.nickname = account(PROGRAM, false, &bytes);
    assert_eq!(
        verify(c, OWNER, NAME).await,
        Err(Invalid),
        "nonzero padding"
    );
    assert_eq!(
        verify(honest(), OWNER, "p28_accept_0923").await,
        Err(Invalid),
        "other name"
    );
}

#[tokio::test]
async fn wrong_cluster_stops_before_program_reads_and_oversize_fails() {
    use RegistryFailure::Unavailable;
    let mut c = honest();
    c.genesis = "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY".into();
    let (result, calls) = verify_logged(c, OWNER, NAME).await;
    assert_eq!(result, Err(Unavailable), "wrong cluster");
    assert_eq!(
        calls,
        ["pair", "getGenesisHash"],
        "no program read on a wrong cluster"
    );
    let (_, calls) = verify_logged(honest(), OWNER, NAME).await;
    assert_eq!(
        calls,
        ["pair", "getGenesisHash", "program"],
        "PDA pair first"
    );
    let mut c = honest();
    c.identity = Value::Null;
    let (_, calls) = verify_logged(c, OWNER, NAME).await;
    assert_eq!(calls, ["pair"], "invalid pair stops before genesis/program");
    let mut c = honest();
    c.pad = 200_000;
    assert_eq!(
        verify(c, OWNER, NAME).await,
        Err(Unavailable),
        "oversized response"
    );
}
