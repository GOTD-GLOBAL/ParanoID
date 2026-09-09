//! Bounded experimental key enrollment; not an accepted production protocol.
use serde::{Deserialize, Serialize};
mod proof;
pub use proof::Challenge;
use sha2::{Digest, Sha256};
use vodozemac::{Ed25519PublicKey, Ed25519SecretKey, Ed25519Signature};

pub type Result<T> = std::result::Result<T, &'static str>;
/// u32 big-endian byte length followed by UTF-8 bytes for every field, including domain.
pub fn transcript(fields: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    for f in fields {
        out.extend_from_slice(&(f.len() as u32).to_be_bytes());
        out.extend_from_slice(f.as_bytes());
    }
    out
}
pub fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Credential {
    pub root: String,
    pub account: String,
    pub device: String,
    pub auth: String,
    pub realm: String,
    pub pin: String,
    pub olm: String,
    pub signature: String,
}
impl Credential {
    pub fn verify(&self) -> Result<()> {
        if self.root == self.auth
            || !hex32(&self.pin)
            || !hex32(&self.olm)
            || !self.realm.starts_with("https://")
            || self.realm.len() > 512
            || uuid::Uuid::parse_str(&self.device)
                .map(|u| u.to_string() != self.device)
                .unwrap_or(true)
            || self.account != digest(&transcript(&["paranoid-account-v1", &self.root]))
        {
            return Err("invalid_credential");
        }
        public_key(&self.auth)?;
        verify(&self.root, &self.bytes(), &self.signature)
    }
    pub fn bytes(&self) -> Vec<u8> {
        transcript(&[
            "paranoid-credential-v1",
            &self.root,
            &self.account,
            &self.device,
            &self.auth,
            &self.realm,
            &self.pin,
            &self.olm,
        ])
    }
    pub fn fingerprint(&self) -> String {
        digest(&self.bytes())
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub root_secret: String,
    pub auth_secret: String,
    pub credential: Credential,
}
impl Identity {
    pub fn create(realm: &str, pin: &str, curve: &str, prekey: &str) -> Result<Self> {
        if !realm.starts_with("https://") || realm.len() > 512 || !hex32(pin) {
            return Err("invalid_configuration");
        }
        let root = Ed25519SecretKey::new();
        let auth = Ed25519SecretKey::new();
        let public = root.public_key().to_base64();
        let mut credential = Credential {
            account: digest(&transcript(&["paranoid-account-v1", &public])),
            root: public,
            device: uuid::Uuid::new_v4().to_string(),
            auth: auth.public_key().to_base64(),
            realm: realm.into(),
            pin: pin.into(),
            olm: olm_digest(curve, prekey),
            signature: String::new(),
        };
        credential.signature = root.sign(&credential.bytes()).to_base64();
        Ok(Self {
            root_secret: root.to_base64(),
            auth_secret: auth.to_base64(),
            credential,
        })
    }
}
pub fn hex32(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn olm_digest(curve: &str, prekey: &str) -> String {
    digest(&transcript(&["paranoid-olm-v1", curve, prekey]))
}

fn public_key(s: &str) -> Result<Ed25519PublicKey> {
    let key = Ed25519PublicKey::from_base64(s).map_err(|_| "invalid_key")?;
    if key.to_base64() != s {
        return Err("noncanonical_key");
    }
    Ok(key)
}
pub fn verify(key: &str, bytes: &[u8], sig: &str) -> Result<()> {
    let signature = Ed25519Signature::from_base64(sig).map_err(|_| "invalid_signature")?;
    if signature.to_base64() != sig {
        return Err("noncanonical_signature");
    }
    public_key(key)?
        .verify(bytes, &signature)
        .map_err(|_| "invalid_signature")
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublicRequest {
    #[serde(rename = "type")]
    pub kind: String,
    pub credential: Credential,
}
#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Grant {
    #[serde(rename = "type")]
    pub kind: String,
    pub id: String,
    pub credential: String,
    pub realm: String,
    pub pin: String,
    pub slot: i16,
    pub expires: i64,
}
impl PublicRequest {
    pub fn verify(&self) -> Result<()> {
        if self.kind != "paranoid-request-v1" {
            return Err("wrong_qr_type");
        }
        self.credential.verify()
    }
}
