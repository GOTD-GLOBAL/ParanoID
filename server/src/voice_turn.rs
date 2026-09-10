//! REQ-CALL-006: optional, volatile coturn REST credentials. No media authority.
use crate::Failure;
use axum::http::StatusCode;
use base64::{engine::general_purpose::STANDARD, Engine};
use rand::RngCore;
use ring::hmac;
use std::{
    collections::{HashMap, VecDeque},
    fs::OpenOptions,
    io::Read,
    net::Ipv4Addr,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const WINDOW: Duration = Duration::from_secs(60);
const BINDING_LIMIT: usize = 4;
const GLOBAL_LIMIT: usize = 32;
const BUCKET_LIMIT: usize = 1024;
const TTL: u64 = 1200;

// Deliberately neither Debug nor Serialize: this owns an issuer secret.
pub struct TurnConfig {
    relay: Ipv4Addr,
    key: hmac::Key,
}

fn public_address(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(a == 0
        || a == 10
        || a == 127
        || a >= 224
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 192 && b == 0 && (c == 0 || c == 2))
        || (a == 192 && b == 88 && c == 99)
        || (a == 198 && (b == 18 || b == 19))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113))
}

impl TurnConfig {
    /// Explicit configuration; environment values are paths/IP only, never keys.
    pub fn from_options(
        secret_file: Option<&Path>,
        relay_ip: Option<&str>,
        local_mode: bool,
    ) -> Result<Option<Self>, &'static str> {
        match (secret_file, relay_ip) {
            (None, None) => Ok(None),
            (Some(path), Some(raw)) => {
                let relay: Ipv4Addr = raw.parse().map_err(|_| "invalid TURN configuration")?;
                if relay.to_string() != raw {
                    return Err("invalid TURN configuration");
                }
                Self::load(path, relay, local_mode).map(Some)
            }
            _ => Err("incomplete TURN configuration"),
        }
    }

    pub fn load(path: &Path, relay: Ipv4Addr, local_mode: bool) -> Result<Self, &'static str> {
        let invalid = "invalid TURN configuration";
        if !path.is_absolute()
            || if local_mode {
                !relay.is_loopback()
            } else {
                !public_address(relay)
            }
        {
            return Err(invalid);
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
            .map_err(|_| invalid)?;
        let meta = file.metadata().map_err(|_| invalid)?;
        // SAFETY: geteuid takes no pointers and has no failure return.
        let uid = unsafe { libc::geteuid() };
        if !meta.is_file()
            || meta.nlink() != 1
            || !matches!(meta.permissions().mode() & 0o7777, 0o400 | 0o600)
            || (meta.uid() != 0 && meta.uid() != uid)
            || meta.len() != 64
        {
            return Err(invalid);
        }
        let mut bytes = Vec::with_capacity(65);
        file.take(65).read_to_end(&mut bytes).map_err(|_| invalid)?;
        if bytes.len() != 64
            || !bytes
                .iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        {
            return Err(invalid);
        }
        // Coturn REST interoperates with HMAC-SHA1 keyed by the ASCII secret,
        // not hex-decoded bytes. Identity/media cryptography does not use SHA1.
        Ok(Self {
            relay,
            key: hmac::Key::new(hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, &bytes),
        })
    }

    pub(crate) fn issuer(self, realm: &str) -> Result<Issuer, sqlx::Error> {
        let uri: axum::http::Uri = realm.parse().map_err(|_| invalid_realm())?;
        if uri.scheme_str() != Some("https")
            || uri.query().is_some()
            || uri.path() != "/"
            || uri
                .authority()
                .is_none_or(|authority| authority.as_str().contains('@'))
            || uri.host() != Some(self.relay.to_string().as_str())
        {
            return Err(invalid_realm());
        }
        Ok(Issuer {
            key: self.key,
            urls: [
                format!("turn:{}:34781?transport=udp", self.relay),
                format!("turn:{}:34781?transport=tcp", self.relay),
            ],
            budget: Mutex::new(Budget::default()),
        })
    }
}

fn invalid_realm() -> sqlx::Error {
    sqlx::Error::Configuration("TURN relay must match saved HTTPS realm".into())
}

#[derive(Default)]
struct Budget {
    bindings: HashMap<(String, String), VecDeque<Instant>>,
    global: VecDeque<Instant>,
}

fn prune(window: &mut VecDeque<Instant>, now: Instant) {
    while window
        .front()
        .is_some_and(|issued| now.saturating_duration_since(*issued) >= WINDOW)
    {
        window.pop_front();
    }
}

impl Budget {
    fn allow(&mut self, account: &str, device: &str, now: Instant) -> bool {
        prune(&mut self.global, now);
        self.bindings.retain(|_, window| {
            prune(window, now);
            !window.is_empty()
        });
        let binding = (account.to_owned(), device.to_owned());
        if self.global.len() >= GLOBAL_LIMIT
            || self
                .bindings
                .get(&binding)
                .is_some_and(|window| window.len() >= BINDING_LIMIT)
            || (!self.bindings.contains_key(&binding) && self.bindings.len() >= BUCKET_LIMIT)
        {
            return false;
        }
        self.bindings.entry(binding).or_default().push_back(now);
        self.global.push_back(now);
        true
    }
}

pub(crate) struct Issuer {
    key: hmac::Key,
    urls: [String; 2],
    budget: Mutex<Budget>,
}

impl Issuer {
    pub(crate) fn issue(&self, account: &str, device: &str) -> Result<serde_json::Value, Failure> {
        if !self
            .budget
            .lock()
            .unwrap()
            .allow(account, device, Instant::now())
        {
            return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "turn_rate"));
        }
        let expires = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|time| time.as_secs().checked_add(TTL))
            .ok_or(Failure(StatusCode::SERVICE_UNAVAILABLE, "turn_unavailable"))?;
        let mut random = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut random);
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let username = format!("{expires}:{suffix}");
        let credential = STANDARD.encode(hmac::sign(&self.key, username.as_bytes()).as_ref());
        Ok(serde_json::json!({
            "v":1,"urls":self.urls,"username":username,
            "credential":credential,"expires":expires,"ttl":TTL
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quota_is_sliding_and_rejecting_does_not_extend_or_erase_live_windows() {
        let t = Instant::now();
        let mut budget = Budget::default();
        assert!(budget.allow("a", "d", t));
        for _ in 0..3 {
            assert!(budget.allow("a", "d", t + Duration::from_secs(30)));
        }
        assert!(!budget.allow("a", "d", t + Duration::from_secs(59)));
        assert!(budget.allow("a", "d", t + Duration::from_secs(60)));
        assert!(!budget.allow("a", "d", t + Duration::from_secs(89)));
        assert!(budget.allow("a", "d", t + Duration::from_secs(90)));
        assert_eq!(budget.bindings.len(), 1);
        assert_eq!(budget.global.len(), 2);
    }

    #[test]
    fn quota_capacity_never_evicts_live_binding_and_expired_entries_reclaim() {
        let t = Instant::now();
        let mut budget = Budget::default();
        // Reach the defensive map cap directly; ordinary global admission keeps
        // it smaller. Exercise capacity without weakening production quotas.
        for n in 0..BUCKET_LIMIT {
            budget
                .bindings
                .insert((n.to_string(), "d".into()), [t].into());
        }
        assert!(!budget.allow("new", "d", t));
        assert_eq!(budget.bindings.len(), BUCKET_LIMIT);
        assert!(budget.bindings.contains_key(&("0".into(), "d".into())));
        assert!(budget.allow("new", "d", t + WINDOW));
        assert_eq!(budget.bindings.len(), 1);
        assert_eq!(budget.global.len(), 1);
    }
}
