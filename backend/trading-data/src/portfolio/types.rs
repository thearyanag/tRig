use bigdecimal::{BigDecimal, Zero};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
use std::str::FromStr;

type Number = BigDecimal;
pub fn number(value: &Value) -> Option<Number> {
    let text = match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return None,
    };
    if text.len() > 320 {
        return None;
    }
    let value = Number::from_str(&text).ok()?;
    let (_, scale) = value.as_bigint_and_exponent();
    (scale.unsigned_abs() <= 320).then_some(value)
}
pub fn text(value: &Number) -> String {
    value.normalized().to_string()
}
pub fn string(value: Option<Number>) -> Option<String> {
    value.as_ref().map(text)
}
pub fn percent(pnl: &Number, basis: &Number) -> Option<Number> {
    (basis > &Number::zero()).then(|| pnl / basis * Number::from(100))
}
pub fn nonnegative(value: &Value) -> Option<Number> {
    number(value).filter(|n| n >= &Number::zero())
}
pub fn amount(value: &Value, decimals: Option<u64>) -> Option<Number> {
    if let (Some(raw), Some(decimals)) = (value.as_str(), decimals.filter(|d| *d <= 255)) {
        if raw.len() <= 256 && !raw.is_empty() && raw.bytes().all(|c| c.is_ascii_digit()) {
            return Number::from_str(&format!("{raw}e-{decimals}")).ok();
        }
    }
    None
}
pub fn chain(network: &Value, explicit: &Value, mint: &str) -> String {
    if let Some(value) = explicit.as_str().filter(|s| !s.is_empty()) {
        let value = value.to_lowercase();
        let canonical = match value.as_str() {
            "solana" => Some("solana"),
            "ethereum" | "eth" => Some("eip155:1"),
            "base" => Some("eip155:8453"),
            "bsc" | "bnb" | "binance-smart-chain" => Some("eip155:56"),
            "monad" => Some("eip155:143"),
            "robinhood" => Some("eip155:4663"),
            "arc" => Some("eip155:5042"),
            "elysium" => Some("eip155:99901"),
            "hyperliquid" => Some("hyperliquid:mainnet"),
            _ => None,
        };
        if let Some(canonical) = canonical {
            return canonical.into();
        }
        if value.starts_with("solana:") {
            return "solana".into();
        }
        return value;
    }
    match network
        .as_i64()
        .or_else(|| network.as_str().and_then(|s| s.parse().ok()))
    {
        Some(1399811149) => "solana".into(),
        Some(1337) => "hyperliquid:mainnet".into(),
        Some(n) if n > 0 => format!("eip155:{n}"),
        _ if mint.starts_with("0x") => "unknown-evm".into(),
        _ => "unknown".into(),
    }
}
pub fn address(value: &str) -> String {
    if value.starts_with("0x") {
        value.to_lowercase()
    } else {
        value.to_owned()
    }
}
pub fn valid_wallet(value: &str) -> bool {
    crate::discovery::is_address(value)
        || (value.len() == 42
            && value.starts_with("0x")
            && value[2..].bytes().all(|c| c.is_ascii_hexdigit()))
}
pub fn https(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|s| s.len() <= 4096 && s.starts_with("https://"))
        .map(str::to_owned)
}
pub const SOL: &str = "So11111111111111111111111111111111111111112";
pub const USDC: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Hash, Eq, PartialEq, Ord, PartialOrd)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Pump,
    Fomo,
}
impl Source {
    pub fn name(self) -> &'static str {
        match self {
            Self::Pump => "Pumpfun",
            Self::Fomo => "Fomo",
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq)]
pub enum Period {
    #[serde(rename = "1d")]
    Day,
    #[serde(rename = "7d")]
    Week,
    #[serde(rename = "30d")]
    Month,
    #[serde(rename = "all")]
    All,
}
impl Period {
    pub fn seconds(self) -> Option<i64> {
        match self {
            Self::Day => Some(86400),
            Self::Week => Some(7 * 86400),
            Self::Month => Some(30 * 86400),
            Self::All => None,
        }
    }
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PortfolioIssue {
    pub source: Source,
    pub message: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PortfolioRequest {
    pub period: Period,
    pub providers: Vec<ProviderInput>,
    #[serde(default)]
    pub issues: Vec<PortfolioIssue>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProviderInput {
    pub source: Source,
    pub account_wallet: String,
    pub evm_wallet: Option<String>,
    pub period: Period,
    pub fetched_at: f64,
    #[serde(default)]
    pub stale: bool,
    pub data: Value,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub source: Source,
    pub fetched_at: f64,
    pub wallets: BTreeSet<String>,
    pub total: Option<Number>,
    pub pnl: Option<Number>,
    pub pnl_percent: Option<Number>,
    pub lots: Vec<Lot>,
    pub history: Vec<Point>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Lot {
    pub id: String,
    pub chain: String,
    pub mint: String,
    pub wallet: String,
    pub name: String,
    pub symbol: String,
    pub image_url: Option<String>,
    pub quantity: Option<String>,
    pub price_usd: Option<String>,
    pub value_usd: Option<String>,
    pub cost_basis_usd: Option<String>,
    pub average_entry_usd: Option<String>,
    pub pnl_percent: Option<String>,
    pub pnl_usd: Option<String>,
    pub sources: Vec<Source>,
    pub warnings: Vec<String>,
    pub fetched_at: f64,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Point {
    pub time: i64,
    pub value: Number,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortfolioViews {
    pub all: PortfolioView,
    pub pump: PortfolioView,
    pub fomo: PortfolioView,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortfolioView {
    pub scope: String,
    pub period: Period,
    pub total_value_usd: Option<String>,
    pub period_pnl_usd: Option<String>,
    pub period_pnl_percent: Option<String>,
    pub unrealized_pnl_usd: Option<String>,
    pub unrealized_pnl_percent: Option<String>,
    pub holdings: Vec<Holding>,
    pub history: Vec<HistoryPoint>,
    pub source_count: usize,
    pub as_of: Option<f64>,
    pub warnings: Vec<String>,
    pub history_message: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Holding {
    pub id: String,
    pub chain: String,
    pub mint: String,
    pub market_mint: Option<String>,
    pub name: String,
    pub symbol: String,
    pub image_url: Option<String>,
    pub quantity: Option<String>,
    pub price_usd: Option<String>,
    pub value_usd: Option<String>,
    pub average_entry_usd: Option<String>,
    pub pnl_usd: Option<String>,
    pub pnl_percent: Option<String>,
    pub sources: Vec<Source>,
    pub lots: Vec<Lot>,
    pub warnings: Vec<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryPoint {
    pub time: i64,
    pub value_usd: String,
    pub segment: usize,
}
