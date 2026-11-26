use crate::{
    chain_registry,
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
    // Saved chart mappings can augment the catalog, but membership always comes from the registry.
    let previous = cache
        .clone()
        .or_else(|| state.market_db.networks(now()))
        .map(|(_, rows)| rows)
        .unwrap_or_default();
    let flash = if state.execution.config.ready(Provider::Flash) {
        state.execution.chain_set(Provider::Flash).await.ok()
    } else {
        None
    };
    let relay_ready = state.execution.config.ready(Provider::Relay);
    let mut rows: Vec<_> = chain_registry::catalog()
        .chains
        .iter()
        .map(|entry| {
            let id = entry.chain_id();
            let gecko = previous
                .iter()
                .find(|row| row.id == id)
                .and_then(|row| row.gecko_id.clone())
                .unwrap_or_else(|| entry.gecko_network.clone());
            let conditional = flash.as_ref().is_some_and(|set| {
                set.chains
                    .iter()
                    .any(|chain| chain.id == id && chain.enabled && chain.deposit_enabled)
            });
            let market_quotes = if id == "solana" {
                state.execution.config.ready(Provider::Jupiter)
            } else {
                (!entry.disabled && entry.deposit_enabled && relay_ready) || conditional
            };
            from_registry(entry, gecko, market_quotes, conditional)
        })
        .collect();
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
                            if let Some(gecko) = mapping.get(&row.id) {
                                row.gecko_id = Some(gecko.clone());
                            }
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
fn from_registry(
    entry: &chain_registry::Entry,
    gecko_network: String,
    market_quotes: bool,
    conditional_quotes: bool,
) -> Network {
    let id = entry.chain_id();
    // Charts use wrapped SOL as their market mint. The registry keeps the network's native address.
    let address = if id == "solana" {
        "So11111111111111111111111111111111111111112".into()
    } else {
        canonical(&id, &entry.currency.address)
    };
    Network {
        id,
        name: entry.display_name.clone(),
        vm: entry.vm_type.clone(),
        gecko_id: Some(gecko_network),
        explorer_url: entry.explorer_url.clone(),
        market_quotes,
        conditional_quotes,
        native_token: Some(Currency {
            address,
            symbol: entry.currency.symbol.clone(),
            name: entry.currency.name.clone(),
            decimals: Some(entry.currency.decimals),
            image_url: None,
        }),
    }
}

pub async fn find(state: &AppState, id: &str) -> Result<Network, ApiError> {
    let unsupported = || {
        ApiError(
            StatusCode::BAD_REQUEST,
            "This chain is not supported.".into(),
        )
    };
    let entry = chain_registry::get(id).ok_or_else(unsupported)?;
    if id == "solana" {
        return Ok(from_registry(
            entry,
            entry.gecko_network.clone(),
            true,
            state.execution.config.ready(Provider::Flash),
        ));
    }
    list(state)
        .await?
        .into_iter()
        .find(|n| n.id == id)
        .ok_or_else(unsupported)
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
    let chain_ids = if let Some(chain) = chain {
        let entry = chain_registry::get(chain)
            .filter(|entry| entry.vm_type == "evm")
            .ok_or_else(|| {
                ApiError(
                    StatusCode::BAD_REQUEST,
                    "Choose a supported EVM network.".into(),
                )
            })?;
        vec![entry.id]
    } else {
        chain_registry::catalog()
            .chains
            .iter()
            .filter(|entry| entry.vm_type == "evm")
            .map(|entry| entry.id)
            .collect()
    };
    body["chainIds"] = json!(chain_ids);
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
        assert_eq!(
            chain_registry::get("eip155:8453").unwrap().gecko_network,
            "base"
        );
        assert_eq!(
            chain_registry::get("eip155:56").unwrap().gecko_network,
            "bsc"
        );
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
