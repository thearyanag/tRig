use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Jupiter,
    Relay,
    Flash,
}
impl Provider {
    pub fn name(self) -> &'static str {
        match self {
            Self::Jupiter => "Jupiter",
            Self::Relay => "Relay",
            Self::Flash => "Definitive Flash",
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "kebab-case")]
pub enum OrderType {
    Market,
    Limit,
    StopLoss,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TokenRef {
    pub chain: String,
    pub address: String,
}
#[derive(Clone, Debug, Deserialize, Serialize, Default, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QuoteContext {
    pub sender: Option<String>,
    pub recipient: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QuoteRequest {
    pub provider: Option<Provider>,
    pub side: Option<crate::quotes::Side>,
    pub input: TokenRef,
    pub output: TokenRef,
    pub amount: String,
    pub order_type: OrderType,
    pub slippage_bps: u16,
    pub limit_price_usd: Option<String>,
    pub trigger_price_usd: Option<String>,
    #[serde(default)]
    pub context: QuoteContext,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Token {
    pub chain: String,
    pub address: String,
    pub symbol: String,
    pub decimals: Option<u8>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chain {
    pub id: String,
    pub name: String,
    pub vm: String,
    pub provider_id: String,
    pub enabled: bool,
    pub deposit_enabled: bool,
    pub native_token: Option<Token>,
    pub minimum_order_usd: Option<String>,
    #[serde(default, skip_serializing)]
    pub rpc_url: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    pub id: Provider,
    pub name: &'static str,
    pub configured: bool,
    pub order_types: Vec<OrderType>,
    pub chains: Vec<Chain>,
    pub metadata_source: String,
    pub warning: Option<String>,
    pub metadata_as_of: u64,
    pub sender_required: bool,
    pub sender_required_cross_chain: bool,
    pub recipient_required_cross_chain: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Fee {
    pub kind: String,
    pub amount_usd: Option<String>,
    pub amount: Option<String>,
    pub token: Option<Token>,
    pub rate_bps: Option<u16>,
    pub included_in_quote: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Quote {
    pub provider: Provider,
    pub provider_name: &'static str,
    pub provider_quote_id: Option<String>,
    pub input: Token,
    pub output: Token,
    pub order_type: OrderType,
    pub requested_amount: String,
    pub pay_amount: String,
    pub receive_amount: String,
    pub minimum_receive: Option<String>,
    pub slippage_bps: u16,
    pub price_impact_percent: Option<String>,
    pub fees: Vec<Fee>,
    pub routes: Vec<String>,
    pub fetched_at: u64,
    pub expires_at: u64,
    pub expiry_kind: &'static str,
    pub indicative: bool,
    pub warnings: Vec<String>,
    pub request: QuoteRequest,
}
#[derive(Debug)]
pub struct Error {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
}
impl Error {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }
    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "invalid_request", message)
    }
    pub fn inconsistent(provider: Provider) -> Self {
        Self::new(
            StatusCode::BAD_GATEWAY,
            "invalid_provider_response",
            format!(
                "{} returned an inconsistent quote. Try refreshing.",
                provider.name()
            ),
        )
    }
}
impl IntoResponse for Error {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({"error":self.message,"code":self.code})),
        )
            .into_response()
    }
}
pub type Result<T> = std::result::Result<T, Error>;

impl Token {
    pub fn precision(&self, provider: Provider) -> Result<u8> {
        self.decimals.ok_or_else(|| Error::inconsistent(provider))
    }
}
