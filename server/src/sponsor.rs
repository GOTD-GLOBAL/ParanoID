//! Devnet nickname registration sponsor (RFC-0026 revision 2026-09-30, owner request).
//!
//! The server pays rent and fee for a user's RegisterV1 transaction so a phone can take a
//! nick without test SOL. The server never signs caller-supplied bytes: it rebuilds the one
//! fixed RegisterV1 message (program, accounts, instruction, its own blockhash) from the
//! requested owner and name, requires a valid owner signature over exactly those bytes,
//! and only then returns its fee-payer signature. The phone assembles and persists the
//! transaction before broadcasting it itself (RFC-0026: persist before send). A sponsor
//! cannot register a name for itself or for anyone who did not sign. Caps bound the spend.
use crate::Failure;
use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use paranoid_key_protocol::identity_v3::{
    base58_decode32, base58_encode, canonical_name, derive_registry,
};
use ring::signature::{self, Ed25519KeyPair, KeyPair};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const PROGRAM: &str = "C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas";
const GENESIS: &str = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";
/// At most this many sponsored registrations per rolling hour and per day (all users).
const PER_HOUR: usize = 20;
const PER_DAY: usize = 60;
/// Refuse to sponsor below this balance (lamports) so the wallet is never drained to zero.
const RESERVE: u64 = 20_000_000;
/// Distinct names one owner may try through the sponsor (e.g. after "name taken").
const MAX_NAMES_PER_OWNER: usize = 3;

pub struct Sponsor {
    key: Ed25519KeyPair,
    payer: [u8; 32],
    rpc: String,
    http: reqwest::Client,
    state: Mutex<Limits>,
}
#[derive(Default)]
struct Limits {
    recent: VecDeque<Instant>,
    /// owner -> (name, blockhash) of the one sponsored attempt; exact repeats resend.
    owners: HashMap<[u8; 32], (String, String, usize)>,
}

impl Sponsor {
    /// `keypair_json` is a Solana CLI keypair file: a JSON array of 64 bytes
    /// (32-byte seed followed by the public key). Never logged.
    pub fn from_keypair_json(
        keypair_json: &str,
        rpc: &str,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        if !rpc.starts_with("https://") {
            return Err("sponsor RPC must be HTTPS".into());
        }
        let bytes: Vec<u8> =
            serde_json::from_str(keypair_json).map_err(|_| "invalid sponsor keypair")?;
        if bytes.len() != 64 {
            return Err("invalid sponsor keypair".into());
        }
        let key = Ed25519KeyPair::from_seed_and_public_key(&bytes[..32], &bytes[32..])
            .map_err(|_| "invalid sponsor keypair")?;
        let payer: [u8; 32] = key
            .public_key()
            .as_ref()
            .try_into()
            .map_err(|_| "invalid sponsor keypair")?;
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            key,
            payer,
            rpc: rpc.into(),
            http,
            state: Mutex::new(Limits::default()),
        })
    }
    pub fn payer(&self) -> String {
        base58_encode(&self.payer)
    }
    async fn rpc(&self, method: &str, params: Value) -> Result<Value, Failure> {
        let unavailable = || Failure(StatusCode::SERVICE_UNAVAILABLE, "sponsor_rpc_unavailable");
        let reply: Value = self
            .http
            .post(&self.rpc)
            .json(&json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}))
            .send()
            .await
            .map_err(|_| unavailable())?
            .json()
            .await
            .map_err(|_| unavailable())?;
        if reply.get("error").is_some() {
            return Err(unavailable());
        }
        reply.get("result").cloned().ok_or_else(unavailable)
    }
}

/// Exact legacy-message bytes of RegisterV1 with a separate fee payer. Mirrors
/// `registration_message_paid` in blockchain/solana/client; a shared vector test pins both.
pub fn message(
    payer: &[u8; 32],
    owner: &[u8; 32],
    name: &str,
    blockhash: &[u8; 32],
) -> Result<Vec<u8>, &'static str> {
    canonical_name(name).map_err(|_| "invalid_name")?;
    let registry = derive_registry(owner, name).map_err(|_| "invalid_name")?;
    let program = base58_decode32(PROGRAM).map_err(|_| "compiled_pin")?;
    // Legacy message layout as solana-message compiles it: fee payer, then the other
    // signer, then writable non-signers and readonly non-signers, each group ordered by
    // key bytes (BTreeMap). Instruction account indexes follow that order.
    let mut writable = [registry.identity, registry.nickname];
    writable.sort();
    let mut readonly = [[0u8; 32], program];
    readonly.sort();
    let keys: [&[u8; 32]; 6] = [
        payer,
        owner,
        &writable[0],
        &writable[1],
        &readonly[0],
        &readonly[1],
    ];
    let index = |k: &[u8; 32]| keys.iter().position(|x| *x == k).expect("key present") as u8;
    let mut m = vec![2u8, 1, 2, 6];
    for key in keys {
        m.extend_from_slice(key);
    }
    m.extend_from_slice(blockhash);
    m.extend_from_slice(&[
        1,
        index(&program),
        5,
        index(payer),
        index(owner),
        index(&registry.identity),
        index(&registry.nickname),
        index(&[0u8; 32]),
        (2 + name.len()) as u8,
        1,
        name.len() as u8,
    ]);
    m.extend_from_slice(name.as_bytes());
    Ok(m)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Prepare {
    genesis: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Register {
    owner: String,
    name: String,
    blockhash: String,
    owner_signature: String,
}

fn bad(code: &'static str) -> Failure {
    Failure(StatusCode::BAD_REQUEST, code)
}

async fn prepare(
    State(s): State<Arc<Sponsor>>,
    Json(r): Json<Prepare>,
) -> Result<Json<Value>, Failure> {
    if r.genesis != GENESIS {
        return Err(bad("wrong_cluster"));
    }
    let block = s
        .rpc("getLatestBlockhash", json!([{"commitment":"finalized"}]))
        .await?;
    Ok(Json(json!({
        "payer": s.payer(),
        "blockhash": block["value"]["blockhash"],
        "last_valid_height": block["value"]["lastValidBlockHeight"],
    })))
}

async fn register(
    State(s): State<Arc<Sponsor>>,
    Json(r): Json<Register>,
) -> Result<Json<Value>, Failure> {
    let owner = base58_decode32(&r.owner).map_err(|_| bad("invalid_owner"))?;
    if owner == s.payer {
        return Err(bad("invalid_owner"));
    }
    let blockhash = base58_decode32(&r.blockhash).map_err(|_| bad("invalid_blockhash"))?;
    let msg = message(&s.payer, &owner, &r.name, &blockhash).map_err(bad)?;
    let sig = decode_signature(&r.owner_signature).ok_or(bad("invalid_owner_signature"))?;
    signature::UnparsedPublicKey::new(&signature::ED25519, owner)
        .verify(&msg, &sig)
        .map_err(|_| bad("invalid_owner_signature"))?;
    {
        let mut limits = s.state.lock().map_err(|_| bad("sponsor_unavailable"))?;
        let now = Instant::now();
        while limits
            .recent
            .front()
            .is_some_and(|t| now.duration_since(*t) > Duration::from_secs(86_400))
        {
            limits.recent.pop_front();
        }
        match limits.owners.get(&owner) {
            // Exact repeat of this owner's sponsored attempt: resend identical bytes.
            Some((name, hash, _)) if *name == r.name && *hash == r.blockhash => {}
            // A new blockhash for the same name after the old one expired is a retry.
            Some((name, _, _)) if *name == r.name => {}
            // Another name (the first one was taken): rent is paid only on success and the
            // program allows one name per owner, so this costs at most a fee; still bounded.
            Some((_, _, tries)) if *tries >= MAX_NAMES_PER_OWNER => {
                return Err(Failure(StatusCode::CONFLICT, "sponsor_used"))
            }
            _ => {
                let hour = limits
                    .recent
                    .iter()
                    .filter(|t| now.duration_since(**t) < Duration::from_secs(3600))
                    .count();
                if hour >= PER_HOUR || limits.recent.len() >= PER_DAY {
                    return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "sponsor_limit"));
                }
                limits.recent.push_back(now);
            }
        }
        let tries = match limits.owners.get(&owner) {
            Some((name, _, n)) if *name == r.name => *n,
            Some((_, _, n)) => n + 1,
            None => 1,
        };
        limits
            .owners
            .insert(owner, (r.name.clone(), r.blockhash.clone(), tries));
    }
    let balance = s
        .rpc("getBalance", json!([s.payer(), {"commitment":"confirmed"}]))
        .await?;
    if balance["value"].as_u64().unwrap_or(0) < RESERVE {
        return Err(Failure(StatusCode::SERVICE_UNAVAILABLE, "sponsor_empty"));
    }
    let payer_sig = base58_encode64(s.key.sign(&msg).as_ref());
    Ok(Json(
        json!({"payer_signature": payer_sig, "payer": s.payer()}),
    ))
}

fn decode_signature(text: &str) -> Option<[u8; 64]> {
    let bytes = base58_decode_any(text)?;
    bytes.try_into().ok()
}
fn base58_decode_any(text: &str) -> Option<Vec<u8>> {
    const A: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    if text.is_empty() || text.len() > 100 {
        return None;
    }
    let mut out: Vec<u8> = Vec::new();
    for c in text.bytes() {
        let mut carry = A.iter().position(|a| *a == c)? as u32;
        for b in out.iter_mut().rev() {
            carry += (*b as u32) * 58;
            *b = carry as u8;
            carry >>= 8;
        }
        while carry > 0 {
            out.insert(0, carry as u8);
            carry >>= 8;
        }
    }
    let zeros = text.bytes().take_while(|c| *c == b'1').count();
    let mut result = vec![0u8; zeros];
    result.extend(out.into_iter().skip_while(|b| *b == 0));
    (base58_encode64(&result) == text).then_some(result)
}
fn base58_encode64(bytes: &[u8]) -> String {
    const A: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    let mut digits: Vec<u8> = Vec::new();
    for b in bytes {
        let mut carry = *b as u32;
        for d in digits.iter_mut() {
            carry += (*d as u32) << 8;
            *d = (carry % 58) as u8;
            carry /= 58;
        }
        while carry > 0 {
            digits.push((carry % 58) as u8);
            carry /= 58;
        }
    }
    let zeros = bytes.iter().take_while(|b| **b == 0).count();
    std::iter::repeat_n('1', zeros)
        .chain(digits.iter().rev().map(|d| A[*d as usize] as char))
        .collect()
}

pub fn router(sponsor: Arc<Sponsor>) -> Router {
    Router::new()
        .route("/v3/sponsor/prepare", post(prepare))
        .route("/v3/sponsor/register", post(register))
        .layer(axum::extract::DefaultBodyLimit::max(4096))
        .with_state(sponsor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine};
    /// Same inputs as the client crate test `sponsored_registration_needs_both_signatures`:
    /// sponsor seed [7;32], owner = 12-word zero vector, name "abc", zero blockhash.
    #[test]
    fn message_matches_client_crate_vector() {
        let sponsor = Ed25519KeyPair::from_seed_unchecked(&[7u8; 32]).unwrap();
        let payer: [u8; 32] = sponsor.public_key().as_ref().try_into().unwrap();
        let owner = base58_decode32("HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk").unwrap();
        let m = message(&payer, &owner, "abc", &[0u8; 32]).unwrap();
        assert_eq!(STANDARD.encode(&m), CLIENT_VECTOR);
        assert!(message(&payer, &owner, "Abc", &[0u8; 32]).is_err());
    }
    const CLIENT_VECTOR: &str = "AgECBupKbGPinFIKvvVQexMuxfmVR3auvr57kkIe6mkURtIs8DYnYkanW53jNJ7UKxXiMvZRj8IPX81PHWToH5vSWPcO93rqgqtxhFFmoWYwjBXLqReo50h00vW2Rj3XgwpRlYpRgLUg35rnbZT0Csoce6Ta0qFNsNl9fU7PGJp//ak9AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAClZY1j/0JtcUim1GEeVLhD+t1QPMbPnn5EjhP1o2VvaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQUFAAECAwQFAQNhYmM=";
    #[test]
    fn base58_signature_round_trip() {
        let sig = [9u8; 64];
        assert_eq!(decode_signature(&base58_encode64(&sig)).unwrap(), sig);
        assert!(decode_signature("0OIl").is_none());
        // Many real signatures, including leading-zero and high-byte cases.
        let key = Ed25519KeyPair::from_seed_unchecked(&[3u8; 32]).unwrap();
        for i in 0u32..5000 {
            let s: [u8; 64] = key.sign(&i.to_le_bytes()).as_ref().try_into().unwrap();
            assert_eq!(decode_signature(&base58_encode64(&s)), Some(s), "sig {i}");
        }
        for lead in [[0u8; 64], {
            let mut x = [255u8; 64];
            x[0] = 0;
            x
        }] {
            assert_eq!(decode_signature(&base58_encode64(&lead)), Some(lead));
        }
    }
}
