pub mod discovery;
pub mod models;

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use models::*;
use serde_json::json;
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    sync::Mutex,
    time::{sleep_until, Instant},
};
use tower_http::services::ServeDir;

const REQUEST_SPACING: Duration = Duration::from_secs(7);
const LATEST_CACHE_TTL: Duration = Duration::from_secs(25);

/// Conservative bound within the public provider's six-month historical window.
pub fn history_floor(at: u64) -> u64 {
    (at / 86400).saturating_sub(180) * 86400
}

#[derive(Clone)]
pub struct AppState {
    client: reqwest::Client,
    feed: Arc<Mutex<FeedState>>,
    gate: Arc<Mutex<Instant>>,
    discovery: Arc<Mutex<HashMap<String, discovery::CachedSearch>>>,
}
struct FeedState {
    cache: HashMap<CacheKey, CacheEntry>,
}
struct CacheEntry {
    expires: Instant,
    response: BarsResponse,
}

pub fn router(assets: std::path::PathBuf) -> Result<Router, reqwest::Error> {
    let state = AppState {
        client: reqwest::Client::builder()
            .user_agent("tRig/0.1")
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(25))
            .build()?,
        feed: Arc::new(Mutex::new(FeedState {
            cache: HashMap::new(),
        })),
        gate: Arc::new(Mutex::new(Instant::now())),
        discovery: Arc::new(Mutex::new(HashMap::new())),
    };
    Ok(Router::new()
        .route(
            "/api/health",
            get(|| async {
                Json(json!({"status":"ok", "pid":std::process::id(), "network":"solana"}))
            }),
        )
        .route("/api/chart/bars", get(bars))
        .route("/api/assets/search", get(discovery::search))
        .route("/api/assets/resolve", get(discovery::resolve))
        .fallback_service(ServeDir::new(assets).append_index_html_on_directories(true))
        .with_state(state))
}

#[derive(Debug)]
pub struct ApiError(StatusCode, String);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error":self.1}))).into_response()
    }
}

pub fn resolution(value: &str) -> Option<(&'static str, u32)> {
    match value {
        "1" => Some(("minute", 1)),
        "5" => Some(("minute", 5)),
        "15" => Some(("minute", 15)),
        "60" => Some(("hour", 1)),
        "240" => Some(("hour", 4)),
        "720" => Some(("hour", 12)),
        "1D" => Some(("day", 1)),
        _ => None,
    }
}

pub fn validated_key(query: BarsQuery) -> Result<CacheKey, ApiError> {
    if resolution(&query.resolution).is_none() {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Unsupported chart interval".into(),
        ));
    }
    let limit = query.limit.unwrap_or(300);
    if limit == 0
        || limit > 1000
        || query
            .before
            .is_some_and(|time| time == 0 || time > now() + 86400)
    {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Invalid candle range".into(),
        ));
    }
    let mint = query
        .mint
        .ok_or_else(|| ApiError(StatusCode::BAD_REQUEST, "Asset identity is required".into()))?;
    let pool = query
        .pool
        .ok_or_else(|| ApiError(StatusCode::BAD_REQUEST, "Asset identity is required".into()))?;
    if !discovery::is_address(&mint) || !discovery::is_address(&pool) {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Invalid asset identity".into(),
        ));
    }
    Ok(CacheKey {
        mint,
        pool,
        resolution: query.resolution,
        before: query.before,
        limit,
    })
}

pub fn normalize(rows: Vec<[f64; 6]>) -> Result<Vec<Bar>, ApiError> {
    let mut bars = Vec::with_capacity(rows.len());
    for row in rows {
        let [time, open, high, low, close, volume] = row;
        if row.iter().any(|n| !n.is_finite())
            || time <= 0.0
            || time.fract() != 0.0
            || time > 9_000_000_000.0
            || low < 0.0
            || volume < 0.0
            || low > open.min(close)
            || high < open.max(close)
            || high < low
        {
            return Err(ApiError(
                StatusCode::BAD_GATEWAY,
                "Provider returned invalid candle data".into(),
            ));
        }
        bars.push(Bar {
            time: (time as i64) * 1000,
            open,
            high,
            low,
            close,
            volume,
        });
    }
    bars.sort_by_key(|bar| bar.time);
    bars.dedup_by_key(|bar| bar.time);
    Ok(bars)
}

async fn bars(
    State(state): State<AppState>,
    Query(query): Query<BarsQuery>,
) -> Result<Json<BarsResponse>, ApiError> {
    let key = validated_key(query)?;
    let floor = history_floor(now());
    if key.before.is_some_and(|before| before <= floor) {
        return Ok(Json(BarsResponse {
            bars: Vec::new(),
            fetched_at: now(),
            cached: true,
            pool: key.pool.clone(),
            mint: key.mint.clone(),
            provider: "GeckoTerminal",
        }));
    }
    // One gate for all timeframes/windows: deduplicate misses and stay below 10 requests/min.
    let mut feed = state.feed.lock().await;
    if let Some(entry) = feed
        .cache
        .get(&key)
        .filter(|entry| entry.expires > Instant::now())
    {
        let mut response = entry.response.clone();
        response.cached = true;
        return Ok(Json(response));
    }
    let (timeframe, aggregate) = resolution(&key.resolution).expect("validated resolution");
    let mut url = reqwest::Url::parse(&format!(
        "https://api.geckoterminal.com/api/v2/networks/solana/pools/{}/ohlcv/{timeframe}",
        key.pool
    ))
    .expect("fixed provider URL");
    {
        let mut params = url.query_pairs_mut();
        params.append_pair("aggregate", &aggregate.to_string());
        params.append_pair("limit", &key.limit.to_string());
        params.append_pair("currency", "usd");
        params.append_pair("token", &key.mint);
        params.append_pair("include_empty_intervals", "false");
        if let Some(before) = key.before {
            params.append_pair("before_timestamp", &before.to_string());
        }
    }
    let body: ProviderResponse = serde_json::from_value(provider_json(&state, url).await?)
        .map_err(|_| ApiError(StatusCode::BAD_GATEWAY, "Unexpected candle response".into()))?;
    let response = BarsResponse {
        bars: normalize(body.data.attributes.ohlcv_list)?
            .into_iter()
            .filter(|bar| bar.time >= (floor as i64) * 1000)
            .collect(),
        fetched_at: now(),
        cached: false,
        pool: key.pool.clone(),
        mint: key.mint.clone(),
        provider: "GeckoTerminal",
    };
    let ttl = if key.before.is_some() {
        Duration::from_secs(3600)
    } else {
        LATEST_CACHE_TTL
    };
    if feed.cache.len() >= 128 {
        feed.cache.retain(|_, entry| entry.expires > Instant::now());
    }
    if feed.cache.len() >= 128 {
        feed.cache.clear();
    }
    feed.cache.insert(
        key,
        CacheEntry {
            expires: Instant::now() + ttl,
            response: response.clone(),
        },
    );
    Ok(Json(response))
}

async fn provider_json(state: &AppState, url: reqwest::Url) -> Result<serde_json::Value, ApiError> {
    let mut gate = state.gate.lock().await;
    sleep_until(*gate).await;
    *gate = Instant::now() + REQUEST_SPACING;
    let upstream = state.client.get(url).send().await.map_err(|error| {
        eprintln!("GeckoTerminal request failed: {error}");
        ApiError(
            StatusCode::BAD_GATEWAY,
            "Could not reach GeckoTerminal. Try again shortly.".into(),
        )
    })?;
    if upstream.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
        *gate = Instant::now() + Duration::from_secs(60);
        return Err(ApiError(
            StatusCode::TOO_MANY_REQUESTS,
            "GeckoTerminal rate limit reached. Retry in one minute.".into(),
        ));
    }
    if !upstream.status().is_success() {
        eprintln!("GeckoTerminal HTTP {}", upstream.status());
        return Err(ApiError(
            if upstream.status() == reqwest::StatusCode::NOT_FOUND {
                StatusCode::NOT_FOUND
            } else {
                StatusCode::BAD_GATEWAY
            },
            "GeckoTerminal could not return market data.".into(),
        ));
    }
    let body: serde_json::Value = upstream.json().await.map_err(|error| {
        eprintln!("GeckoTerminal response could not be parsed: {error}");
        ApiError(
            StatusCode::BAD_GATEWAY,
            "GeckoTerminal returned an unexpected response.".into(),
        )
    })?;
    Ok(body)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn free_history_boundary_is_aligned_and_bounded() {
        let timestamp = 180 * 86400 + 12345;
        assert_eq!(history_floor(timestamp), 0);
        assert_eq!(history_floor(timestamp + 86400), 86400);
    }
    #[test]
    fn resolution_mapping_preserves_requested_interval() {
        assert_eq!(resolution("5"), Some(("minute", 5)));
        assert_eq!(resolution("240"), Some(("hour", 4)));
        assert_eq!(resolution("1D"), Some(("day", 1)));
        assert_eq!(resolution("30"), None);
    }
    #[test]
    fn candles_are_sorted_deduplicated_and_converted_to_milliseconds() {
        let bars = normalize(vec![
            [20.0, 2.0, 3.0, 1.0, 2.5, 4.0],
            [10.0, 1.0, 2.0, 0.5, 1.5, 6.0],
            [20.0, 2.0, 3.0, 1.0, 2.5, 4.0],
        ])
        .unwrap();
        assert_eq!(bars.len(), 2);
        assert_eq!(bars[0].time, 10000);
        assert_eq!(bars[1].time, 20000);
        assert_eq!(bars[0].volume, 6.0);
    }
    #[test]
    fn empty_history_is_data_but_corrupt_candles_are_errors() {
        assert!(normalize(vec![]).unwrap().is_empty());
        assert!(normalize(vec![[1.0, 2.0, 1.0, 3.0, 2.0, 0.0]]).is_err());
        assert!(normalize(vec![[1.0, f64::NAN, 3.0, 1.0, 2.0, 0.0]]).is_err());
        assert!(serde_json::from_str::<ProviderResponse>("{}").is_err());
    }
    #[test]
    fn cache_keys_are_scoped_to_asset_identity() {
        let make = |mint: &str| {
            validated_key(BarsQuery {
                mint: Some(mint.into()),
                pool: Some(BP_POOL.into()),
                resolution: "1D".into(),
                before: None,
                limit: Some(10),
            })
            .unwrap()
        };
        assert_ne!(
            make(BP_MINT),
            make("So11111111111111111111111111111111111111112")
        );
        assert!(validated_key(BarsQuery {
            resolution: "1D".into(),
            ..Default::default()
        })
        .is_err());
    }
    #[test]
    fn bad_or_unbounded_ranges_are_rejected() {
        assert!(validated_key(BarsQuery {
            resolution: "1D".into(),
            before: None,
            limit: Some(1001),
            ..Default::default()
        })
        .is_err());
        assert!(validated_key(BarsQuery {
            resolution: "99".into(),
            before: None,
            limit: Some(10),
            ..Default::default()
        })
        .is_err());
        assert!(validated_key(BarsQuery {
            resolution: "1".into(),
            before: Some(0),
            limit: None,
            ..Default::default()
        })
        .is_err());
    }
}
