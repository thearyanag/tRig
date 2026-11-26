use super::{config::Config, types::*};
use crate::chain_registry;
use axum::http::StatusCode;
use reqwest::{Method, Url};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    sync::Mutex,
    time::{sleep_until, Instant},
};

#[derive(Clone)]
pub struct ChainSet {
    pub chains: Vec<Chain>,
    pub source: String,
    pub at: u64,
    pub warning: Option<String>,
}
struct Gate {
    next: Instant,
}
type TokenCache = HashMap<(Provider, String, String), (Token, u64)>;

pub struct Service {
    pub config: Config,
    client: reqwest::Client,
    gates: [Mutex<Gate>; 3],
    chains: Mutex<HashMap<Provider, ChainSet>>,
    tokens: Mutex<TokenCache>,
    pub quote_locks: [Mutex<()>; 3],
    pub quotes: Mutex<HashMap<QuoteRequest, Quote>>,
}
pub fn slot(p: Provider) -> usize {
    match p {
        Provider::Jupiter => 0,
        Provider::Relay => 1,
        Provider::Flash => 2,
    }
}
impl Service {
    pub fn new(config: Config) -> std::result::Result<Arc<Self>, reqwest::Error> {
        Ok(Arc::new(Self {
            config,
            client: reqwest::Client::builder()
                .user_agent("TradingWorkspace/0.1")
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(8))
                .timeout(Duration::from_secs(25))
                .build()?,
            gates: std::array::from_fn(|_| {
                Mutex::new(Gate {
                    next: Instant::now(),
                })
            }),
            chains: Mutex::new(HashMap::new()),
            tokens: Mutex::new(HashMap::new()),
            quote_locks: std::array::from_fn(|_| Mutex::new(())),
            quotes: Mutex::new(HashMap::new()),
        }))
    }
    pub async fn request(
        &self,
        p: Provider,
        method: Method,
        url: Url,
        body: Option<Value>,
        authenticated: bool,
    ) -> Result<Value> {
        let expected = match p {
            Provider::Jupiter => "api.jup.ag",
            Provider::Relay => "api.relay.link",
            Provider::Flash => "flash.definitive.fi",
        };
        if url.scheme() != "https" || url.host_str() != Some(expected) {
            return Err(Error::invalid("Unsupported provider URL."));
        }
        if authenticated && !self.config.ready(p) {
            return Err(Error::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "key_required",
                format!("Configure {} on this Mac to request quotes.", p.name()),
            ));
        }
        let mut gate = self.gates[slot(p)].lock().await;
        sleep_until(gate.next).await;
        let spacing = match p {
            Provider::Jupiter if self.config.key(p).is_some() => 1100,
            Provider::Jupiter => 2100,
            Provider::Relay => 1300,
            Provider::Flash => 250,
        };
        gate.next = Instant::now() + Duration::from_millis(spacing);
        let mut request = self
            .client
            .request(method, url)
            .header("Accept", "application/json");
        if authenticated {
            if let Some(key) = self.config.key(p) {
                let mut value = reqwest::header::HeaderValue::from_str(key)
                    .map_err(|_| Error::invalid("Invalid provider configuration."))?;
                value.set_sensitive(true);
                request = request.header(
                    if p == Provider::Flash {
                        "x-definitive-api-key"
                    } else {
                        "x-api-key"
                    },
                    value,
                );
            }
        }
        if let Some(body) = body {
            request = request.json(&body)
        }
        let response = request.send().await.map_err(|_| {
            Error::new(
                StatusCode::BAD_GATEWAY,
                "provider_unavailable",
                format!("{} could not be reached. Try again shortly.", p.name()),
            )
        })?;
        let status = response.status();
        if status == StatusCode::TOO_MANY_REQUESTS {
            let seconds = response
                .headers()
                .get("retry-after")
                .or_else(|| response.headers().get("ratelimit-reset"))
                .and_then(|h| h.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok())
                .map(|n| n.clamp(1, 120))
                .or_else(|| {
                    response
                        .headers()
                        .get("x-ratelimit-reset")
                        .and_then(|h| h.to_str().ok())
                        .and_then(|s| s.parse::<u64>().ok())
                        .map(|t| t.saturating_sub(crate::now()).clamp(1, 120))
                })
                .unwrap_or(30);
            gate.next = Instant::now() + Duration::from_secs(seconds);
            return Err(Error::new(
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
                format!(
                    "{} requested a cooldown. Retry in {seconds} seconds.",
                    p.name()
                ),
            ));
        }
        if [StatusCode::UNAUTHORIZED, StatusCode::FORBIDDEN].contains(&status) {
            return Err(Error::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_access",
                format!(
                    "{} access could not be confirmed. Check its configured key and permissions.",
                    p.name()
                ),
            ));
        }
        if [
            StatusCode::BAD_REQUEST,
            StatusCode::NOT_FOUND,
            StatusCode::UNPROCESSABLE_ENTITY,
        ]
        .contains(&status)
        {
            return Err(Error::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "route_unavailable",
                format!(
                    "{} could not quote this pair, amount or order type.",
                    p.name()
                ),
            ));
        }
        if !status.is_success() {
            return Err(Error::new(
                StatusCode::BAD_GATEWAY,
                "provider_unavailable",
                format!("{} quotes are temporarily unavailable.", p.name()),
            ));
        }
        let bytes = response.bytes().await.map_err(|_| Error::inconsistent(p))?;
        if bytes.len() > 4 * 1024 * 1024 {
            return Err(Error::inconsistent(p));
        }
        serde_json::from_slice(&bytes).map_err(|_| Error::inconsistent(p))
    }
    pub async fn chain_set(&self, p: Provider) -> Result<ChainSet> {
        let old = self.chains.lock().await.get(&p).cloned();
        if let Some(old) = &old {
            if crate::now().saturating_sub(old.at) < 600 {
                return Ok(old.clone());
            }
        }
        let result = match p {
            Provider::Jupiter => Ok(ChainSet {
                chains: vec![Chain {
                    id: "solana".into(),
                    name: "Solana".into(),
                    vm: "svm".into(),
                    provider_id: "solana".into(),
                    enabled: true,
                    deposit_enabled: true,
                    native_token: None,
                    minimum_order_usd: None,
                    rpc_url: None,
                }],
                source: "provider contract".into(),
                at: crate::now(),
                warning: None,
            }),
            Provider::Relay => {
                let registry = chain_registry::catalog();
                return Ok(ChainSet {
                    chains: registry
                        .chains
                        .iter()
                        .map(|chain| chain.relay_chain())
                        .collect(),
                    source: "bundled chain registry".into(),
                    at: registry.captured_at,
                    warning: None,
                });
            }
            Provider::Flash if self.config.ready(p) => self
                .request(
                    p,
                    Method::GET,
                    url("https://flash.definitive.fi/v1/chains"),
                    None,
                    true,
                )
                .await
                .and_then(|v| flash_chains(&v, false)),
            Provider::Flash => self
                .request(
                    p,
                    Method::GET,
                    url("https://flash.definitive.fi/v1/openapi.json"),
                    None,
                    false,
                )
                .await
                .and_then(|v| flash_chains(&v, true)),
        };
        match result {
            Ok(set) => {
                self.chains.lock().await.insert(p, set.clone());
                Ok(set)
            }
            Err(error) => {
                if let Some(mut old) = old {
                    old.warning = Some(
                        "Supported-chain data could not refresh. Saved coverage is shown.".into(),
                    );
                    Ok(old)
                } else {
                    Err(error)
                }
            }
        }
    }
    pub async fn token(&self, p: Provider, chain: &Chain, address: &str) -> Result<Token> {
        let key = (
            p,
            chain.id.clone(),
            super::amounts::canonical_address(&chain.vm, address),
        );
        if let Some((token, at)) = self.tokens.lock().await.get(&key).cloned() {
            if crate::now().saturating_sub(at) < if token.decimals.is_some() { 86400 } else { 60 } {
                return Ok(token);
            }
        }
        let token = if p == Provider::Flash {
            let shared = {
                let cache = self.tokens.lock().await;
                cache
                    .iter()
                    .find(|((_, id, a), (t, at))| {
                        id == &chain.id
                            && a == &key.2
                            && t.decimals.is_some()
                            && crate::now().saturating_sub(*at) < 86400
                    })
                    .map(|(_, (token, _))| token.clone())
            };
            if let Some(shared) = shared {
                shared
            } else {
                let metadata = if chain.id == "solana" {
                    self.lookup_token(Provider::Jupiter, chain, address)
                        .await
                        .ok()
                } else if self.config.ready(Provider::Relay) {
                    if let Ok(set) = self.chain_set(Provider::Relay).await {
                        if let Some(source) = set.chains.iter().find(|c| c.id == chain.id) {
                            if address
                                .eq_ignore_ascii_case("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
                            {
                                source.native_token.clone()
                            } else {
                                self.lookup_token(Provider::Relay, source, address)
                                    .await
                                    .ok()
                            }
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                } else {
                    None
                };
                metadata
                    .map(|mut t| {
                        t.address = address.into();
                        t
                    })
                    .unwrap_or_else(|| Token {
                        chain: chain.id.clone(),
                        address: address.into(),
                        symbol: if address.len() > 12 {
                            format!("{}…{}", &address[..4], &address[address.len() - 4..])
                        } else {
                            address.into()
                        },
                        decimals: None,
                    })
            }
        } else {
            self.lookup_token(p, chain, address).await?
        };
        let mut cache = self.tokens.lock().await;
        if cache.len() >= 256 {
            cache.clear()
        }
        cache.insert(key, (token.clone(), crate::now()));
        Ok(token)
    }
    async fn lookup_token(&self, p: Provider, chain: &Chain, address: &str) -> Result<Token> {
        if p == Provider::Relay {
            if let Some(native) = &chain.native_token {
                if super::amounts::same_address(&chain.vm, address, &native.address) {
                    return Ok(native.clone());
                }
            }
        }
        let value=match p {
   Provider::Jupiter=>{let mut u=url("https://api.jup.ag/tokens/v2/search");u.query_pairs_mut().append_pair("query",address);self.request(p,Method::GET,u,None,true).await?},
   Provider::Relay=>self.request(p,Method::POST,url("https://api.relay.link/currencies/v2"),Some(json!({"chainIds":[chain.provider_id.parse::<u64>().map_err(|_|Error::inconsistent(p))?],"address":address,"limit":5,"useExternalSearch":true})),true).await?,
   Provider::Flash=>return Err(Error::invalid("Flash uses shared token metadata.")),
  };
        let rows = value.as_array().ok_or_else(|| Error::inconsistent(p))?;
        let row = rows
            .iter()
            .find(|v| {
                let id = if p == Provider::Jupiter {
                    v["id"].as_str()
                } else {
                    v["address"].as_str()
                };
                id.is_some_and(|id| super::amounts::same_address(&chain.vm, id, address))
                    && match p {
                        Provider::Relay => {
                            v["chainId"].as_u64().map(|id| id.to_string())
                                == Some(chain.provider_id.clone())
                        }

                        _ => true,
                    }
            })
            .ok_or_else(|| {
                Error::new(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "token_unavailable",
                    "This exact token is not available from the selected provider.",
                )
            })?;
        let decimals = row["decimals"]
            .as_u64()
            .and_then(|d| u8::try_from(d).ok())
            .ok_or_else(|| Error::inconsistent(p))?;
        let symbol = row["symbol"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| Error::inconsistent(p))?
            .chars()
            .take(40)
            .collect();
        let token = Token {
            chain: chain.id.clone(),
            address: address.into(),
            symbol,
            decimals: Some(decimals),
        };

        Ok(token)
    }
}
pub fn url(s: &str) -> Url {
    Url::parse(s).expect("fixed provider URL")
}
pub fn flash_chains(v: &Value, schema: bool) -> Result<ChainSet> {
    let mut chains = Vec::new();
    if schema {
        let names = v["components"]["schemas"]["Chain"]["enum"]
            .as_array()
            .ok_or_else(|| Error::inconsistent(Provider::Flash))?;
        // The public schema supplies identifiers; EVM IDs come from its maintained RPC docs only
        // when the keyed registry is unavailable. Use namespaced IDs until the live registry loads.
        for name in names.iter().filter_map(Value::as_str) {
            chains.push(Chain {
                id: if name == "solana" {
                    "solana".into()
                } else {
                    format!("flash:{name}")
                },
                name: name.into(),
                vm: if name == "solana" { "svm" } else { "evm" }.into(),
                provider_id: name.into(),
                enabled: true,
                deposit_enabled: true,
                native_token: None,
                minimum_order_usd: None,
                rpc_url: None,
            });
        }
    } else {
        for c in v["chains"]
            .as_array()
            .ok_or_else(|| Error::inconsistent(Provider::Flash))?
            .iter()
            .take(1000)
        {
            let Some(name) = c["chain"].as_str() else {
                continue;
            };
            let key = if name == "solana" {
                "solana".into()
            } else {
                format!(
                    "eip155:{}",
                    c["chainId"]
                        .as_u64()
                        .ok_or_else(|| Error::inconsistent(Provider::Flash))?
                )
            };
            chains.push(Chain {
                id: key,
                name: name.into(),
                vm: if name == "solana" { "svm" } else { "evm" }.into(),
                provider_id: name.into(),
                enabled: true,
                deposit_enabled: true,
                native_token: None,
                minimum_order_usd: super::amounts::nonnegative(&c["minimumOrderNotionalUsd"]),
                rpc_url: None,
            });
        }
    }
    if chains.is_empty() {
        return Err(Error::inconsistent(Provider::Flash));
    }
    chains.retain_mut(|chain| {
        let entry = if schema {
            chain_registry::catalog()
                .chains
                .iter()
                .find(|entry| entry.name.eq_ignore_ascii_case(&chain.provider_id))
        } else {
            chain_registry::get(&chain.id)
        };
        let Some(entry) = entry else {
            return false;
        };
        chain.id = entry.chain_id();
        chain.name = entry.display_name.clone();
        true
    });
    Ok(ChainSet {
        chains,
        source: if schema {
            "public provider schema"
        } else {
            "live chain registry"
        }
        .into(),
        at: crate::now(),
        warning: schema
            .then(|| "Configure Flash to load its live chain identifiers and minimums.".into()),
    })
}
