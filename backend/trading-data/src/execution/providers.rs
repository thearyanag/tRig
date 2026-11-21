use super::{amounts::*, types::*};
use axum::http::StatusCode;
use bigdecimal::BigDecimal;
use serde_json::{json, Value};
use std::str::FromStr;

pub fn relay_body(r: &QuoteRequest, from: &Chain, to: &Chain, input: &Token) -> Result<Value> {
    let sender=r.context.sender.as_deref().filter(|s|address(&from.vm,s)).ok_or_else(||Error::new(StatusCode::BAD_REQUEST,"address_context_required","Relay needs a public sender address for this estimate. This does not connect or authorize a wallet."))?;
    let recipient = if r.input.chain == r.output.chain {
        r.context.recipient.as_deref().unwrap_or(sender)
    } else {
        r.context.recipient.as_deref().ok_or_else(|| {
            Error::new(
                StatusCode::BAD_REQUEST,
                "address_context_required",
                "Enter a public destination address for the cross-chain estimate.",
            )
        })?
    };
    if !address(&to.vm, recipient) {
        return Err(Error::invalid(
            "The destination address does not match the selected chain.",
        ));
    }
    Ok(
        json!({"user":sender,"recipient":recipient,"originChainId":from.provider_id.parse::<u64>().map_err(|_|Error::inconsistent(Provider::Relay))?,"destinationChainId":to.provider_id.parse::<u64>().map_err(|_|Error::inconsistent(Provider::Relay))?,"originCurrency":r.input.address,"destinationCurrency":r.output.address,"amount":atomic(&r.amount,input.precision(Provider::Relay)?)?,"tradeType":"EXACT_INPUT","slippageTolerance":r.slippage_bps.to_string(),"appFees":[]}),
    )
}
pub fn flash_body(r: &QuoteRequest, from: &Chain, to: &Chain) -> Result<Value> {
    if r.input.chain != r.output.chain && r.context.sender.is_none() {
        return Err(Error::new(StatusCode::BAD_REQUEST,"address_context_required","Flash needs public sender and destination addresses for cross-chain estimates. This does not authorize a wallet."));
    }
    let sell = r.order_type == OrderType::StopLoss || r.side == Some(crate::quotes::Side::Sell);
    let (target, contra, target_chain, contra_chain) = if sell {
        (&r.input, &r.output, from, to)
    } else {
        (&r.output, &r.input, to, from)
    };
    let mut body = json!({"targetChain":target_chain.provider_id,"contraChain":contra_chain.provider_id,"targetAsset":target.address,"contraAsset":contra.address,"side":if sell{"sell"}else{"buy"},"qty":r.amount,"orderType":match r.order_type{OrderType::Market=>"market",OrderType::Limit=>"limit",OrderType::StopLoss=>"stop-loss"},"maxSlippage":(BigDecimal::from(r.slippage_bps)/BigDecimal::from(10000)).normalized().to_string()});
    if let Some(price) = &r.limit_price_usd {
        body["limitNotionalPrice"] = json!(price)
    }
    if let Some(price) = &r.trigger_price_usd {
        body["triggers"] = json!([{"notionalPrice":price,"triggerType":"lower"}])
    }
    if let Some(sender) = &r.context.sender {
        if !address(&from.vm, sender) {
            return Err(Error::invalid(
                "The sender address does not match the input chain.",
            ));
        }
        body["funderAddress"] = json!(sender)
    }
    if let Some(recipient) = &r.context.recipient {
        if !address(&to.vm, recipient) {
            return Err(Error::invalid(
                "The destination address does not match the output chain.",
            ));
        }
        body["recipientAddress"] = json!(recipient)
    }
    if r.input.chain != r.output.chain && r.context.recipient.is_none() {
        return Err(Error::new(
            StatusCode::BAD_REQUEST,
            "address_context_required",
            "Flash needs a public destination address for a cross-chain estimate.",
        ));
    }
    Ok(body)
}
fn base(r: &QuoteRequest, p: Provider, input: Token, output: Token, at: u64) -> Quote {
    Quote{provider:p,provider_name:p.name(),provider_quote_id:None,input,output,order_type:r.order_type,requested_amount:r.amount.clone(),pay_amount:r.amount.clone(),receive_amount:String::new(),minimum_receive:None,slippage_bps:r.slippage_bps,price_impact_percent:None,fees:vec![],routes:vec![],fetched_at:at,expires_at:at+20,expiry_kind:"app-freshness",indicative:true,warnings:vec!["Read-only estimate. Refresh before making a trading decision; no order has been created.".into()],request:r.clone()}
}
pub fn normalize_jupiter(
    v: &Value,
    r: &QuoteRequest,
    input: Token,
    output: Token,
    at: u64,
) -> Result<Quote> {
    let amount = crate::quotes::atomic(&r.amount, input.precision(Provider::Jupiter)?)
        .map_err(|e| Error::invalid(e.1))?;
    let query = crate::quotes::QuoteQuery {
        asset_mint: r.output.address.clone(),
        side: crate::quotes::Side::Buy,
        amount: r.amount.clone(),
        slippage_bps: r.slippage_bps,
    };
    let a = crate::quotes::Token {
        id: input.address.clone(),
        symbol: input.symbol.clone(),
        decimals: input.precision(Provider::Jupiter)?,
    };
    let b = crate::quotes::Token {
        id: output.address.clone(),
        symbol: output.symbol.clone(),
        decimals: output.precision(Provider::Jupiter)?,
    };
    let old = crate::quotes::normalize_quote(v, &query, &a, &b, amount, at)
        .map_err(|_| Error::inconsistent(Provider::Jupiter))?;
    let fee_token = if v["feeMint"] == input.address {
        Some(input.clone())
    } else if v["feeMint"] == output.address {
        Some(output.clone())
    } else {
        None
    };
    let mut q = base(r, Provider::Jupiter, input, output, at);
    q.pay_amount = old.pay_amount;
    q.receive_amount = old.receive_amount;
    q.minimum_receive = Some(old.minimum_receive);
    q.routes = old.routes;
    q.price_impact_percent = old.price_impact_percent.map(|n| n.to_string());
    q.fees.push(Fee {
        kind: "Swap fee".into(),
        amount_usd: None,
        amount: None,
        token: fee_token,
        rate_bps: Some(old.fee_bps),
        included_in_quote: true,
    });
    q.warnings
        .push("Wallet-dependent network and account-creation costs are not estimated.".into());
    Ok(q)
}
pub fn normalize_relay(
    v: &Value,
    r: &QuoteRequest,
    from: &Chain,
    to: &Chain,
    input: Token,
    output: Token,
    at: u64,
) -> Result<Quote> {
    let fail = || Error::inconsistent(Provider::Relay);
    let i = &v["details"]["currencyIn"];
    let o = &v["details"]["currencyOut"];
    for (row, chain, token) in [(i, from, &input), (o, to, &output)] {
        if row["currency"]["chainId"].as_u64().map(|id| id.to_string())
            != Some(chain.provider_id.clone())
            || !row["currency"]["address"]
                .as_str()
                .is_some_and(|a| same_address(&chain.vm, a, &token.address))
            || row["currency"]["decimals"].as_u64() != token.decimals.map(u64::from)
        {
            return Err(fail());
        }
    }
    let in_raw = i["amount"].as_str().ok_or_else(fail)?;
    let out_raw = o["amount"].as_str().ok_or_else(fail)?;
    let min_raw = o["minimumAmount"].as_str().ok_or_else(fail)?;
    if in_raw != atomic(&r.amount, input.precision(Provider::Relay)?)? {
        return Err(fail());
    }
    let receive = units(out_raw, output.precision(Provider::Relay)?)
        .filter(|s| decimal(s).is_ok())
        .ok_or_else(fail)?;
    let minimum = units(min_raw, output.precision(Provider::Relay)?)
        .filter(|s| decimal(s).is_ok())
        .ok_or_else(fail)?;
    if decimal(&minimum)? > decimal(&receive)? {
        return Err(fail());
    }
    let mut q = base(r, Provider::Relay, input, output, at);
    q.receive_amount = receive;
    q.minimum_receive = Some(minimum);
    q.provider_quote_id = v["requestId"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .map(str::to_owned);
    if q.provider_quote_id.is_none() {
        return Err(fail());
    }
    for (key, kind) in [
        ("swap", "Swap cost"),
        ("execution", "Execution cost"),
        ("relay", "Platform fee"),
        ("app", "App fee"),
        ("sponsored", "Sponsored cost"),
    ] {
        if let Some(usd) = number(&v["details"]["expandedPriceImpact"][key]["usd"]) {
            q.fees.push(Fee {
                kind: kind.into(),
                amount_usd: Some(usd),
                amount: None,
                token: None,
                rate_bps: None,
                included_in_quote: true,
            })
        }
    }
    if q.fees.is_empty() {
        q.warnings
            .push("The provider did not supply a complete fee breakdown.".into())
    }
    q.warnings
        .push("Address-dependent estimate. Origin-chain gas may be payable separately.".into());
    if v["warnings"].as_array().is_some_and(|w| !w.is_empty()) {
        q.warnings.push(
            "The provider returned route warnings; refresh and review before any future execution."
                .into(),
        )
    }
    Ok(q)
}
pub fn normalize_flash(
    v: &Value,
    r: &QuoteRequest,
    input: Token,
    output: Token,
    at: u64,
) -> Result<Quote> {
    let fail = || Error::inconsistent(Provider::Flash);
    let sell = r.order_type == OrderType::StopLoss || r.side == Some(crate::quotes::Side::Sell);
    let expected = match r.order_type {
        OrderType::Market => "market",
        OrderType::Limit => "limit",
        OrderType::StopLoss => "stop-loss",
    };
    let (target, contra) = if sell {
        (&input, &output)
    } else {
        (&output, &input)
    };
    let match_token = |a: &Value, t: &Token| {
        a.as_str().is_some_and(|s| {
            if t.chain == "solana" {
                s == t.address
            } else {
                s.eq_ignore_ascii_case(&t.address)
            }
        })
    };
    if v["side"] != if sell { "sell" } else { "buy" }
        || v["orderType"] != expected
        || !match_token(&v["targetAsset"], target)
        || !match_token(&v["contraAsset"], contra)
        || v["from"]["asset"] != if sell { "target" } else { "contra" }
        || v["to"]["asset"] != if sell { "contra" } else { "target" }
    {
        return Err(fail());
    }
    let pay = positive(&v["from"]["amount"]).ok_or_else(fail)?;
    let receive = positive(&v["to"]["amount"]).ok_or_else(fail)?;
    if !same_amount(&pay, &r.amount) {
        return Err(fail());
    }
    let unknown_metadata = input.decimals.is_none() || output.decimals.is_none();
    let mut q = base(r, Provider::Flash, input, output, at);
    if unknown_metadata {
        q.warnings.push(
            "Token metadata could not be confirmed; addresses identify the quoted tokens.".into(),
        );
    }

    q.pay_amount = pay;
    q.receive_amount = receive;
    q.provider_quote_id = v["quoteId"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .map(str::to_owned);
    if q.provider_quote_id.is_none() {
        return Err(fail());
    }
    let fee = nonnegative(&v["fees"]["estimatedFeeNotional"]).ok_or_else(fail)?;
    q.fees.push(Fee {
        kind: "Estimated total fees".into(),
        amount_usd: Some(fee),
        amount: None,
        token: None,
        rate_bps: None,
        included_in_quote: true,
    });
    q.price_impact_percent = number(&v["estimatedPriceImpact"])
        .and_then(|s| BigDecimal::from_str(&s).ok())
        .map(|n| (n * BigDecimal::from(100)).normalized().to_string());
    q.warnings
        .push("A minimum receive amount was not provided by Flash.".into());
    if r.order_type != OrderType::Market {
        q.warnings.push("Conditional-order pricing is illustrative; no resting order or trigger has been created.".into())
    }
    // evm/svm/setupTxs/typed data/signatures are intentionally not part of Quote.
    Ok(q)
}
