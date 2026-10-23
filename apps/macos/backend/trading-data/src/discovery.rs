use crate::{now, provider_json, ApiError, AppState};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, time::Duration};
use tokio::time::Instant;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub id: String,
    pub name: String,
    pub symbol: String,
    pub network: String,
    pub pool: String,
    pub decimals: Option<u32>,
    pub price_usd: Option<f64>,
}
#[derive(Clone, Serialize)]
pub struct AssetsResponse {
    pub assets: Vec<Asset>,
    pub fetched_at: u64,
}
pub struct CachedSearch {
    pub expires: Instant,
    pub response: AssetsResponse,
}
#[derive(Deserialize)]
pub struct SearchQuery {
    pub q: String,
}
#[derive(Deserialize)]
pub struct ResolveQuery {
    pub mint: String,
}

pub fn is_address(address: &str) -> bool {
    (32..=44).contains(&address.len())
        && bs58::decode(address)
            .into_vec()
            .is_ok_and(|bytes| bytes.len() == 32)
}

pub async fn search(
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<AssetsResponse>, ApiError> {
    discover(&state, query.q.trim(), false).await.map(Json)
}
pub async fn resolve(
    State(state): State<AppState>,
    Query(query): Query<ResolveQuery>,
) -> Result<Json<Asset>, ApiError> {
    if !is_address(&query.mint) {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Invalid Solana address".into(),
        ));
    }
    let result = discover(&state, &query.mint, true).await?;
    result
        .assets
        .into_iter()
        .find(|asset| asset.id == query.mint)
        .map(Json)
        .ok_or_else(|| {
            ApiError(
                StatusCode::NOT_FOUND,
                "No supported market was found for this asset.".into(),
            )
        })
}

async fn discover(state: &AppState, query: &str, exact: bool) -> Result<AssetsResponse, ApiError> {
    if query.is_empty() || query.chars().count() > 80 {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Enter an asset name, ticker or Solana address.".into(),
        ));
    }
    let address = is_address(query);
    let key = if address {
        query.to_string()
    } else {
        query.to_lowercase()
    };
    let mut cache = state.discovery.lock().await;
    if let Some(entry) = cache
        .get(&key)
        .filter(|entry| entry.expires > Instant::now())
    {
        return Ok(entry.response.clone());
    }
    let mut url = if address {
        reqwest::Url::parse(&format!(
            "https://api.geckoterminal.com/api/v2/networks/solana/tokens/{query}/pools"
        ))
    } else {
        reqwest::Url::parse("https://api.geckoterminal.com/api/v2/search/pools")
    }
    .expect("fixed provider origin");
    {
        let mut params = url.query_pairs_mut();
        params.append_pair("include", "base_token,quote_token,dex");
        if !address {
            params.append_pair("query", query);
            params.append_pair("network", "solana");
        }
    }
    let body = match provider_json(state, url).await {
        Ok(body) => body,
        Err(error) if address && error.0 == StatusCode::NOT_FOUND => {
            serde_json::json!({"data":[],"included":[]})
        }
        Err(error) => return Err(error),
    };
    let assets = parse_assets(&body, query, address || exact)?;
    let response = AssetsResponse {
        assets,
        fetched_at: now(),
    };
    if cache.len() >= 128 {
        cache.retain(|_, entry| entry.expires > Instant::now());
    }
    if cache.len() >= 128 {
        cache.clear();
    }
    cache.insert(
        key,
        CachedSearch {
            expires: Instant::now() + Duration::from_secs(if address { 300 } else { 60 }),
            response: response.clone(),
        },
    );
    Ok(response)
}

fn number(value: Option<&Value>) -> Option<f64> {
    let value = value?;
    let n = value.as_f64().or_else(|| value.as_str()?.parse().ok())?;
    (n.is_finite() && n >= 0.0).then_some(n)
}

fn canonical_identity(id: &str, term: &str) -> bool {
    match term {
        "sol" | "solana" | "wrapped sol" => id == "So11111111111111111111111111111111111111112",
        "bp" | "backpack" => id == crate::models::BP_MINT,
        "usdc" | "usd coin" => id == "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        _ => false,
    }
}
fn search_quality(asset: &Asset, term: &str) -> u8 {
    if canonical_identity(&asset.id, term) {
        3
    } else if asset.symbol.to_lowercase() == term || asset.name.to_lowercase() == term {
        2
    } else {
        1
    }
}

/// Resolve both sides, deduplicate by mint, and choose the most liquid active route.
/// Pool routing stays internal; token identity never comes from a pool's display name.
pub fn parse_assets(body: &Value, query: &str, exact: bool) -> Result<Vec<Asset>, ApiError> {
    let pools = body.get("data").and_then(Value::as_array).ok_or_else(|| {
        ApiError(
            StatusCode::BAD_GATEWAY,
            "Asset search returned an unexpected response.".into(),
        )
    })?;
    let included = body
        .get("included")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let tokens: HashMap<&str, &Value> = included
        .iter()
        .filter(|item| item["type"] == "token")
        .filter_map(|item| Some((item["id"].as_str()?, item.get("attributes")?)))
        .collect();
    let term = query.to_lowercase();
    let mut best: HashMap<String, (Asset, bool, f64, f64)> = HashMap::new();
    for pool in pools {
        let Some(attrs) = pool.get("attributes") else {
            continue;
        };
        let Some(pool_address) = attrs["address"]
            .as_str()
            .filter(|address| is_address(address))
        else {
            continue;
        };
        let reserve = number(attrs.get("reserve_in_usd")).unwrap_or(0.0);
        if reserve <= 0.0 {
            continue;
        }
        let volume = number(attrs.get("volume_usd").and_then(|v| v.get("h24"))).unwrap_or(0.0);
        for side in ["base", "quote"] {
            let relation = format!("{side}_token");
            let Some(token_id) = pool["relationships"][&relation]["data"]["id"].as_str() else {
                continue;
            };
            if !token_id.starts_with("solana_") {
                continue;
            }
            let Some(token) = tokens.get(token_id) else {
                continue;
            };
            let Some(id) = token["address"]
                .as_str()
                .filter(|address| is_address(address))
            else {
                continue;
            };
            if token_id.strip_prefix("solana_") != Some(id) {
                continue;
            }
            let name = token["name"].as_str().unwrap_or("").trim();
            let symbol = token["symbol"].as_str().unwrap_or("").trim();
            if name.is_empty() || symbol.is_empty() {
                continue;
            }
            let matches = if exact {
                id == query
            } else {
                name.to_lowercase().contains(&term)
                    || symbol.to_lowercase().contains(&term)
                    || canonical_identity(id, &term)
            };
            if !matches {
                continue;
            }
            let price_key = format!("{side}_token_price_usd");
            let asset = Asset {
                id: id.into(),
                name: name.into(),
                symbol: symbol.into(),
                network: "Solana".into(),
                pool: pool_address.into(),
                decimals: token["decimals"]
                    .as_u64()
                    .filter(|value| *value <= 255)
                    .map(|value| value as u32),
                price_usd: number(attrs.get(&price_key)).filter(|price| *price > 0.0),
            };
            let active = volume > 0.0;
            let replace = best
                .get(id)
                .is_none_or(|(_, old_active, old_reserve, old_volume)| {
                    (active, reserve, volume) > (*old_active, *old_reserve, *old_volume)
                });
            if replace {
                best.insert(id.into(), (asset, active, reserve, volume));
            }
        }
    }
    let mut ranked: Vec<_> = best.into_values().collect();
    ranked.sort_by(|a, b| {
        search_quality(&b.0, &term)
            .cmp(&search_quality(&a.0, &term))
            .then_with(|| b.1.cmp(&a.1))
            .then_with(|| b.2.total_cmp(&a.2))
            .then_with(|| a.0.id.cmp(&b.0.id))
    });
    Ok(ranked.into_iter().take(20).map(|value| value.0).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{BP_MINT, BP_POOL};
    use serde_json::json;
    const SOL: &str = "So11111111111111111111111111111111111111112";
    fn document() -> Value {
        let pool = |address, reserve, volume| json!({"attributes":{"address":address,"reserve_in_usd":reserve,"volume_usd":{"h24":volume},"base_token_price_usd":"1.2","quote_token_price_usd":"120"},"relationships":{"base_token":{"data":{"id":format!("solana_{BP_MINT}")}},"quote_token":{"data":{"id":format!("solana_{SOL}")}}}});
        json!({"data":[pool(SOL,"10000","0"),pool(BP_POOL,"1000","10")],"included":[
            {"id":format!("solana_{BP_MINT}"),"type":"token","attributes":{"address":BP_MINT,"name":"Backpack","symbol":"BP","decimals":9}},
            {"id":format!("solana_{SOL}"),"type":"token","attributes":{"address":SOL,"name":"Wrapped SOL","symbol":"SOL","decimals":9}}
        ]})
    }
    #[test]
    fn identity_is_exact_and_routes_are_deduplicated() {
        let results = parse_assets(&document(), BP_MINT, true).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, BP_MINT);
        assert_eq!(results[0].pool, BP_POOL);
        assert!(
            parse_assets(&document(), "11111111111111111111111111111111", true)
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn known_identity_wins_over_duplicate_tickers_and_aliases() {
        let mut body = document();
        body["included"][0]["attributes"]["name"] = json!("Solana");
        body["included"][0]["attributes"]["symbol"] = json!("SOL");
        let results = parse_assets(&body, "SOL", false).unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].id, SOL);
        assert_eq!(parse_assets(&body, "Solana", false).unwrap()[0].id, SOL);
    }
    #[test]
    fn quote_side_search_uses_the_quote_token_and_price() {
        let results = parse_assets(&document(), "SOL", false).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, SOL);
        assert_eq!(results[0].price_usd, Some(120.0));
    }
    #[test]
    fn addresses_are_decoded_and_missing_metadata_is_not_guessed() {
        assert!(is_address(BP_MINT));
        assert!(!is_address("../foo"));
        assert!(
            parse_assets(&json!({"data":document()["data"]}), "BP", false)
                .unwrap()
                .is_empty()
        );
    }
}
