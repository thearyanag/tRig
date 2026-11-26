pub mod amounts;
pub mod config;
pub mod providers;
pub mod service;
#[cfg(test)]
mod tests;
pub mod types;
use crate::{chain_registry, AppState};
use axum::{extract::State, http::StatusCode, Json};
use reqwest::Method;
use types::*;

pub async fn catalog(State(state): State<AppState>) -> Json<Vec<ProviderInfo>> {
    async fn info(state: &AppState, p: Provider) -> ProviderInfo {
        let result = state.execution.chain_set(p).await;
        let (chains, source, at, warning) = match result {
            Ok(s) => (s.chains, s.source, s.at, s.warning),
            Err(_) => (
                vec![],
                "unavailable".into(),
                0,
                Some("Supported chains could not be loaded. Retry shortly.".into()),
            ),
        };
        ProviderInfo {
            id: p,
            name: p.name(),
            configured: state.execution.config.ready(p),
            order_types: if p == Provider::Flash {
                vec![OrderType::Market, OrderType::Limit, OrderType::StopLoss]
            } else {
                vec![OrderType::Market]
            },
            chains,
            metadata_source: source,
            warning,
            metadata_as_of: at,
            sender_required: p == Provider::Relay,
            sender_required_cross_chain: p != Provider::Jupiter,
            recipient_required_cross_chain: p != Provider::Jupiter,
        }
    }
    let (j, r, f) = tokio::join!(
        info(&state, Provider::Jupiter),
        info(&state, Provider::Relay),
        info(&state, Provider::Flash)
    );
    Json(vec![j, r, f])
}
pub fn choose(r: &QuoteRequest) -> Provider {
    r.provider.unwrap_or(if r.order_type != OrderType::Market {
        Provider::Flash
    } else if r.input.chain == "solana" && r.output.chain == "solana" {
        Provider::Jupiter
    } else {
        Provider::Relay
    })
}
pub fn validate_route(r: &QuoteRequest, p: Provider, from: &Chain, to: &Chain) -> Result<()> {
    amounts::validate(r)?;
    if !from.enabled || !to.enabled || !from.deposit_enabled {
        return Err(Error::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "chain_unavailable",
            "This chain is temporarily unavailable for the selected provider.",
        ));
    }
    if !amounts::address(&from.vm, &r.input.address) || !amounts::address(&to.vm, &r.output.address)
    {
        return Err(Error::invalid(
            "The token address does not match its chain.",
        ));
    }
    if p != Provider::Flash && r.order_type != OrderType::Market {
        return Err(Error::invalid("This provider supports market quotes only."));
    }
    if r.order_type != OrderType::Market && r.input.chain != r.output.chain {
        return Err(Error::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "unsupported_order",
            "Limit and stop-loss quotes currently require a same-chain pair.",
        ));
    }
    Ok(())
}
pub async fn quote(
    State(state): State<AppState>,
    Json(r): Json<QuoteRequest>,
) -> Result<Json<Quote>> {
    fetch(&state, r).await.map(Json)
}

pub async fn fetch(state: &AppState, mut r: QuoteRequest) -> Result<Quote> {
    r.amount = r.amount.trim().to_string();
    amounts::validate(&r)?;
    if [&r.input, &r.output]
        .iter()
        .any(|token| chain_registry::get(&token.chain).is_none())
    {
        return Err(Error::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "unsupported_chain",
            "Choose a supported tRig network.",
        ));
    }
    let preferred = choose(&r);
    let candidates = if r.provider.is_some() {
        vec![preferred]
    } else if r.order_type != OrderType::Market {
        vec![Provider::Flash]
    } else if preferred == Provider::Jupiter {
        vec![Provider::Jupiter, Provider::Relay, Provider::Flash]
    } else {
        vec![Provider::Relay, Provider::Flash]
    };
    let mut selected = None;
    for candidate in candidates {
        if !state.execution.config.ready(candidate) {
            continue;
        }
        let Ok(set) = state.execution.chain_set(candidate).await else {
            continue;
        };
        if set
            .chains
            .iter()
            .any(|c| c.id == r.input.chain && c.enabled && c.deposit_enabled)
            && set
                .chains
                .iter()
                .any(|c| c.id == r.output.chain && c.enabled)
        {
            selected = Some(candidate);
            break;
        }
    }
    let p = selected.unwrap_or(preferred);
    if !state.execution.config.ready(p) {
        return Err(Error::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "key_required",
            format!(
                "Configure {} in the server's quotes.env file, then restart the app.",
                p.name()
            ),
        ));
    }
    let _lock = state.execution.quote_locks[service::slot(p)].lock().await;
    if let Some(q) = state
        .execution
        .quotes
        .lock()
        .await
        .get(&r)
        .filter(|q| crate::now().saturating_sub(q.fetched_at) < 3 && q.expires_at > crate::now())
        .cloned()
    {
        return Ok(q);
    }
    let chains = state.execution.chain_set(p).await?;
    let find = |id: &str| {
        chains
            .chains
            .iter()
            .find(|c| c.id == id)
            .cloned()
            .ok_or_else(|| {
                Error::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "unsupported_chain",
                    format!("{} does not currently list this chain.", p.name()),
                )
            })
    };
    let from = find(&r.input.chain)?;
    let to = find(&r.output.chain)?;
    validate_route(&r, p, &from, &to)?;
    // Validate context before token lookups so a missing address never consumes multiple calls.
    let body = match p {
        Provider::Flash => Some(providers::flash_body(&r, &from, &to)?),
        Provider::Relay => {
            if r.context.sender.is_none()
                || r.input.chain != r.output.chain && r.context.recipient.is_none()
            {
                return Err(Error::new(StatusCode::BAD_REQUEST,"address_context_required","Enter public sender/destination addresses for this estimate. No wallet connection or funding authorization is needed."));
            }
            None
        }
        _ => None,
    };
    let input = state.execution.token(p, &from, &r.input.address).await?;
    let output = state.execution.token(p, &to, &r.output.address).await?;
    let value = match p {
        Provider::Jupiter => {
            let amount = crate::quotes::atomic(&r.amount, input.precision(p)?)
                .map_err(|e| Error::invalid(e.1))?;
            let q = crate::quotes::QuoteQuery {
                asset_mint: r.output.address.clone(),
                side: crate::quotes::Side::Buy,
                amount: r.amount.clone(),
                slippage_bps: r.slippage_bps,
            };
            let a = crate::quotes::Token {
                id: input.address.clone(),
                symbol: input.symbol.clone(),
                decimals: input.precision(p)?,
            };
            let b = crate::quotes::Token {
                id: output.address.clone(),
                symbol: output.symbol.clone(),
                decimals: output.precision(p)?,
            };
            state
                .execution
                .request(
                    p,
                    Method::GET,
                    crate::quotes::order_url(&q, &a, &b, amount),
                    None,
                    true,
                )
                .await?
        }
        Provider::Relay => {
            state
                .execution
                .request(
                    p,
                    Method::POST,
                    service::url("https://api.relay.link/quote/v2"),
                    Some(providers::relay_body(&r, &from, &to, &input)?),
                    true,
                )
                .await?
        }
        Provider::Flash => {
            state
                .execution
                .request(
                    p,
                    Method::POST,
                    service::url("https://flash.definitive.fi/v1/quote"),
                    body,
                    true,
                )
                .await?
        }
    };
    let mut result = match p {
        Provider::Jupiter => providers::normalize_jupiter(&value, &r, input, output, crate::now())?,
        Provider::Relay => {
            providers::normalize_relay(&value, &r, &from, &to, input, output, crate::now())?
        }
        Provider::Flash => providers::normalize_flash(&value, &r, input, output, crate::now())?,
    };
    if let Some(warning) = chains.warning {
        result.warnings.push(warning)
    }
    let mut cache = state.execution.quotes.lock().await;
    if cache.len() >= 64 {
        cache.retain(|_, q| crate::now().saturating_sub(q.fetched_at) < 3)
    }
    if cache.len() >= 64 {
        cache.clear()
    }
    cache.insert(r, result.clone());
    Ok(result)
}
