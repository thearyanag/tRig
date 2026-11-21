use crate::{
    execution::{service, types::Provider},
    now, provider_json, ApiError, AppState,
};
use axum::{extract::State, http::StatusCode, Json};
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Currency {
    pub address: String,
    pub symbol: String,
    pub name: String,
    pub decimals: Option<u8>,
    pub image_url: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Network {
    pub id: String,
    pub name: String,
    pub vm: String,
    pub gecko_id: Option<String>,
    pub explorer_url: Option<String>,
    pub market_quotes: bool,
    pub conditional_quotes: bool,
    pub native_token: Option<Currency>,
}

pub fn address(chain: &str, value: &str) -> bool {
    if chain == "solana" {
        crate::discovery::is_address(value)
    } else {
        chain
            .strip_prefix("eip155:")
            .is_some_and(|id| id.parse::<u64>().is_ok_and(|n| n > 0))
            && value.len() == 42
            && value.starts_with("0x")
            && value[2..].bytes().all(|c| c.is_ascii_hexdigit())
    }
}
pub fn canonical(chain: &str, value: &str) -> String {
    if chain == "solana" {
        value.into()
    } else {
        value.to_ascii_lowercase()
    }
}
pub fn pool_address(chain: &str, value: &str) -> bool {
    address(chain, value)
        || chain.starts_with("eip155:")
            && value.len() == 66
            && value.starts_with("0x")
            && value[2..].bytes().all(|c| c.is_ascii_hexdigit())
}
pub fn https(value: &Value) -> Option<String> {
    let u = reqwest::Url::parse(value.as_str()?).ok()?;
    (u.scheme() == "https"
        && u.host_str().is_some()
        && u.username().is_empty()
        && u.password().is_none())
    .then(|| u.to_string())
}
pub fn currency(value: &Value, chain: &str) -> Option<Currency> {
    let a = value["address"].as_str()?;
    if !address(chain, a) {
        return None;
    }
    Some(Currency {
        address: canonical(chain, a),
        symbol: value["symbol"].as_str()?.chars().take(40).collect(),
        name: value["name"]
            .as_str()
            .unwrap_or("")
            .chars()
            .take(100)
            .collect(),
        decimals: value["decimals"]
            .as_u64()
            .and_then(|n| u8::try_from(n).ok()),
        image_url: https(&value["metadata"]["logoURI"]),
    })
}

pub async fn catalog(State(state): State<AppState>) -> Result<Json<Vec<Network>>, ApiError> {
    list(&state).await.map(Json)
}
pub async fn list(state: &AppState) -> Result<Vec<Network>, ApiError> {
    let mut cache = state.market.networks.lock().await;
    if let Some((at, rows)) = &*cache {
        if now().saturating_sub(*at) < 3600
            || state
                .market
                .pending_networks
                .load(std::sync::atomic::Ordering::SeqCst)
        {
            return Ok(rows.clone());
        }
    }
    if cache.is_none() {
        if let Some(saved) = state.market_db.networks(now()) {
            *cache = Some(saved.clone());
            return Ok(saved.1);
        }
    }
    let old = cache.clone();
    let relay = state
        .execution
        .request(
            Provider::Relay,
            Method::GET,
            service::url("https://api.relay.link/chains"),
            None,
            false,
        )
        .await;
    let flash = if state.execution.config.ready(Provider::Flash) {
        state.execution.chain_set(Provider::Flash).await.ok()
    } else {
        None
    };
    // Open known networks immediately. The public network/platform join runs
    // independently so its rate limit cannot block token metadata or quotes.
    let mut mapping: HashMap<String, String> =
        serde_json::from_str(include_str!("network-market-map.json"))
            .expect("bundled network mapping");
    if let Some((_, previous)) = &old {
        for row in previous {
            if let Some(g) = &row.gecko_id {
                mapping.insert(row.id.clone(), g.clone());
            }
        }
    }
    let mut rows = vec![Network {
        id: "solana".into(),
        name: "Solana".into(),
        vm: "svm".into(),
        gecko_id: Some("solana".into()),
        explorer_url: Some("https://solscan.io".into()),
        market_quotes: state.execution.config.ready(Provider::Jupiter),
        conditional_quotes: flash
            .as_ref()
            .is_some_and(|s| s.chains.iter().any(|c| c.id == "solana" && c.enabled)),
        native_token: Some(Currency {
            address: "So11111111111111111111111111111111111111112".into(),
            symbol: "SOL".into(),
            name: "Solana".into(),
            decimals: Some(9),
            image_url: None,
        }),
    }];
    if let Ok(raw) = relay {
        let parsed = service::relay_chains(&raw).map_err(|_| {
            ApiError(
                StatusCode::BAD_GATEWAY,
                "Networks could not be loaded.".into(),
            )
        })?;
        for chain in parsed.chains.into_iter().filter(|c| c.vm == "evm") {
            let raw_chain = raw["chains"].as_array().and_then(|cs| {
                cs.iter().find(|c| {
                    c["id"].as_u64().map(|id| id.to_string()) == Some(chain.provider_id.clone())
                })
            });
            let supported_flash = flash.as_ref().is_some_and(|s| {
                s.chains
                    .iter()
                    .any(|c| c.id == chain.id && c.enabled && c.deposit_enabled)
            });
            rows.push(Network {
                id: chain.id.clone(),
                name: chain.name,
                vm: "evm".into(),
                gecko_id: mapping.get(&chain.id).cloned(),
                explorer_url: raw_chain.and_then(|c| https(&c["explorerUrl"])),
                market_quotes: chain.enabled
                    && chain.deposit_enabled
                    && state.execution.config.ready(Provider::Relay)
                    || supported_flash,
                conditional_quotes: supported_flash,
                native_token: raw_chain.and_then(|c| currency(&c["currency"], &chain.id)),
            });
        }
    } else if let Some((_, rows)) = old {
        return Ok(rows);
    } else {
        return Err(ApiError(
            StatusCode::BAD_GATEWAY,
            "Networks could not be loaded. Try again shortly.".into(),
        ));
    }
    rows.sort_by(|a, b| a.name.cmp(&b.name));
    let timestamp = catalog_timestamp(now(), false);
    *cache = Some((timestamp, rows.clone()));
    let _ = state.market_db.save_networks(&rows, timestamp);
    drop(cache);
    if !state
        .market
        .pending_networks
        .swap(true, std::sync::atomic::Ordering::SeqCst)
    {
        let state = state.clone();
        tokio::spawn(async move {
            let mapping = market_mapping(&state).await;
            let mut cache = state.market.networks.lock().await;
            if let Some((at, rows)) = &mut *cache {
                match mapping {
                    Ok(mapping) => {
                        for row in rows.iter_mut().filter(|n| n.vm == "evm") {
                            row.gecko_id = mapping.get(&row.id).cloned();
                        }
                        *at = now();
                        let _ = state.market_db.save_networks(rows, *at);
                    }
                    Err(_) => {
                        *at = catalog_timestamp(now(), false);
                    }
                }
            }
            state
                .market
                .pending_networks
                .store(false, std::sync::atomic::Ordering::SeqCst);
        });
    }
    Ok(rows)
}

fn catalog_timestamp(at: u64, mapping_fresh: bool) -> u64 {
    // Retry degraded discovery after one minute, preserving known capabilities.
    if mapping_fresh {
        at
    } else {
        at.saturating_sub(3540)
    }
}

async fn market_mapping(state: &AppState) -> Result<HashMap<String, String>, ApiError> {
    let platforms: Value = state
        .client
        .get("https://api.coingecko.com/api/v3/asset_platforms")
        .send()
        .await
        .map_err(|_| {
            ApiError(
                StatusCode::BAD_GATEWAY,
                "Market coverage could not be loaded.".into(),
            )
        })?
        .error_for_status()
        .map_err(|_| {
            ApiError(
                StatusCode::BAD_GATEWAY,
                "Market coverage could not be loaded.".into(),
            )
        })?
        .json()
        .await
        .map_err(|_| {
            ApiError(
                StatusCode::BAD_GATEWAY,
                "Market coverage is invalid.".into(),
            )
        })?;
    let mut mapping = HashMap::new();
    // Follow a bounded page sequence, never provider-returned arbitrary URLs.
    for page in 1..=10 {
        let v = provider_json(
            state,
            service::url(&format!(
                "https://api.geckoterminal.com/api/v2/networks?page={page}"
            )),
        )
        .await?;
        merge_mapping(&platforms, &v, &mut mapping);
        if v["links"]["next"].is_null() {
            break;
        }
    }
    Ok(mapping)
}
pub fn merge_mapping(platforms: &Value, networks: &Value, out: &mut HashMap<String, String>) {
    let Some(platforms) = platforms.as_array() else {
        return;
    };
    let Some(networks) = networks["data"].as_array() else {
        return;
    };
    for network in networks {
        let Some(id) = network["id"].as_str().filter(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }) else {
            continue;
        };
        let Some(platform) = network["attributes"]["coingecko_asset_platform_id"].as_str() else {
            continue;
        };
        if let Some(chain) = platforms
            .iter()
            .find(|p| p["id"].as_str() == Some(platform))
            .and_then(|p| p["chain_identifier"].as_u64())
            .filter(|id| *id > 0)
        {
            out.insert(format!("eip155:{chain}"), id.into());
        }
    }
}
pub async fn find(state: &AppState, id: &str) -> Result<Network, ApiError> {
    if id == "solana" {
        return Ok(Network {
            id: id.into(),
            name: "Solana".into(),
            vm: "svm".into(),
            gecko_id: Some(id.into()),
            explorer_url: Some("https://solscan.io".into()),
            market_quotes: true,
            conditional_quotes: state.execution.config.ready(Provider::Flash),
            native_token: None,
        });
    }
    list(state)
        .await?
        .into_iter()
        .find(|n| n.id == id)
        .ok_or_else(|| {
            ApiError(
                StatusCode::BAD_REQUEST,
                "This chain is not supported.".into(),
            )
        })
}
pub async fn currencies(
    state: &AppState,
    chain: Option<&str>,
    query: &str,
) -> Result<Value, ApiError> {
    let mut body = json!({"term":query,"limit":40,"useExternalSearch":true});
    if query.len() == 42
        && query.starts_with("0x")
        && query[2..].bytes().all(|c| c.is_ascii_hexdigit())
    {
        body.as_object_mut().expect("object").remove("term");
        body["address"] = json!(query);
    }
    if let Some(chain) = chain {
        let n = chain
            .strip_prefix("eip155:")
            .and_then(|id| id.parse::<u64>().ok())
            .ok_or_else(|| ApiError(StatusCode::BAD_REQUEST, "Choose an EVM network.".into()))?;
        body["chainIds"] = json!([n]);
    }
    state
        .execution
        .request(
            Provider::Relay,
            Method::POST,
            service::url("https://api.relay.link/currencies/v2"),
            Some(body),
            state.execution.config.ready(Provider::Relay),
        )
        .await
        .map_err(|_| {
            ApiError(
                StatusCode::BAD_GATEWAY,
                "Token search is temporarily unavailable.".into(),
            )
        })
}

pub async fn quote_currency(state: &AppState, chain: &str) -> Option<Currency> {
    let mut cache = state.market.quote_currencies.lock().await;
    if let Some((at, currency)) = cache
        .get(chain)
        .filter(|(at, _)| now().saturating_sub(*at) < 86400)
    {
        let _ = at;
        return currency.clone();
    }
    let rows = currencies(state, Some(chain), "USDC").await.ok()?;
    let currency = rows
        .as_array()
        .and_then(|rows| {
            rows.iter().find(|r| {
                r["symbol"] == "USDC"
                    && r["metadata"]["verified"] == true
                    && r["chainId"].as_u64().map(|id| format!("eip155:{id}")) == Some(chain.into())
            })
        })
        .and_then(|r| self::currency(r, chain));
    cache.insert(chain.into(), (now(), currency.clone()));
    currency
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn degraded_catalog_retries_without_erasing_verified_bootstrap_coverage() {
        let mapping: HashMap<String, String> =
            serde_json::from_str(include_str!("network-market-map.json")).unwrap();
        assert_eq!(mapping.get("eip155:8453").map(String::as_str), Some("base"));
        assert_eq!(mapping.get("eip155:56").map(String::as_str), Some("bsc"));
        assert_eq!(catalog_timestamp(10_000, false), 6460);
        assert_eq!(catalog_timestamp(10_000, true), 10_000);
    }
    #[test]
    fn identity_is_chain_scoped_and_mapping_is_explicit() {
        let a = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
        assert!(address("eip155:8453", a));
        assert!(!address("solana", a));
        assert!(!address("eip155:1", "0x00"));
        assert_ne!(
            format!("eip155:1:{}", canonical("eip155:1", a)),
            format!("eip155:8453:{}", canonical("eip155:8453", a))
        );
        let mut out = HashMap::new();
        merge_mapping(
            &json!([{"id":"ethereum","chain_identifier":1}]),
            &json!({"data":[{"id":"eth","attributes":{"coingecko_asset_platform_id":"ethereum"}}]}),
            &mut out,
        );
        assert_eq!(out.get("eip155:1").map(String::as_str), Some("eth"));
    }
}
