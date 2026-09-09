//! Strict encrypted voice controls; runtime consent/clocks remain outside durable state.
use super::intro_v2::canonical_id;
use super::Result;
use paranoid_key_protocol::{digest, hex32};
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CallV1 {
    v: u8,
    kind: String,
    call_id: String,
    caller_nonce: String,
    callee_nonce: String,
    seq: u32,
    sent_ms: u64,
    expires_ms: u64,
    sdp: String,
    fingerprint: String,
    ice_ufrag: String,
    ice_pwd: String,
    offer_digest: String,
    reason: String,
}

impl CallV1 {
    pub fn validate(&self) -> Result<()> {
        if self.v != 1
            || !canonical_id(&self.call_id)
            || !hex32(&self.caller_nonce)
            || self.seq > i32::MAX as u32
            || self.sent_ms == 0
            || self.expires_ms > i64::MAX as u64
            || self.expires_ms <= self.sent_ms
            || self.expires_ms - self.sent_ms > 45_000
        {
            return Err("invalid_call");
        }
        let media = matches!(self.kind.as_str(), "offer" | "answer");
        let context = match self.kind.as_str() {
            "knock" => {
                self.seq == 0 && self.callee_nonce.is_empty() && self.offer_digest.is_empty()
            }
            "ready" => self.seq == 0 && hex32(&self.callee_nonce) && self.offer_digest.is_empty(),
            "offer" | "answer" => {
                self.seq == 1 && hex32(&self.callee_nonce) && hex32(&self.offer_digest)
            }
            "heartbeat" => self.seq >= 2 && hex32(&self.callee_nonce) && hex32(&self.offer_digest),
            "end" => {
                self.seq >= 2
                    && (self.callee_nonce.is_empty() || hex32(&self.callee_nonce))
                    && (self.offer_digest.is_empty() || hex32(&self.offer_digest))
                    && (!self.callee_nonce.is_empty() || self.offer_digest.is_empty())
            }
            _ => false,
        };
        if !context
            || if self.kind == "end" {
                !matches!(
                    self.reason.as_str(),
                    "hangup" | "reject" | "cancel" | "busy" | "timeout" | "failed" | "unavailable"
                )
            } else {
                !self.reason.is_empty()
            }
        {
            return Err("invalid_call");
        }
        if media {
            self.validate_sdp()?;
            if self.kind == "offer" && self.offer_digest != digest(self.sdp.as_bytes()) {
                return Err("call_sdp_mismatch");
            }
        } else if !self.sdp.is_empty()
            || !self.fingerprint.is_empty()
            || !self.ice_ufrag.is_empty()
            || !self.ice_pwd.is_empty()
        {
            return Err("invalid_call");
        }
        Ok(())
    }

    fn validate_sdp(&self) -> Result<()> {
        if self.sdp.is_empty()
            || self.sdp.len() > 6144
            || !hex32(&self.fingerprint)
            || !ice_token(&self.ice_ufrag, 4, 256)
            || !ice_token(&self.ice_pwd, 22, 256)
            || !self.sdp.is_ascii()
        {
            return Err("invalid_call_sdp");
        }
        let mut media = 0;
        let mut fingerprint = 0;
        let mut ufrag = 0;
        let mut password = 0;
        let mut mux = 0;
        let mut direction = 0;
        let mut setup = 0;
        let mut opus = Vec::new();
        let mut mappings = std::collections::BTreeSet::new();
        let mut payloads = Vec::new();
        let mut candidates = 0;
        let mut lines = self.sdp.lines();
        if lines.next() != Some("v=0") {
            return Err("invalid_call_sdp");
        }
        for line in lines {
            if line.len() < 2
                || line.as_bytes()[1] != b'='
                || !line.as_bytes()[0].is_ascii_lowercase()
                || line.bytes().any(|byte| !(32..=126).contains(&byte))
            {
                return Err("invalid_call_sdp");
            }
            if let Some(value) = line.strip_prefix("m=") {
                media += 1;
                let fields: Vec<_> = value.split(' ').collect();
                if fields.len() < 4
                    || fields[0] != "audio"
                    || fields[1].parse::<u16>().ok().filter(|p| *p > 0).is_none()
                    || fields[2] != "UDP/TLS/RTP/SAVPF"
                    || fields[3..]
                        .iter()
                        .any(|s| s.parse::<u8>().map_or(true, |v| v > 127))
                {
                    return Err("invalid_call_sdp");
                }
                payloads.extend(fields[3..].iter().map(|p| p.to_string()));
            } else if let Some(value) = line.strip_prefix("a=fingerprint:") {
                fingerprint += 1;
                let value = value.strip_prefix("sha-256 ").ok_or("invalid_call_sdp")?;
                let bytes: Vec<_> = value.split(':').collect();
                if bytes.len() != 32
                    || bytes
                        .iter()
                        .any(|s| s.len() != 2 || !s.bytes().all(|b| b.is_ascii_hexdigit()))
                    || bytes.concat().to_ascii_lowercase() != self.fingerprint
                {
                    return Err("call_sdp_mismatch");
                }
            } else if let Some(value) = line.strip_prefix("a=ice-ufrag:") {
                ufrag += 1;
                if value != self.ice_ufrag {
                    return Err("call_sdp_mismatch");
                }
            } else if let Some(value) = line.strip_prefix("a=ice-pwd:") {
                password += 1;
                if value != self.ice_pwd {
                    return Err("call_sdp_mismatch");
                }
            } else if line == "a=rtcp-mux" {
                mux += 1;
            } else if line == "a=sendrecv" {
                direction += 1;
            } else if matches!(line, "a=sendonly" | "a=recvonly" | "a=inactive") {
                return Err("invalid_call_sdp");
            } else if let Some(value) = line.strip_prefix("a=setup:") {
                setup += 1;
                if !(self.kind == "offer" && value == "actpass"
                    || self.kind == "answer" && matches!(value, "active" | "passive"))
                {
                    return Err("invalid_call_sdp");
                }
            } else if let Some(value) = line.strip_prefix("a=rtpmap:") {
                let (payload, codec) = value.split_once(' ').ok_or("invalid_call_sdp")?;
                if payload.parse::<u8>().map_or(true, |p| p > 127)
                    || !mappings.insert(payload.to_string())
                {
                    return Err("invalid_call_sdp");
                }
                if codec.eq_ignore_ascii_case("opus/48000/2") {
                    opus.push(payload.to_string());
                }
            } else if line.starts_with("a=candidate:") {
                candidates += 1;
                if line.len() > 512 || candidates > 16 {
                    return Err("invalid_call_sdp");
                }
            } else if line.starts_with("a=crypto:") {
                // SDES must not introduce an alternate keying authority.
                return Err("invalid_call_sdp");
            }
        }
        if media != 1
            || fingerprint != 1
            || ufrag != 1
            || password != 1
            || mux != 1
            || direction != 1
            || setup != 1
            || opus.len() != 1
            || !payloads.contains(&opus[0])
            || mappings.iter().any(|payload| !payloads.contains(payload))
        {
            return Err("invalid_call_sdp");
        }
        Ok(())
    }
}

fn ice_token(value: &str, minimum: usize, maximum: usize) -> bool {
    (minimum..=maximum).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
}
