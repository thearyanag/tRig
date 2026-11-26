use crate::{chain_registry, models::BarsQuery, now, provider_json, ApiError, AppState};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, time::Duration};
use tokio::time::Instant;

pub(crate) const MARKET_ROUTE_VERSION: u8 = 2;
const ESTABLISHED_MARKET_AGE: Duration = Duration::from_secs(7 * 86400);
// Matches the initial daily chart request, so validation warms that cache.
const DAILY_HISTORY_LIMIT: usize = 300;

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
    #[serde(rename = "imageURL")]
    pub image_url: Option<String>,
    #[serde(rename = "volume24h")]
    pub volume_24h: Option<f64>,
    #[serde(default = "solana")]
    pub chain_id: String,
    #[serde(default)]
    pub market_network: Option<String>,
    #[serde(default)]
    pub explorer_url: Option<String>,
    #[serde(default)]
    pub change24h: Option<f64>,
    #[serde(default)]
    pub liquidity_usd: Option<f64>,
    #[serde(default)]
    pub market_cap_usd: Option<f64>,
    #[serde(default)]
    pub fdv_usd: Option<f64>,
    #[serde(default)]
    pub quote_token: Option<crate::market::networks::Currency>,
    #[serde(default)]
    pub market_quotes: bool,
    #[serde(default)]
    pub conditional_quotes: bool,
    #[serde(default)]
    pub market_resolved: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub market_route_version: Option<u8>,
}
impl Asset {
    pub(crate) fn has_current_market_route(&self) -> bool {
        self.market_route_version == Some(MARKET_ROUTE_VERSION)
    }
}
fn solana() -> String {
    "solana".into()
}
#[derive(Clone, Deserialize, Serialize)]
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
    pub chain: Option<String>,
}
#[derive(Deserialize)]
pub struct ResolveQuery {
    pub mint: String,
    pub chain: Option<String>,
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
    let term = query.q.trim();
    let scope = query.chain.as_deref().unwrap_or("all");
    if scope != "all" && chain_registry::get(scope).is_none() {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Unsupported network.".into(),
        ));
    }
    if !term.is_empty() && term.len() <= 320 {
        if let Some((mut saved, at)) = state.market_db.search(scope, term, now()) {
            let had_assets = !saved.assets.is_empty();
            let refresh =
                keep_registered_assets(&mut saved.assets) || now().saturating_sub(at) >= 60;
            if !had_assets || !saved.assets.is_empty() {
                if refresh {
                    schedule_search_refresh(&state, scope, term).await;
                }
                return Ok(Json(saved));
            }
        }
    }
    if is_address(term) || crate::market::networks::address("eip155:1", term) {
        let (mut known, at) = state.market_db.address_matches(scope, term, now());
        keep_registered_assets(&mut known);
        if !known.is_empty() {
            schedule_search_refresh(&state, scope, term).await;
            return Ok(Json(AssetsResponse {
                assets: known,
                fetched_at: at,
            }));
        }
    }
    discover(&state, term, false, query.chain.as_deref())
        .await
        .map(Json)
}

fn keep_registered_assets(assets: &mut Vec<Asset>) -> bool {
    let original = assets.len();
    assets.retain(|asset| chain_registry::get(&asset.chain_id).is_some());
    assets.len() != original
}

async fn schedule_search_refresh(state: &AppState, scope: &str, term: &str) {
    let key = format!("{scope}:{term}");
    if state
        .market
        .pending_searches
        .lock()
        .await
        .insert(key.clone())
    {
        let state = state.clone();
        let scope = scope.to_owned();
        let term = term.to_owned();
        tokio::spawn(async move {
            let _ = discover(&state, &term, false, Some(&scope)).await;
            state.market.pending_searches.lock().await.remove(&key);
        });
    }
}

pub async fn resolve(
    State(state): State<AppState>,
    Query(query): Query<ResolveQuery>,
) -> Result<Json<Asset>, ApiError> {
    let chain = query.chain.as_deref().unwrap_or("solana");
    if chain_registry::get(chain).is_none() {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Unsupported network.".into(),
        ));
    }
    if !crate::market::networks::address(chain, &query.mint) {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "The contract address does not match its network.".into(),
        ));
    }
    if let Some(saved) = state.market_db.asset(chain, &query.mint, now(), 300) {
        if saved.has_current_market_route()
            && saved.market_resolved
            && (chain == "solana" || saved.quote_token.is_some())
        {
            return Ok(Json(saved));
        }
    }
    let result = discover(&state, &query.mint, true, Some(chain)).await?;
    let mut asset = result
        .assets
        .into_iter()
        .find(|asset| asset.id == crate::market::networks::canonical(chain, &query.mint))
        .ok_or_else(|| {
            ApiError(
                StatusCode::NOT_FOUND,
                "No supported market was found for this asset.".into(),
            )
        })?;
    if chain != "solana" {
        let network = crate::market::networks::find(&state, chain).await?;
        asset.quote_token = crate::market::networks::quote_currency(&state, chain)
            .await
            .filter(|q| q.address != asset.id)
            .or_else(|| network.native_token.filter(|q| q.address != asset.id));
    }
    asset.market_resolved = true;
    asset.market_route_version = Some(MARKET_ROUTE_VERSION);
    let _ = state.market_db.save_asset(&asset, now());
    Ok(Json(asset))
}

async fn discover(
    state: &AppState,
    query: &str,
    exact: bool,
    chain: Option<&str>,
) -> Result<AssetsResponse, ApiError> {
    if query.is_empty() || query.chars().count() > 80 {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Enter an asset name, ticker or contract address.".into(),
        ));
    }
    let selected = chain.filter(|c| *c != "all");
    let networks = if selected == Some("solana") {
        vec![crate::market::networks::find(state, "solana").await?]
    } else {
        crate::market::networks::list(state).await?
    };
    if selected.is_some_and(|c| !networks.iter().any(|n| n.id == c)) {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Unsupported network.".into(),
        ));
    }
    let address = is_address(query) || query.starts_with("0x");
    let term = if address {
        query.to_string()
    } else {
        query.to_lowercase()
    };
    // A search result is ranked, but exact resolution also checks candle history.
    let key = format!("{exact}:{}:{term}", selected.unwrap_or("all"));
    let mut cache = state.discovery.lock().await;
    if let Some(entry) = cache
        .get(&key)
        .filter(|entry| entry.expires > Instant::now())
    {
        return Ok(entry.response.clone());
    }
    let gecko = selected
        .and_then(|c| networks.iter().find(|n| n.id == c))
        .and_then(|n| n.gecko_id.as_deref())
        .or_else(|| (selected.is_none() && is_address(query)).then_some("solana"));
    let mut url = if address && gecko.is_some() {
        reqwest::Url::parse(&format!(
            "https://api.geckoterminal.com/api/v2/networks/{}/tokens/{query}/pools",
            gecko.unwrap()
        ))
    } else {
        reqwest::Url::parse("https://api.geckoterminal.com/api/v2/search/pools")
    }
    .expect("fixed provider origin");
    {
        let mut params = url.query_pairs_mut();
        params.append_pair("include", "base_token,quote_token,dex");
        if !address || gecko.is_none() {
            params.append_pair("query", query);
            if let Some(gecko) = gecko {
                params.append_pair("network", gecko);
            }
        }
    }
    let should_fetch = !(address && gecko.is_none() && selected.is_some());
    let body = match if should_fetch {
        provider_json(state, url).await
    } else {
        Ok(serde_json::json!({"data":[],"included":[]}))
    } {
        Ok(body) => body,
        Err(error) if address && error.0 == StatusCode::NOT_FOUND => {
            serde_json::json!({"data":[],"included":[]})
        }
        Err(error) if exact || selected == Some("solana") => return Err(error),
        Err(_) => serde_json::json!({"data":[],"included":[]}),
    };
    let mut ranked = rank_assets(&body, query, address || exact, &networks)?;
    // Reuse verified discovery resources for stats and trades without refetching
    // the same market immediately after the trader opens a search result.
    if let Some(pools) = body["data"].as_array() {
        let mut raw = state.upstream.lock().await;
        for pool in pools.iter().take(20) {
            let Some(id) = pool["id"].as_str() else {
                continue;
            };
            let Some(address) = pool["attributes"]["address"].as_str() else {
                continue;
            };
            let Some(network) = networks.iter().find(|n| {
                n.gecko_id
                    .as_ref()
                    .is_some_and(|g| id == format!("{g}_{address}"))
            }) else {
                continue;
            };
            if !crate::market::networks::pool_address(&network.id, address) {
                continue;
            }
            let url=crate::execution::service::url(&format!("https://api.geckoterminal.com/api/v2/networks/{}/pools/{address}?include=base_token,quote_token",network.gecko_id.as_deref().unwrap_or("")));
            if raw.len() < 128 {
                raw.insert(
                    url.to_string(),
                    (
                        Instant::now(),
                        serde_json::json!({"data":pool,"included":body["included"]}),
                    ),
                );
            }
        }
    }
    if let (true, Some((primary, Some(alternate)))) = (exact, ranked.first_mut()) {
        if let Some(count @ 0..=1) = daily_candle_count(state, primary).await {
            if daily_candle_count(state, alternate)
                .await
                .is_some_and(|other| other > count)
            {
                std::mem::swap(primary, alternate);
            }
        }
    }
    let mut assets: Vec<_> = ranked.into_iter().map(|(asset, _)| asset).collect();
    if selected != Some("solana") && (!exact || assets.is_empty()) {
        match crate::market::networks::currencies(state, selected, query).await {
            Ok(rows) => {
                for token in rows.as_array().into_iter().flatten() {
                    let Some(id) = token["chainId"].as_u64() else {
                        continue;
                    };
                    let chain = format!("eip155:{id}");
                    let Some(network) = networks
                        .iter()
                        .find(|n| n.id == chain && selected.is_none_or(|s| s == chain))
                    else {
                        continue;
                    };
                    let Some(c) = crate::market::networks::currency(token, &chain) else {
                        continue;
                    };
                    if exact && c.address != crate::market::networks::canonical(&chain, query) {
                        continue;
                    }
                    if assets
                        .iter()
                        .any(|a| a.chain_id == chain && a.id == c.address)
                    {
                        continue;
                    }
                    assets.push(Asset {
                        id: c.address,
                        name: c.name,
                        symbol: c.symbol,
                        network: network.name.clone(),
                        pool: String::new(),
                        decimals: c.decimals.map(u32::from),
                        price_usd: None,
                        image_url: c.image_url,
                        volume_24h: None,
                        chain_id: chain,
                        market_network: network.gecko_id.clone(),
                        explorer_url: network.explorer_url.clone(),
                        change24h: None,
                        liquidity_usd: None,
                        market_cap_usd: None,
                        fdv_usd: None,
                        quote_token: None,
                        market_quotes: network.market_quotes,
                        conditional_quotes: network.conditional_quotes,
                        market_resolved: false,
                        market_route_version: None,
                    });
                }
            }
            Err(e) if assets.is_empty() => return Err(e),
            Err(_) => {}
        }
    }
    if let Some(chain) = selected {
        assets.retain(|a| a.chain_id == chain);
    }
    assets.truncate(40);
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
    let _ = state
        .market_db
        .save_search(selected.unwrap_or("all"), query, &response);
    cache.insert(
        key,
        CachedSearch {
            expires: Instant::now() + Duration::from_secs(if address { 300 } else { 60 }),
            response: response.clone(),
        },
    );
    Ok(response)
}

async fn daily_candle_count(state: &AppState, asset: &Asset) -> Option<usize> {
    crate::bars(
        State(state.clone()),
        Query(BarsQuery {
            chain: Some(asset.chain_id.clone()),
            mint: Some(asset.id.clone()),
            pool: Some(asset.pool.clone()),
            resolution: "1D".into(),
            before: None,
            limit: Some(DAILY_HISTORY_LIMIT),
        }),
    )
    .await
    .ok()
    .map(|response| response.0.bars.len())
}

pub fn number(value: Option<&Value>) -> Option<f64> {
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

/// Resolve both sides and choose an active market with established history.
/// Pool routing stays internal; token identity never comes from a pool's display name.
pub fn parse_assets(body: &Value, query: &str, exact: bool) -> Result<Vec<Asset>, ApiError> {
    parse_assets_on(
        body,
        query,
        exact,
        &[crate::market::networks::Network {
            id: "solana".into(),
            name: "Solana".into(),
            vm: "svm".into(),
            gecko_id: Some("solana".into()),
            explorer_url: Some("https://solscan.io".into()),
            market_quotes: true,
            conditional_quotes: true,
            native_token: None,
        }],
    )
}
pub fn parse_assets_on(
    body: &Value,
    query: &str,
    exact: bool,
    networks: &[crate::market::networks::Network],
) -> Result<Vec<Asset>, ApiError> {
    Ok(rank_assets(body, query, exact, networks)?
        .into_iter()
        .map(|(asset, _)| asset)
        .collect())
}

struct MarketCandidate {
    asset: Asset,
    history: HistoryCoverage,
    volume: f64,
    liquidity: f64,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum HistoryCoverage {
    New,
    Established,
    FullWindow,
}

fn history_coverage(created_at: Option<&str>, at: u64) -> HistoryCoverage {
    let created_at = created_at
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .and_then(|value| u64::try_from(value.timestamp()).ok());
    if created_at.is_some_and(|created_at| created_at <= crate::history_floor(at)) {
        HistoryCoverage::FullWindow
    } else if created_at
        .is_some_and(|created_at| created_at <= at.saturating_sub(ESTABLISHED_MARKET_AGE.as_secs()))
    {
        HistoryCoverage::Established
    } else {
        HistoryCoverage::New
    }
}
impl MarketCandidate {
    fn active(&self) -> bool {
        self.volume > 0.0
    }
}

fn rank_assets(
    body: &Value,
    query: &str,
    exact: bool,
    networks: &[crate::market::networks::Network],
) -> Result<Vec<(Asset, Option<Asset>)>, ApiError> {
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
    let mut candidates: HashMap<(String, String), Vec<MarketCandidate>> = HashMap::new();
    let at = now();
    for pool in pools {
        let Some(attrs) = pool.get("attributes") else {
            continue;
        };
        let Some(pool_address) = attrs["address"].as_str() else {
            continue;
        };
        let reserve = number(attrs.get("reserve_in_usd")).unwrap_or(0.0);
        if reserve <= 0.0 {
            continue;
        }
        let volume = number(attrs.get("volume_usd").and_then(|v| v.get("h24"))).unwrap_or(0.0);
        let history = history_coverage(attrs["pool_created_at"].as_str(), at);
        for side in ["base", "quote"] {
            let relation = format!("{side}_token");
            let Some(token_id) = pool["relationships"][&relation]["data"]["id"].as_str() else {
                continue;
            };
            let Some(network) = networks.iter().find(|n| {
                n.gecko_id
                    .as_ref()
                    .is_some_and(|g| token_id.starts_with(&format!("{g}_")))
            }) else {
                continue;
            };
            if !crate::market::networks::pool_address(&network.id, pool_address) {
                continue;
            }
            let Some(token) = tokens.get(token_id) else {
                continue;
            };
            let Some(id) = token["address"]
                .as_str()
                .filter(|address| crate::market::networks::address(&network.id, address))
            else {
                continue;
            };
            if token_id
                .strip_prefix(&format!("{}_", network.gecko_id.as_deref().unwrap_or("")))
                .map(|v| crate::market::networks::canonical(&network.id, v))
                != Some(crate::market::networks::canonical(&network.id, id))
            {
                continue;
            }
            let name = token["name"].as_str().unwrap_or("").trim();
            let symbol = token["symbol"].as_str().unwrap_or("").trim();
            if name.is_empty() || symbol.is_empty() {
                continue;
            }
            let matches = if exact {
                crate::market::networks::canonical(&network.id, id)
                    == crate::market::networks::canonical(&network.id, query)
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
                id: crate::market::networks::canonical(&network.id, id),
                name: name.into(),
                symbol: symbol.into(),
                network: network.name.clone(),
                pool: pool_address.into(),
                decimals: token["decimals"]
                    .as_u64()
                    .filter(|value| *value <= 255)
                    .map(|value| value as u32),
                price_usd: number(attrs.get(&price_key)).filter(|price| *price > 0.0),
                image_url: token["image_url"]
                    .as_str()
                    .filter(|url| url.starts_with("https://"))
                    .map(str::to_owned),
                volume_24h: number(attrs.get("volume_usd").and_then(|v| v.get("h24"))),
                chain_id: network.id.clone(),
                market_network: network.gecko_id.clone(),
                explorer_url: network.explorer_url.clone(),
                change24h: if side == "base" {
                    attrs["price_change_percentage"]["h24"]
                        .as_str()
                        .and_then(|s| s.parse::<f64>().ok())
                        .filter(|n| n.is_finite())
                } else {
                    None
                },
                liquidity_usd: Some(reserve),
                market_cap_usd: if side == "base" {
                    number(attrs.get("market_cap_usd"))
                } else {
                    None
                },
                fdv_usd: if side == "base" {
                    number(attrs.get("fdv_usd"))
                } else {
                    None
                },
                quote_token: None,
                market_quotes: network.market_quotes,
                conditional_quotes: network.conditional_quotes,
                market_resolved: true,
                market_route_version: None,
            };
            let identity = (network.id.clone(), asset.id.clone());
            candidates
                .entry(identity)
                .or_default()
                .push(MarketCandidate {
                    asset,
                    history,
                    volume,
                    liquidity: reserve,
                });
        }
    }
    let mut ranked: Vec<_> = candidates
        .into_values()
        .filter_map(|mut markets| {
            markets.sort_by(|a, b| {
                b.active()
                    .cmp(&a.active())
                    .then_with(|| b.history.cmp(&a.history))
                    .then_with(|| b.volume.total_cmp(&a.volume))
                    .then_with(|| b.liquidity.total_cmp(&a.liquidity))
                    .then_with(|| a.asset.pool.cmp(&b.asset.pool))
            });
            let mut markets = markets.into_iter();
            let primary = markets.next()?;
            let alternate =
                markets.find(|market| market.active() && market.asset.pool != primary.asset.pool);
            Some((primary, alternate.map(|market| market.asset)))
        })
        .collect();
    ranked.sort_by(|(a, _), (b, _)| {
        search_quality(&b.asset, &term)
            .cmp(&search_quality(&a.asset, &term))
            .then_with(|| b.active().cmp(&a.active()))
            .then_with(|| b.liquidity.total_cmp(&a.liquidity))
            .then_with(|| a.asset.id.cmp(&b.asset.id))
            .then_with(|| a.asset.chain_id.cmp(&b.asset.chain_id))
    });
    Ok(ranked
        .into_iter()
        .take(20)
        .map(|(primary, alternate)| (primary.asset, alternate))
        .collect())
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
    fn cached_discovery_keeps_only_registered_networks() {
        let mut results = parse_assets(&document(), BP_MINT, true).unwrap();
        let mut old_asset = results[0].clone();
        old_asset.chain_id = "eip155:100".into();
        results.push(old_asset);
        assert!(keep_registered_assets(&mut results));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].chain_id, "solana");
        assert!(!keep_registered_assets(&mut results));
    }
    #[test]
    fn established_active_market_beats_new_liquidity_and_volume_outlier() {
        let mut body = document();
        body["data"][0]["attributes"]["pool_created_at"] =
            json!(chrono::DateTime::from_timestamp(now() as i64, 0)
                .unwrap()
                .to_rfc3339());
        body["data"][0]["attributes"]["volume_usd"]["h24"] = json!("100000");
        body["data"][1]["attributes"]["pool_created_at"] = json!("2024-01-01T00:00:00Z");
        assert_eq!(parse_assets(&body, BP_MINT, true).unwrap()[0].pool, BP_POOL);
        body["data"][0]["attributes"]["pool_created_at"] = json!(chrono::DateTime::from_timestamp(
            (now() - 30 * 86400) as i64,
            0
        )
        .unwrap()
        .to_rfc3339());
        assert_eq!(parse_assets(&body, BP_MINT, true).unwrap()[0].pool, BP_POOL);
        body["data"][1]["attributes"]["volume_usd"]["h24"] = json!("0");
        assert_eq!(parse_assets(&body, BP_MINT, true).unwrap()[0].pool, SOL);
        body["data"].as_array_mut().unwrap().truncate(1);
        assert_eq!(parse_assets(&body, BP_MINT, true).unwrap()[0].pool, SOL);
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
    fn artwork_and_volume_stay_attached_to_the_resolved_identity() {
        let mut body = document();
        body["included"][0]["attributes"]["image_url"] = json!("https://example.com/bp.png");
        body["included"][1]["attributes"]["image_url"] = json!("https://example.com/sol.png");
        let bp = parse_assets(&body, BP_MINT, true).unwrap().remove(0);
        let sol = parse_assets(&body, SOL, true).unwrap().remove(0);
        assert_eq!(bp.image_url.as_deref(), Some("https://example.com/bp.png"));
        assert_eq!(
            sol.image_url.as_deref(),
            Some("https://example.com/sol.png")
        );
        assert_eq!(bp.volume_24h, Some(10.0));
        let serialized = serde_json::to_value(&bp).unwrap();
        assert_eq!(serialized["imageURL"], "https://example.com/bp.png");
        assert_eq!(serialized["volume24h"], 10.0);
        body["included"][0]["attributes"]["image_url"] = json!("file:///tmp/private.png");
        assert!(parse_assets(&body, BP_MINT, true).unwrap()[0]
            .image_url
            .is_none());
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
    #[test]
    fn evm_results_do_not_merge_the_same_contract_across_networks() {
        let address = "0x1111111111111111111111111111111111111111";
        let quote = "0x2222222222222222222222222222222222222222";
        let pool = "0x3333333333333333333333333333333333333333";
        let mut data = vec![];
        let mut included = vec![];
        let mut networks = vec![];
        for (id, gecko, name) in [
            ("eip155:1", "eth", "Ethereum"),
            ("eip155:8453", "base", "Base"),
        ] {
            networks.push(crate::market::networks::Network {
                id: id.into(),
                name: name.into(),
                vm: "evm".into(),
                gecko_id: Some(gecko.into()),
                explorer_url: None,
                market_quotes: true,
                conditional_quotes: false,
                native_token: None,
            });
            data.push(json!({"attributes":{"address":pool,"reserve_in_usd":"100","volume_usd":{"h24":"10"},"base_token_price_usd":"2","quote_token_price_usd":"1","market_cap_usd":null,"fdv_usd":"1000","price_change_percentage":{"h24":"-5"}},"relationships":{"base_token":{"data":{"id":format!("{gecko}_{address}")}},"quote_token":{"data":{"id":format!("{gecko}_{quote}")}}}}));
            for (a, s) in [(address, "TOK"), (quote, "USD")] {
                included.push(json!({"type":"token","id":format!("{gecko}_{a}"),"attributes":{"address":a,"name":s,"symbol":s,"decimals":18}}));
            }
        }
        let result = parse_assets_on(
            &json!({"data":data,"included":included}),
            "TOK",
            false,
            &networks,
        )
        .unwrap();
        assert_eq!(result.len(), 2);
        assert_ne!(result[0].chain_id, result[1].chain_id);
        assert_eq!(result[0].market_cap_usd, None);
        assert_eq!(result[0].fdv_usd, Some(1000.));
        assert_eq!(result[0].change24h, Some(-5.));
    }
}
