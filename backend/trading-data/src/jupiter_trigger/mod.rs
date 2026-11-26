use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use reqwest::{header::HeaderValue, Method};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::File,
    io::Read,
    path::Path,
    sync::{Arc, Mutex as DbMutex},
    time::Duration,
};
use tokio::{
    sync::Mutex,
    time::{sleep_until, Instant},
};
use trig_wallet_swap_policy::trigger::{
    self, AuthPlan, CancelConsent, TransferDirection, TransferPlan,
};

use crate::{
    execution::types::Provider,
    wallet::{self, Rpc},
    ApiError, AppState,
};

mod orders;

const CHALLENGE_TTL: u64 = 300;
const REVIEW_TTL: u64 = 45;
const ORDER_TTL: u64 = 30 * 24 * 60 * 60;
const MAX_WALLETS: usize = 128;
const MAX_PLANS: usize = 24;
const MAX_BODY: usize = 2 * 1024 * 1024;
type Result<T> = std::result::Result<T, ApiError>;

pub(crate) struct Service {
    client: reqwest::Client,
    next: Mutex<Instant>,
    wallets: Mutex<HashMap<String, Arc<Mutex<WalletState>>>>,
    db: DbMutex<Connection>,
}

#[derive(Default)]
struct WalletState {
    challenge: Option<AuthPlan>,
    tokens: Option<Tokens>,
    vault: Option<String>,
    placements: HashMap<String, Placement>,
    cancellation: Option<CancelConsent>,
    orders: HashMap<String, orders::Order>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Tokens {
    access_token: String,
    refresh_token: String,
    expires_at: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct WalletQuery {
    wallet: String,
}

#[derive(Serialize)]
pub(crate) struct SessionStatus {
    authenticated: bool,
    // Older app builds use this flag to decide whether to show wallet login.
    configured: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VerifyRequest {
    wallet: String,
    signature: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Review {
    plan_id: String,
    signing_plan: TransferPlan,
    fee_lamports: String,
    rent_lamports: String,
    mint_decimals: u8,
    order_expires_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_valid_block_height: Option<u64>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PrepareRequest {
    wallet: String,
    input_mint: String,
    output_mint: String,
    input_amount: String,
    trigger_mint: String,
    trigger_condition: String,
    trigger_price_usd: String,
    slippage_bps: u16,
    input_decimals: Option<u8>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SubmitRequest {
    wallet: String,
    plan_id: String,
    signed: String,
    transaction_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Receipt {
    order_id: String,
    transaction_id: String,
    confirmed: bool,
}

struct Placement {
    request: PrepareRequest,
    review: Review,
    expires_at: u64,
}

fn invalid(message: impl Into<String>) -> ApiError {
    ApiError(StatusCode::UNPROCESSABLE_ENTITY, message.into())
}
fn unavailable(message: impl Into<String>) -> ApiError {
    ApiError(StatusCode::SERVICE_UNAVAILABLE, message.into())
}
fn bad_upstream() -> ApiError {
    ApiError(
        StatusCode::BAD_GATEWAY,
        "Jupiter Trigger returned unexpected data.".into(),
    )
}
fn local_error() -> ApiError {
    unavailable("Couldn’t open the local Jupiter Trigger order records.")
}
fn need_auth() -> ApiError {
    ApiError(
        StatusCode::UNAUTHORIZED,
        "Connect this wallet to Jupiter Trigger.".into(),
    )
}
fn pubkey(value: &str) -> bool {
    value.len() <= 44
        && bs58::decode(value)
            .into_vec()
            .is_ok_and(|bytes| bytes.len() == 32)
}
fn require_wallet(wallet: &str) -> Result<()> {
    if pubkey(wallet) {
        Ok(())
    } else {
        Err(invalid("Invalid Solana funding wallet."))
    }
}
fn signature(value: &str) -> bool {
    value.len() <= 88
        && bs58::decode(value)
            .into_vec()
            .is_ok_and(|bytes| bytes.len() == 64)
}
fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
}
fn atomic(value: &str) -> Option<u64> {
    value
        .parse::<u64>()
        .ok()
        .filter(|amount| amount.to_string() == value)
}
fn nonce() -> Result<String> {
    let mut bytes = [0; 24];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|_| unavailable("Couldn’t prepare a local verification challenge."))?;
    Ok(hex::encode(bytes))
}

impl Service {
    pub(crate) fn open(path: &Path) -> std::result::Result<Self, Box<dyn std::error::Error>> {
        let db = Connection::open(path)?;
        db.busy_timeout(Duration::from_secs(3))?;
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS jupiter_trigger_deposits (
                intent TEXT PRIMARY KEY,
                wallet TEXT NOT NULL,
                order_token_account TEXT NOT NULL,
                transaction_id TEXT NOT NULL UNIQUE,
                order_id TEXT,
                last_valid_block_height INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS jupiter_trigger_withdrawals (
                wallet TEXT NOT NULL,
                order_id TEXT NOT NULL,
                plan_id TEXT NOT NULL UNIQUE,
                review TEXT NOT NULL,
                submitted_signature TEXT,
                PRIMARY KEY (wallet, order_id)
            );",
        )?;
        Ok(Self {
            client: reqwest::Client::builder()
                .user_agent("TradingWorkspace/0.1")
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(8))
                .timeout(Duration::from_secs(30))
                .build()?,
            next: Mutex::new(Instant::now()),
            wallets: Mutex::new(HashMap::new()),
            db: DbMutex::new(db),
        })
    }

    async fn wallet(&self, wallet: &str, create: bool) -> Result<Arc<Mutex<WalletState>>> {
        require_wallet(wallet)?;
        let mut wallets = self.wallets.lock().await;
        if let Some(state) = wallets.get(wallet) {
            return Ok(state.clone());
        }
        if !create {
            return Err(need_auth());
        }
        if wallets.len() >= MAX_WALLETS {
            return Err(unavailable("Too many local Jupiter wallet sessions."));
        }
        Ok(wallets.entry(wallet.into()).or_default().clone())
    }
}

struct ProviderFailure(StatusCode, &'static str);

impl ProviderFailure {
    fn api(self) -> ApiError {
        ApiError(self.0, self.1.into())
    }
}

impl Service {
    async fn request(
        &self,
        api_key: Option<&str>,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<&Value>,
    ) -> std::result::Result<Value, ProviderFailure> {
        let mut next = self.next.lock().await;
        sleep_until(*next).await;
        let spacing = if api_key.is_some() { 1100 } else { 2100 };
        *next = Instant::now() + Duration::from_millis(spacing);
        let mut request = self
            .client
            .request(method, format!("https://api.jup.ag/trigger/v2/{path}"))
            .header("Accept", "application/json");
        if let Some(api_key) = api_key {
            let mut key = HeaderValue::from_str(api_key).map_err(|_| {
                ProviderFailure(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "The Jupiter API key is invalid.",
                )
            })?;
            key.set_sensitive(true);
            request = request.header("x-api-key", key);
        }
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        let mut response = request.send().await.map_err(|_| {
            ProviderFailure(
                StatusCode::BAD_GATEWAY,
                "Jupiter Trigger could not be reached. Check Orders before retrying a submission.",
            )
        })?;
        let status = response.status();
        if status == StatusCode::TOO_MANY_REQUESTS {
            let cooldown = response
                .headers()
                .get("retry-after")
                .and_then(|header| header.to_str().ok())
                .and_then(|seconds| seconds.parse::<u64>().ok())
                .unwrap_or(10)
                .clamp(1, 120);
            *next = Instant::now() + Duration::from_secs(cooldown);
            return Err(ProviderFailure(
                status,
                "Jupiter Trigger is rate-limiting requests. Try again shortly.",
            ));
        }
        if !status.is_success() {
            let message = match status {
                StatusCode::UNAUTHORIZED => "Jupiter Trigger rejected the session or API key.",
                StatusCode::FORBIDDEN if api_key.is_some() =>
                    "Jupiter Trigger access was denied. Check your API key permissions.",
                StatusCode::FORBIDDEN => "Jupiter denied keyless Trigger access.",
                StatusCode::NOT_FOUND => "Jupiter Trigger could not find this wallet vault or order.",
                StatusCode::CONFLICT => "Jupiter Trigger already has a record for this request.",
                StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY =>
                    "Jupiter Trigger rejected this request. Check the order amount, balance, and status.",
                _ => "Jupiter Trigger could not complete this request. Check Orders before retrying a submission.",
            };
            return Err(ProviderFailure(status, message));
        }
        let mut payload = Vec::new();
        loop {
            let next = response.chunk().await.map_err(|_| {
                ProviderFailure(
                    StatusCode::BAD_GATEWAY,
                    "Couldn’t read the Jupiter Trigger response.",
                )
            })?;
            let Some(bytes) = next else { break };
            if payload.len().saturating_add(bytes.len()) > MAX_BODY {
                return Err(ProviderFailure(
                    StatusCode::BAD_GATEWAY,
                    "The Jupiter Trigger response was too large.",
                ));
            }
            payload.extend_from_slice(&bytes);
        }
        serde_json::from_slice(&payload).map_err(|_| {
            ProviderFailure(
                StatusCode::BAD_GATEWAY,
                "Jupiter Trigger returned unexpected data.",
            )
        })
    }

    async fn refresh(&self, key: Option<&str>, wallet: &mut WalletState) -> Result<()> {
        let refresh = &wallet.tokens.as_ref().ok_or_else(need_auth)?.refresh_token;
        let response = self
            .request(
                key,
                Method::POST,
                "auth/refresh",
                None,
                Some(&json!({"refreshToken":refresh})),
            )
            .await;
        match response {
            Ok(value) => {
                wallet.tokens = Some(parse_tokens(value)?);
                Ok(())
            }
            Err(ProviderFailure(StatusCode::UNAUTHORIZED, _)) => {
                wallet.tokens = None;
                wallet.vault = None;
                Err(need_auth())
            }
            Err(error) => Err(error.api()),
        }
    }

    async fn authenticated(
        &self,
        key: Option<&str>,
        wallet: &mut WalletState,
        method: Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<Value> {
        let expires = access_expiry(wallet.tokens.as_ref().ok_or_else(need_auth)?)?;
        if expires <= crate::now() + 30 {
            self.refresh(key, wallet).await?;
        }
        let token = &wallet.tokens.as_ref().ok_or_else(need_auth)?.access_token;
        let response = self
            .request(key, method.clone(), path, Some(token), body)
            .await;
        match response {
            Ok(value) => Ok(value),
            // A 401 rejects authorization before processing. Other errors may follow a
            // submitted transaction, so never replay a request on a timeout or a 5xx.
            Err(ProviderFailure(StatusCode::UNAUTHORIZED, _)) => {
                self.refresh(key, wallet).await?;
                let token = &wallet.tokens.as_ref().ok_or_else(need_auth)?.access_token;
                self.request(key, method, path, Some(token), body)
                    .await
                    .map_err(ProviderFailure::api)
            }
            Err(error) => Err(error.api()),
        }
    }
}

fn api_key(state: &AppState) -> Option<&str> {
    state.execution.config.key(Provider::Jupiter)
}

fn access_expiry(tokens: &Tokens) -> Result<u64> {
    chrono::DateTime::parse_from_rfc3339(&tokens.expires_at)
        .ok()
        .and_then(|date| u64::try_from(date.timestamp()).ok())
        .ok_or_else(bad_upstream)
}

fn parse_tokens(value: Value) -> Result<Tokens> {
    let tokens: Tokens = serde_json::from_value(value).map_err(|_| bad_upstream())?;
    let now = crate::now();
    if [tokens.access_token.as_str(), tokens.refresh_token.as_str()]
        .iter()
        .any(|token| {
            token.is_empty() || token.len() > 8192 || !token.bytes().all(|b| b.is_ascii_graphic())
        })
        || !(now + 1..=now + 20 * 60).contains(&access_expiry(&tokens)?)
    {
        return Err(bad_upstream());
    }
    Ok(tokens)
}

pub(crate) async fn session_status(
    State(state): State<AppState>,
    Query(input): Query<WalletQuery>,
) -> Result<Json<SessionStatus>> {
    require_wallet(&input.wallet)?;
    let authenticated = if let Ok(wallet) = state.jupiter_trigger.wallet(&input.wallet, false).await
    {
        wallet.lock().await.tokens.is_some()
    } else {
        false
    };
    Ok(Json(SessionStatus {
        authenticated,
        configured: true,
    }))
}

pub(crate) async fn challenge(
    State(state): State<AppState>,
    Json(input): Json<WalletQuery>,
) -> Result<Json<AuthPlan>> {
    let service = &state.jupiter_trigger;
    let wallet = service.wallet(&input.wallet, true).await?;
    let mut wallet = wallet.lock().await;
    let response = service
        .request(
            api_key(&state),
            Method::POST,
            "auth/challenge",
            None,
            Some(&json!({"walletPubkey":input.wallet, "type":"message"})),
        )
        .await
        .map_err(ProviderFailure::api)?;
    let text = response["challenge"].as_str().ok_or_else(bad_upstream)?;
    let now = crate::now();
    let expires_at = trigger::challenge_expires_at(&input.wallet, text, now)
        .map_err(invalid)?
        .min(now + CHALLENGE_TTL);
    let plan = AuthPlan {
        wallet: input.wallet,
        challenge: text.into(),
        expires_at,
    };
    plan.message_at(now).map_err(invalid)?;
    wallet.challenge = Some(plan.clone());
    Ok(Json(plan))
}

pub(crate) async fn verify(
    State(state): State<AppState>,
    Json(input): Json<VerifyRequest>,
) -> Result<Json<SessionStatus>> {
    let service = &state.jupiter_trigger;
    let wallet = service.wallet(&input.wallet, false).await?;
    let mut wallet = wallet.lock().await;
    let plan = wallet.challenge.as_ref().ok_or_else(need_auth)?;
    let message = plan.message_at(crate::now()).map_err(invalid)?;
    trigger::verify_message(&plan.wallet, message.as_ref(), &input.signature).map_err(invalid)?;
    wallet.challenge = None;
    let response = service
        .request(
            api_key(&state),
            Method::POST,
            "auth/verify",
            None,
            Some(
                &json!({"walletPubkey":input.wallet, "type":"message", "signature":input.signature,
                    "authMode":"access_refresh"}),
            ),
        )
        .await
        .map_err(ProviderFailure::api)?;
    wallet.tokens = Some(parse_tokens(response)?);
    Ok(Json(SessionStatus {
        authenticated: true,
        configured: true,
    }))
}

impl Service {
    async fn vault(
        &self,
        key: Option<&str>,
        state: &mut WalletState,
        wallet: &str,
        register: bool,
    ) -> Result<String> {
        if let Some(vault) = &state.vault {
            return Ok(vault.clone());
        }
        let first = self
            .authenticated(key, state, Method::GET, "vault", None)
            .await;
        let value = match first {
            Err(ApiError(StatusCode::NOT_FOUND, _)) if register => {
                match self
                    .authenticated(key, state, Method::GET, "vault/register", None)
                    .await
                {
                    Err(ApiError(StatusCode::CONFLICT, _)) => {
                        self.authenticated(key, state, Method::GET, "vault", None)
                            .await?
                    }
                    response => response?,
                }
            }
            response => response?,
        };
        let vault = value["vaultPubkey"]
            .as_str()
            .filter(|address| pubkey(address))
            .ok_or_else(bad_upstream)?;
        if value["userPubkey"] != wallet || vault == wallet {
            return Err(bad_upstream());
        }
        state.vault = Some(vault.to_string());
        Ok(vault.to_string())
    }

    fn lock_deposit(
        &self,
        intent: &str,
        wallet: &str,
        token_account: &str,
        transaction_id: &str,
        block_height: u64,
    ) -> Result<()> {
        let db = self.db.lock().map_err(|_| local_error())?;
        let applied = db
            .execute(
                "INSERT OR IGNORE INTO jupiter_trigger_deposits
             (intent, wallet, order_token_account, transaction_id, last_valid_block_height)
             VALUES (?, ?, ?, ?, ?)",
                params![intent, wallet, token_account, transaction_id, block_height],
            )
            .map_err(|_| local_error())?;
        if applied == 0 {
            return Err(deposit_pending());
        }
        Ok(())
    }

    fn reconcile_deposit(&self, wallet: &str, transaction_id: &str, order: &str) -> Result<()> {
        let db = self.db.lock().map_err(|_| local_error())?;
        db.execute(
            "UPDATE jupiter_trigger_deposits SET order_id = ?, intent = transaction_id
             WHERE wallet = ? AND transaction_id = ?",
            params![order, wallet, transaction_id],
        )
        .map_err(|_| local_error())?;
        Ok(())
    }

    fn pending_deposit(&self, intent: &str) -> Result<Option<PendingDeposit>> {
        let db = self.db.lock().map_err(|_| local_error())?;
        db.query_row(
            "SELECT transaction_id, order_token_account, last_valid_block_height
             FROM jupiter_trigger_deposits WHERE intent = ? AND order_id IS NULL",
            [intent],
            |row| {
                Ok(PendingDeposit {
                    signature: row.get(0)?,
                    token_account: row.get(1)?,
                    last_valid_block_height: row.get(2)?,
                })
            },
        )
        .optional()
        .map_err(|_| local_error())
    }

    fn clear_failed_deposit(&self, intent: &str, transaction_id: &str) -> Result<()> {
        let db = self.db.lock().map_err(|_| local_error())?;
        db.execute(
            "DELETE FROM jupiter_trigger_deposits WHERE intent = ? AND transaction_id = ? AND order_id IS NULL",
            params![intent, transaction_id],
        ).map_err(|_| local_error())?;
        Ok(())
    }
}

struct PendingDeposit {
    signature: String,
    token_account: String,
    last_valid_block_height: u64,
}

impl PendingDeposit {
    async fn can_clear(&self, rpc: &Rpc) -> Result<bool> {
        let Some(failure) =
            transaction_failure(rpc, &self.signature, self.last_valid_block_height).await?
        else {
            return Ok(false);
        };
        let TransactionFailure::Expired { min_slot } = failure else {
            return Ok(true);
        };
        let target = rpc
            .call(
                "getAccountInfo",
                json!([
                    self.token_account,
                    {"commitment":"finalized", "encoding":"base64", "minContextSlot":min_slot}
                ]),
            )
            .await?;
        Ok(target.get("value") == Some(&Value::Null))
    }
}

enum TransactionFailure {
    Rejected,
    Expired { min_slot: u64 },
}

async fn transaction_failure(
    rpc: &Rpc,
    signature: &str,
    last_valid_height: u64,
) -> Result<Option<TransactionFailure>> {
    let history = json!([[signature], {"searchTransactionHistory":true}]);
    let status = rpc.call("getSignatureStatuses", history.clone()).await?;
    let entry = status["value"].get(0).ok_or_else(bad_upstream)?;
    if !entry.is_null() {
        return Ok((entry["confirmationStatus"] == "finalized"
            && entry.get("err").is_some_and(|error| !error.is_null()))
        .then_some(TransactionFailure::Rejected));
    }
    let finalized = rpc
        .call("getEpochInfo", json!([{"commitment":"finalized"}]))
        .await?;
    let height = finalized["blockHeight"].as_u64().ok_or_else(bad_upstream)?;
    let min_slot = finalized["absoluteSlot"]
        .as_u64()
        .ok_or_else(bad_upstream)?;
    if height <= last_valid_height {
        return Ok(None);
    }
    // Different RPC backends may answer at different slots. Only use absence
    // from history if its response has reached the observed finalized height.
    let status = rpc.call("getSignatureStatuses", history).await?;
    let entry = status["value"].get(0).ok_or_else(bad_upstream)?;
    let slot = status["context"]["slot"]
        .as_u64()
        .ok_or_else(bad_upstream)?;
    Ok((entry.is_null() && slot >= min_slot).then_some(TransactionFailure::Expired { min_slot }))
}

fn deposit_pending() -> ApiError {
    ApiError(StatusCode::CONFLICT,
        "An identical Jupiter Trigger deposit may have been submitted. Check Orders and Activity before placing another."
            .into())
}

impl PrepareRequest {
    fn price(&self) -> Result<serde_json::Number> {
        use std::str::FromStr;
        let raw = &self.trigger_price_usd;
        if raw.len() > 32 || raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        {
            return Err(invalid("Enter a positive USD trigger price."));
        }
        let price = bigdecimal::BigDecimal::from_str(raw)
            .map_err(|_| invalid("Enter a positive USD trigger price."))?;
        let number = serde_json::Number::from_str(&price.normalized().to_string())
            .map_err(|_| invalid("Enter a positive USD trigger price."))?;
        if number.as_f64().is_none_or(|n| n <= 0.0 || !n.is_finite())
            || bigdecimal::BigDecimal::from_str(&number.to_string())
                .ok()
                .as_ref()
                != Some(&price)
        {
            return Err(invalid(
                "The USD trigger price exceeds Jupiter’s supported precision.",
            ));
        }
        Ok(number)
    }

    fn validate(&self) -> Result<()> {
        require_wallet(&self.wallet)?;
        if !pubkey(&self.input_mint)
            || !pubkey(&self.output_mint)
            || self.input_mint == self.output_mint
            || ![&self.input_mint, &self.output_mint].contains(&&self.trigger_mint)
            || !matches!(self.trigger_condition.as_str(), "above" | "below")
            || atomic(&self.input_amount).is_none_or(|amount| amount == 0)
            || !(1..=500).contains(&self.slippage_bps)
        {
            return Err(invalid(
                "Choose supported Solana tokens, a positive amount, and a valid price trigger.",
            ));
        }
        self.price()?;
        Ok(())
    }

    fn intent(&self) -> Result<String> {
        use sha2::{Digest, Sha256};
        let bytes = serde_json::to_vec(&(
            &self.wallet,
            &self.input_mint,
            &self.output_mint,
            &self.input_amount,
            &self.trigger_mint,
            &self.trigger_condition,
            self.price()?,
            self.slippage_bps,
        ))
        .map_err(|_| local_error())?;
        Ok(hex::encode(Sha256::digest(bytes)))
    }
}

async fn solana_rpc() -> Result<Rpc> {
    Rpc::for_chain(&wallet::chain_for("solana")?).await
}
fn decode_account(account: &Value) -> Result<Vec<u8>> {
    use base64::{engine::general_purpose::STANDARD, Engine};
    account["data"]
        .get(0)
        .and_then(Value::as_str)
        .and_then(|data| STANDARD.decode(data).ok())
        .ok_or_else(|| invalid("This Solana token account is unavailable."))
}
fn token_precision(account: &Value) -> Result<u8> {
    let data = decode_account(account)?;
    if account["owner"] != trig_wallet_swap_policy::TOKEN || data.len() != 82 || data[45] != 1 {
        return Err(invalid(
            "This Trigger order path supports standard SPL tokens and SOL.",
        ));
    }
    Ok(data[44])
}
async fn mint_pair_precision(rpc: &Rpc, input: &str, output: &str) -> Result<(u8, u8)> {
    let response = rpc
        .call(
            "getMultipleAccounts",
            json!([[input, output], {"encoding":"base64", "commitment":"confirmed"}]),
        )
        .await?;
    let values = response["value"]
        .as_array()
        .filter(|values| values.len() == 2)
        .ok_or_else(|| invalid("Couldn’t validate both Solana mints."))?;
    Ok((token_precision(&values[0])?, token_precision(&values[1])?))
}
async fn transaction_fee_and_rent(rpc: &Rpc, plan: &mut TransferPlan) -> Result<()> {
    use base64::{engine::general_purpose::STANDARD, Engine};
    let now = crate::now();
    let reviewed = plan.inspect_at(now).map_err(invalid)?;
    let fee = rpc.call("getFeeForMessage", json!([
        STANDARD.encode(reviewed.transaction.message.serialize()), {"commitment":"confirmed"}
    ])).await?["value"].as_u64().filter(|fee| *fee > 0)
        .ok_or_else(|| invalid("The Jupiter Trigger transaction blockhash expired. Refresh the review."))?;
    let mut rent = reviewed.seeded_rent_lamports;
    if !reviewed.ata_creations.is_empty() {
        let per_account = rpc
            .call(
                "getMinimumBalanceForRentExemption",
                json!([165, {"commitment":"confirmed"}]),
            )
            .await?
            .as_u64()
            .ok_or_else(|| invalid("Couldn’t verify Solana token-account rent."))?;
        rent = rent
            .checked_add(
                per_account
                    .checked_mul(reviewed.ata_creations.len() as u64)
                    .ok_or_else(|| invalid("Unsupported token-account cost."))?,
            )
            .ok_or_else(|| invalid("Unsupported token-account cost."))?;
    }
    plan.fee_lamports = fee;
    plan.rent_lamports = rent;
    plan.review_at(crate::now()).map_err(invalid)?;
    Ok(())
}

async fn simulate(rpc: &Rpc, plan: &TransferPlan) -> Result<u64> {
    let result = rpc
        .call(
            "simulateTransaction",
            json!([
                plan.transaction, {"encoding":"base64", "commitment":"confirmed", "sigVerify":false}
            ]),
        )
        .await?;
    let simulation = result["value"]
        .as_object()
        .ok_or_else(|| invalid("Couldn’t simulate the Jupiter Trigger transaction."))?;
    if simulation.get("err") != Some(&Value::Null) {
        return Err(invalid("The Jupiter Trigger transaction did not pass simulation. Check balances, then refresh the review."));
    }
    result["context"]["slot"]
        .as_u64()
        .ok_or_else(|| invalid("Couldn’t verify the Solana simulation slot."))
}

fn deposit_terms(
    payload: &Value,
    request: &PrepareRequest,
    vault: &str,
    decimals: u8,
    now: u64,
) -> Result<Review> {
    let plan_id = payload["requestId"]
        .as_str()
        .filter(|id| identifier(id))
        .ok_or_else(bad_upstream)?;
    let token_account = payload["inputTokenAccount"]
        .as_str()
        .filter(|address| pubkey(address))
        .ok_or_else(bad_upstream)?;
    if payload["receiverAddress"] != vault
        || payload["mint"] != request.input_mint
        || payload["amount"] != request.input_amount
        || payload["tokenDecimals"].as_u64() != Some(u64::from(decimals))
    {
        return Err(bad_upstream());
    }
    let transaction = payload["transaction"]
        .as_str()
        .filter(|transaction| !transaction.is_empty() && transaction.len() <= 1644)
        .ok_or_else(bad_upstream)?;
    Ok(Review {
        plan_id: plan_id.into(),
        signing_plan: TransferPlan {
            wallet: request.wallet.clone(),
            vault: vault.into(),
            mint: request.input_mint.clone(),
            order_token_account: token_account.into(),
            amount: request.input_amount.clone(),
            decimals,
            transaction: transaction.into(),
            expires_at: now + REVIEW_TTL,
            direction: TransferDirection::Deposit,
            fee_lamports: 0,
            rent_lamports: 0,
        },
        fee_lamports: "0".into(),
        rent_lamports: "0".into(),
        mint_decimals: decimals,
        order_expires_at: Some(now + ORDER_TTL),
        last_valid_block_height: payload["lastValidBlockHeight"].as_u64().filter(|h| *h > 0),
    })
}

async fn build_review(rpc: &Rpc, review: &mut Review) -> Result<()> {
    transaction_fee_and_rent(rpc, &mut review.signing_plan).await?;
    let slot = simulate(rpc, &review.signing_plan).await?;
    // Simulation accepted the reviewed blockhash in a confirmed bank. The most
    // recent confirmed blockhash will expire at or after that earlier blockhash.
    // This gives receipt polling a conservative upper bound on missing signatures.
    let latest = rpc
        .call(
            "getLatestBlockhash",
            json!([
                {"commitment":"confirmed", "minContextSlot":slot}
            ]),
        )
        .await?;
    review.last_valid_block_height = Some(
        latest["value"]["lastValidBlockHeight"]
            .as_u64()
            .filter(|height| *height > 0)
            .ok_or_else(|| invalid("Couldn’t check the Jupiter Trigger transaction lifetime."))?,
    );
    review
        .signing_plan
        .review_at(crate::now())
        .map_err(invalid)?;
    review.fee_lamports = review.signing_plan.fee_lamports.to_string();
    review.rent_lamports = review.signing_plan.rent_lamports.to_string();
    Ok(())
}

pub(crate) async fn prepare(
    State(state): State<AppState>,
    Json(input): Json<PrepareRequest>,
) -> Result<Json<Value>> {
    input.validate()?;
    let key = api_key(&state);
    let service = &state.jupiter_trigger;
    let wallet = service.wallet(&input.wallet, false).await?;
    let mut wallet = wallet.lock().await;
    let rpc = solana_rpc().await?;
    let intent = input.intent()?;
    if let Some(pending) = service.pending_deposit(&intent)? {
        if pending.can_clear(&rpc).await? {
            service.clear_failed_deposit(&intent, &pending.signature)?;
        } else {
            return Err(deposit_pending());
        }
    }
    let (decimals, _) = mint_pair_precision(&rpc, &input.input_mint, &input.output_mint).await?;
    if input.input_decimals.is_some_and(|value| value != decimals) {
        return Err(invalid(
            "Token decimals changed. Reopen the market before placing an order.",
        ));
    }
    wallet
        .placements
        .retain(|_, plan| plan.expires_at > crate::now());
    if wallet.placements.len() >= MAX_PLANS {
        return Err(invalid(
            "Too many Jupiter Trigger reviews. Wait for an earlier review to expire.",
        ));
    }
    let vault = service.vault(key, &mut wallet, &input.wallet, true).await?;
    let response = service.authenticated(key, &mut wallet, Method::POST, "deposit/craft",
        Some(&json!({
            "inputMint":input.input_mint, "outputMint":input.output_mint, "userAddress":input.wallet,
            "amount":input.input_amount, "orderType":"price", "orderSubType":"single"
        }))).await?;
    let now = crate::now();
    let mut review = deposit_terms(&response, &input, &vault, decimals, now)?;
    build_review(&rpc, &mut review).await?;
    if wallet.placements.contains_key(&review.plan_id) {
        return Err(bad_upstream());
    }
    wallet.placements.insert(
        review.plan_id.clone(),
        Placement {
            request: input,
            review: review.clone(),
            expires_at: review.signing_plan.expires_at,
        },
    );
    Ok(Json(
        serde_json::to_value(review).map_err(|_| local_error())?,
    ))
}

pub(crate) async fn submit(
    State(state): State<AppState>,
    Json(input): Json<SubmitRequest>,
) -> Result<Json<Receipt>> {
    if !identifier(&input.plan_id) || !signature(&input.transaction_id) {
        return Err(invalid("Invalid Jupiter Trigger submission."));
    }
    let key = api_key(&state);
    let service = &state.jupiter_trigger;
    let wallet = service.wallet(&input.wallet, false).await?;
    let mut wallet = wallet.lock().await;
    let plan = wallet
        .placements
        .get(&input.plan_id)
        .filter(|plan| plan.expires_at > crate::now())
        .ok_or_else(|| invalid("Review a fresh Jupiter Trigger order before signing."))?;
    trigger::validate_transfer_signed(
        &plan.review.signing_plan,
        &input.signed,
        &input.transaction_id,
        crate::now(),
    )
    .map_err(invalid)?;
    let plan = wallet
        .placements
        .remove(&input.plan_id)
        .ok_or_else(local_error)?;
    let expiry = plan.review.order_expires_at.ok_or_else(local_error)?;
    let request = &plan.request;
    let price = request.price()?;
    let intent = request.intent()?;
    let block_height = plan
        .review
        .last_valid_block_height
        .ok_or_else(local_error)?;
    service.lock_deposit(
        &intent,
        &input.wallet,
        &plan.review.signing_plan.order_token_account,
        &input.transaction_id,
        block_height,
    )?;
    let value = service.authenticated(key, &mut wallet, Method::POST, "orders/price",
        Some(&json!({
            "orderType":"single", "depositRequestId":input.plan_id, "depositSignedTx":input.signed,
            "userPubkey":request.wallet, "inputMint":request.input_mint, "outputMint":request.output_mint,
            "inputAmount":request.input_amount, "triggerMint":request.trigger_mint,
            "triggerCondition":request.trigger_condition, "triggerPriceUsd":price,
            "slippageBps":request.slippage_bps, "expiresAt":expiry * 1000,
        }))).await?;
    let receipt = receipt(&value, None, &input.transaction_id, false)?;
    service.reconcile_deposit(&input.wallet, &receipt.transaction_id, &receipt.order_id)?;
    Ok(Json(receipt))
}

fn receipt(
    value: &Value,
    expected_order: Option<&str>,
    transaction: &str,
    cancel: bool,
) -> Result<Receipt> {
    let order_id = value["id"]
        .as_str()
        .filter(|id| orders::order_id(id))
        .ok_or_else(bad_upstream)?;
    if expected_order.is_some_and(|expected| expected != order_id)
        || value["txSignature"] != transaction
    {
        return Err(bad_upstream());
    }
    let confirmed = if cancel {
        true
    } else {
        value["depositConfirmed"]
            .as_bool()
            .ok_or_else(bad_upstream)?
    };
    Ok(Receipt {
        order_id: order_id.into(),
        transaction_id: transaction.into(),
        confirmed,
    })
}

pub(crate) use orders::{cancel_challenge, cancel_prepare, cancel_submit, orders};

#[cfg(test)]
mod tests {
    use super::*;

    const WALLET: &str = "FVen3X669xLzsi6N2V91DoiyzHzg1uAgqiT8jZ9nS96Z";
    const VAULT: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    const TOKEN_ACCOUNT: &str = "So11111111111111111111111111111111111111112";

    fn order() -> PrepareRequest {
        PrepareRequest {
            wallet: WALLET.into(),
            input_mint: TOKEN_ACCOUNT.into(),
            output_mint: VAULT.into(),
            input_amount: "1000000000".into(),
            trigger_mint: TOKEN_ACCOUNT.into(),
            trigger_condition: "above".into(),
            trigger_price_usd: "150.00".into(),
            slippage_bps: 50,
            input_decimals: Some(9),
        }
    }

    #[test]
    fn trigger_deposit_response_must_echo_the_reviewed_intent() {
        let request = order();
        let payload = json!({
            "transaction":"fake-unsigned-wire", "requestId":"craft-fixture-1",
            "receiverAddress":VAULT, "mint":TOKEN_ACCOUNT, "amount":request.input_amount,
            "tokenDecimals":9, "inputTokenAccount":TOKEN_ACCOUNT,
        });
        let review = deposit_terms(&payload, &request, VAULT, 9, 100).unwrap();
        assert_eq!(review.plan_id, "craft-fixture-1");
        assert_eq!(review.order_expires_at, Some(100 + ORDER_TTL));
        assert_eq!(review.signing_plan.wallet, WALLET);
        assert_eq!(review.signing_plan.amount, request.input_amount);
        for (field, value) in [
            ("amount", json!("999")),
            ("mint", json!(VAULT)),
            ("receiverAddress", json!(WALLET)),
            ("tokenDecimals", json!(8)),
        ] {
            let mut tampered = payload.clone();
            tampered[field] = value;
            assert!(deposit_terms(&tampered, &request, VAULT, 9, 100).is_err());
        }
    }

    #[test]
    fn trigger_intent_normalizes_decimal_spelling_and_binds_the_direction() {
        let original = order();
        assert!(original.validate().is_ok());
        let mut other = original.clone();
        other.trigger_price_usd = "150".into();
        assert_eq!(original.intent().unwrap(), other.intent().unwrap());
        other.trigger_condition = "below".into();
        assert_ne!(original.intent().unwrap(), other.intent().unwrap());
        other.trigger_price_usd = "150.99999999999999999".into();
        assert!(other.validate().is_err());
        other.trigger_price_usd = "0".into();
        assert!(other.validate().is_err());
    }

    #[test]
    fn trigger_ambiguous_deposit_is_bound_to_the_exact_signature() {
        let service = Service::open(Path::new(":memory:")).unwrap();
        service
            .lock_deposit("intent", WALLET, TOKEN_ACCOUNT, "transaction-one", 100)
            .unwrap();
        assert!(service
            .lock_deposit("intent", WALLET, TOKEN_ACCOUNT, "transaction-two", 200)
            .is_err());
        service
            .reconcile_deposit(VAULT, "transaction-one", "incorrect-wallet")
            .unwrap();
        assert!(service.pending_deposit("intent").unwrap().is_some());
        service
            .reconcile_deposit(WALLET, "transaction-two", "incorrect-signature")
            .unwrap();
        assert!(service.pending_deposit("intent").unwrap().is_some());
        let pending = service.pending_deposit("intent").unwrap().unwrap();
        assert_eq!(pending.signature, "transaction-one");
        assert_eq!(pending.last_valid_block_height, 100);
        service
            .reconcile_deposit(WALLET, "transaction-one", "order-one")
            .unwrap();
        assert!(service.pending_deposit("intent").unwrap().is_none());
        assert!(service
            .lock_deposit("intent", WALLET, TOKEN_ACCOUNT, "transaction-one", 200)
            .is_err());
        service
            .lock_deposit("intent", WALLET, TOKEN_ACCOUNT, "transaction-two", 200)
            .unwrap();
    }

    #[test]
    fn trigger_receipt_needs_the_reviewed_signature_and_order() {
        let order = "eaf80f62-45b6-4fec-86d7-1d1a76d6519e";
        let payload = json!({"id":order, "txSignature":"signature", "depositConfirmed":false});
        let pending = receipt(&payload, None, "signature", false).unwrap();
        assert!(!pending.confirmed);
        assert!(receipt(&payload, None, "different-signature", false).is_err());
        assert!(receipt(&payload, Some("another-order"), "signature", true).is_err());
        assert!(
            receipt(&payload, Some(order), "signature", true)
                .unwrap()
                .confirmed
        );
    }
}
