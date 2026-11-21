use crate::{discovery::is_address, ApiError, AppState};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const USDC: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Hash)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QuoteQuery {
    pub asset_mint: String,
    pub side: Side,
    pub amount: String,
    pub slippage_bps: u16,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Buy,
    Sell,
}
#[derive(Clone, Deserialize)]
pub struct Token {
    pub id: String,
    pub symbol: String,
    pub decimals: u8,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SwapQuote {
    pub asset_mint: String,
    pub side: Side,
    pub input_mint: String,
    pub requested_amount: String,
    pub output_mint: String,
    pub in_amount: String,
    pub out_amount: String,
    pub input_decimals: u8,
    pub output_decimals: u8,
    pub pay_amount: String,
    pub pay_symbol: String,
    pub receive_amount: String,
    pub receive_symbol: String,
    pub minimum_receive: String,
    pub slippage_bps: u16,
    pub fee_bps: u16,
    pub fee_symbol: String,
    pub price_impact_percent: Option<f64>,
    pub routes: Vec<String>,
    pub router: String,
    pub fetched_at: u64,
    pub expires_at: u64,
}

fn bad(message: &str) -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, message.into())
}
fn invalid_response() -> ApiError {
    ApiError(
        StatusCode::BAD_GATEWAY,
        "Jupiter returned an inconsistent quote. Refresh to try again.".into(),
    )
}

/// Decimal text to raw SPL units, with no float conversion or silent rounding.
pub fn atomic(text: &str, decimals: u8) -> Result<u64, ApiError> {
    let (whole, fraction) = amount_parts(text)?;
    let fraction = fraction.trim_end_matches('0');
    if fraction.len() > usize::from(decimals) {
        return Err(bad(
            "Amount has more precision than the input token supports.",
        ));
    }
    let raw = format!(
        "{}{}{}",
        whole.trim_start_matches('0'),
        fraction,
        "0".repeat(usize::from(decimals) - fraction.len())
    );
    let amount = raw
        .trim_start_matches('0')
        .parse::<u64>()
        .map_err(|_| bad("Amount is zero or outside the supported token range."))?;
    if amount == 0 {
        return Err(bad("Enter a positive amount."));
    }
    Ok(amount)
}

fn amount_parts(text: &str) -> Result<(&str, &str), ApiError> {
    let text = text.trim();
    if text.is_empty() || text.len() > 300 {
        return Err(bad("Enter a positive amount."));
    }
    let mut parts = text.split('.');
    let whole = parts.next().unwrap_or("");
    let fraction = parts.next().unwrap_or("");
    if parts.next().is_some()
        || (whole.is_empty() && fraction.is_empty())
        || !whole
            .bytes()
            .chain(fraction.bytes())
            .all(|b| b.is_ascii_digit())
    {
        return Err(bad(
            "Use positive digits and a decimal point for the amount.",
        ));
    }
    if !whole
        .bytes()
        .chain(fraction.bytes())
        .any(|byte| byte != b'0')
    {
        return Err(bad("Enter a positive amount."));
    }
    Ok((whole, fraction))
}

pub fn units(amount: u64, decimals: u8) -> String {
    if decimals == 0 {
        return amount.to_string();
    }
    let raw = format!("{:0>width$}", amount, width = usize::from(decimals) + 1);
    let point = raw.len() - usize::from(decimals);
    let value = format!("{}.{}", &raw[..point], &raw[point..]);
    value
        .trim_end_matches('0')
        .trim_end_matches('.')
        .to_string()
}

pub fn order_url(query: &QuoteQuery, input: &Token, output: &Token, amount: u64) -> reqwest::Url {
    let mut url =
        reqwest::Url::parse("https://api.jup.ag/swap/v2/order").expect("fixed Jupiter URL");
    url.query_pairs_mut()
        .append_pair("inputMint", &input.id)
        .append_pair("outputMint", &output.id)
        .append_pair("amount", &amount.to_string())
        .append_pair("slippageBps", &query.slippage_bps.to_string());
    // Deliberately no taker, payer, receiver or wallet. This returns transaction:null.
    url
}

pub fn normalize_quote(
    value: &Value,
    query: &QuoteQuery,
    input: &Token,
    output: &Token,
    amount: u64,
    at: u64,
) -> Result<SwapQuote, ApiError> {
    if value.get("transaction") != Some(&Value::Null)
        || !value["taker"].is_null()
        || value["inputMint"] != input.id
        || value["outputMint"] != output.id
        || value["swapMode"] != "ExactIn"
        || value["slippageBps"].as_u64() != Some(u64::from(query.slippage_bps))
    {
        return Err(invalid_response());
    }
    let parse = |key: &str| {
        value[key]
            .as_str()
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or_else(invalid_response)
    };
    if parse("inAmount")? != amount {
        return Err(invalid_response());
    }
    let receive = parse("outAmount")?;
    let minimum = parse("otherAmountThreshold")?;
    if receive == 0 || minimum == 0 || minimum > receive {
        return Err(invalid_response());
    }
    let fee_bps = value["feeBps"]
        .as_u64()
        .filter(|bps| *bps <= 10000)
        .ok_or_else(invalid_response)? as u16;
    let fee_mint = value["feeMint"].as_str().filter(|mint| is_address(mint));
    if fee_bps > 0 && fee_mint.is_none() {
        return Err(invalid_response());
    }
    let fee_symbol = if fee_mint == Some(input.id.as_str()) {
        input.symbol.clone()
    } else if fee_mint == Some(output.id.as_str()) {
        output.symbol.clone()
    } else if let Some(fee_mint) = fee_mint {
        format!("{}…{}", &fee_mint[..4], &fee_mint[fee_mint.len() - 4..])
    } else {
        String::new()
    };
    let mut routes = Vec::new();
    if let Some(legs) = value["routePlan"].as_array() {
        for leg in legs {
            if let Some(label) = leg["swapInfo"]["label"].as_str() {
                if !routes.iter().any(|v| v == label) {
                    routes.push(label.to_string());
                }
            }
        }
    }
    Ok(SwapQuote {
        asset_mint: query.asset_mint.clone(),
        side: query.side,
        requested_amount: query.amount.clone(),
        input_mint: input.id.clone(),
        output_mint: output.id.clone(),
        in_amount: amount.to_string(),
        out_amount: receive.to_string(),
        input_decimals: input.decimals,
        output_decimals: output.decimals,
        pay_amount: units(amount, input.decimals),
        pay_symbol: input.symbol.clone(),
        receive_amount: units(receive, output.decimals),
        receive_symbol: output.symbol.clone(),
        minimum_receive: units(minimum, output.decimals),
        slippage_bps: query.slippage_bps,
        fee_bps,
        fee_symbol,
        price_impact_percent: value["priceImpact"].as_f64().filter(|n| n.is_finite()),
        routes,
        router: value["router"].as_str().unwrap_or("Jupiter").into(),
        fetched_at: at,
        expires_at: at + 20,
    })
}

pub async fn quote(
    State(state): State<AppState>,
    Query(mut query): Query<QuoteQuery>,
) -> Result<Json<SwapQuote>, ApiError> {
    query.amount = query.amount.trim().to_string();
    if !is_address(&query.asset_mint) {
        return Err(bad("Choose a valid Solana asset."));
    }
    if query.asset_mint == USDC {
        return Err(bad("USDC is the quote currency. Choose another asset."));
    }
    if !(1..=500).contains(&query.slippage_bps) {
        return Err(bad("Unsupported slippage tolerance."));
    }
    let (input, output) = if query.side == Side::Buy {
        (USDC, query.asset_mint.as_str())
    } else {
        (query.asset_mint.as_str(), USDC)
    };
    let common = crate::execution::fetch(
        &state,
        crate::execution::types::QuoteRequest {
            provider: Some(crate::execution::types::Provider::Jupiter),
            side: Some(query.side),
            input: crate::execution::types::TokenRef {
                chain: "solana".into(),
                address: input.into(),
            },
            output: crate::execution::types::TokenRef {
                chain: "solana".into(),
                address: output.into(),
            },
            amount: query.amount.clone(),
            order_type: crate::execution::types::OrderType::Market,
            slippage_bps: query.slippage_bps,
            limit_price_usd: None,
            trigger_price_usd: None,
            context: Default::default(),
        },
    )
    .await
    .map_err(|e| ApiError(e.status, e.message))?;
    let fee = common.fees.first();
    let result = SwapQuote {
        asset_mint: query.asset_mint,
        side: query.side,
        requested_amount: query.amount,
        input_mint: common.input.address.clone(),
        output_mint: common.output.address.clone(),
        in_amount: crate::execution::amounts::atomic(
            &common.pay_amount,
            common.input.decimals.ok_or_else(invalid_response)?,
        )
        .map_err(|_| invalid_response())?,
        out_amount: crate::execution::amounts::atomic(
            &common.receive_amount,
            common.output.decimals.ok_or_else(invalid_response)?,
        )
        .map_err(|_| invalid_response())?,
        input_decimals: common.input.decimals.ok_or_else(invalid_response)?,
        output_decimals: common.output.decimals.ok_or_else(invalid_response)?,
        pay_amount: common.pay_amount,
        pay_symbol: common.input.symbol,
        receive_amount: common.receive_amount,
        receive_symbol: common.output.symbol,
        minimum_receive: common.minimum_receive.ok_or_else(invalid_response)?,
        slippage_bps: common.slippage_bps,
        fee_bps: fee.and_then(|f| f.rate_bps).unwrap_or(0),
        fee_symbol: fee
            .and_then(|f| f.token.as_ref())
            .map(|t| t.symbol.clone())
            .unwrap_or_default(),
        price_impact_percent: common
            .price_impact_percent
            .and_then(|s| s.parse::<f64>().ok()),
        router: "Jupiter".into(),
        routes: common.routes,
        fetched_at: common.fetched_at,
        expires_at: common.expires_at,
    };
    Ok(Json(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    const SOL: &str = "So11111111111111111111111111111111111111112";
    fn query() -> QuoteQuery {
        QuoteQuery {
            asset_mint: SOL.into(),
            side: Side::Buy,
            amount: "100".into(),
            slippage_bps: 50,
        }
    }
    fn tokens() -> (Token, Token) {
        (
            Token {
                id: USDC.into(),
                symbol: "USDC".into(),
                decimals: 6,
            },
            Token {
                id: SOL.into(),
                symbol: "SOL".into(),
                decimals: 9,
            },
        )
    }
    fn response() -> Value {
        json!({"transaction":null,"taker":null,"inputMint":USDC,"outputMint":SOL,"swapMode":"ExactIn","slippageBps":50,"inAmount":"100000000","outAmount":"1000000001","otherAmountThreshold":"995000000","feeBps":2,"feeMint":SOL,"priceImpact":-0.02,"router":"metis","routePlan":[{"swapInfo":{"label":"Venue"}}]})
    }
    #[test]
    fn exact_amounts_do_not_round_or_use_floating_point() {
        assert_eq!(atomic("100", 6).unwrap(), 100000000);
        assert_eq!(atomic(".000000001", 9).unwrap(), 1);
        assert_eq!(atomic("1.0000000", 6).unwrap(), 1000000);
        assert_eq!(units(1000000001, 9), "1.000000001");
        for text in ["0", "-1", "1e3", "1,000", "NaN", "1.2.3"] {
            assert!(atomic(text, 6).is_err());
        }
        assert!(atomic("0.0000001", 6).is_err());
        assert!(atomic("18446744073709551616", 0).is_err());
    }
    #[test]
    fn requests_are_quote_only_and_unknown_wallet_fields_are_rejected() {
        let (input, output) = tokens();
        let url = order_url(&query(), &input, &output, 100000000);
        assert_eq!(url.path(), "/swap/v2/order");
        assert!(!url
            .query_pairs()
            .any(|(key, _)| ["taker", "payer", "receiver"].contains(&key.as_ref())));
        assert!(serde_json::from_value::<QuoteQuery>(
            json!({"assetMint":SOL,"side":"buy","amount":"1","slippageBps":50,"taker":SOL})
        )
        .is_err());
    }
    #[test]
    fn provider_threshold_and_fees_are_preserved() {
        let (input, output) = tokens();
        let result =
            normalize_quote(&response(), &query(), &input, &output, 100000000, 100).unwrap();
        assert_eq!(result.receive_amount, "1.000000001");
        assert_eq!(result.minimum_receive, "0.995");
        assert_eq!(result.fee_bps, 2);
        assert_eq!(result.price_impact_percent, Some(-0.02));
        assert_eq!(result.expires_at, 120);
    }
    #[test]
    fn zero_fee_quotes_do_not_invent_a_fee_token() {
        let (input, output) = tokens();
        let mut body = response();
        body["feeBps"] = json!(0);
        body["feeMint"] = Value::Null;
        let result = normalize_quote(&body, &query(), &input, &output, 100000000, 100).unwrap();
        assert_eq!(result.fee_bps, 0);
        assert_eq!(result.fee_symbol, "");
    }
    #[test]
    fn mismatched_or_transaction_bearing_responses_fail_closed() {
        let (input, output) = tokens();
        for (key, value) in [
            ("inputMint", json!(SOL)),
            ("inAmount", json!("1")),
            ("slippageBps", json!(100)),
            ("transaction", json!("unexpected")),
            ("otherAmountThreshold", json!("2000000000")),
        ] {
            let mut body = response();
            body[key] = value;
            assert!(normalize_quote(&body, &query(), &input, &output, 100000000, 100).is_err());
        }
    }
}
