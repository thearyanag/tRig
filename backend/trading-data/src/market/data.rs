use super::networks;
use crate::{discovery, models::BarsQuery, now, provider_json, ApiError, AppState};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use bigdecimal::BigDecimal;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::str::FromStr;

#[derive(Deserialize, Clone)]
pub struct MarketQuery {
    pub chain: String,
    pub address: String,
    pub pool: String,
}
impl MarketQuery {
    fn key(&self) -> Result<String, ApiError> {
        if !networks::address(&self.chain, &self.address)
            || !networks::pool_address(&self.chain, &self.pool)
        {
            return Err(ApiError(
                StatusCode::BAD_REQUEST,
                "Invalid market identity.".into(),
            ));
        }
        Ok(format!(
            "{}:{}:{}",
            self.chain,
            networks::canonical(&self.chain, &self.address),
            networks::canonical(&self.chain, &self.pool)
        ))
    }
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetLink {
    pub title: String,
    pub url: String,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub chain: String,
    pub address: String,
    pub pool: String,
    pub asset: discovery::Asset,
    pub high24h: Option<f64>,
    pub low24h: Option<f64>,
    pub range_start: u64,
    pub range_end: u64,
    pub links: Vec<AssetLink>,
    pub fetched_at: u64,
    pub warning: Option<String>,
    pub range_loading: bool,
}
#[derive(Clone)]
pub struct RangeData {
    pub high: Option<f64>,
    pub low: Option<f64>,
    pub start: u64,
    pub end: u64,
    pub at: u64,
    pub warning: Option<String>,
    pub change: Option<f64>,
    pub market_cap: Option<f64>,
    pub fdv: Option<f64>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Trade {
    pub id: String,
    pub side: String,
    pub price_usd: String,
    pub quantity: String,
    pub value_usd: String,
    pub timestamp: String,
    pub transaction: String,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Trades {
    pub chain: String,
    pub address: String,
    pub pool: String,
    pub rows: Vec<Trade>,
    pub fetched_at: u64,
    pub warning: Option<String>,
}

async fn verified_pool(
    state: &AppState,
    q: &MarketQuery,
) -> Result<(Value, networks::Network), ApiError> {
    q.key()?;
    let n = networks::find(state, &q.chain).await?;
    let gecko = n.gecko_id.as_ref().ok_or_else(|| {
        ApiError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Market data is not available on this network.".into(),
        )
    })?;
    let url=crate::execution::service::url(&format!("https://api.geckoterminal.com/api/v2/networks/{gecko}/pools/{}?include=base_token,quote_token",q.pool));
    let v = provider_json(state, url).await?;
    let expected = format!("{gecko}_{}", q.pool);
    if v["data"]["id"].as_str().is_none_or(|id| {
        networks::canonical(&q.chain, id) != networks::canonical(&q.chain, &expected)
    }) || !pool_matches(&v, &q.chain, &q.address, &q.pool)
    {
        return Err(ApiError(
            StatusCode::BAD_GATEWAY,
            "Market identity could not be confirmed.".into(),
        ));
    }
    Ok((v, n))
}
pub fn pool_matches(v: &Value, chain: &str, address: &str, pool: &str) -> bool {
    let data = &v["data"];
    if data["attributes"]["address"]
        .as_str()
        .is_none_or(|p| networks::canonical(chain, p) != networks::canonical(chain, pool))
    {
        return false;
    }
    ["base_token", "quote_token"].iter().any(|side| {
        let Some(id) = data["relationships"][side]["data"]["id"].as_str() else {
            return false;
        };
        v["included"].as_array().is_some_and(|items| {
            items.iter().any(|t| {
                t["type"] == "token"
                    && t["id"].as_str() == Some(id)
                    && t["attributes"]["address"].as_str().is_some_and(|a| {
                        networks::canonical(chain, a) == networks::canonical(chain, address)
                    })
            })
        })
    })
}
pub async fn snapshot(
    State(state): State<AppState>,
    Query(q): Query<MarketQuery>,
) -> Result<Json<Snapshot>, ApiError> {
    let key = q.key()?;
    let mut cache = state.market.snapshots.lock().await;
    if let Some(old) = cache
        .get(&key)
        .filter(|s| now().saturating_sub(s.fetched_at) < 60)
    {
        return Ok(Json(old.clone()));
    }
    let (mut pool, network) = match verified_pool(&state, &q).await {
        Ok(p) => p,
        Err(e) => {
            if let Some(mut old) = cache.get(&key).cloned() {
                old.warning =
                    Some("Showing saved market data; refresh is temporarily unavailable.".into());
                return Ok(Json(old));
            }
            return Err(e);
        }
    };
    pool["data"] = serde_json::json!([pool["data"].clone()]);
    let mut asset =
        discovery::parse_assets_on(&pool, &q.address, true, std::slice::from_ref(&network))?
            .into_iter()
            .find(|a| a.chain_id == q.chain)
            .ok_or_else(|| {
                ApiError(
                    StatusCode::BAD_GATEWAY,
                    "Market metadata is unavailable.".into(),
                )
            })?;
    let needs_token_metrics = asset.market_cap_usd.is_none() || asset.fdv_usd.is_none();
    let fetched = now();
    let range_end = now() / 60 * 60;
    let range_start = range_end.saturating_sub(86400);
    let cached_range = state.market.ranges.lock().await.get(&key).cloned();
    let needs_range = cached_range
        .as_ref()
        .is_none_or(|r| now().saturating_sub(r.at) >= 60);
    if let Some(r) = &cached_range {
        asset.change24h = asset.change24h.or(r.change);
        asset.market_cap_usd = asset.market_cap_usd.or(r.market_cap);
        asset.fdv_usd = asset.fdv_usd.or(r.fdv);
    }
    let high24h = cached_range.as_ref().and_then(|r| r.high);
    let low24h = cached_range.as_ref().and_then(|r| r.low);
    let warning = cached_range.as_ref().and_then(|r| r.warning.clone());
    let links = state
        .market
        .info
        .lock()
        .await
        .get(&format!("{}:{}", q.chain, q.address))
        .map(|(_, links)| links.clone())
        .unwrap_or_default();
    let result = Snapshot {
        chain: q.chain.clone(),
        address: networks::canonical(&q.chain, &q.address),
        pool: networks::canonical(&q.chain, &q.pool),
        asset,
        high24h,
        low24h,
        range_start: cached_range
            .as_ref()
            .map(|r| r.start)
            .unwrap_or(range_start),
        range_end: cached_range.as_ref().map(|r| r.end).unwrap_or(range_end),
        links,
        fetched_at: fetched,
        warning,
        range_loading: needs_range,
    };
    if cache.len() > 128 {
        cache.clear();
    }
    cache.insert(key, result.clone());
    drop(cache);
    if needs_range {
        schedule_range(
            state.clone(),
            q.clone(),
            network,
            range_start,
            range_end,
            needs_token_metrics,
        )
        .await;
    }
    Ok(Json(result))
}
async fn schedule_range(
    state: AppState,
    q: MarketQuery,
    network: networks::Network,
    start: u64,
    end: u64,
    needs_token_metrics: bool,
) {
    let Ok(key) = q.key() else { return };
    if !state.market.pending_ranges.lock().await.insert(key.clone()) {
        return;
    }
    tokio::spawn(async move {
        let result = recent_range(&state, &q, start, end).await;
        let ranges = state.market.ranges.lock().await;
        let mut data = match result {
            Ok((high, low, change)) => RangeData {
                high,
                low,
                start,
                end,
                at: now(),
                warning: None,
                change,
                market_cap: None,
                fdv: None,
            },
            Err(error) => {
                let mut old = ranges.get(&key).cloned().unwrap_or(RangeData {
                    high: None,
                    low: None,
                    start,
                    end,
                    at: now(),
                    warning: None,
                    change: None,
                    market_cap: None,
                    fdv: None,
                });
                old.at = now();
                old.warning = Some(format!("The 24h range could not refresh: {}", error.1));
                old
            }
        };
        drop(ranges);
        if needs_token_metrics {
            if let Some(g) = &network.gecko_id {
                if let Ok(v) = provider_json(
                    &state,
                    crate::execution::service::url(&format!(
                        "https://api.geckoterminal.com/api/v2/networks/{g}/tokens/{}",
                        q.address
                    )),
                )
                .await
                {
                    (data.market_cap, data.fdv) = token_metrics(&v, &q, g);
                }
            }
        }
        state
            .market
            .ranges
            .lock()
            .await
            .insert(key.clone(), data.clone());
        let links = links(&state, &q, &network).await;
        if let Some(current) = state.market.snapshots.lock().await.get_mut(&key) {
            current.asset.change24h = current.asset.change24h.or(data.change);
            current.asset.market_cap_usd = current.asset.market_cap_usd.or(data.market_cap);
            current.asset.fdv_usd = current.asset.fdv_usd.or(data.fdv);
            current.high24h = data.high;
            current.low24h = data.low;
            current.range_start = data.start;
            current.range_end = data.end;
            current.warning = data.warning;
            current.links = links;
            current.range_loading = false;
        }
        state.market.pending_ranges.lock().await.remove(&key);
    });
}
async fn recent_range(
    state: &AppState,
    q: &MarketQuery,
    start: u64,
    end: u64,
) -> Result<(Option<f64>, Option<f64>, Option<f64>), ApiError> {
    let mut all = Vec::new();
    let mut before = end.saturating_sub(1);
    for _ in 0..2 {
        let response = crate::bars(
            State(state.clone()),
            Query(BarsQuery {
                chain: Some(q.chain.clone()),
                mint: Some(q.address.clone()),
                pool: Some(q.pool.clone()),
                resolution: "1".into(),
                before: Some(before),
                limit: Some(1000),
            }),
        )
        .await?
        .0;
        let oldest = response.bars.first().map(|b| (b.time / 1000) as u64);
        let len = response.bars.len();
        all.extend(response.bars);
        match oldest {
            Some(t) if t > start && len == 1000 => before = t.saturating_sub(1),
            _ => break,
        }
    }
    let (high, low) = range(&all, start, end);
    Ok((high, low, rolling_change(&all, start, end)))
}
pub fn range(bars: &[crate::models::Bar], start: u64, end: u64) -> (Option<f64>, Option<f64>) {
    let filtered: Vec<_> = bars
        .iter()
        .filter(|b| b.time >= start as i64 * 1000 && b.time < end as i64 * 1000)
        .collect();
    (
        filtered.iter().map(|b| b.high).reduce(f64::max),
        filtered.iter().map(|b| b.low).reduce(f64::min),
    )
}
// Pool market-cap and change fields describe its base token. Never use them for
// the quote token; validate token metadata independently and derive its change
// from the same completed-minute window used for high/low.
fn token_metrics(v: &Value, q: &MarketQuery, gecko: &str) -> (Option<f64>, Option<f64>) {
    let d = &v["data"];
    let expected = format!("{gecko}_{}", q.address);
    if d["type"] != "token"
        || d["id"].as_str().is_none_or(|id| {
            networks::canonical(&q.chain, id) != networks::canonical(&q.chain, &expected)
        })
        || d["attributes"]["address"].as_str().is_none_or(|a| {
            networks::canonical(&q.chain, a) != networks::canonical(&q.chain, &q.address)
        })
    {
        return (None, None);
    }
    let a = &d["attributes"];
    (
        discovery::number(a.get("market_cap_usd")),
        discovery::number(a.get("fdv_usd")),
    )
}
fn rolling_change(bars: &[crate::models::Bar], start: u64, end: u64) -> Option<f64> {
    let first = bars
        .iter()
        .filter(|b| b.time >= start as i64 * 1000 && b.time < end as i64 * 1000)
        .min_by_key(|b| b.time)?;
    let last = bars
        .iter()
        .filter(|b| b.time < end as i64 * 1000 && b.time >= start as i64 * 1000)
        .max_by_key(|b| b.time)?;
    let baseline = bars
        .iter()
        .filter(|b| b.time < start as i64 * 1000)
        .max_by_key(|b| b.time)
        .map(|b| b.close)
        .unwrap_or(first.open);
    let change = (last.close / baseline - 1.) * 100.;
    (baseline > 0. && change.is_finite()).then_some(change)
}
async fn links(state: &AppState, q: &MarketQuery, n: &networks::Network) -> Vec<AssetLink> {
    let key = format!("{}:{}", q.chain, q.address);
    let mut cache = state.market.info.lock().await;
    if let Some((at, links)) = cache
        .get(&key)
        .filter(|(at, _)| now().saturating_sub(*at) < 86400)
    {
        let _ = at;
        return links.clone();
    }
    let Some(g) = &n.gecko_id else { return vec![] };
    let result = provider_json(
        state,
        crate::execution::service::url(&format!(
            "https://api.geckoterminal.com/api/v2/networks/{g}/tokens/{}/info",
            q.address
        )),
    )
    .await;
    let mut links = vec![];
    if let Ok(v) = result {
        let a = &v["data"]["attributes"];
        if let Some(web) = a["websites"]
            .as_array()
            .and_then(|s| s.iter().find_map(networks::https))
        {
            links.push(AssetLink {
                title: "Website".into(),
                url: web,
            });
        }
        if let Some(handle) = a["twitter_handle"].as_str().filter(|s| {
            !s.is_empty()
                && s.len() <= 30
                && s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
        }) {
            links.push(AssetLink {
                title: "X".into(),
                url: format!("https://x.com/{handle}"),
            });
        }
    }
    if cache.len() > 256 {
        cache.clear();
    }
    cache.insert(key, (now(), links.clone()));
    links
}

pub async fn trades(
    State(state): State<AppState>,
    Query(q): Query<MarketQuery>,
) -> Result<Json<Trades>, ApiError> {
    let key = q.key()?;
    let mut cache = state.market.trades.lock().await;
    if let Some(old) = cache
        .get(&key)
        .filter(|s| now().saturating_sub(s.fetched_at) < 60)
    {
        return Ok(Json(old.clone()));
    }
    // Reuse a verified snapshot when possible; never accept a mismatched token/pool.
    let snapshot_verified = state.market.snapshots.try_lock().is_ok_and(|s| {
        s.get(&key)
            .is_some_and(|s| now().saturating_sub(s.fetched_at) < 300)
    });
    let n = if snapshot_verified {
        networks::find(&state, &q.chain).await?
    } else {
        verified_pool(&state, &q).await?.1
    };
    let g = n.gecko_id.ok_or_else(|| {
        ApiError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Recent trades are unavailable on this network.".into(),
        )
    })?;
    let mut url = crate::execution::service::url(&format!(
        "https://api.geckoterminal.com/api/v2/networks/{g}/pools/{}/trades",
        q.pool
    ));
    url.query_pairs_mut().append_pair("token", &q.address);
    let result = provider_json(&state, url).await;
    let v = match result {
        Ok(v) => v,
        Err(e) => {
            if let Some(mut old) = cache.get(&key).cloned() {
                old.warning =
                    Some("Showing saved trades; refresh is temporarily unavailable.".into());
                return Ok(Json(old));
            }
            return Err(e);
        }
    };
    let result = Trades {
        chain: q.chain.clone(),
        address: networks::canonical(&q.chain, &q.address),
        pool: networks::canonical(&q.chain, &q.pool),
        rows: normalize_trades(&v, &q.chain, &q.address)?,
        fetched_at: now(),
        warning: None,
    };
    if cache.len() > 128 {
        cache.clear();
    }
    cache.insert(key, result.clone());
    Ok(Json(result))
}
fn decimal(v: &Value) -> Option<String> {
    let s = v.as_str()?;
    if s.len() > 512 {
        return None;
    }
    let n = BigDecimal::from_str(s).ok()?;
    (n > 0).then(|| n.normalized().to_string())
}
pub fn normalize_trades(v: &Value, chain: &str, asset: &str) -> Result<Vec<Trade>, ApiError> {
    let rows = v["data"].as_array().ok_or_else(|| {
        ApiError(
            StatusCode::BAD_GATEWAY,
            "Recent trades returned invalid data.".into(),
        )
    })?;
    let mut seen = HashSet::new();
    let mut out = vec![];
    for row in rows.iter().take(300) {
        let a = &row["attributes"];
        let Some(id) = row["id"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() < 512)
        else {
            continue;
        };
        if !seen.insert(id) || a["is_anomalous"] == true {
            continue;
        }
        let from = a["from_token_address"]
            .as_str()
            .is_some_and(|s| networks::canonical(chain, s) == networks::canonical(chain, asset));
        let to = a["to_token_address"]
            .as_str()
            .is_some_and(|s| networks::canonical(chain, s) == networks::canonical(chain, asset));
        if from == to {
            continue;
        }
        let Some(price) = decimal(
            &a[if from {
                "price_from_in_usd"
            } else {
                "price_to_in_usd"
            }],
        ) else {
            continue;
        };
        let Some(quantity) = decimal(
            &a[if from {
                "from_token_amount"
            } else {
                "to_token_amount"
            }],
        ) else {
            continue;
        };
        let Some(value) = decimal(&a["volume_in_usd"]) else {
            continue;
        };
        let Some(time) = a["block_timestamp"].as_str().filter(|s| {
            s.len() >= 20
                && s.len() <= 35
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || b"-:TZ.+".contains(&b))
        }) else {
            continue;
        };
        let Some(tx) = a["tx_hash"].as_str().filter(|s| {
            if chain == "solana" {
                bs58::decode(s).into_vec().is_ok_and(|b| b.len() == 64)
            } else {
                s.len() == 66
                    && s.starts_with("0x")
                    && s[2..].bytes().all(|b| b.is_ascii_hexdigit())
            }
        }) else {
            continue;
        };
        out.push(Trade {
            id: id.into(),
            side: if to { "buy" } else { "sell" }.into(),
            price_usd: price,
            quantity,
            value_usd: value,
            timestamp: time.into(),
            transaction: tx.into(),
        });
    }
    out.sort_by(|a, b| b.timestamp.cmp(&a.timestamp).then_with(|| b.id.cmp(&a.id)));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn market_identity_requires_the_requested_token_and_pool() {
        let token = "0x1111111111111111111111111111111111111111";
        let pool = "0x2222222222222222222222222222222222222222";
        let doc = json!({"data":{"attributes":{"address":pool},"relationships":{"base_token":{"data":{"id":"base_token"}}}},"included":[{"id":"base_token","type":"token","attributes":{"address":token}}]});
        assert!(pool_matches(&doc, "eip155:8453", token, pool));
        assert!(!pool_matches(&doc, "eip155:8453", pool, pool));
        assert!(!pool_matches(&doc, "eip155:8453", token, token));
    }
    #[test]
    fn range_is_a_rolling_window_not_the_selected_chart_interval() {
        let b = |time, high, low| crate::models::Bar {
            time,
            high,
            low,
            open: 1.,
            close: 1.,
            volume: 1.,
        };
        let bs = [
            b(99_000, 100., 0.),
            b(100_000, 4., 1.),
            b(199_000, 5., 0.5),
            b(200_000, 99., 0.),
        ];
        assert_eq!(range(&bs, 100, 200), (Some(5.), Some(0.5)));
        assert_eq!(range(&[], 100, 200), (None, None));
    }
    #[test]
    fn token_metrics_require_matching_network_and_address_without_fdv_fallback() {
        let q = MarketQuery {
            chain: "eip155:8453".into(),
            address: "0x1111111111111111111111111111111111111111".into(),
            pool: "0x2222222222222222222222222222222222222222".into(),
        };
        let v = json!({"data":{"type":"token","id":format!("base_{}",q.address),"attributes":{"address":q.address,"market_cap_usd":null,"fdv_usd":"100"}}});
        assert_eq!(token_metrics(&v, &q, "base"), (None, Some(100.)));
        assert_eq!(token_metrics(&v, &q, "eth"), (None, None));
        let mut wrong = v.clone();
        wrong["data"]["attributes"]["address"] = json!(q.pool);
        assert_eq!(token_metrics(&wrong, &q, "base"), (None, None));
    }
    #[test]
    fn quote_token_change_uses_sorted_completed_candles_and_preserves_losses() {
        let b = |time, open, close| crate::models::Bar {
            time,
            open,
            close,
            high: 10.,
            low: 1.,
            volume: 1.,
        };
        let bars = [
            b(199_000, 8., 6.),
            b(99_000, 10., 8.),
            b(100_000, 8., 7.),
            b(200_000, 6., 100.),
        ];
        assert_eq!(rolling_change(&bars, 100, 200), Some(-25.));
        assert_eq!(rolling_change(&[], 100, 200), None);
    }
    #[test]
    fn trades_use_target_direction_and_event_ids_not_just_transaction_hashes() {
        let token = "0x1111111111111111111111111111111111111111";
        let other = "0x2222222222222222222222222222222222222222";
        let a = json!({"tx_hash":format!("0x{}","a".repeat(64)),"block_timestamp":"2026-11-21T00:00:00Z","from_token_address":other,"to_token_address":token,"from_token_amount":"4","to_token_amount":"2","price_to_in_usd":"2","volume_in_usd":"4","kind":"sell"});
        let v = json!({"data":[{"id":"one","attributes":a},{"id":"one","attributes":a},{"id":"two","attributes":a}]});
        let rows = normalize_trades(&v, "eip155:1", token).unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| r.side == "buy" && r.quantity == "2"));
    }
}
