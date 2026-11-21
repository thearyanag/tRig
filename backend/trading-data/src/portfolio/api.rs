use super::{storage::*, Period};
use crate::{ApiError, AppState};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CacheQuery {
    period: Period,
}
async fn run<T: Send + 'static>(
    repo: Arc<Repository>,
    f: impl FnOnce(&Repository) -> Result<T, StoreError> + Send + 'static,
) -> Result<T, ApiError> {
    tokio::task::spawn_blocking(move || f(&repo))
        .await
        .map_err(|_| {
            ApiError(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Portfolio storage could not respond.".into(),
            )
        })?
        .map_err(|e| match e {
            StoreError::Invalid => {
                ApiError(StatusCode::BAD_REQUEST, "Invalid portfolio update.".into())
            }
            StoreError::Conflict => ApiError(
                StatusCode::CONFLICT,
                "Portfolio accounts or refresh changed. Reload the saved view.".into(),
            ),
            StoreError::Database => ApiError(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Portfolio storage is unavailable. Your last saved data has been retained.".into(),
            ),
        })
}
pub async fn cached(
    State(s): State<AppState>,
    Query(q): Query<CacheQuery>,
) -> Result<Json<CachedPortfolio>, ApiError> {
    run(s.portfolio, move |repo| {
        repo.read(q.period, crate::now() as f64)
    })
    .await
    .map(Json)
}
pub async fn accounts(
    State(s): State<AppState>,
    Json(r): Json<AccountsRequest>,
) -> Result<Json<Value>, ApiError> {
    run(s.portfolio, move |repo| repo.accounts(r)).await?;
    Ok(Json(json!({"ok":true})))
}
pub async fn claim(
    State(s): State<AppState>,
    Json(r): Json<SyncRequest>,
) -> Result<Json<SyncPlan>, ApiError> {
    run(s.portfolio, move |repo| repo.claim(r, crate::now() as f64))
        .await
        .map(Json)
}
pub async fn complete(
    State(s): State<AppState>,
    Json(r): Json<CompleteRequest>,
) -> Result<Json<Value>, ApiError> {
    run(s.portfolio, move |repo| {
        repo.complete(r, crate::now() as f64)
    })
    .await?;
    Ok(Json(json!({"ok":true})))
}
