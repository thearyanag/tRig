use crate::{chain_registry, execution::amounts, provider_json, wallet, ApiError, AppState};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use bigdecimal::{num_bigint::BigUint, BigDecimal};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

const SPL_TOKEN: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const SPL_TOKEN_2022: &str = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
const WRAPPED_SOL: &str = "So11111111111111111111111111111111111111112";

#[derive(Deserialize)]
pub struct HoldingsQuery {
    chain: String,
    address: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Holdings {
    chain: String,
    address: String,
    tokens: Vec<HoldingToken>,
    warnings: Vec<String>,
    as_of: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HoldingToken {
    address: Option<String>,
    market_mint: Option<String>,
    name: String,
    symbol: String,
    quantity: String,
    decimals: u8,
    image_url: Option<String>,
    price_usd: Option<String>,
}

pub async fn holdings(
    State(state): State<AppState>,
    Query(query): Query<HoldingsQuery>,
) -> Result<Json<Holdings>, ApiError> {
    let chain = wallet::chain_for(&query.chain)?;
    let entry = chain_registry::get(&query.chain).expect("registered wallet network");
    if !amounts::address(&chain.vm, &query.address) {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Invalid wallet address.".into(),
        ));
    }

    let mut warnings = Vec::new();
    let mut tokens = Vec::new();
    let rpc = wallet::Rpc::for_chain(&chain).await;
    let mut native_read = false;
    let mut token_read = false;
    if let Ok(rpc) = &rpc {
        let valid_rpc = chain.vm != "evm" || rpc.verify_evm(&chain).await.is_ok();
        if valid_rpc {
            if let Ok(amount) = wallet::atomic_balance(rpc, &chain, &query.address).await {
                if let Ok(quantity) = wallet::format_amount(&amount, &chain) {
                    native_read = true;
                    if amount != BigUint::ZERO {
                        tokens.push(HoldingToken {
                            address: None,
                            market_mint: (query.chain == "solana").then(|| WRAPPED_SOL.into()),
                            name: entry.currency.name.clone(),
                            symbol: entry.currency.symbol.clone(),
                            quantity,
                            decimals: entry.currency.decimals,
                            image_url: None,
                            price_usd: native_price(&state, entry).await,
                        });
                    }
                }
            }
            if query.chain == "solana" {
                let (classic, extended) = tokio::join!(
                    solana_accounts(rpc, &query.address, SPL_TOKEN),
                    solana_accounts(rpc, &query.address, SPL_TOKEN_2022)
                );
                token_read = classic.is_some() || extended.is_some();
                if classic.is_none() || extended.is_none() {
                    warnings.push("Some SPL balances could not be loaded on Solana.".into());
                }
                tokens.extend(solana_tokens(classic.into_iter().chain(extended)));
                enrich_solana(&state, &mut tokens).await;
            }
        }
    }
    if !native_read {
        warnings.push(format!(
            "Native balance could not be loaded on {}.",
            entry.display_name
        ));
    }
    if chain.vm == "evm" {
        match explorer(entry.id) {
            Some(host) => {
                let result = erc20_tokens(&state, host, &query.address).await;
                if let Some(rows) = result {
                    token_read = true;
                    tokens.extend(rows);
                } else {
                    warnings.push(format!(
                        "ERC-20 balances could not be loaded on {}.",
                        entry.display_name
                    ));
                }
            }
            None => warnings.push(format!(
                "ERC-20 discovery is unavailable on {}.",
                entry.display_name
            )),
        }
    } else if rpc.is_err() {
        warnings.push("SPL balances could not be loaded on Solana.".into());
    }
    if !native_read && !token_read {
        return Err(ApiError(StatusCode::BAD_GATEWAY, warnings.join(" ")));
    }
    Ok(Json(Holdings {
        chain: query.chain,
        address: query.address,
        tokens,
        warnings,
        as_of: crate::now(),
    }))
}

async fn solana_accounts(rpc: &wallet::Rpc, owner: &str, program: &str) -> Option<Value> {
    let value = rpc.call(
        "getTokenAccountsByOwner",
        json!([owner, {"programId":program}, {"encoding":"jsonParsed","commitment":"confirmed"}]),
    ).await.ok()?;
    value["value"].is_array().then_some(value)
}

fn solana_tokens(pages: impl IntoIterator<Item = Value>) -> Vec<HoldingToken> {
    let mut balances = BTreeMap::<String, (u8, BigUint)>::new();
    for page in pages {
        for row in page["value"].as_array().into_iter().flatten() {
            let info = &row["account"]["data"]["parsed"]["info"];
            let Some(mint) = info["mint"].as_str().filter(|v| amounts::address("svm", v)) else {
                continue;
            };
            let balance = &info["tokenAmount"];
            let Some(decimals) = balance["decimals"]
                .as_u64()
                .and_then(|v| u8::try_from(v).ok())
            else {
                continue;
            };
            let Some(amount) = balance["amount"]
                .as_str()
                .and_then(|v| v.parse::<u64>().ok())
            else {
                continue;
            };
            if amount > 0 {
                let (expected, total) = balances
                    .entry(mint.into())
                    .or_insert((decimals, BigUint::ZERO));
                if *expected == decimals {
                    *total += amount;
                }
            }
        }
    }
    balances
        .into_iter()
        .filter_map(|(mint, (decimals, amount))| {
            Some(HoldingToken {
                market_mint: Some(mint.clone()),
                address: Some(mint.clone()),
                symbol: short_address(&mint),
                name: "SPL token".into(),
                quantity: amounts::units(&amount.to_string(), decimals)?,
                decimals,
                image_url: None,
                price_usd: None,
            })
        })
        .collect()
}

async fn enrich_solana(state: &AppState, tokens: &mut [HoldingToken]) {
    let mut token_rows: Vec<_> = tokens
        .iter_mut()
        .filter(|row| row.address.is_some())
        .collect();
    for rows in token_rows.chunks_mut(25).take(2) {
        let addresses = rows
            .iter()
            .filter_map(|row| row.address.as_deref())
            .collect::<Vec<_>>()
            .join(",");
        let url = crate::execution::service::url(&format!(
            "https://api.geckoterminal.com/api/v2/networks/solana/tokens/multi/{addresses}"
        ));
        let Ok(value) = provider_json(state, url).await else {
            return;
        };
        let Some(response_rows) = value["data"].as_array() else {
            continue;
        };
        for row in rows {
            let Some(attributes) = response_rows
                .iter()
                .map(|item| &item["attributes"])
                .find(|attrs| attrs["address"].as_str() == row.address.as_deref())
            else {
                continue;
            };
            if let Some(name) = bounded_text(&attributes["name"], 80) {
                row.name = name;
            }
            if let Some(symbol) = bounded_text(&attributes["symbol"], 20) {
                row.symbol = symbol;
            }
            row.image_url = https_image(&attributes["image_url"]);
            row.price_usd = price(&attributes["price_usd"]);
        }
    }
}

fn explorer(id: u64) -> Option<&'static str> {
    Some(match id {
        1 => "eth.blockscout.com",
        10 => "optimism.blockscout.com",
        130 => "unichain.blockscout.com",
        137 => "polygon.blockscout.com",
        999 => "www.hyperscan.com",
        4326 => "megaeth.blockscout.com",
        4663 => "robinhoodchain.blockscout.com",
        5042 => "explorer.arc.io",
        8453 => "base.blockscout.com",
        42161 => "arbitrum.blockscout.com",
        57073 => "explorer.inkonchain.com",
        _ => return None,
    })
}

async fn erc20_tokens(state: &AppState, host: &str, owner: &str) -> Option<Vec<HoldingToken>> {
    let url = format!("https://{host}/api/v2/addresses/{owner}/token-balances");
    let mut response = state
        .client
        .get(url)
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?;
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        if body.len() + chunk.len() > 512 * 1024 {
            return None;
        }
        body.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&body).ok()?;
    Some(erc20_rows(value.as_array()?))
}

fn erc20_rows(rows: &[Value]) -> Vec<HoldingToken> {
    let mut tokens = BTreeMap::new();
    for row in rows {
        let token = &row["token"];
        if token["type"].as_str() != Some("ERC-20") {
            continue;
        }
        let Some(address) = token["address_hash"]
            .as_str()
            .or_else(|| token["address"].as_str())
            .filter(|v| {
                amounts::address("evm", v) && *v != "0x0000000000000000000000000000000000000000"
            })
            .map(str::to_ascii_lowercase)
        else {
            continue;
        };
        let Some(decimals) = token["decimals"]
            .as_u64()
            .and_then(|v| u8::try_from(v).ok())
            .or_else(|| token["decimals"].as_str()?.parse::<u8>().ok())
        else {
            continue;
        };
        let Some(raw) = row["value"]
            .as_str()
            .filter(|v| v.len() <= 78 && v.bytes().any(|b| b != b'0'))
        else {
            continue;
        };
        let Some(quantity) = amounts::units(raw, decimals) else {
            continue;
        };
        tokens
            .entry(address.clone())
            .or_insert_with(|| HoldingToken {
                market_mint: Some(address.clone()),
                address: Some(address.clone()),
                name: bounded_text(&token["name"], 80).unwrap_or_else(|| "ERC-20 token".into()),
                symbol: bounded_text(&token["symbol"], 20)
                    .unwrap_or_else(|| short_address(&address)),
                quantity,
                decimals,
                image_url: https_image(&token["icon_url"]),
                price_usd: price(&token["exchange_rate"]),
            });
    }
    tokens.into_values().collect()
}

async fn native_price(state: &AppState, entry: &chain_registry::Entry) -> Option<String> {
    let id = match entry.currency.symbol.as_str() {
        "SOL" => "solana",
        "ETH" => "ethereum",
        "USDC" => "usd-coin",
        "BNB" => "binancecoin",
        "POL" => "polygon-ecosystem-token",
        "HYPE" => "hyperliquid",
        "AVAX" => "avalanche-2",
        "MNT" => "mantle",
        "CRO" => "crypto-com-chain",
        "S" => "sonic-3",
        "BERA" => "berachain-bera",
        "MON" => "monad",
        "OKB" => "okb",
        "XPL" => "plasma",
        _ => return None,
    };
    let url = crate::execution::service::url(concat!(
        "https://api.coingecko.com/api/v3/simple/price?vs_currencies=usd&ids=",
        "avalanche-2,berachain-bera,binancecoin,crypto-com-chain,ethereum,hyperliquid,mantle,",
        "monad,okb,plasma,polygon-ecosystem-token,solana,sonic-3,usd-coin"
    ));
    price(&provider_json(state, url).await.ok()?[id]["usd"])
}

fn price(value: &Value) -> Option<String> {
    let raw = match value {
        Value::Number(number) => number.to_string(),
        Value::String(number) => number.clone(),
        _ => return None,
    };
    if raw.len() > 48 {
        return None;
    }
    let amount = raw.parse::<BigDecimal>().ok()?;
    let (_, scale) = amount.as_bigint_and_exponent();
    (amount > BigDecimal::from(0) && (-30..=30).contains(&scale)).then(|| amount.to_plain_string())
}

fn bounded_text(value: &Value, length: usize) -> Option<String> {
    let value: String = value
        .as_str()?
        .trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(length)
        .collect();
    (!value.is_empty()).then_some(value)
}

fn https_image(value: &Value) -> Option<String> {
    let raw = value.as_str().filter(|v| v.len() <= 512)?;
    let url = reqwest::Url::parse(raw).ok()?;
    (url.scheme() == "https" && url.username().is_empty() && url.password().is_none())
        .then(|| url.to_string())
}

fn short_address(value: &str) -> String {
    format!("{}…{}", &value[..5], &value[value.len() - 4..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spl_balances_sum_exact_atomic_units_by_mint() {
        let mint = "So11111111111111111111111111111111111111112";
        let row = |amount: &str| {
            json!({"account":{"data":{"parsed":{"info":{
                "mint":mint,"tokenAmount":{"amount":amount,"decimals":9}
            }}}}})
        };
        let rows = solana_tokens([json!({"value":[row("9007199254740992"),row("1")]})]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].quantity, "9007199.254740993");
    }

    #[test]
    fn erc20_balances_use_contract_and_skip_nfts_and_zero_rows() {
        let token = |kind: &str, balance: &str| {
            json!({"value":balance,"token":{
                "type":kind,"address_hash":"0x1234567890123456789012345678901234567890",
                "name":"Example","symbol":"EX","decimals":"18","exchange_rate":"0.0000123"
            }})
        };
        let rows = erc20_rows(&[
            token("ERC-721", "99"),
            token("ERC-20", "0"),
            token("ERC-20", "1000000000000000001"),
        ]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].quantity, "1.000000000000000001");
        assert_eq!(rows[0].price_usd.as_deref(), Some("0.0000123"));
    }
}
