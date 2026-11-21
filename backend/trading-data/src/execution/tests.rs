use super::{amounts::*, providers::*, service::*, types::*, *};
use serde_json::{json, Value};
const USDC: &str = crate::quotes::USDC;
const SOL: &str = "So11111111111111111111111111111111111111112";
fn request() -> QuoteRequest {
    serde_json::from_value(json!({"input":{"chain":"solana","address":USDC},"output":{"chain":"solana","address":SOL},"amount":"100","orderType":"market","slippageBps":50})).unwrap()
}
fn chain(id: &str, provider_id: &str, vm: &str) -> Chain {
    Chain {
        id: id.into(),
        name: id.into(),
        provider_id: provider_id.into(),
        vm: vm.into(),
        enabled: true,
        deposit_enabled: true,
        native_token: None,
        minimum_order_usd: None,
    }
}
fn token(address: &str, decimals: u8) -> Token {
    Token {
        chain: "solana".into(),
        address: address.into(),
        symbol: if address == USDC { "USDC" } else { "SOL" }.into(),
        decimals: Some(decimals),
    }
}
fn relay() -> Value {
    json!({"requestId":"fixture","steps":[{"data":{"transaction":"must-not-leave-server"}}],"details":{"currencyIn":{"currency":{"chainId":792703809u64,"address":USDC,"decimals":6},"amount":"100000000"},"currencyOut":{"currency":{"chainId":792703809u64,"address":SOL,"decimals":9},"amount":"1000000001","minimumAmount":"995000000"},"expandedPriceImpact":{"relay":{"usd":"0.15"},"execution":{"usd":"0.02"}}}})
}
fn flash() -> Value {
    json!({"quoteId":"fixture","orderType":"market","side":"buy","targetAsset":SOL,"contraAsset":USDC,"from":{"asset":"contra","amount":"100","notional":"100"},"to":{"asset":"target","amount":"1.01","notional":"100"},"fees":{"estimatedFeeNotional":"0.2"},"estimatedPriceImpact":"0.0042","evm":{"orderTypedData":"must-not-leave-server"},"svm":{"transaction":"must-not-leave-server"},"setupTxs":["must-not-leave-server"]})
}
#[test]
fn amounts_are_exact_and_reject_rounding() {
    assert_eq!(
        atomic("9007199254740993.123456789", 9).unwrap(),
        "9007199254740993123456789"
    );
    assert_eq!(
        units("9007199254740993123456789", 9).unwrap(),
        "9007199254740993.123456789"
    );
    assert!(atomic("1.0000001", 6).is_err());
    for s in ["0", "-1", "1e6", "1,000", "NaN", "1.2.3"] {
        assert!(decimal(s).is_err())
    }
    assert!(atomic(
        "115792089237316195423570985008687907853269984665640564039457584007913129639936",
        0
    )
    .is_err());
}
#[test]
fn unknown_signing_fields_are_rejected() {
    let mut v = serde_json::to_value(request()).unwrap();
    for field in [
        "signedTransaction",
        "signature",
        "payer",
        "funderAddress",
        "providerUrl",
    ] {
        v[field] = json!("unexpected");
        assert!(serde_json::from_value::<QuoteRequest>(v.clone()).is_err());
        v.as_object_mut().unwrap().remove(field);
    }
}
#[test]
fn routing_uses_capabilities_without_a_product_chain_allowlist() {
    let mut r = request();
    assert_eq!(choose(&r), Provider::Jupiter);
    r.output.chain = "eip155:999999".into();
    assert_eq!(choose(&r), Provider::Relay);
    r.order_type = OrderType::Limit;
    assert_eq!(choose(&r), Provider::Flash);
    assert_eq!(chain_id("evm", 999999, "newchain"), "eip155:999999");
}
#[test]
fn discovered_disabled_chains_and_cross_chain_conditions_are_rejected() {
    let mut r = request();
    let mut c = chain("solana", "792703809", "svm");
    c.enabled = false;
    assert!(validate_route(&r, Provider::Relay, &c, &c).is_err());
    c.enabled = true;
    r.order_type = OrderType::Limit;
    r.limit_price_usd = Some("10".into());
    r.output.chain = "eip155:1".into();
    let evm = chain("eip155:1", "ethereum", "evm");
    assert!(validate_route(&r, Provider::Flash, &c, &evm).is_err());
}
#[test]
fn relay_requires_explicit_context_and_only_builds_quote_requests() {
    let mut r = request();
    let c = chain("solana", "792703809", "svm");
    assert!(relay_body(&r, &c, &c, &token(USDC, 6)).is_err());
    r.context.sender = Some(SOL.into());
    let b = relay_body(&r, &c, &c, &token(USDC, 6)).unwrap();
    assert_eq!(b["tradeType"], "EXACT_INPUT");
    assert_eq!(b["amount"], "100000000");
    assert!(b.get("signature").is_none());
    assert_eq!(b["appFees"], json!([]));
}
#[test]
fn relay_keeps_real_fees_thresholds_and_strips_execution_payloads() {
    let r = request();
    let c = chain("solana", "792703809", "svm");
    let q = normalize_relay(&relay(), &r, &c, &c, token(USDC, 6), token(SOL, 9), 100).unwrap();
    assert_eq!(q.receive_amount, "1.000000001");
    assert_eq!(q.minimum_receive.as_deref(), Some("0.995"));
    assert_eq!(q.fees.len(), 2);
    let encoded = serde_json::to_string(&q).unwrap();
    assert!(!encoded.contains("must-not-leave-server"));
    assert_eq!(q.expiry_kind, "app-freshness");
}
#[test]
fn relay_rejects_mismatched_currency_decimals_chain_and_input() {
    let r = request();
    let c = chain("solana", "792703809", "svm");
    for (path, value) in [
        ("/details/currencyIn/amount", json!("1")),
        ("/details/currencyOut/currency/chainId", json!(1)),
        ("/details/currencyOut/currency/address", json!(USDC)),
        ("/details/currencyOut/currency/decimals", json!(6)),
        ("/details/currencyOut/minimumAmount", json!("999000000000")),
    ] {
        let mut v = relay();
        *v.pointer_mut(path).unwrap() = value;
        assert!(normalize_relay(&v, &r, &c, &c, token(USDC, 6), token(SOL, 9), 100).is_err());
    }
}
#[test]
fn flash_uses_human_units_and_does_not_bind_an_unselected_funder() {
    let mut r = request();
    let c = chain("solana", "solana", "svm");
    let b = flash_body(&r, &c, &c).unwrap();
    assert_eq!(b["qty"], "100");
    assert_eq!(b["maxSlippage"], "0.005");
    assert!(b.get("funderAddress").is_none());
    assert!(b.get("flashIntegratorFeeBps").is_none());
    r.order_type = OrderType::Limit;
    r.limit_price_usd = Some("50".into());
    let b = flash_body(&r, &c, &c).unwrap();
    assert_eq!(b["limitNotionalPrice"], "50");
    r.order_type = OrderType::StopLoss;
    r.limit_price_usd = None;
    r.trigger_price_usd = Some("50".into());
    let b = flash_body(&r, &c, &c).unwrap();
    assert_eq!(b["side"], "sell");
    assert_eq!(b["targetAsset"], USDC);
    assert_eq!(b["triggers"][0]["triggerType"], "lower");
}
#[test]
fn flash_normalization_preserves_fees_converts_impact_and_drops_signing_data() {
    let q = normalize_flash(&flash(), &request(), token(USDC, 6), token(SOL, 9), 100).unwrap();
    assert_eq!(q.price_impact_percent.as_deref(), Some("0.42"));
    assert!(q.minimum_receive.is_none());
    assert_eq!(q.fees[0].amount_usd.as_deref(), Some("0.2"));
    assert!(!serde_json::to_string(&q)
        .unwrap()
        .contains("must-not-leave-server"));
}
#[test]
fn flash_rejects_mismatched_orders_and_amounts() {
    for (field, value) in [
        ("targetAsset", json!(USDC)),
        ("side", json!("sell")),
        ("orderType", json!("limit")),
    ] {
        let mut v = flash();
        v[field] = value;
        assert!(normalize_flash(&v, &request(), token(USDC, 6), token(SOL, 9), 100).is_err());
    }
    let mut v = flash();
    v["from"]["amount"] = json!("101");
    assert!(normalize_flash(&v, &request(), token(USDC, 6), token(SOL, 9), 100).is_err());
}
#[test]
fn flash_chain_discovery_uses_live_ids_and_minimums() {
    let v = json!({"chains":[{"chain":"futurechain","chainId":998899,"minimumOrderNotionalUsd":"0.15"},{"chain":"solana","chainId":null}]});
    let s = flash_chains(&v, false).unwrap();
    assert_eq!(s.chains[0].id, "eip155:998899");
    assert_eq!(s.chains[0].minimum_order_usd.as_deref(), Some("0.15"));
    assert_eq!(s.chains[1].id, "solana");
}

#[test]
fn flash_sell_limit_prices_the_spent_asset() {
    let mut r = request();
    r.order_type = OrderType::Limit;
    r.limit_price_usd = Some("1".into());
    r.side = Some(crate::quotes::Side::Sell);
    let c = chain("solana", "solana", "svm");
    let b = flash_body(&r, &c, &c).unwrap();
    assert_eq!(b["side"], "sell");
    assert_eq!(b["targetAsset"], USDC);
    assert_eq!(b["contraAsset"], SOL);
    assert!(b.get("funderAddress").is_none());
    assert!(b.get("flashIntegratorFeeBps").is_none());
}

#[test]
fn flash_can_quote_human_units_when_search_metadata_is_not_available() {
    let mut input = token(USDC, 6);
    input.decimals = None;
    let q = normalize_flash(&flash(), &request(), input, token(SOL, 9), 100).unwrap();
    assert!(q.input.decimals.is_none());
    assert_eq!(q.pay_amount, "100");
    assert!(q.warnings.iter().any(|w| w.contains("metadata")));
}

#[test]
fn flash_cross_chain_preview_requires_both_addresses() {
    let mut r = request();
    r.input.chain = "eip155:8453".into();
    r.output.chain = "eip155:10".into();
    r.input.address = "0x1111111111111111111111111111111111111111".into();
    r.output.address = "0x2222222222222222222222222222222222222222".into();
    let a = chain("eip155:8453", "base", "evm");
    let b = chain("eip155:10", "optimism", "evm");
    r.context.recipient = Some("0x3333333333333333333333333333333333333333".into());
    assert!(flash_body(&r, &a, &b).is_err());
    r.context.sender = Some("0x4444444444444444444444444444444444444444".into());
    assert!(flash_body(&r, &a, &b).is_ok());
}
