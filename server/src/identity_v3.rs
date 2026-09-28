//! RFC-0027 identity-login-v3 (draft, private Devnet alpha). See docs/protocol/identity-login-v3.md.
//!
//! Separate runtime mode over an EMPTY database: legacy v2 self-registration is not
//! routed; transport accounts are created only by a dual-proof identity commit. The
//! existing v2 transport (auth proofs, sessions, messages, events, push, TURN) is reused
//! unchanged and enforces retirement through the locked `ss_accounts.mode` check.
use crate::self_service_http::{routes, service, Service};
use crate::Failure;
use axum::{body::Bytes, extract::State, http::StatusCode, routing::post, Json, Router};
use paranoid_key_protocol::identity_v3::{
    base58_encode, verify_records, ChallengeRequestV3, CheckedRequest, IdentityChallengeV3,
    Purpose, CHALLENGE_SECONDS, GENESIS, PROGRAM,
};
use serde_json::{json, Value};
use sqlx::{PgConnection, PgPool};
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const MAX_PENDING: usize = 64;
const MAX_MEMBERSHIPS: i64 = 128;
const MAX_GENERATION: i64 = 8;
const REPLACE_COOLDOWN: i64 = 86_400;
const RPC_CONCURRENCY: usize = 2;
const RPC_BUDGET: Duration = Duration::from_secs(6);
const FRESHNESS: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistryFailure {
    /// Network/RPC/size/timeout/genesis/program-artifact uncertainty. Retryable.
    Unavailable,
    /// Finalized registry does not prove this owner owns this canonical name.
    Invalid,
}

pub type Verification<'a> = Pin<Box<dyn Future<Output = Result<(), RegistryFailure>> + Send + 'a>>;

/// Finalized registry proof that `owner` holds `name`. Implementations must fail closed.
pub trait RegistryVerifier: Send + Sync + 'static {
    fn verify<'a>(&'a self, owner: [u8; 32], name: &'a str) -> Verification<'a>;
}

pub(crate) struct V3State {
    pending: Mutex<HashMap<String, (IdentityChallengeV3, CheckedRequest, Instant)>>,
    rpc: tokio::sync::Semaphore,
    registry: Arc<dyn RegistryVerifier>,
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn fail(status: StatusCode, code: &'static str) -> Failure {
    Failure(status, code)
}
fn denied() -> Failure {
    fail(StatusCode::UNAUTHORIZED, "unauthorized")
}
fn conflict(code: &'static str) -> Failure {
    fail(StatusCode::CONFLICT, code)
}
fn invalid_identity() -> Failure {
    fail(StatusCode::FORBIDDEN, "identity_invalid")
}

/// Offline initialization of an EMPTY database. Never converts a populated one.
pub async fn initialize(pool: &PgPool, realm: &str, pin: &str) -> Result<(), sqlx::Error> {
    if !realm.starts_with("https://") || realm.len() > 512 || !paranoid_key_protocol::hex32(pin) {
        return Err(sqlx::Error::Configuration("invalid realm".into()));
    }
    let mut tx = pool.begin().await?;
    let existing: i64 = sqlx::query_scalar("SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public')+(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public')+(SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typrelid=0 AND t.typelem=0)").fetch_one(&mut *tx).await?;
    if existing != 0 {
        return Err(sqlx::Error::Configuration(
            "identity-v3 requires an empty database".into(),
        ));
    }
    sqlx::raw_sql(include_str!("../self-service-schema.sql"))
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO ss_meta(id,version,realm,pin) VALUES(1,2,$1,$2)")
        .bind(realm)
        .bind(pin)
        .execute(&mut *tx)
        .await?;
    // Same guard as fresh v2: legacy v0 startup must refuse this database.
    sqlx::raw_sql("CREATE TABLE room_state(id SMALLINT PRIMARY KEY CHECK(id=1),sequence BIGINT NOT NULL CHECK(sequence>=0),used_bytes BIGINT NOT NULL CHECK(used_bytes>=0)); CREATE FUNCTION refuse_v0_room_initialization() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'self-service schema requires v2 startup'; END; $$; CREATE TRIGGER key_schema_startup_guard BEFORE INSERT ON room_state FOR EACH ROW EXECUTE FUNCTION refuse_v0_room_initialization()").execute(&mut *tx).await?;
    sqlx::raw_sql(include_str!("../identity-v3-schema.sql"))
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO id_meta(id,version,genesis,program) VALUES(1,3,$1,$2)")
        .bind(GENESIS)
        .bind(PROGRAM)
        .execute(&mut *tx)
        .await?;
    tx.commit().await
}

pub async fn init_cli() -> Result<(), Box<dyn std::error::Error>> {
    let options: sqlx::postgres::PgConnectOptions =
        std::env::var("PARANOID_DATABASE_URL")?.parse()?;
    if options.get_socket().is_none() || !crate::development_database_allowed(&options, false) {
        return Err("private local database required".into());
    }
    let _guard = crate::self_service::worker_guard(&options)?;
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?;
    initialize(
        &pool,
        &std::env::var("PARANOID_KEY_REALM")?,
        &std::env::var("PARANOID_KEY_PIN")?,
    )
    .await?;
    println!("Identity-v3 schema initialized offline");
    Ok(())
}

pub async fn app(
    pool: PgPool,
    turn: Option<crate::voice_turn::TurnConfig>,
    push: Option<crate::push_fcm::PushConfig>,
    registry: Arc<dyn RegistryVerifier>,
) -> Result<Router, sqlx::Error> {
    let pinned: Option<(i16, String, String)> =
        sqlx::query_as("SELECT version,genesis,program FROM id_meta WHERE id=1")
            .fetch_optional(&pool)
            .await
            .map_err(|_| sqlx::Error::Configuration("identity-v3 database required".into()))?;
    if pinned != Some((3, GENESIS.into(), PROGRAM.into())) {
        return Err(sqlx::Error::Configuration(
            "identity-v3 database required".into(),
        ));
    }
    let state = V3State {
        pending: Mutex::new(HashMap::new()),
        rpc: tokio::sync::Semaphore::new(RPC_CONCURRENCY),
        registry,
    };
    let s = service(pool, turn, push, Some(state)).await?;
    let extra = Router::new()
        .route("/v3/identity/challenge", post(challenge))
        .route("/v3/identity/inspect", post(inspect))
        .route("/v3/identity/status", post(status))
        .route("/v3/identity/commit", post(commit));
    Ok(routes(
        s,
        false,
        json!({"status":"ok","protocol":"paranoid-identity-v3","realtime":"signed-long-poll-v1"}),
        extra,
    ))
}

fn v3(s: &Service) -> &V3State {
    s.v3.as_ref()
        .expect("identity-v3 route in identity-v3 mode")
}

async fn challenge(State(s): State<Arc<Service>>, bytes: Bytes) -> Result<Json<Value>, Failure> {
    let request: ChallengeRequestV3 =
        serde_json::from_slice(&bytes).map_err(|_| crate::invalid())?;
    // Cheap, membership-independent checks only: no DB, no RPC (RFC-0027 N1/B6).
    let checked = request
        .validate(&s.realm, &s.pin)
        .map_err(|_| crate::invalid())?;
    let challenge = IdentityChallengeV3::try_issue(
        &checked,
        &s.realm,
        &s.pin,
        &s.epoch,
        now() + CHALLENGE_SECONDS,
    )
    .map_err(|_| fail(StatusCode::SERVICE_UNAVAILABLE, "randomness_unavailable"))?;
    let mut pending = v3(&s).pending.lock().unwrap();
    pending.retain(|_, (_, _, t)| t.elapsed() < Duration::from_secs(CHALLENGE_SECONDS as u64));
    if pending.len() >= MAX_PENDING {
        return Err(fail(StatusCode::TOO_MANY_REQUESTS, "challenge_capacity"));
    }
    pending.insert(
        challenge.id.clone(),
        (challenge.clone(), checked, Instant::now()),
    );
    Ok(Json(
        serde_json::to_value(challenge).map_err(|_| crate::invalid())?,
    ))
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Proof {
    id: String,
    owner_signature: Option<String>,
    device_signature: String,
}

/// Verify and atomically consume a stored challenge for exactly this route. Invalid
/// proofs never consume; a valid proof stays consumed whatever happens afterwards.
fn take(
    s: &Service,
    path: &str,
    bytes: &[u8],
) -> Result<(IdentityChallengeV3, CheckedRequest), Failure> {
    let proof: Proof = serde_json::from_slice(bytes).map_err(|_| denied())?;
    let mut pending = v3(s).pending.lock().unwrap();
    let (ch, checked, issued) = pending.get(&proof.id).ok_or_else(denied)?;
    if ch.purpose.path() != path
        || issued.elapsed() >= Duration::from_secs(CHALLENGE_SECONDS as u64)
        || ch.expires <= now()
    {
        return Err(denied());
    }
    ch.verify_proofs(
        checked,
        proof.owner_signature.as_deref(),
        &proof.device_signature,
    )
    .map_err(|_| denied())?;
    let (ch, checked, _) = pending.remove(&proof.id).ok_or_else(denied)?;
    Ok((ch, checked))
}

type MembershipRow = (
    String,
    String,
    i64,
    String,
    String,
    String,
    Option<i64>,
    String,
    String,
);

struct Membership {
    id: String,
    state: String,
    generation: i64,
    operation: String,
    intent: String,
    result: String,
    last_replace: Option<i64>,
    name: String,
    account: String,
}

async fn membership(
    conn: &mut PgConnection,
    identity: &str,
) -> Result<Option<Membership>, Failure> {
    let row: Option<MembershipRow> = sqlx::query_as("SELECT membership,state,generation,operation,intent,result,last_replace,name,account FROM id_memberships WHERE identity=$1")
        .bind(identity)
        .fetch_optional(&mut *conn)
        .await?;
    Ok(row.map(
        |(id, state, generation, operation, intent, result, last_replace, name, account)| {
            Membership {
                id,
                state,
                generation,
                operation,
                intent,
                result,
                last_replace,
                name,
                account,
            }
        },
    ))
}

async fn inspect(State(s): State<Arc<Service>>, bytes: Bytes) -> Result<Json<Value>, Failure> {
    let (_, checked) = take(&s, Purpose::Inspect.path(), &bytes)?;
    // Read-only, lock-free, looked up ONLY by the proven owner's identity PDA.
    let mut conn = s.pool.acquire().await?;
    let found = membership(&mut conn, &checked.request().identity).await?;
    Ok(Json(match found {
        None => json!({"mode":"absent","generation":"0"}),
        Some(m) if m.name != checked.request().name => return Err(conflict("identity_mismatch")),
        Some(m) => json!({"mode": m.state, "generation": m.generation.to_string()}),
    }))
}

type StatusRow = (
    i64,
    String,
    bool,
    String,
    i64,
    String,
    String,
    String,
    String,
);

async fn status(State(s): State<Arc<Service>>, bytes: Bytes) -> Result<Json<Value>, Failure> {
    let (_, checked) = take(&s, Purpose::Status.path(), &bytes)?;
    let r = checked.request();
    let row: Option<StatusRow> = sqlx::query_as("SELECT b.generation,b.operation,b.retired,m.state,m.generation,m.operation,m.identity,m.name,d.credential FROM id_bindings b JOIN id_memberships m USING(membership) JOIN ss_devices d ON d.account=b.account WHERE b.fingerprint=$1")
        .bind(checked.credential_fingerprint())
        .fetch_optional(&s.pool)
        .await?;
    let exact = row.filter(|(.., identity, name, raw)| {
        *identity == r.identity
            && *name == r.name
            && serde_json::from_str::<paranoid_key_protocol::Credential>(raw)
                .ok()
                .as_ref()
                == Some(&r.credential_object)
    });
    Ok(Json(match exact {
        Some((generation, operation, true, ..)) => {
            json!({"mode":"revoked","generation":generation.to_string(),"operation":operation})
        }
        Some((_, _, false, state, generation, operation, ..)) => {
            json!({"mode":state,"generation":generation.to_string(),"operation":operation})
        }
        None => json!({"mode":"absent","generation":"0","operation":""}),
    }))
}

enum Decision {
    Retry(Value),
    Proceed(Option<Membership>),
}

async fn db_now(conn: &mut PgConnection) -> Result<i64, Failure> {
    Ok(
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
            .fetch_one(&mut *conn)
            .await?,
    )
}

/// Decisions that reveal only the PROVEN owner's own identity. Run as an unlocked
/// hint before RPC, and again authoritatively under the ss_meta lock.
async fn evaluate(
    conn: &mut PgConnection,
    checked: &CheckedRequest,
    intent: &str,
) -> Result<Decision, Failure> {
    let r = checked.request();
    let Some(m) = membership(conn, &r.identity).await? else {
        return if r.purpose == Purpose::Enroll {
            Ok(Decision::Proceed(None))
        } else {
            Err(conflict("generation_conflict"))
        };
    };
    if m.name != r.name {
        return Err(conflict("identity_mismatch"));
    }
    if m.operation == r.operation {
        if m.state == "banned" {
            return Err(fail(StatusCode::FORBIDDEN, "membership_banned"));
        }
        return if m.intent == intent {
            Ok(Decision::Retry(
                serde_json::from_str(&m.result).map_err(|_| crate::invalid())?,
            ))
        } else {
            Err(conflict("operation_conflict"))
        };
    }
    // Own-membership bindings only: the candidate device, or reuse of an old operation.
    let own_device: Option<bool> = sqlx::query_scalar(
        "SELECT retired FROM id_bindings WHERE membership=$1 AND fingerprint=$2",
    )
    .bind(&m.id)
    .bind(checked.credential_fingerprint())
    .fetch_optional(&mut *conn)
    .await?;
    match own_device {
        Some(true) => return Err(conflict("device_revoked")),
        Some(false) => return Err(conflict("binding_used")),
        None => {}
    }
    let reused_operation: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM id_bindings WHERE membership=$1 AND operation=$2)",
    )
    .bind(&m.id)
    .bind(&r.operation)
    .fetch_one(&mut *conn)
    .await?;
    if reused_operation {
        return Err(conflict("operation_conflict"));
    }
    if m.state == "banned" {
        return Err(fail(StatusCode::FORBIDDEN, "membership_banned"));
    }
    if r.purpose == Purpose::Enroll || checked.generation() != m.generation {
        return Err(conflict("generation_conflict"));
    }
    let now = db_now(conn).await?;
    if m.generation >= MAX_GENERATION
        || m.last_replace
            .is_some_and(|t| now < t || now - t < REPLACE_COOLDOWN)
    {
        return Err(conflict("replacement_limit"));
    }
    Ok(Decision::Proceed(Some(m)))
}

/// Fixed global window of at most eight per 60 s, persisted; clock rollback denies.
async fn take_window(conn: &mut PgConnection, successes: bool) -> Result<bool, Failure> {
    let sql = if successes {
        "UPDATE id_meta SET successes=CASE WHEN t.n-success_window>=60 THEN 1 ELSE successes+1 END, success_window=CASE WHEN t.n-success_window>=60 THEN t.n ELSE success_window END FROM (SELECT floor(extract(epoch FROM clock_timestamp()))::bigint AS n) t WHERE id=1 AND t.n>=success_window AND (successes<8 OR t.n-success_window>=60) RETURNING successes"
    } else {
        "UPDATE id_meta SET starts=CASE WHEN t.n-start_window>=60 THEN 1 ELSE starts+1 END, start_window=CASE WHEN t.n-start_window>=60 THEN t.n ELSE start_window END FROM (SELECT floor(extract(epoch FROM clock_timestamp()))::bigint AS n) t WHERE id=1 AND t.n>=start_window AND (starts<8 OR t.n-start_window>=60) RETURNING starts"
    };
    let taken: Option<i64> = sqlx::query_scalar(sql).fetch_optional(&mut *conn).await?;
    Ok(taken.is_some())
}

async fn commit(State(s): State<Arc<Service>>, bytes: Bytes) -> Result<Json<Value>, Failure> {
    let (ch, checked) = take(&s, "/v3/identity/commit", &bytes)?;
    let intent = checked.intent_digest();
    // Unlocked hint: exact retries and own-identity terminal states need no RPC.
    {
        let mut conn = s.pool.acquire().await?;
        if let Decision::Retry(result) = evaluate(&mut conn, &checked, &intent).await? {
            return Ok(Json(result));
        }
    }
    let state = v3(&s);
    let _permit = state
        .rpc
        .try_acquire()
        .map_err(|_| fail(StatusCode::TOO_MANY_REQUESTS, "verification_budget"))?;
    {
        let mut conn = s.pool.acquire().await?;
        if !take_window(&mut conn, false).await? {
            return Err(fail(StatusCode::TOO_MANY_REQUESTS, "verification_budget"));
        }
    }
    let r = checked.request();
    match tokio::time::timeout(RPC_BUDGET, state.registry.verify(*checked.owner(), &r.name)).await {
        Ok(Ok(())) => {}
        Ok(Err(RegistryFailure::Invalid)) => return Err(invalid_identity()),
        Ok(Err(RegistryFailure::Unavailable)) | Err(_) => {
            return Err(fail(
                StatusCode::SERVICE_UNAVAILABLE,
                "registry_unavailable",
            ))
        }
    }
    let verified = Instant::now();
    let mut tx = s.pool.begin().await?;
    sqlx::query("SET LOCAL synchronous_commit=on")
        .execute(&mut *tx)
        .await?;
    sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await?;
    if verified.elapsed() > FRESHNESS || ch.expires <= now() {
        return Err(fail(
            StatusCode::SERVICE_UNAVAILABLE,
            "registry_unavailable",
        ));
    }
    let existing = match evaluate(&mut tx, &checked, &intent).await? {
        Decision::Retry(result) => return Ok(Json(result)),
        Decision::Proceed(existing) => existing,
    };
    let c = &r.credential_object;
    let fingerprint = checked.credential_fingerprint();
    // Cross-membership collisions are checked only now, after finalized registry proof,
    // and never identify which foreign field collided (RFC-0027 N1).
    let taken: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM ss_accounts WHERE account=$1 OR root=$2) OR EXISTS(SELECT 1 FROM ss_devices WHERE device=$3 OR auth=$4 OR fingerprint=$5) OR EXISTS(SELECT 1 FROM id_bindings WHERE account=$1 OR root=$2 OR device=$3 OR auth=$4 OR fingerprint=$5 OR olm=$6 OR operation=$7) OR EXISTS(SELECT 1 FROM id_memberships WHERE operation=$7 OR (name=$8 AND identity<>$9))")
        .bind(&c.account).bind(&c.root).bind(&c.device).bind(&c.auth).bind(fingerprint)
        .bind(&c.olm).bind(&r.operation).bind(&r.name).bind(&r.identity)
        .fetch_one(&mut *tx).await?;
    if taken {
        return Err(invalid_identity());
    }
    if existing.is_none() {
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM id_memberships")
            .fetch_one(&mut *tx)
            .await?;
        if count >= MAX_MEMBERSHIPS {
            return Err(fail(StatusCode::TOO_MANY_REQUESTS, "capacity"));
        }
    }
    if !take_window(&mut tx, true).await? {
        return Err(fail(StatusCode::TOO_MANY_REQUESTS, "mutation_budget"));
    }
    let generation = existing.as_ref().map_or(1, |m| m.generation + 1);
    let membership_id = existing
        .as_ref()
        .map_or_else(|| uuid::Uuid::new_v4().to_string(), |m| m.id.clone());
    let result = json!({
        "operation": r.operation, "membership": membership_id,
        "generation": generation.to_string(), "account": c.account, "device": c.device,
        "credential_fingerprint": fingerprint, "mode": "active",
    });
    let stored = result.to_string();
    let raw = serde_json::to_string(c).map_err(|_| crate::invalid())?;
    sqlx::query("INSERT INTO ss_accounts VALUES($1,$2,'active')")
        .bind(&c.account)
        .bind(&c.root)
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO ss_devices VALUES($1,$2,$3,$4,$5)")
        .bind(&c.account)
        .bind(&c.device)
        .bind(&c.auth)
        .bind(fingerprint)
        .bind(&raw)
        .execute(&mut *tx)
        .await?;
    let retired = match &existing {
        None => {
            sqlx::query(
                "INSERT INTO id_memberships VALUES($1,$2,$3,$4,'active',1,$5,$6,$7,$8,NULL)",
            )
            .bind(&membership_id)
            .bind(&r.identity)
            .bind(&r.owner)
            .bind(&r.name)
            .bind(&c.account)
            .bind(&r.operation)
            .bind(&intent)
            .bind(&stored)
            .execute(&mut *tx)
            .await?;
            None
        }
        Some(m) => {
            sqlx::query("UPDATE ss_accounts SET mode='revoked' WHERE account=$1")
                .bind(&m.account)
                .execute(&mut *tx)
                .await?;
            sqlx::query("UPDATE id_bindings SET retired=true WHERE account=$1")
                .bind(&m.account)
                .execute(&mut *tx)
                .await?;
            let push: bool =
                sqlx::query_scalar("SELECT to_regclass('public.ss_push_tokens') IS NOT NULL")
                    .fetch_one(&mut *tx)
                    .await?;
            if push {
                sqlx::query("DELETE FROM ss_push_tokens WHERE account=$1")
                    .bind(&m.account)
                    .execute(&mut *tx)
                    .await?;
            }
            let replaced_at = db_now(&mut tx).await?;
            sqlx::query("UPDATE id_memberships SET generation=$2,account=$3,operation=$4,intent=$5,result=$6,last_replace=$7 WHERE membership=$1")
                .bind(&m.id)
                .bind(generation)
                .bind(&c.account)
                .bind(&r.operation)
                .bind(&intent)
                .bind(&stored)
                .bind(replaced_at)
                .execute(&mut *tx)
                .await?;
            Some(m.account.clone())
        }
    };
    sqlx::query("INSERT INTO id_bindings VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,false)")
        .bind(&c.account)
        .bind(&membership_id)
        .bind(generation)
        .bind(&r.operation)
        .bind(&c.root)
        .bind(&c.device)
        .bind(&c.auth)
        .bind(fingerprint)
        .bind(&c.olm)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    if let Some(old) = retired {
        s.retire_sessions(&old);
    }
    Ok(Json(result))
}

/// Live verifier against the pinned Devnet RPC (RFC-0026 pins). Checks the paired PDA
/// records first, then genesis, then the loader/ProgramData artifact. Fails closed.
pub struct DevnetRegistry {
    http: reqwest::Client,
    url: String,
}

pub const DEVNET_RPC: &str = "https://api.devnet.solana.com";
const LOADER: &str = "BPFLoaderUpgradeab1e11111111111111111111111";
const PROGRAMDATA: &str = "3WzWMcWhaZtbCGubaJHUfVRm5edgkr4amWLWdHVkQLFr";
const AUTHORITY: &str = "5jD3zwcQPiLoM41eHZXSL8bZnWn16WuZ7kBqBjMUwndm";
const SBF_SIZE: usize = 73_800;
const SBF_SHA256: &str = "ab3517cb30be9832344f46638373bfd305f954619f3a95a6513d4981a4f93efa";
const PROGRAMDATA_HEADER: usize = 45;
/// 4*ceil((45+73800)/3) base64 payload plus 16 KiB JSON envelope.
const PROGRAMDATA_CAP: usize = 4 * (PROGRAMDATA_HEADER + SBF_SIZE).div_ceil(3) + 16_384;
const RESPONSE_CAP: usize = 65_536;

/// Upgradeable-loader Program = [2,0,0,0]+ProgramData address (36 bytes, executable).
/// ProgramData = [3,0,0,0] + slot u64 LE + Some(authority) tag 1 + 32-byte authority +
/// exactly the pinned ELF (not executable). Any extension, missing/other authority or
/// ELF change fails; the deployment slot is intentionally not pinned.
fn check_artifact(
    code: &[u8],
    code_executable: bool,
    meta: &[u8],
    meta_executable: bool,
    elf_sha256: &str,
) -> bool {
    use sha2::{Digest, Sha256};
    let decode = paranoid_key_protocol::identity_v3::base58_decode32;
    let (Ok(programdata), Ok(authority)) = (decode(PROGRAMDATA), decode(AUTHORITY)) else {
        return false;
    };
    code_executable
        && !meta_executable
        && code.len() == 36
        && code[..4] == [2, 0, 0, 0]
        && code[4..] == programdata
        && meta.len() == PROGRAMDATA_HEADER + SBF_SIZE
        && meta[..4] == [3, 0, 0, 0]
        && meta[12] == 1
        && meta[13..PROGRAMDATA_HEADER] == authority
        && format!("{:x}", Sha256::digest(&meta[PROGRAMDATA_HEADER..])) == elf_sha256
}

impl DevnetRegistry {
    pub fn new(url: &str) -> Result<Self, Box<dyn std::error::Error>> {
        if !url.starts_with("https://") {
            return Err("registry RPC must be HTTPS".into());
        }
        Self::build(url)
    }

    /// Plain-HTTP fixture limited to an IPv4 loopback literal, for local lying-RPC tests.
    /// The runtime only calls `new`, which requires HTTPS.
    pub fn new_loopback_fixture(url: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let host = url
            .strip_prefix("http://")
            .and_then(|rest| rest.split('/').next())
            .and_then(|authority| authority.rsplit_once(':').map(|(host, _)| host))
            .ok_or("loopback fixture only")?;
        if host
            .parse::<std::net::Ipv4Addr>()
            .map(|ip| ip.is_loopback())
            != Ok(true)
        {
            return Err("loopback fixture only".into());
        }
        Self::build(url)
    }

    fn build(url: &str) -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            http: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(RPC_BUDGET)
                .build()?,
            url: url.into(),
        })
    }

    async fn rpc(&self, method: &str, params: Value, cap: usize) -> Result<Value, RegistryFailure> {
        use RegistryFailure::Unavailable;
        let mut response = self
            .http
            .post(&self.url)
            .json(&json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}))
            .send()
            .await
            .map_err(|_| Unavailable)?;
        if !response.status().is_success()
            || response.content_length().is_some_and(|n| n as usize > cap)
        {
            return Err(Unavailable);
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Unavailable)? {
            if body.len() + chunk.len() > cap {
                return Err(Unavailable);
            }
            body.extend_from_slice(&chunk);
        }
        let value: Value = serde_json::from_slice(&body).map_err(|_| Unavailable)?;
        value.get("result").cloned().ok_or(Unavailable)
    }

    async fn accounts(&self, keys: [&str; 2], cap: usize) -> Result<Vec<Value>, RegistryFailure> {
        let result = self
            .rpc(
                "getMultipleAccounts",
                json!([keys, {"encoding":"base64","commitment":"finalized"}]),
                cap,
            )
            .await?;
        let values = result["value"]
            .as_array()
            .ok_or(RegistryFailure::Unavailable)?;
        if values.len() != 2 {
            return Err(RegistryFailure::Unavailable);
        }
        Ok(values.clone())
    }

    async fn check(&self, owner: [u8; 32], name: &str) -> Result<(), RegistryFailure> {
        use base64::{engine::general_purpose::STANDARD, Engine};
        use RegistryFailure::{Invalid, Unavailable};
        let derived = paranoid_key_protocol::identity_v3::derive_registry(&owner, name)
            .map_err(|_| Invalid)?;
        let identity = base58_encode(&derived.identity);
        let nickname = base58_encode(&derived.nickname);
        let data = |account: &Value, expected_owner: &str| -> Result<Vec<u8>, RegistryFailure> {
            if account["owner"] != expected_owner || account["data"][1] != "base64" {
                return Err(Invalid);
            }
            let encoded = account["data"][0].as_str().ok_or(Invalid)?;
            STANDARD.decode(encoded).map_err(|_| Invalid)
        };
        let records = self.accounts([&identity, &nickname], RESPONSE_CAP).await?;
        if records.iter().any(Value::is_null) {
            return Err(Invalid);
        }
        if records.iter().any(|a| a["executable"] != false) {
            return Err(Invalid);
        }
        verify_records(
            &owner,
            name,
            &data(&records[0], PROGRAM)?,
            &data(&records[1], PROGRAM)?,
        )
        .map_err(|_| Invalid)?;
        let genesis = self.rpc("getGenesisHash", json!([]), RESPONSE_CAP).await?;
        if genesis != GENESIS {
            return Err(Unavailable);
        }
        let program = self
            .accounts([PROGRAM, PROGRAMDATA], PROGRAMDATA_CAP)
            .await?;
        let (code, meta) = (&program[0], &program[1]);
        let code_bytes = data(code, LOADER).map_err(|_| Unavailable)?;
        let meta_bytes = data(meta, LOADER).map_err(|_| Unavailable)?;
        if check_artifact(
            &code_bytes,
            code["executable"] == true,
            &meta_bytes,
            meta["executable"] == true,
            SBF_SHA256,
        ) {
            Ok(())
        } else {
            Err(Unavailable)
        }
    }
}

impl RegistryVerifier for DevnetRegistry {
    fn verify<'a>(&'a self, owner: [u8; 32], name: &'a str) -> Verification<'a> {
        Box::pin(self.check(owner, name))
    }
}

#[cfg(test)]
mod tests {
    use super::{check_artifact, PROGRAMDATA_HEADER};

    fn artifact() -> (Vec<u8>, Vec<u8>, String) {
        use sha2::{Digest, Sha256};
        let pd = paranoid_key_protocol::identity_v3::base58_decode32(super::PROGRAMDATA).unwrap();
        let auth = paranoid_key_protocol::identity_v3::base58_decode32(super::AUTHORITY).unwrap();
        let code = [&[2u8, 0, 0, 0][..], &pd[..]].concat();
        let elf: Vec<u8> = (0..super::SBF_SIZE).map(|i| (i % 251) as u8).collect();
        let mut meta = vec![3u8, 0, 0, 0];
        meta.extend_from_slice(&42u64.to_le_bytes());
        meta.push(1);
        meta.extend_from_slice(&auth);
        meta.extend_from_slice(&elf);
        let sha = format!("{:x}", Sha256::digest(&elf));
        (code, meta, sha)
    }

    #[test]
    fn artifact_check_accepts_exact_layout_and_rejects_each_deviation() {
        let (code, meta, sha) = artifact();
        assert!(check_artifact(&code, true, &meta, false, &sha));
        assert!(
            !check_artifact(&code, false, &meta, false, &sha),
            "program not executable"
        );
        assert!(
            !check_artifact(&code, true, &meta, true, &sha),
            "programdata executable"
        );
        let mut c = code.clone();
        c[0] = 3;
        assert!(!check_artifact(&c, true, &meta, false, &sha), "program tag");
        let mut c = code.clone();
        c[20] ^= 1;
        assert!(
            !check_artifact(&c, true, &meta, false, &sha),
            "programdata address"
        );
        let mut c = code.clone();
        c.push(0);
        assert!(
            !check_artifact(&c, true, &meta, false, &sha),
            "program length"
        );
        for (index, value, why) in [
            (0, 2u8, "programdata tag"),
            (12, 0, "authority removed"),
            (12, 2, "Option tag 2"),
            (13, 0, "authority byte"),
            (PROGRAMDATA_HEADER, 0xff, "elf byte"),
        ] {
            let mut m = meta.clone();
            m[index] = value;
            assert!(!check_artifact(&code, true, &m, false, &sha), "{why}");
        }
        let mut m = meta.clone();
        m.push(0);
        assert!(
            !check_artifact(&code, true, &m, false, &sha),
            "extended allocation"
        );
        assert!(
            !check_artifact(&code, true, &meta[..meta.len() - 1], false, &sha),
            "short"
        );
        assert!(
            !check_artifact(&code, true, &meta, false, super::SBF_SHA256),
            "wrong artifact"
        );
        // The slot field is not pinned: any deployment slot is accepted.
        let mut m = meta.clone();
        m[4..12].copy_from_slice(&7u64.to_le_bytes());
        assert!(check_artifact(&code, true, &m, false, &sha));
    }

    #[test]
    fn loopback_fixture_constructor_refuses_remote_hosts() {
        assert!(super::DevnetRegistry::new_loopback_fixture("http://127.0.0.1:9/").is_ok());
        for bad in [
            "http://api.devnet.solana.com/",
            "http://10.0.0.1/",
            "https://127.0.0.1/",
            "http://127.0.0.1.evil/",
        ] {
            assert!(
                super::DevnetRegistry::new_loopback_fixture(bad).is_err(),
                "{bad}"
            );
        }
    }

    #[test]
    fn server_pins_match_the_android_devnet_client_source() {
        let client = include_str!("../../blockchain/solana/client/src/lib.rs");
        for pin in [
            super::PROGRAM,
            super::GENESIS,
            super::AUTHORITY,
            super::SBF_SHA256,
            super::LOADER,
            super::DEVNET_RPC,
        ] {
            assert!(client.contains(pin), "pin drift: {pin}");
        }
        assert!(client.contains(&format!("\"sbf_size\":{}", super::SBF_SIZE)));
        assert_eq!(super::PROGRAMDATA_CAP, 98_460 + 16_384);
    }
}
