//! Candidate identity-v3 primitives for RFC-0027.
//!
//! These functions validate syntax, canonical encodings, fixed Devnet pins, registry
//! derivation/layout and proof signatures. They are NOT admission, membership,
//! replay, RPC-freshness or database authorization decisions; callers own those.
use crate::{digest, transcript, Credential};
use base64::{engine::general_purpose::STANDARD, Engine};
use curve25519_dalek::edwards::CompressedEdwardsY;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// RFC-0026 registry program (Devnet only).
pub const PROGRAM: &str = "C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas";
/// Solana Devnet genesis hash pinned by RFC-0026.
pub const GENESIS: &str = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";
/// Challenge lifetime in seconds.
pub const CHALLENGE_SECONDS: i64 = 60;
/// Tolerated difference between the phone clock and the server clock when the phone
/// checks a challenge expiry before signing. The server enforces the real lifetime on its
/// own clock; the phone check only rejects absurd values. Phone test 2026-09-30: a phone
/// a few seconds behind the server refused every challenge (`challenge_mismatch`).
pub const CLOCK_SKEW_SECONDS: i64 = 300;
const ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const RECORD_BYTES: usize = 128;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProofRole {
    Owner,
    Device,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Purpose {
    Inspect,
    Status,
    Enroll,
    Replace,
}

impl Purpose {
    pub fn name(self) -> &'static str {
        match self {
            Self::Inspect => "inspect",
            Self::Status => "status",
            Self::Enroll => "enroll",
            Self::Replace => "replace",
        }
    }
    pub fn path(self) -> &'static str {
        match self {
            Self::Inspect => "/v3/identity/inspect",
            Self::Status => "/v3/identity/status",
            Self::Enroll | Self::Replace => "/v3/identity/commit",
        }
    }
    /// Status is device-only; every other purpose requires owner and device proof.
    pub fn requires_owner(self) -> bool {
        self != Self::Status
    }
}

/// Canonical decimal generation, bounded by PostgreSQL/Java signed 64-bit integers.
pub fn parse_generation(value: &str) -> crate::Result<i64> {
    if value.is_empty()
        || value.len() > 19
        || !value.bytes().all(|b| b.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        return Err("invalid_generation");
    }
    value.parse().map_err(|_| "invalid_generation")
}

fn generation_for(purpose: Purpose, value: &str) -> crate::Result<i64> {
    let generation = parse_generation(value)?;
    let valid = match purpose {
        Purpose::Replace => (1..i64::MAX).contains(&generation),
        _ => generation == 0,
    };
    valid.then_some(generation).ok_or("invalid_generation")
}

pub fn base58_encode(bytes: &[u8]) -> String {
    let mut digits: Vec<u8> = Vec::new();
    for &byte in bytes {
        let mut carry = byte as u32;
        for digit in digits.iter_mut() {
            carry += (*digit as u32) << 8;
            *digit = (carry % 58) as u8;
            carry /= 58;
        }
        while carry > 0 {
            digits.push((carry % 58) as u8);
            carry /= 58;
        }
    }
    let zeros = bytes.iter().take_while(|b| **b == 0).count();
    std::iter::repeat_n('1', zeros)
        .chain(digits.iter().rev().map(|d| ALPHABET[*d as usize] as char))
        .collect()
}

/// Exactly 32 bytes, canonical Base58 (re-encoding must reproduce the input).
pub fn base58_decode32(text: &str) -> crate::Result<[u8; 32]> {
    if text.is_empty() || text.len() > 44 {
        return Err("invalid_base58");
    }
    let mut bytes: Vec<u8> = Vec::new();
    for c in text.bytes() {
        let mut carry = ALPHABET
            .iter()
            .position(|a| *a == c)
            .ok_or("invalid_base58")? as u32;
        for byte in bytes.iter_mut() {
            carry += (*byte as u32) * 58;
            *byte = carry as u8;
            carry >>= 8;
        }
        while carry > 0 {
            bytes.push(carry as u8);
            carry >>= 8;
        }
    }
    let zeros = text.bytes().take_while(|c| *c == b'1').count();
    bytes.extend(std::iter::repeat_n(0, zeros));
    bytes.reverse();
    let out: [u8; 32] = bytes.try_into().map_err(|_| "invalid_base58")?;
    if base58_encode(&out) != text {
        return Err("invalid_base58");
    }
    Ok(out)
}

/// RFC-0026 canonical name grammar. The input must already be canonical (no case folding).
pub fn canonical_name(name: &str) -> crate::Result<()> {
    let b = name.as_bytes();
    if (3..=24).contains(&b.len())
        && b[0].is_ascii_lowercase()
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
    {
        Ok(())
    } else {
        Err("invalid_name")
    }
}

fn on_curve(bytes: &[u8; 32]) -> bool {
    CompressedEdwardsY(*bytes).decompress().is_some()
}

/// Accept only a canonically encoded, prime-order (torsion-free) Ed25519 point.
fn owner_key(bytes: &[u8; 32]) -> crate::Result<()> {
    match CompressedEdwardsY(*bytes).decompress() {
        Some(point)
            if !point.is_small_order()
                && point.is_torsion_free()
                && point.compress().to_bytes() == *bytes =>
        {
            Ok(())
        }
        _ => Err("invalid_owner"),
    }
}

/// Solana `find_program_address`: highest bump whose derivation is off the curve.
pub fn program_address(seeds: &[&[u8]], program: &[u8; 32]) -> crate::Result<([u8; 32], u8)> {
    find_program_address(seeds, program)
}

fn find_program_address(seeds: &[&[u8]], program: &[u8; 32]) -> crate::Result<([u8; 32], u8)> {
    for bump in (0..=255u8).rev() {
        let mut hash = Sha256::new();
        for seed in seeds {
            hash.update(seed);
        }
        hash.update([bump]);
        hash.update(program);
        hash.update(b"ProgramDerivedAddress");
        let address: [u8; 32] = hash.finalize().into();
        if !on_curve(&address) {
            return Ok((address, bump));
        }
    }
    Err("no_program_address")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Registry {
    pub identity: [u8; 32],
    pub identity_bump: u8,
    pub nickname: [u8; 32],
    pub nickname_bump: u8,
}

pub fn derive_registry(owner: &[u8; 32], name: &str) -> crate::Result<Registry> {
    canonical_name(name)?;
    let program = base58_decode32(PROGRAM)?;
    let (identity, identity_bump) =
        find_program_address(&[b"paranoid-identity-v1", owner], &program)?;
    let (nickname, nickname_bump) =
        find_program_address(&[b"paranoid-name-v1", name.as_bytes()], &program)?;
    Ok(Registry {
        identity,
        identity_bump,
        nickname,
        nickname_bump,
    })
}

fn expected_record(
    magic: &[u8; 8],
    bump: u8,
    owner: &[u8; 32],
    other: &[u8; 32],
    name: &str,
) -> [u8; RECORD_BYTES] {
    let mut out = [0u8; RECORD_BYTES];
    out[..8].copy_from_slice(magic);
    out[8] = 1;
    out[9] = bump;
    out[10..42].copy_from_slice(owner);
    out[42..74].copy_from_slice(other);
    out[74] = name.len() as u8;
    out[75..75 + name.len()].copy_from_slice(name.as_bytes());
    out
}

/// Byte-exact RFC-0026 records, including canonical bumps, mutual links and zero padding.
/// Callers must separately verify account owner=PROGRAM, finalized commitment and genesis.
pub fn verify_records(
    owner: &[u8; 32],
    name: &str,
    identity_data: &[u8],
    nickname_data: &[u8],
) -> crate::Result<Registry> {
    let r = derive_registry(owner, name)?;
    let identity = expected_record(b"PNDID001", r.identity_bump, owner, &r.nickname, name);
    let nickname = expected_record(b"PNDNAME1", r.nickname_bump, owner, &r.identity, name);
    if identity_data != identity.as_slice() || nickname_data != nickname.as_slice() {
        return Err("record_mismatch");
    }
    Ok(r)
}

fn uuid_v4(value: &str) -> bool {
    uuid::Uuid::parse_str(value).is_ok_and(|u| {
        u.to_string() == value
            && u.get_version_num() == 4
            && u.get_variant() == uuid::Variant::RFC4122
    })
}

fn key32(text: &str) -> crate::Result<[u8; 32]> {
    base64::engine::general_purpose::STANDARD_NO_PAD
        .decode(text)
        .map_err(|_| "invalid_key")?
        .try_into()
        .map_err(|_| "invalid_key")
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ChallengeRequestV3 {
    pub purpose: Purpose,
    pub operation: String,
    pub genesis: String,
    pub program: String,
    pub identity: String,
    pub owner: String,
    pub name: String,
    pub credential_object: Credential,
    pub expected_generation: String,
}

/// A request whose syntax, pins, derivation and credential signature were verified.
/// Construction does NOT query membership, admission or RPC.
#[derive(Clone)]
pub struct CheckedRequest {
    request: ChallengeRequestV3,
    owner: [u8; 32],
    registry: Registry,
    fingerprint: String,
    generation: i64,
}

impl ChallengeRequestV3 {
    /// The identity PDA binds only the owner. The claimed name is checked for grammar
    /// here, but its ownership is proved solely by `verify_records` on finalized data.
    pub fn validate(&self, realm: &str, pin: &str) -> crate::Result<CheckedRequest> {
        let generation = generation_for(self.purpose, &self.expected_generation)?;
        if !uuid_v4(&self.operation) || self.genesis != GENESIS || self.program != PROGRAM {
            return Err("invalid_request");
        }
        let owner = base58_decode32(&self.owner)?;
        owner_key(&owner)?;
        let registry = derive_registry(&owner, &self.name)?;
        if base58_encode(&registry.identity) != self.identity {
            return Err("identity_mismatch");
        }
        let c = &self.credential_object;
        c.verify()?;
        if c.realm != realm || c.pin != pin {
            return Err("wrong_server");
        }
        let (root, auth) = (key32(&c.root)?, key32(&c.auth)?);
        if root == owner || auth == owner || root == auth {
            return Err("key_reuse");
        }
        Ok(CheckedRequest {
            request: self.clone(),
            owner,
            registry,
            fingerprint: c.fingerprint(),
            generation,
        })
    }
}

impl CheckedRequest {
    pub fn request(&self) -> &ChallengeRequestV3 {
        &self.request
    }
    pub fn owner(&self) -> &[u8; 32] {
        &self.owner
    }
    pub fn registry(&self) -> &Registry {
        &self.registry
    }
    pub fn credential_fingerprint(&self) -> &str {
        &self.fingerprint
    }
    pub fn generation(&self) -> i64 {
        self.generation
    }
    /// SHA256(LP("paranoid-identity-intent-v3", ...)) excluding ephemeral challenge fields.
    pub fn intent_digest(&self) -> String {
        let r = &self.request;
        digest(&transcript(&[
            "paranoid-identity-intent-v3",
            r.purpose.name(),
            &r.operation,
            &r.genesis,
            &r.program,
            &r.identity,
            &r.owner,
            &r.name,
            &self.fingerprint,
            &r.expected_generation,
        ]))
    }
}

/// Wire challenge. Encoding it is NOT acceptance; see `matches_request` and `verify_proofs`.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct IdentityChallengeV3 {
    pub id: String,
    pub nonce: String,
    pub epoch: String,
    pub expires: i64,
    pub realm: String,
    pub pin: String,
    pub purpose: Purpose,
    pub operation: String,
    pub genesis: String,
    pub program: String,
    pub identity: String,
    pub owner: String,
    pub name: String,
    pub account: String,
    pub device: String,
    pub credential_fingerprint: String,
    pub expected_generation: String,
}

impl IdentityChallengeV3 {
    /// Server-side issuance with fresh OS randomness; `expires` is the absolute wall time.
    /// Fails (instead of panicking) if the operating system cannot supply randomness.
    pub fn try_issue(
        checked: &CheckedRequest,
        realm: &str,
        pin: &str,
        epoch: &str,
        expires: i64,
    ) -> crate::Result<Self> {
        let mut nonce = [0u8; 32];
        let mut id = [0u8; 16];
        getrandom::getrandom(&mut nonce).map_err(|_| "randomness_unavailable")?;
        getrandom::getrandom(&mut id).map_err(|_| "randomness_unavailable")?;
        let r = &checked.request;
        Ok(Self {
            id: uuid::Builder::from_random_bytes(id).into_uuid().to_string(),
            nonce: STANDARD.encode(nonce),
            epoch: epoch.into(),
            expires,
            realm: realm.into(),
            pin: pin.into(),
            purpose: r.purpose,
            operation: r.operation.clone(),
            genesis: r.genesis.clone(),
            program: r.program.clone(),
            identity: r.identity.clone(),
            owner: r.owner.clone(),
            name: r.name.clone(),
            account: r.credential_object.account.clone(),
            device: r.credential_object.device.clone(),
            credential_fingerprint: checked.fingerprint.clone(),
            expected_generation: r.expected_generation.clone(),
        })
    }

    /// Test/fixture convenience; production servers use `try_issue`.
    pub fn issue(
        checked: &CheckedRequest,
        realm: &str,
        pin: &str,
        epoch: &str,
        expires: i64,
    ) -> Self {
        Self::try_issue(checked, realm, pin, epoch, expires).expect("operating system randomness")
    }

    fn echoes(&self, r: &ChallengeRequestV3, fingerprint: &str, realm: &str, pin: &str) -> bool {
        self.realm == realm
            && self.pin == pin
            && self.purpose == r.purpose
            && self.operation == r.operation
            && self.genesis == r.genesis
            && self.program == r.program
            && self.identity == r.identity
            && self.owner == r.owner
            && self.name == r.name
            && self.account == r.credential_object.account
            && self.device == r.credential_object.device
            && self.credential_fingerprint == fingerprint
            && self.expected_generation == r.expected_generation
    }

    fn well_formed(&self) -> bool {
        uuid_v4(&self.id)
            && uuid_v4(&self.epoch)
            && STANDARD
                .decode(&self.nonce)
                .is_ok_and(|n| n.len() == 32 && STANDARD.encode(&n) == self.nonce)
    }

    /// Client check before signing: every field equals the retained intent/configuration,
    /// identifiers are canonical, and the expiry lies within the challenge lifetime of the
    /// phone clock allowing ±`CLOCK_SKEW_SECONDS` of clock difference with the server.
    pub fn matches_request(
        &self,
        r: &ChallengeRequestV3,
        realm: &str,
        pin: &str,
        now: i64,
    ) -> bool {
        let Ok(checked) = r.validate(realm, pin) else {
            return false;
        };
        self.well_formed()
            && self.echoes(r, &checked.fingerprint, realm, pin)
            && self.expires.checked_sub(now).is_some_and(|left| {
                left > -CLOCK_SKEW_SECONDS && left <= CHALLENGE_SECONDS + CLOCK_SKEW_SECONDS
            })
    }

    /// Same intent digest as `CheckedRequest::intent_digest`, from the stored challenge.
    pub fn intent_digest(&self) -> String {
        digest(&transcript(&[
            "paranoid-identity-intent-v3",
            self.purpose.name(),
            &self.operation,
            &self.genesis,
            &self.program,
            &self.identity,
            &self.owner,
            &self.name,
            &self.credential_fingerprint,
            &self.expected_generation,
        ]))
    }

    /// Encoding primitive, not a signer. Do not sign without full context validation.
    pub fn transcript(&self, role: ProofRole) -> crate::Result<Vec<u8>> {
        generation_for(self.purpose, &self.expected_generation).map_err(|_| "invalid_challenge")?;
        if self.expires < 0 || (role == ProofRole::Owner && !self.purpose.requires_owner()) {
            return Err("invalid_challenge");
        }
        let domain = match role {
            ProofRole::Owner => "paranoid-identity-v3-owner",
            ProofRole::Device => "paranoid-identity-v3-device",
        };
        Ok(transcript(&[
            domain,
            &self.id,
            &self.nonce,
            &self.epoch,
            &self.expires.to_string(),
            &self.realm,
            &self.pin,
            self.purpose.name(),
            &self.operation,
            &self.genesis,
            &self.program,
            &self.identity,
            &self.owner,
            &self.name,
            &self.account,
            &self.device,
            &self.credential_fingerprint,
            &self.expected_generation,
            "POST",
            self.purpose.path(),
        ]))
    }

    /// Verify exactly the proofs required by the purpose over this stored challenge.
    /// Expiry, one-time consumption and membership are the caller's responsibility.
    pub fn verify_proofs(
        &self,
        checked: &CheckedRequest,
        owner_signature: Option<&str>,
        device_signature: &str,
    ) -> crate::Result<()> {
        let r = &checked.request;
        if !self.echoes(r, &checked.fingerprint, &self.realm, &self.pin)
            || r.credential_object.realm != self.realm
            || r.credential_object.pin != self.pin
            || owner_signature.is_some() != self.purpose.requires_owner()
        {
            return Err("invalid_proof");
        }
        if let Some(signature) = owner_signature {
            let owner = base64::engine::general_purpose::STANDARD_NO_PAD.encode(checked.owner);
            crate::verify(&owner, &self.transcript(ProofRole::Owner)?, signature)
                .map_err(|_| "invalid_proof")?;
        }
        crate::verify(
            &r.credential_object.auth,
            &self.transcript(ProofRole::Device)?,
            device_signature,
        )
        .map_err(|_| "invalid_proof")
    }
}
