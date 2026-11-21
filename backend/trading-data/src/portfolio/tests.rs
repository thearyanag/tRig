use super::*;
use bigdecimal::BigDecimal as N;
use serde_json::{json, Value};
use std::str::FromStr;

const A: &str = "So11111111111111111111111111111111111111112";
const B: &str = "11111111111111111111111111111111";
const MINT: &str = crate::models::BP_MINT;
fn request(providers: Vec<Value>) -> PortfolioRequest {
    serde_json::from_value(json!({"period":"1d","providers":providers,"issues":[]})).unwrap()
}
fn pump(wallet: &str, qty: &str, price: &str, basis: &str) -> Value {
    let q = N::from_str(qty).unwrap();
    let p = N::from_str(price).unwrap();
    let value = (q * p).to_string();
    let now = crate::now();
    json!({"source":"pump","accountWallet":wallet,"period":"1d","fetchedAt":now,
      "data":{"summary":{"wallet":wallet,"totalValueUsd":value,"pnl":{"usd":"2"},"percentage":{"usd":"5"}},
        "positionsComplete":true,"positions":[{"chainId":1399811149i64,"coinMint":MINT,"walletAddress":wallet,
          "amountHeld":qty,"tokenPriceUsd":price,"valueUsd":value,"costBasisUsd":basis,
          "coin":{"name":"Backpack","symbol":"BP"}}],
        "history":[{"time":now-86400,"value":"4"},{"time":now-43200,"value":"5"},{"time":now,"value":value}]}})
}
fn fomo(wallet: &str, raw: &str, decimals: u64, price: &str, basis: &str) -> Value {
    let q = types::amount(&json!(raw), Some(decimals)).unwrap();
    let entry = if q == 0 {
        N::from(0)
    } else {
        N::from_str(basis).unwrap() / &q
    };
    let now = crate::now();
    json!({"source":"fomo","accountWallet":wallet,"period":"1d","fetchedAt":now,
      "data":{"balances":{"balances":[{
        "balance":{"balance":raw,"tokenAddress":MINT,"address":wallet},
        "tokenFilterResult":{"priceUSD":price,"token":{"name":"Backpack","symbol":"BP","decimals":decimals}},
        "userToken":{"networkId":1399811149i64,"humanAmountRemaining":q.to_string(),"averageEntryPriceUsd":entry.to_string(),"currentCostBasisUsd":basis,"currentRealizedPnlUsd":"0"}
      }],"otherEquity":"0","otherPnlV2":"0","livePerpPnl":"0"},
      "baseline":{"pnl":"1"},"history":[{"snapshotId":now-86400,"equity":"8"},{"snapshotId":now,"equity":(&q*N::from_str(price).unwrap()).to_string()}]}})
}
#[test]
fn groups_distinct_accounts_and_weights_cost_basis() {
    let result = build(request(vec![
        pump(A, "3", "2", "3"),
        fomo(B, "5000000000", 9, "2", "5"),
    ]))
    .unwrap();
    assert_eq!(result.all.total_value_usd.as_deref(), Some("16"));
    assert_eq!(result.all.holdings.len(), 1);
    let row = &result.all.holdings[0];
    assert_eq!(row.quantity.as_deref(), Some("8"));
    assert_eq!(row.average_entry_usd.as_deref(), Some("1"));
    assert_eq!(row.pnl_usd.as_deref(), Some("8"));
    assert_eq!(row.pnl_percent.as_deref(), Some("100"));
    assert_eq!(row.lots.len(), 2);
    assert_eq!(row.sources.len(), 2);
    assert_eq!(result.pump.holdings[0].quantity.as_deref(), Some("3"));
    assert_eq!(result.fomo.holdings[0].quantity.as_deref(), Some("5"));
    assert_eq!(result.all.history.last().unwrap().value_usd, "16");
}
#[test]
fn shared_wallet_is_counted_once_and_history_is_not_double_counted() {
    let mut latest = fomo(A, "5000000000", 9, "2", "5");
    latest["fetchedAt"] = json!(crate::now() + 1);
    let result = build(request(vec![pump(A, "3", "2", "3"), latest])).unwrap();
    assert_eq!(result.all.holdings[0].quantity.as_deref(), Some("5"));
    assert_eq!(result.all.total_value_usd.as_deref(), Some("10"));
    assert_eq!(result.all.holdings[0].sources.len(), 2);
    assert_eq!(result.all.holdings[0].lots.len(), 1);
    assert!(result.all.partial);
    assert!(result.all.history.is_empty());
    assert!(result.all.period_pnl_usd.is_none());
    assert_eq!(result.pump.total_value_usd.as_deref(), Some("6"));
}
#[test]
fn raw_quantities_above_float_precision_are_preserved() {
    let result = build(request(vec![fomo(
        B,
        "900719925474099312345678",
        18,
        "1",
        "0",
    )]))
    .unwrap();
    assert_eq!(
        result.fomo.holdings[0].quantity.as_deref(),
        Some("900719.925474099312345678")
    );
}
#[test]
fn chain_and_mint_identity_prevent_ticker_collisions() {
    let mut other = fomo(B, "5", 0, "2", "5");
    other["evmWallet"] = json!("0x1111111111111111111111111111111111111111");
    other["data"]["balances"]["balances"][0]["userToken"]["networkId"] = json!(8453);
    let result = build(request(vec![pump(A, "3", "2", "3"), other])).unwrap();
    assert_eq!(result.all.holdings.len(), 2);
}
#[test]
fn missing_prices_and_unknown_basis_never_become_zero_profit() {
    let mut source = pump(A, "3", "2", "3");
    source["data"]["positions"][0]["valueUsd"] = Value::Null;
    source["data"]["positions"][0]["tokenPriceUsd"] = Value::Null;
    source["data"]["positions"][0]["hasUntrustedUsdBasis"] = json!(true);
    source["data"]["summary"]["unpriced"] = json!(true);
    let result = build(request(vec![source])).unwrap();
    let row = &result.pump.holdings[0];
    assert!(row.value_usd.is_none());
    assert!(row.pnl_usd.is_none());
    assert!(row.average_entry_usd.is_none());
    assert!(result.pump.unrealized_pnl_usd.is_none());
    assert!(result.pump.partial);
}
#[test]
fn provider_totals_are_not_replaced_by_a_visible_holdings_subtotal() {
    let mut source = pump(A, "3", "2", "3");
    source["data"]["summary"]["totalValueUsd"] = json!("100");
    let result = build(request(vec![source])).unwrap();
    assert_eq!(result.pump.total_value_usd.as_deref(), Some("100"));
    assert_eq!(result.pump.holdings[0].value_usd.as_deref(), Some("6"));
}
#[test]
fn fomo_period_profit_uses_profit_baseline_not_equity_change() {
    let result = build(request(vec![fomo(B, "5", 0, "2", "5")])).unwrap();
    assert_eq!(result.fomo.period_pnl_usd.as_deref(), Some("4"));
    assert!(result.fomo.period_pnl_percent.is_none());
    assert_eq!(result.fomo.unrealized_pnl_usd.as_deref(), Some("5"));
}
#[test]
fn history_uses_the_common_range_without_zero_filling_missing_accounts() {
    let mut second = fomo(B, "5", 0, "2", "5");
    second["data"]["history"][0]["snapshotId"] = json!(crate::now() - 43200);
    let result = build(request(vec![pump(A, "3", "2", "3"), second])).unwrap();
    assert_eq!(
        result.all.history.first().unwrap().time,
        crate::now() as i64 - 43200
    );
    assert!(result.all.history_message.is_some());
}
#[test]
fn missing_sources_are_partial_not_empty_successful_portfolios() {
    let mut req = request(vec![]);
    req.issues.push(PortfolioIssue {
        source: Source::Pump,
        message: "Refresh failed".into(),
    });
    let result = build(req).unwrap();
    assert!(result.all.total_value_usd.is_none());
    assert!(result.all.partial);
    assert_eq!(result.all.source_count, 0);
    assert!(!result.all.warnings.is_empty());
}
#[test]
fn malformed_source_identity_and_periods_are_rejected() {
    let mut source = pump(A, "3", "2", "3");
    source["data"]["summary"]["wallet"] = json!(B);
    let invalid = build(request(vec![source])).unwrap();
    assert_eq!(invalid.pump.source_count, 0);
    assert!(invalid.pump.partial);
    let mut source = pump(A, "3", "2", "3");
    source["period"] = json!("7d");
    assert!(build(request(vec![source])).is_err());
    assert!(build(request(vec![
        pump(A, "3", "2", "3"),
        pump(B, "3", "2", "3")
    ]))
    .is_err());
}
#[test]
fn stablecoin_symbols_are_not_used_as_token_identity() {
    let mut source = pump(A, "3", "2", "3");
    source["data"]["positions"][0]["coin"]["symbol"] = json!("USDC");
    let result = build(request(vec![source])).unwrap();
    assert_eq!(result.pump.holdings[0].pnl_usd.as_deref(), Some("3"));
}
#[test]
fn unsafe_decimal_exponents_and_invalid_native_mints_are_not_invented() {
    assert!(types::number(&json!("1e9999999")).is_none());
    assert!(normalize::native_market_mint("eip155:1", MINT).is_none());
    assert!(normalize::native_market_mint("solana", "USD").is_none());
    assert_eq!(
        normalize::native_market_mint("solana", "native:solana").as_deref(),
        Some(A)
    );
}

#[test]
fn fomo_unknown_basis_does_not_show_partial_profit_as_the_account_total() {
    let mut source = fomo(B, "5", 0, "2", "5");
    let mut unknown = source["data"]["balances"]["balances"][0].clone();
    unknown["balance"]["tokenAddress"] = json!(A);
    unknown["userToken"] = Value::Null;
    unknown["tokenFilterResult"]["token"]["networkId"] = json!(1399811149i64);
    source["data"]["balances"]["balances"]
        .as_array_mut()
        .unwrap()
        .push(unknown);
    let result = build(request(vec![source])).unwrap();
    assert_eq!(result.fomo.holdings.len(), 2);
    assert!(result.fomo.holdings.iter().all(|h| h.chain == "solana"));
    assert!(result.fomo.unrealized_pnl_usd.is_none());
    assert!(result.fomo.period_pnl_usd.is_none());
    assert!(result.fomo.partial);
}
#[test]
fn one_invalid_provider_does_not_hide_the_other_accounts_portfolio() {
    let mut invalid = pump(A, "3", "2", "3");
    invalid["data"]["summary"]["wallet"] = json!(B);
    let result = build(request(vec![invalid, fomo(B, "5", 0, "2", "5")])).unwrap();
    assert_eq!(result.all.source_count, 1);
    assert_eq!(result.all.total_value_usd.as_deref(), Some("10"));
    assert!(result.all.partial);
    assert_eq!(result.pump.source_count, 0);
    assert_eq!(result.fomo.source_count, 1);
}

#[test]
fn summary_chain_aliases_do_not_duplicate_detailed_positions() {
    for (name, id) in [
        ("ethereum", 1),
        ("bsc", 56),
        ("robinhood", 4663),
        ("base", 8453),
    ] {
        let mut source = pump(A, "3", "2", "3");
        let evm = "0x1111111111111111111111111111111111111111";
        let mint = "0x2222222222222222222222222222222222222222";
        source["evmWallet"] = json!(evm);
        source["data"]["positions"][0]["chainId"] = json!(id);
        source["data"]["positions"][0]["coinMint"] = json!(mint);
        source["data"]["positions"][0]["walletAddress"] = json!(evm);
        source["data"]["summary"]["holdings"] =
            json!([{"chain":name,"mint":mint,"amount":"3","priceUsd":"2","valueUsd":"6"}]);
        let result = build(request(vec![source])).unwrap();
        assert_eq!(result.pump.holdings.len(), 1, "{name}");
        assert_eq!(result.pump.holdings[0].quantity.as_deref(), Some("3"));
        assert_eq!(result.pump.holdings[0].symbol, "BP");
    }
}

#[test]
fn sparse_history_retains_isolated_snapshots_in_separate_segments() {
    let mut source = pump(A, "3", "2", "3");
    let now = crate::now();
    source["period"] = json!("all");
    source["data"]["history"] = json!([
        {"time":now-7*86400,"value":"9"},
        {"time":now-3*86400,"value":"7"},
        {"time":now,"value":"6"}
    ]);
    let mut req = request(vec![source]);
    req.period = Period::All;
    let result = build(req).unwrap();
    assert_eq!(result.all.history.len(), 3);
    assert_eq!(
        result
            .all
            .history
            .iter()
            .map(|p| p.segment)
            .collect::<Vec<_>>(),
        vec![0, 1, 2]
    );
    assert!(result.all.history_message.is_some());
}
