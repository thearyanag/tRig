use super::types::*;
use bigdecimal::{BigDecimal as N, Zero};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

fn string_at(value: &Value, key: &str, fallback: &str) -> String {
    value[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or(fallback)
        .chars()
        .take(160)
        .collect()
}
fn owner(chain: &str, raw: &Value, primary: &str, evm: Option<&str>) -> String {
    if let Some(value) = raw.as_str().filter(|s| valid_wallet(s)) {
        if chain == "solana" && crate::discovery::is_address(value) {
            return value.into();
        }
        if chain.starts_with("eip155:") && value.starts_with("0x") {
            return address(value);
        }
    }
    if chain == "solana" {
        primary.into()
    } else {
        evm.map(address)
            .unwrap_or_else(|| format!("unresolved:{primary}"))
    }
}
fn point_time(value: &Value) -> Option<i64> {
    let value = number(value)?.to_string().parse::<f64>().ok()?;
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    Some(if value > 1e11 {
        (value / 1000.0) as i64
    } else {
        value as i64
    })
}
fn history(values: &Value, time: &str, value: &str) -> Vec<Point> {
    let mut points = BTreeMap::new();
    for row in values.as_array().into_iter().flatten().take(20000) {
        if let (Some(t), Some(v)) = (point_time(&row[time]), nonnegative(&row[value])) {
            points.insert(t, v);
        }
    }
    points
        .into_iter()
        .map(|(time, value)| Point { time, value })
        .collect()
}
fn lot(
    source: Source,
    fetched: f64,
    chain: String,
    mint: String,
    wallet: String,
    name: String,
    symbol: String,
) -> Lot {
    Lot {
        id: format!("{chain}:{}:{}", address(&wallet), address(&mint)),
        chain,
        mint,
        wallet,
        name,
        symbol,
        image_url: None,
        quantity: None,
        price_usd: None,
        value_usd: None,
        cost_basis_usd: None,
        average_entry_usd: None,
        pnl_percent: None,
        pnl_usd: None,
        sources: vec![source],
        warnings: Vec::new(),
        fetched_at: fetched,
    }
}
fn is_cash(mint: &str, _symbol: &str) -> bool {
    mint == USDC
}
fn finish(mut snapshot: Snapshot, input: &ProviderInput) -> Snapshot {
    for lot in &mut snapshot.lots {
        let qty = lot
            .quantity
            .as_ref()
            .and_then(|v| number(&Value::String(v.clone())));
        let basis = lot
            .cost_basis_usd
            .as_ref()
            .and_then(|v| number(&Value::String(v.clone())));
        let pnl = lot
            .pnl_usd
            .as_ref()
            .and_then(|v| number(&Value::String(v.clone())));
        lot.average_entry_usd = string(
            basis
                .as_ref()
                .zip(qty.as_ref())
                .and_then(|(b, q)| (q > &N::zero()).then(|| b / q)),
        );
        lot.pnl_percent = string(
            pnl.as_ref()
                .zip(basis.as_ref())
                .and_then(|(p, b)| percent(p, b)),
        );
    }
    if input.stale {
        snapshot.partial = true;
        snapshot.warnings.push(format!(
            "{} is showing its last successful refresh.",
            input.source.name()
        ));
    }
    for warning in input.data["warnings"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        snapshot.warnings.push(warning.chars().take(240).collect());
    }
    if let Some(total) = &snapshot.total {
        let now = input.fetched_at as i64;
        if snapshot.history.last().is_some_and(|p| p.time <= now) {
            snapshot.history.retain(|p| p.time < now);
            snapshot.history.push(Point {
                time: now,
                value: total.clone(),
            });
        }
    }
    snapshot.warnings.sort();
    snapshot.warnings.dedup();
    snapshot
}
pub fn snapshot(input: ProviderInput) -> Result<Snapshot, String> {
    if !valid_wallet(&input.account_wallet)
        || !input.fetched_at.is_finite()
        || input.fetched_at <= 0.0
        || input.fetched_at > crate::now() as f64 + 60.0
    {
        return Err("Invalid portfolio account or timestamp".into());
    }
    if input
        .evm_wallet
        .as_deref()
        .is_some_and(|w| !valid_wallet(w))
    {
        return Err("Invalid linked wallet".into());
    }
    let mut wallets = BTreeSet::from([address(&input.account_wallet)]);
    if let Some(evm) = &input.evm_wallet {
        wallets.insert(address(evm));
    }
    let empty = Snapshot {
        source: input.source,
        fetched_at: input.fetched_at,
        wallets,
        total: None,
        pnl: None,
        pnl_percent: None,
        unrealized: None,
        lots: Vec::new(),
        history: Vec::new(),
        warnings: Vec::new(),
        partial: false,
    };
    let result = match input.source {
        Source::Pump => pump(&input, empty)?,
        Source::Fomo => fomo(&input, empty)?,
    };
    Ok(finish(result, &input))
}
fn pump(input: &ProviderInput, mut out: Snapshot) -> Result<Snapshot, String> {
    let summary = &input.data["summary"];
    if summary["wallet"].as_str() != Some(input.account_wallet.as_str()) {
        return Err("Pumpfun portfolio identity mismatch".into());
    }
    let rows = input.data["positions"]
        .as_array()
        .ok_or("Invalid Pumpfun positions")?;
    out.total = nonnegative(&summary["totalValueUsd"]);
    out.pnl = number(&summary["pnl"]["usd"]);
    out.pnl_percent = number(&summary["percentage"]["usd"]);
    if summary["unpriced"].as_bool() == Some(true)
        || summary["unpricedCount"].as_u64().unwrap_or(0) > 0
    {
        out.partial = true;
        out.warnings
            .push("Pumpfun reports assets with missing prices.".into());
    }
    if summary["reprice"]["unrepriced"]
        .as_array()
        .is_some_and(|v| !v.is_empty())
    {
        out.partial = true;
        out.warnings
            .push("Some Pumpfun holdings could not be repriced.".into());
    }
    if input.data["positionsComplete"].as_bool() != Some(true) {
        out.partial = true;
        out.warnings
            .push("Pumpfun position history is still incomplete.".into());
    }
    let mut lots = BTreeMap::new();
    let mut unrealized = N::zero();
    let mut any_pnl = false;
    for row in rows.iter().take(4000) {
        if row["assetClass"]
            .as_str()
            .is_some_and(|v| v.contains("PERPETUAL") || v.contains("PREDICTION"))
            || !row["perp"].is_null()
        {
            out.partial = true;
            out.warnings.push(
                "Non-spot exposure is included in platform totals but not expanded in Holdings."
                    .into(),
            );
            continue;
        }
        let Some(mint) = row["coinMint"].as_str().filter(|s| !s.is_empty()) else {
            out.partial = true;
            continue;
        };
        let Some(qty) = nonnegative(&row["amountHeld"]).filter(|n| n > &N::zero()) else {
            continue;
        };
        let c = chain(&row["chainId"], &row["chain"], mint);
        let wallet = owner(
            &c,
            &row["walletAddress"],
            &input.account_wallet,
            input.evm_wallet.as_deref(),
        );
        out.wallets.insert(address(&wallet));
        let symbol = string_at(&row["coin"], "symbol", "Token");
        let mut entry = lot(
            input.source,
            input.fetched_at,
            c,
            mint.into(),
            wallet,
            string_at(&row["coin"], "name", &symbol),
            symbol.clone(),
        );
        entry.quantity = Some(text(&qty));
        entry.price_usd = string(nonnegative(&row["tokenPriceUsd"]));
        entry.value_usd = string(nonnegative(&row["valueUsd"]));
        entry.image_url = https(&row["coin"]["imageUri"]);
        if !is_cash(mint, &symbol) && row["isNative"].as_bool() != Some(true) {
            if row["hasUntrustedUsdBasis"].as_bool() == Some(true) {
                entry
                    .warnings
                    .push("Cost basis could not be verified by Pumpfun.".into());
            } else if let Some(cost) = nonnegative(&row["costBasisUsd"]) {
                entry.cost_basis_usd = Some(text(&cost));
                if let Some(value) = nonnegative(&row["valueUsd"]) {
                    let pnl = value - cost;
                    unrealized += &pnl;
                    any_pnl = true;
                    entry.pnl_usd = Some(text(&pnl));
                }
            }
        }
        if row["potentialSpam"].as_bool() == Some(true)
            && row["userMarkedNonSpam"].as_bool() != Some(true)
        {
            entry
                .warnings
                .push("Flagged by the platform as possible spam.".into());
        }
        if row["dustFloorFiltered"].as_bool() == Some(true) {
            entry
                .warnings
                .push("Below the platform's dust threshold.".into());
        }
        if entry.value_usd.is_none() {
            out.partial = true;
            entry.warnings.push("Current value is unavailable.".into());
        }
        lots.insert(entry.id.clone(), entry);
    }
    // The summary is an additional balance source, not a complete holdings list.
    // Add missing cash/balance rows without duplicating detailed positions.
    for row in summary["holdings"]
        .as_array()
        .into_iter()
        .flatten()
        .take(25)
    {
        let Some(mint) = row["mint"].as_str() else {
            continue;
        };
        let c = chain(&Value::Null, &row["chain"], mint);
        let wallet = owner(
            &c,
            &Value::Null,
            &input.account_wallet,
            input.evm_wallet.as_deref(),
        );
        let qty = nonnegative(&row["amount"]);
        if qty.as_ref().is_none_or(|n| n <= &N::zero()) {
            continue;
        }
        let symbol = if mint == USDC {
            "USDC"
        } else if mint == SOL {
            "SOL"
        } else {
            "Token"
        };
        let mut entry = lot(
            input.source,
            input.fetched_at,
            c,
            mint.into(),
            wallet,
            symbol.into(),
            symbol.into(),
        );
        if lots.contains_key(&entry.id) {
            continue;
        }
        entry.quantity = string(qty);
        entry.price_usd = string(nonnegative(&row["priceUsd"]));
        entry.value_usd = string(nonnegative(&row["valueUsd"]));
        if !is_cash(mint, symbol) {
            entry
                .warnings
                .push("Entry price and cost basis are unavailable for this balance.".into());
        }
        lots.insert(entry.id.clone(), entry);
    }
    if let Some(qty) = nonnegative(&summary["nativeBalanceSol"]).filter(|n| n > &N::zero()) {
        let has_native = rows.iter().any(|r| {
            r["isNative"].as_bool() == Some(true)
                && chain(&r["chainId"], &r["chain"], "") == "solana"
        });
        if !has_native {
            let mut entry = lot(
                input.source,
                input.fetched_at,
                "solana".into(),
                "native:solana".into(),
                input.account_wallet.clone(),
                "Solana".into(),
                "SOL".into(),
            );
            entry.quantity = Some(text(&qty));
            let price = nonnegative(&summary["solPriceUsd"]);
            entry.price_usd = string(price.clone());
            entry.value_usd = string(price.map(|p| p * qty));
            lots.insert(entry.id.clone(), entry);
        }
    }
    out.unrealized = if any_pnl {
        Some(unrealized)
    } else if lots.is_empty() {
        Some(N::zero())
    } else {
        None
    };
    out.lots = lots.into_values().collect();
    if out
        .lots
        .iter()
        .any(|l| !is_cash(&l.mint, &l.symbol) && l.mint != "native:solana" && l.pnl_usd.is_none())
    {
        out.unrealized = None;
    }
    out.history = history(&input.data["history"], "time", "value");
    Ok(out)
}
fn fomo(input: &ProviderInput, mut out: Snapshot) -> Result<Snapshot, String> {
    let body = &input.data["balances"];
    let rows = body["balances"].as_array().ok_or("Invalid Fomo balances")?;
    let mut equity = number(&body["otherEquity"]).unwrap_or_default();
    let mut pnl = number(&body["otherPnlV2"]).unwrap_or_default()
        + number(&body["livePerpPnl"]).unwrap_or_default();
    let mut unrealized = N::zero();
    let mut any_pnl = false;
    let mut incomplete_pnl = false;
    for row in rows.iter().take(4000) {
        if row["excludedFromEquity"].as_bool() == Some(true) {
            continue;
        }
        let token = &row["tokenFilterResult"]["token"];
        let mint = row["balance"]["tokenAddress"]
            .as_str()
            .or_else(|| row["userToken"]["tokenAddress"].as_str())
            .unwrap_or("");
        if mint.is_empty() {
            out.partial = true;
            continue;
        }
        let qty = amount(&row["balance"]["balance"], token["decimals"].as_u64())
            .or_else(|| nonnegative(&row["balance"]["shiftedBalance"]));
        let Some(qty) = qty.filter(|n| n > &N::zero()) else {
            continue;
        };
        let network = row["userToken"]
            .get("networkId")
            .filter(|v| !v.is_null())
            .unwrap_or(&token["networkId"]);
        let c = chain(network, &Value::Null, mint);
        let wallet = owner(
            &c,
            &row["balance"]["address"],
            &input.account_wallet,
            input.evm_wallet.as_deref(),
        );
        out.wallets.insert(address(&wallet));
        let symbol = string_at(token, "symbol", "Token");
        let cash = row["isCash"].as_bool() == Some(true);
        let mut entry = lot(
            input.source,
            input.fetched_at,
            c,
            mint.into(),
            wallet,
            string_at(token, "name", &symbol),
            symbol.clone(),
        );
        entry.image_url = https(&row["imageUrl"]);
        entry.quantity = Some(text(&qty));
        let use_live = row["valuation"]["useLivePrice"].as_bool() != Some(false);
        let include = row["valuation"]["includeInEquity"].as_bool() != Some(false);
        let price = if cash {
            Some(N::from(1))
        } else if !use_live {
            Some(N::zero())
        } else {
            nonnegative(&row["tokenFilterResult"]["priceUSD"])
        };
        let value = price.as_ref().map(|p| p * &qty);
        if include || cash {
            if let Some(value) = &value {
                equity += value;
            } else {
                out.partial = true;
            }
        } else {
            entry
                .warnings
                .push("Excluded from equity by the platform's valuation rules.".into());
        }
        entry.price_usd = string(price.clone());
        entry.value_usd = if include || cash { string(value) } else { None };
        let active = row.get("activeTrade").filter(|v| v.is_object());
        let tracked = active
            .and_then(|v| nonnegative(&v["humanTokenAmount"]))
            .or_else(|| nonnegative(&row["userToken"]["humanAmountRemaining"]));
        let basis_price = active
            .and_then(|v| {
                nonnegative(&v["displayAvgEntryPriceUsd"])
                    .or_else(|| nonnegative(&v["avgEntryPrice"]))
            })
            .or_else(|| nonnegative(&row["userToken"]["averageEntryPriceUsd"]));
        if !cash && !is_cash(mint, &symbol) {
            entry.cost_basis_usd = string(
                nonnegative(&row["userToken"]["currentCostBasisUsd"]).or_else(|| {
                    basis_price
                        .as_ref()
                        .zip(tracked.as_ref())
                        .map(|(p, q)| p * q)
                }),
            );
            if row["valuation"]["includeUnrealizedPnl"].as_bool() != Some(false) {
                if let (Some(price), Some(basis), Some(tracked)) = (&price, basis_price, tracked) {
                    let value = tracked * (price - basis);
                    pnl += &value;
                    unrealized += &value;
                    any_pnl = true;
                    entry.pnl_usd = Some(text(&value));
                } else {
                    out.partial = true;
                    incomplete_pnl = true;
                    entry
                        .warnings
                        .push("Unrealized P&L is unavailable for this balance.".into());
                }
            }
            if row["valuation"]["includeRealizedPnl"].as_bool() != Some(false) {
                pnl += active
                    .and_then(|v| number(&v["realizedPnlUsd"]))
                    .or_else(|| number(&row["userToken"]["currentRealizedPnlUsd"]))
                    .unwrap_or_default();
            }
        }
        if entry.value_usd.is_none() {
            out.partial = true;
            entry.warnings.push("Current value is unavailable.".into());
        }
        out.lots.push(entry);
    }
    let perps = &body["hyperliquidPerps"];
    if perps.is_object() {
        let positions = perps["positions"].as_array();
        if positions.is_some_and(|p| !p.is_empty()) {
            out.partial = true;
            out.warnings.push(
                "Perpetual exposure is included in platform totals but not expanded in Holdings."
                    .into(),
            );
        }
        if let Some(value) = nonnegative(&perps["marginSummary"]["accountValue"]) {
            equity += value;
        } else if let Some(quote) = number(&perps["quoteBalance"]) {
            let mut value = quote;
            let mut complete = true;
            for position in positions.into_iter().flatten() {
                if let (Some(size), Some(mark)) = (
                    number(&position["size"]),
                    nonnegative(&position["markPriceUsd"]),
                ) {
                    value += size
                        * mark
                        * N::from(if position["side"].as_str() == Some("short") {
                            -1
                        } else {
                            1
                        });
                } else {
                    complete = false;
                }
            }
            if complete {
                equity += value;
            } else {
                out.partial = true;
                out.warnings
                    .push("Some perp equity could not be priced.".into());
            }
        } else {
            out.partial = true;
            out.warnings
                .push("Perp account value is unavailable.".into());
        }
    }
    if rows.len() >= 4000 {
        out.partial = true;
        out.warnings
            .push("Some Fomo balances are not loaded.".into());
    }
    if body["nativeEvmBalances"]
        .as_array()
        .is_some_and(|v| !v.is_empty())
    {
        out.partial = true;
        out.warnings
            .push("Additional native balances need valuation coverage.".into());
    }
    out.total = Some(equity);
    out.unrealized = if !incomplete_pnl && (any_pnl || out.lots.is_empty()) {
        Some(unrealized)
    } else {
        None
    };
    out.pnl = if incomplete_pnl {
        None
    } else if input.period == Period::All {
        Some(pnl)
    } else {
        number(&input.data["baseline"]["pnl"]).map(|base| pnl - base)
    };
    if out.pnl.is_none() {
        out.warnings
            .push("Fomo's P&L baseline is unavailable for this period.".into());
    }
    out.history = history(&input.data["history"], "snapshotId", "equity");
    if out.partial {
        out.warnings
            .push("Fomo has incomplete pricing or valuation coverage.".into());
    }
    Ok(out)
}

// Kept small and independently testable: native asset mapping never manufactures
// a token from a symbol alone.
pub fn native_market_mint(chain: &str, mint: &str) -> Option<String> {
    (chain == "solana" && (mint == "native:solana" || crate::discovery::is_address(mint))).then(
        || {
            if mint == "native:solana" {
                SOL.to_owned()
            } else {
                mint.to_owned()
            }
        },
    )
}
