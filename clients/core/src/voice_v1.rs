//! Strict encrypted call controls (wire body v2: audio + optional camera video).
//! Runtime consent/clocks remain outside durable state. The struct keeps its
//! historical `CallV1` name; every field/limit below is the call-v2 contract
//! (docs/protocol/call-v2.md). v1 bodies (no `video`, `v: 1`) are rejected.
use super::intro_v2::canonical_id;
use super::Result;
use paranoid_key_protocol::{digest, hex32};
use serde::{Deserialize, Serialize};

pub(super) const MAX_SDP: usize = 12288;
const VIDEO_CODECS: [&str; 6] = [
    "h264/90000",
    "vp8/90000",
    "rtx/90000",
    "red/90000",
    "ulpfec/90000",
    "flexfec-03/90000",
];

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
    /// knock/ready/offer/answer: sender is willing to negotiate camera video;
    /// media: sender's current camera state; heartbeat/end: must be false.
    video: bool,
}

impl CallV1 {
    pub fn validate(&self) -> Result<()> {
        if self.v != 2
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
            "heartbeat" | "media" => {
                self.seq >= 2 && hex32(&self.callee_nonce) && hex32(&self.offer_digest)
            }
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
            || (matches!(self.kind.as_str(), "heartbeat" | "end") && self.video)
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
            || self.sdp.len() > MAX_SDP
            || !hex32(&self.fingerprint)
            || !ice_token(&self.ice_ufrag, 4, 256)
            || !ice_token(&self.ice_pwd, 22, 256)
            || !self.sdp.is_ascii()
        {
            return Err("invalid_call_sdp");
        }
        // Index 0 = audio section, 1 = video section, 2 = session level.
        let mut section = 2usize;
        let mut media = 0usize;
        let mut fingerprint = [0u32; 3];
        let mut ufrag = [0u32; 3];
        let mut password = [0u32; 3];
        let mut mux = [0u32; 3];
        let mut direction = [0u32; 3];
        let mut setup = [0u32; 3];
        let mut setup_value: Option<&str> = None;
        let mut opus = Vec::new();
        let mut video_codec = 0usize;
        let mut mappings: [std::collections::BTreeSet<String>; 2] = Default::default();
        let mut payloads: [Vec<String>; 2] = Default::default();
        let mut candidates = 0;
        let mut lines = self.sdp.lines();
        if lines.next() != Some("v=0") {
            return Err("invalid_call_sdp");
        }
        for (index, line) in lines.enumerate() {
            if index >= 512 {
                return Err("invalid_call_sdp");
            }
            if line.len() < 2
                || line.as_bytes()[1] != b'='
                || !line.as_bytes()[0].is_ascii_lowercase()
                || line.bytes().any(|byte| !(32..=126).contains(&byte))
            {
                return Err("invalid_call_sdp");
            }
            if let Some(value) = line.strip_prefix("m=") {
                let fields: Vec<_> = value.split(' ').collect();
                let expected = ["audio", "video"].get(media).copied();
                if fields.len() < 4
                    || Some(fields[0]) != expected
                    || fields[2] != "UDP/TLS/RTP/SAVPF"
                    || fields[3..]
                        .iter()
                        .any(|s| s.parse::<u8>().map_or(true, |v| v > 127))
                {
                    return Err("invalid_call_sdp");
                }
                // The bundled audio section carries the transport; a bundled
                // video section may advertise port 0 (bundle-only) or 9.
                match fields[1].parse::<u16>() {
                    Ok(port) if port > 0 || media == 1 => {}
                    _ => return Err("invalid_call_sdp"),
                }
                section = media;
                media += 1;
                if media > 2 {
                    return Err("invalid_call_sdp");
                }
                payloads[section].extend(fields[3..].iter().map(|p| p.to_string()));
            } else if let Some(value) = line.strip_prefix("a=fingerprint:") {
                fingerprint[section] += 1;
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
                ufrag[section] += 1;
                if value != self.ice_ufrag {
                    return Err("call_sdp_mismatch");
                }
            } else if let Some(value) = line.strip_prefix("a=ice-pwd:") {
                password[section] += 1;
                if value != self.ice_pwd {
                    return Err("call_sdp_mismatch");
                }
            } else if line == "a=rtcp-mux" {
                mux[section] += 1;
            } else if line == "a=sendrecv" {
                direction[section] += 1;
            } else if matches!(line, "a=sendonly" | "a=recvonly" | "a=inactive") {
                return Err("invalid_call_sdp");
            } else if let Some(value) = line.strip_prefix("a=setup:") {
                setup[section] += 1;
                if !(self.kind == "offer" && value == "actpass"
                    || self.kind == "answer" && matches!(value, "active" | "passive"))
                    || setup_value.get_or_insert(value) != &value
                {
                    return Err("invalid_call_sdp");
                }
            } else if let Some(value) = line.strip_prefix("a=rtpmap:") {
                if section > 1 {
                    return Err("invalid_call_sdp");
                }
                let (payload, codec) = value.split_once(' ').ok_or("invalid_call_sdp")?;
                if payload.parse::<u8>().map_or(true, |p| p > 127)
                    || !mappings[section].insert(payload.to_string())
                {
                    return Err("invalid_call_sdp");
                }
                let codec = codec.to_ascii_lowercase();
                if section == 0 {
                    if codec == "opus/48000/2" {
                        opus.push(payload.to_string());
                    }
                } else {
                    if !VIDEO_CODECS.contains(&codec.as_str()) {
                        return Err("invalid_call_sdp");
                    }
                    if codec == "h264/90000" || codec == "vp8/90000" {
                        video_codec += 1;
                    }
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
        let once_per_section =
            |counts: &[u32; 3]| counts[0] + counts[2] == 1 && counts[1] + counts[2] <= 1;
        if media != 2
            || !once_per_section(&fingerprint)
            || !once_per_section(&ufrag)
            || !once_per_section(&password)
            || !once_per_section(&setup)
            || mux[0] != 1
            || mux[1] > 1
            || mux[2] != 0
            || direction != [1, 1, 0]
            || opus.len() != 1
            || !payloads[0].contains(&opus[0])
            || video_codec == 0
            || (0..2).any(|s| {
                mappings[s]
                    .iter()
                    .any(|payload| !payloads[s].contains(payload))
            })
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
