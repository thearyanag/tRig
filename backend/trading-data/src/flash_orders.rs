use crate::{
    execution::{
        amounts,
        service::{url, Service},
        types::{Error, Provider, Result},
    },
    AppState,
};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

const ORDERS: &str = "https://flash.definitive.fi/v1/orders";

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Family {
    Solana,
    Evm,
}

impl Family {
    fn vm(self) -> &'static str {
        match self {
            Self::Solana => "svm",
            Self::Evm => "evm",
        }
    }

    fn accept_funder(self, funder: &str) -> bool {
        amounts::address(self.vm(), funder)
            && match self {
                Self::Evm => funder.starts_with("0x"),
                Self::Solana => true,
            }
    }

    fn accept_signature(self, signature: &str) -> bool {
        match self {
            Self::Evm => signature.strip_prefix("0x").is_some_and(|value| {
                value.len() == 130 && value.bytes().all(|c| c.is_ascii_hexdigit())
            }),
            Self::Solana => {
                (64..=88).contains(&signature.len())
                    && bs58::decode(signature)
                        .into_vec()
                        .is_ok_and(|bytes| bytes.len() == 64)
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListRequest {
    funder: String,
    family: Family,
    page_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CancelRequest {
    order_id: String,
    funder: String,
    family: Family,
    signature: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderOrder {
    order_id: String,
    order_type: String,
    side: String,
    status: String,
    funder_address: String,
    target_asset: ProviderAsset,
    contra_asset: ProviderAsset,
    qty: String,
    limit_notional_price: Option<String>,
    trigger: Option<ProviderTrigger>,
    placed_at: String,
    filled: Option<ProviderFill>,
}

#[derive(Deserialize)]
struct ProviderAsset {
    ticker: String,
    chain: ProviderChain,
}

#[derive(Deserialize)]
struct ProviderChain {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderTrigger {
    notional_price: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderFill {
    target_amount: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderPage {
    orders: Vec<Value>,
    next_page_token: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlashOrder {
    order_id: String,
    order_type: String,
    side: String,
    status: &'static str,
    chain: String,
    asset: String,
    spend_asset: String,
    quantity: String,
    price: Option<String>,
    can_cancel: bool,
    placed_at: String,
    filled_quantity: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlashOrderPage {
    orders: Vec<FlashOrder>,
    next_page_token: Option<String>,
}

fn response_error() -> Error {
    Error::new(
        StatusCode::BAD_GATEWAY,
        "invalid_flash_response",
        "Flash returned an unexpected order response.",
    )
}

pub(crate) fn canonical_order_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')
            }
        })
}

fn cancel_message(id: &str) -> String {
    format!("Definitive Flash v1 — Cancel Order\nOrder: {id}")
}

fn order_status(status: &str) -> (&'static str, bool) {
    match status {
        "ORDER_STATUS_PENDING" => ("Pending", true),
        "ORDER_STATUS_ACCEPTED" => ("Open", true),
        "ORDER_STATUS_PARTIALLY_FILLED" => ("Partially filled", true),
        "ORDER_STATUS_PENDING_CANCEL" => ("Cancel pending", false),
        "ORDER_STATUS_FILLED" => ("Filled", false),
        "ORDER_STATUS_CANCELLED" => ("Cancelled", false),
        "ORDER_STATUS_REJECTED" => ("Rejected", false),
        "ORDER_STATUS_EXPIRED" => ("Expired", false),
        "ORDER_STATUS_TERMINATED" => ("Closed", false),
        _ => ("Unknown", false),
    }
}

fn normalize(value: Value, family: Family, funder: &str) -> Option<FlashOrder> {
    let order: ProviderOrder = serde_json::from_value(value).ok()?;
    if !canonical_order_id(&order.order_id)
        || !matches!(
            order.order_type.as_str(),
            "limit"
                | "stop"
                | "stop-loss"
                | "take-profit"
                | "bracket"
                | "trailing-stop"
                | "trailing-stop-limit"
        )
        || !matches!(order.side.as_str(), "buy" | "sell")
        || !amounts::same_address(family.vm(), &order.funder_address, funder)
    {
        return None;
    }
    let (status, can_cancel) = order_status(&order.status);
    let spend_asset = if order.side == "buy" {
        order.contra_asset.ticker
    } else {
        order.target_asset.ticker.clone()
    };
    Some(FlashOrder {
        order_id: order.order_id,
        order_type: order.order_type,
        side: order.side,
        status,
        chain: order.target_asset.chain.name,
        asset: order.target_asset.ticker,
        spend_asset,
        quantity: order.qty,
        price: order
            .limit_notional_price
            .or_else(|| order.trigger.and_then(|value| value.notional_price)),
        can_cancel,
        placed_at: order.placed_at,
        filled_quantity: order
            .filled
            .and_then(|fill| fill.target_amount)
            .and_then(|amount| amounts::positive(&json!(amount))),
    })
}

async fn fetch_order(service: &Service, request: &CancelRequest) -> Result<FlashOrder> {
    let mut endpoint = url(&format!("{ORDERS}/{}", request.order_id));
    endpoint
        .query_pairs_mut()
        .append_pair("funderAddress", &request.funder);
    let response = service
        .request(Provider::Flash, Method::GET, endpoint, None, true)
        .await?;
    let order = normalize(response["order"].clone(), request.family, &request.funder)
        .filter(|order| order.order_id == request.order_id)
        .ok_or_else(response_error)?;
    Ok(order)
}

pub async fn list(
    State(state): State<AppState>,
    Query(request): Query<ListRequest>,
) -> Result<Json<FlashOrderPage>> {
    if !request.family.accept_funder(&request.funder)
        || request
            .page_token
            .as_ref()
            .is_some_and(|token| token.len() > 2048)
    {
        return Err(Error::invalid("Choose a valid funding wallet."));
    }
    let mut endpoint = url(ORDERS);
    {
        let mut query = endpoint.query_pairs_mut();
        query.append_pair("funderAddress", &request.funder);
        query.append_pair("pageSize", "50");
        if let Some(ref token) = request.page_token {
            query.append_pair("pageToken", token);
        }
    }
    let response = state
        .execution
        .request(Provider::Flash, Method::GET, endpoint, None, true)
        .await?;
    let page: ProviderPage = serde_json::from_value(response).map_err(|_| response_error())?;
    let mut seen = HashSet::new();
    let orders = page
        .orders
        .into_iter()
        .filter_map(|value| normalize(value, request.family, &request.funder))
        .filter(|order| seen.insert(order.order_id.clone()))
        .collect();
    Ok(Json(FlashOrderPage {
        orders,
        next_page_token: page
            .next_page_token
            .filter(|token| !token.is_empty() && token.len() <= 2048),
    }))
}

pub async fn cancel(
    State(state): State<AppState>,
    Json(request): Json<CancelRequest>,
) -> Result<Json<FlashOrder>> {
    if !canonical_order_id(&request.order_id)
        || !request.family.accept_funder(&request.funder)
        || !request.family.accept_signature(&request.signature)
    {
        return Err(Error::invalid("Invalid signed Flash cancellation."));
    }
    let order = fetch_order(&state.execution, &request).await?;
    if order.status == "Cancelled" {
        return Ok(Json(order));
    }
    if !order.can_cancel {
        return Err(Error::new(
            StatusCode::CONFLICT,
            "order_not_cancellable",
            "This order can no longer be cancelled. Refresh Orders for its latest status.",
        ));
    }
    let endpoint = url(&format!("{ORDERS}/{}/cancel", request.order_id));
    let result = state
        .execution
        .request(
            Provider::Flash,
            Method::POST,
            endpoint,
            Some(json!({
                "cancelMessage": cancel_message(&request.order_id),
                "userSignature": request.signature,
            })),
            true,
        )
        .await;
    match result {
        Ok(response) if response["ok"].as_bool() == Some(true) => {
            // The cancel endpoint acknowledged this request. A lagging detail response must
            // not make the order appear active again while cancellation is being reconciled.
            let updated = fetch_order(&state.execution, &request)
                .await
                .unwrap_or(order);
            if !updated.can_cancel {
                return Ok(Json(updated));
            }
            Ok(Json(FlashOrder {
                status: "Cancel pending",
                can_cancel: false,
                ..updated
            }))
        }
        _ => {
            if let Ok(updated) = fetch_order(&state.execution, &request).await {
                if !updated.can_cancel {
                    return Ok(Json(updated));
                }
            }
            Err(Error::new(
                StatusCode::BAD_GATEWAY,
                "flash_cancel_unconfirmed",
                "Cancellation could not be confirmed. Refresh Orders to check its status.",
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FUNDER: &str = "0xAbCd000000000000000000000000000000000000";
    const ORDER: &str = "deadbeef-1234-abcd-9876-000000000001";

    fn fixture(status: &str) -> Value {
        json!({
            "orderId": ORDER, "orderType": "take-profit", "side": "sell",
            "status": status, "funderAddress": FUNDER.to_ascii_lowercase(),
            "targetAsset": {"ticker": "WETH", "chain": {"name": "Base"}},
            "contraAsset": {"ticker": "USDC", "chain": {"name": "Base"}},
            "qty": "0.25", "trigger": {"notionalPrice": "2400"},
            "placedAt": "2026-05-12T00:00:00Z"
        })
    }

    #[test]
    fn list_binds_funder_and_normalizes_only_conditional_orders() {
        let value = fixture("ORDER_STATUS_ACCEPTED");
        let order = normalize(value.clone(), Family::Evm, FUNDER).unwrap();
        assert_eq!(order.price.as_deref(), Some("2400"));
        assert_eq!(order.spend_asset, "WETH");
        assert!(order.can_cancel);
        assert!(normalize(value.clone(), Family::Evm, "0x0").is_none());
        let mut market = value;
        market["orderType"] = json!("market");
        assert!(normalize(market, Family::Evm, FUNDER).is_none());
        assert!(
            !normalize(fixture("ORDER_STATUS_FILLED"), Family::Evm, FUNDER)
                .unwrap()
                .can_cancel
        );
    }

    #[test]
    fn cancel_message_is_strictly_domain_separated_and_addressed_by_uuid() {
        assert!(canonical_order_id(ORDER));
        assert!(!canonical_order_id(&ORDER.to_ascii_uppercase()));
        assert!(!canonical_order_id("../orders"));
        assert_eq!(
            cancel_message(ORDER),
            "Definitive Flash v1 — Cancel Order\nOrder: deadbeef-1234-abcd-9876-000000000001"
        );
    }
}
