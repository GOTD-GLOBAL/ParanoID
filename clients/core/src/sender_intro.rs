//! RFC-0014 offline bootstrap prototype. Authentication is NOT contact acceptance.
//! These functions never persist state, decrypt text, or upgrade identity trust.
use super::contact_v2::ContactV2;
use super::*;
use paranoid_key_protocol::{digest, transcript, verify};

const MAX_FRAME: usize = 16384;
const DOMAIN: &str = "paranoid-sender-intro-v1";
const PROFILE: &str = "account-id-v2";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Introduction {
    #[serde(rename = "type")]
    kind: String,
    pub contact: ContactV2,
    recipient_account: String,
    recipient_device: String,
    recipient_credential: String,
    recipient_contact: String,
    id: String,
    profile: String,
    ciphertext: String,
    signature: String,
}

fn frame(text: &str) -> Result<Vec<u8>> {
    // Bound BEFORE base64 allocation, serde, signatures or Olm processing.
    if text.len() > 4 * MAX_FRAME.div_ceil(3) {
        return Err("introduction_limit");
    }
    let bytes = STANDARD.decode(text).map_err(|_| "invalid_introduction")?;
    if bytes.len() < 2 || bytes.len() > MAX_FRAME || STANDARD.encode(&bytes) != text {
        return Err("invalid_introduction");
    }
    Ok(bytes)
}
impl Introduction {
    fn bytes(&self) -> Result<Vec<u8>> {
        let inner = frame(&self.ciphertext)?;
        if inner[0] > 1 {
            return Err("invalid_introduction");
        }
        OlmMessage::from_parts(inner[0] as usize, &inner[1..])
            .map_err(|_| "invalid_introduction")?;
        Ok(transcript(&[
            DOMAIN,
            &self.contact.fingerprint(),
            &self.recipient_account,
            &self.recipient_device,
            &self.recipient_credential,
            &self.recipient_contact,
            &self.id,
            &self.profile,
            &digest(&inner),
        ]))
    }

    pub fn create(
        own: &Client,
        fallback: &str,
        recipient: &ContactV2,
        pending: &Outgoing,
    ) -> Result<Outgoing> {
        recipient.verify(own)?;
        if pending.recipient != recipient.credential.account {
            return Err("introduction_context_mismatch");
        }
        let identity = own.identity.as_ref().ok_or("create_identity_first")?;
        let mut intro = Self {
            kind: DOMAIN.into(),
            contact: ContactV2::create(own, fallback)?,
            recipient_account: recipient.credential.account.clone(),
            recipient_device: recipient.credential.device.clone(),
            recipient_credential: recipient.credential.fingerprint(),
            recipient_contact: recipient.fingerprint(),
            id: pending.id.clone(),
            profile: PROFILE.into(),
            ciphertext: pending.ciphertext.clone(),
            signature: String::new(),
        };
        intro.signature = vodozemac::Ed25519SecretKey::from_base64(&identity.auth_secret)
            .map_err(|_| "invalid_state")?
            .sign(&intro.bytes()?)
            .to_base64();
        let mut bytes = vec![2];
        bytes.extend(serde_json::to_vec(&intro).map_err(|_| "state_error")?);
        if bytes.len() > MAX_FRAME {
            return Err("introduction_limit");
        }
        Ok(Outgoing {
            id: pending.id.clone(),
            recipient: pending.recipient.clone(),
            ciphertext: STANDARD.encode(bytes),
        })
    }

    pub fn inspect(own: &Client, fallback: &str, message: &Incoming) -> Result<Self> {
        let bytes = frame(&message.ciphertext)?;
        if bytes[0] != 2 {
            return Err("invalid_introduction");
        }
        // Typed deserialization rejects duplicate AND unknown fields recursively.
        let intro: Self =
            serde_json::from_slice(&bytes[1..]).map_err(|_| "invalid_introduction")?;
        intro.contact.verify(own)?;
        let identity = own.identity.as_ref().ok_or("create_identity_first")?;
        let recipient = &identity.credential;
        if intro.kind != DOMAIN
            || intro.profile != PROFILE
            || intro.contact.credential.account != message.sender
            || intro.recipient_account != recipient.account
            || intro.recipient_device != recipient.device
            || intro.recipient_credential != recipient.fingerprint()
            || intro.recipient_contact != ContactV2::create(own, fallback)?.fingerprint()
            || intro.id != message.id
            || !uuid::Uuid::parse_str(&intro.id).is_ok_and(|id| id.to_string() == intro.id)
            || !(1..=100000).contains(&message.sequence)
        {
            return Err("introduction_context_mismatch");
        }
        verify(
            &intro.contact.credential.auth,
            &intro.bytes()?,
            &intro.signature,
        )?;
        Ok(intro)
    }

    pub fn report(&self) -> Result<String> {
        Ok(json!({
            "account": self.contact.credential.account,
            "contact_fingerprint": self.contact.fingerprint(),
            "profile": self.profile,
            "identity_verified": false,
            "ciphertext_digest": digest(&frame(&self.ciphertext)?),
        })
        .to_string())
    }
}
