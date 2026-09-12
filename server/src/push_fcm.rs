//! FCM wake gateway (RFC-0020). The server holds the only Firebase service-account
//! key; a wake carries no content, only "there is something for you". A device
//! registers an opaque FCM token over its signed session; the token is deleted
//! when FCM reports it unregistered or the device sends an empty token.
//!
//! Boundaries: no message bytes, sender, or call metadata ever reach Google —
//! the push payload is the constant `{"t":"wake"}`. Wakes are rate-limited per
//! account and suppressed while the account holds a live long-poll waiter.
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ring::{rand, signature};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const MIN_INTERVAL: Duration = Duration::from_secs(10);
pub const MAX_TOKEN: usize = 4096;

/// Deliberately neither Debug nor Serialize: owns the service-account private key.
pub struct PushConfig {
    project: String,
    email: String,
    token_uri: String,
    key: signature::RsaKeyPair,
    /// Test override for the FCM send endpoint (`{project}` substituted).
    send_url: String,
}

pub struct Gateway {
    config: PushConfig,
    http: reqwest::Client,
    access: Mutex<Option<(String, Instant)>>,
    recent: Mutex<HashMap<String, Instant>>,
}

fn pem_pkcs8(pem: &str) -> Result<Vec<u8>, &'static str> {
    let body: String = pem
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(body.trim())
        .map_err(|_| "invalid push key")
}

impl PushConfig {
    /// `file` is the Firebase service-account JSON. Environment carries the path only.
    pub fn from_options(
        file: Option<&Path>,
        send_url_override: Option<&str>,
    ) -> Result<Option<Self>, &'static str> {
        let Some(path) = file else { return Ok(None) };
        let raw = std::fs::read(path).map_err(|_| "unreadable push credential")?;
        let json: serde_json::Value =
            serde_json::from_slice(&raw).map_err(|_| "invalid push credential")?;
        let field = |name: &str| {
            json[name]
                .as_str()
                .filter(|v| !v.is_empty() && v.len() <= 4096)
                .map(str::to_owned)
                .ok_or("invalid push credential")
        };
        let project = field("project_id")?;
        let email = field("client_email")?;
        let token_uri = field("token_uri")?;
        if !(token_uri.starts_with("https://") || token_uri.starts_with("http://127.0.0.1:"))
            || !project
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return Err("invalid push credential");
        }
        let key = signature::RsaKeyPair::from_pkcs8(&pem_pkcs8(&field("private_key")?)?)
            .map_err(|_| "invalid push key")?;
        let send_url = match send_url_override {
            Some(url) if url.starts_with("http://127.0.0.1:") || url.starts_with("https://") => {
                url.to_owned()
            }
            Some(_) => return Err("invalid push endpoint"),
            None => "https://fcm.googleapis.com/v1/projects/{project}/messages:send".to_owned(),
        };
        Ok(Some(Self {
            project,
            email,
            token_uri,
            key,
            send_url,
        }))
    }
    pub(crate) fn gateway(self) -> Result<Gateway, &'static str> {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|_| "push client")?;
        Ok(Gateway {
            config: self,
            http,
            access: Mutex::new(None),
            recent: Mutex::new(HashMap::new()),
        })
    }
}

pub fn valid_token(token: &str) -> bool {
    token.len() <= MAX_TOKEN && token.bytes().all(|b| b.is_ascii_graphic())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

impl Gateway {
    fn jwt(&self) -> Result<String, &'static str> {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"RS256","typ":"JWT"}"#);
        let issued = now();
        let claims = serde_json::json!({
            "iss": self.config.email,
            "scope": SCOPE,
            "aud": self.config.token_uri,
            "iat": issued,
            "exp": issued + 3600,
        });
        let claims = URL_SAFE_NO_PAD.encode(claims.to_string());
        let signing = format!("{header}.{claims}");
        let mut sig = vec![0u8; self.config.key.public().modulus_len()];
        self.config
            .key
            .sign(
                &signature::RSA_PKCS1_SHA256,
                &rand::SystemRandom::new(),
                signing.as_bytes(),
                &mut sig,
            )
            .map_err(|_| "push sign")?;
        Ok(format!("{signing}.{}", URL_SAFE_NO_PAD.encode(sig)))
    }
    async fn access_token(&self) -> Result<String, &'static str> {
        if let Some((token, until)) = self.access.lock().unwrap().clone() {
            if Instant::now() < until {
                return Ok(token);
            }
        }
        let assertion = self.jwt()?;
        let response = self
            .http
            .post(&self.config.token_uri)
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", assertion.as_str()),
            ])
            .send()
            .await
            .map_err(|_| "push oauth")?;
        if !response.status().is_success() {
            return Err("push oauth rejected");
        }
        let body: serde_json::Value = response.json().await.map_err(|_| "push oauth")?;
        let token = body["access_token"]
            .as_str()
            .filter(|t| !t.is_empty() && t.len() <= 4096)
            .ok_or("push oauth")?
            .to_owned();
        let ttl = body["expires_in"].as_u64().unwrap_or(3600).clamp(60, 3600);
        *self.access.lock().unwrap() = Some((
            token.clone(),
            Instant::now() + Duration::from_secs(ttl.saturating_sub(60)),
        ));
        Ok(token)
    }
    /// True when a wake should be attempted now (rate limit per account).
    pub fn admit(&self, account: &str) -> bool {
        let mut recent = self.recent.lock().unwrap();
        let now = Instant::now();
        recent.retain(|_, at| now.duration_since(*at) < Duration::from_secs(600));
        if recent.len() >= 4096 {
            return false;
        }
        match recent.get(account) {
            Some(at) if now.duration_since(*at) < MIN_INTERVAL => false,
            _ => {
                recent.insert(account.to_owned(), now);
                true
            }
        }
    }
    /// Sends the constant wake. `Ok(false)` means FCM reports the token dead
    /// (the caller deletes it); `Ok(true)` accepted; `Err` transient.
    pub async fn wake(&self, token: &str) -> Result<bool, &'static str> {
        let access = self.access_token().await?;
        let url = self
            .config
            .send_url
            .replace("{project}", &self.config.project);
        let payload = serde_json::json!({"message":{"token":token,"data":{"t":"wake"},
            "android":{"priority":"high","ttl":"60s"}}});
        let response = self
            .http
            .post(url)
            .bearer_auth(access)
            .json(&payload)
            .send()
            .await
            .map_err(|_| "push send")?;
        let status = response.status().as_u16();
        if status == 200 {
            return Ok(true);
        }
        let body = response.text().await.unwrap_or_default();
        if status == 404
            || status == 400 && body.contains("UNREGISTERED")
            || body.contains("UNREGISTERED")
        {
            return Ok(false);
        }
        if status == 401 {
            *self.access.lock().unwrap() = None;
        }
        Err("push rejected")
    }
}
