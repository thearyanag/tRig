pub(crate) mod order;

use crate::{
    chain_registry,
    execution::{
        self,
        amounts::{same_address, units},
        providers::{normalize_relay, relay_body},
        service::url,
        types::{Chain, OrderType, Provider, QuoteRequest, Token},
    },
    wallet::{self, atomic_balance, chain_for, format_amount, rpc_number, Rpc},
    ApiError, AppState,
};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use bigdecimal::num_bigint::BigUint;
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha3::{Digest, Keccak256};

use trig_wallet_transfers::{
    evm_address as address_bytes,
    relay::{approval_data, deposit_data, depository, NATIVE_EVM_TOKEN},
};

fn unverifiable() -> ApiError {
    ApiError(
        StatusCode::UNPROCESSABLE_ENTITY,
        "Relay did not return a verifiable deposit route for this trade.".into(),
    )
}

pub(crate) fn protocol_chain(id: &str) -> Result<&'static str, ApiError> {
    let entry = chain_registry::get(id).ok_or_else(unverifiable)?;
    Ok(if entry.name == "bsc" {
        "bnb"
    } else {
        &entry.name
    })
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
enum Action {
    Approve,
    Deposit,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Plan {
    request_id: String,
    request: QuoteRequest,
    action: Action,
    chain_id: u64,
    from: String,
    token: String,
    depository: &'static str,
    order_id: String,
    nonce: String,
    gas_price: String,
    gas_limit: String,
    fee_atomic: String,
    amount_atomic: String,
    token_decimals: u8,
    fee_decimals: u8,
    expires_at: u64,
    minimum_receive: String,
    receive_amount: String,
    pay_balance: String,
    input_network: String,
    output_network: String,
    fee: String,
    fee_symbol: String,
}

pub(crate) async fn prepare(
    State(state): State<AppState>,
    Json(request): Json<QuoteRequest>,
) -> Result<Json<Plan>, ApiError> {
    let source = chain_for(&request.input.chain)?;
    let destination = chain_for(&request.output.chain)?;
    if source.vm != "evm"
        || request.order_type != OrderType::Market
        || request
            .provider
            .is_some_and(|provider| provider != Provider::Relay)
    {
        return Err(unverifiable());
    }
    execution::validate_route(&request, Provider::Relay, &source, &destination)
        .map_err(quote_error)?;
    let chain_id = source.provider_id.parse().map_err(|_| unverifiable())?;
    let depository = depository(chain_id).ok_or_else(unverifiable)?;
    let input = state
        .execution
        .token(Provider::Relay, &source, &request.input.address)
        .await
        .map_err(quote_error)?;
    let output = state
        .execution
        .token(Provider::Relay, &destination, &request.output.address)
        .await
        .map_err(quote_error)?;
    let mut body = relay_body(&request, &source, &destination, &input).map_err(quote_error)?;
    let payer = body["user"].as_str().ok_or_else(unverifiable)?.to_owned();
    let recipient = body["recipient"]
        .as_str()
        .ok_or_else(unverifiable)?
        .to_owned();
    let amount_atomic = body["amount"].as_str().ok_or_else(unverifiable)?.to_owned();
    body["includeProtocolData"] = json!(true);
    body["explicitDeposit"] = json!(true);
    body["forceSolverExecution"] = json!(true);
    body["usePermit"] = json!(false);
    body["useDepositAddress"] = json!(false);
    let quote = state
        .execution
        .request(
            Provider::Relay,
            Method::POST,
            url("https://api.relay.link/quote/v3"),
            Some(body),
            true,
        )
        .await
        .map_err(quote_error)?;
    let at = crate::now();
    let terms = normalize_relay(&quote, &request, &source, &destination, input, output, at)
        .map_err(quote_error)?;
    let minimum = terms.minimum_receive.ok_or_else(unverifiable)?;
    let minimum_atomic = quote["details"]["currencyOut"]["minimumAmount"]
        .as_str()
        .ok_or_else(unverifiable)?;
    let protocol = &quote["protocol"]["v2"];
    let order = order::validate(
        &protocol["orderData"],
        &order::OrderContext {
            origin: protocol_chain(&source.id)?,
            destination: protocol_chain(&destination.id)?,
            input: &terms.input.address,
            output: &terms.output.address,
            payer: &payer,
            recipient: &recipient,
            amount: &amount_atomic,
            minimum_receive: minimum_atomic,
            now: at,
        },
    )
    .map_err(|_| unverifiable())?;
    let order_id = format!("0x{}", hex::encode(order.id));
    let request_id = terms
        .provider_quote_id
        .filter(|id| valid_hash(id))
        .ok_or_else(unverifiable)?;
    let native = terms.input.address.eq_ignore_ascii_case(NATIVE_EVM_TOKEN);
    let token_decimals = terms
        .input
        .precision(Provider::Relay)
        .map_err(quote_error)?;
    let amount = order::uint_string(&amount_atomic).map_err(|_| unverifiable())?;
    let call = validate_deposit(
        &quote,
        &source,
        &payer,
        depository,
        &terms.input,
        &amount,
        &order_id,
    )?;

    let rpc = Rpc::for_chain(&source).await?;
    rpc.verify_evm(&source).await?;
    let source_currency = source.native_token.as_ref().ok_or_else(unverifiable)?;
    let fee_decimals = source_currency
        .precision(Provider::Relay)
        .map_err(quote_error)?;
    if native && fee_decimals != token_decimals {
        return Err(unverifiable());
    }
    let native_balance = atomic_balance(&rpc, &source, &payer).await?;
    let (action, pay_balance, transaction) = if native {
        (
            Action::Deposit,
            format_amount(&native_balance, &source)?,
            call,
        )
    } else {
        let token = &terms.input.address;
        let decimals = terms
            .input
            .precision(Provider::Relay)
            .map_err(quote_error)?;
        let payer_word = address_word(&payer)?;
        let spender_word = address_word(depository)?;
        let (token_decimals, balance, allowance) = tokio::try_join!(
            rpc.call("eth_call", json!([{"to":token,"data":"0x313ce567"},"latest"])),
            rpc.call("eth_call", json!([{"to":token,"data":encode_call("balanceOf(address)", &[payer_word])},"latest"])),
            rpc.call("eth_call", json!([{"to":token,"data":encode_call("allowance(address,address)", &[payer_word, spender_word])},"latest"])),
        )?;
        if rpc_number(&token_decimals)? != BigUint::from(decimals) {
            return Err(unverifiable());
        }
        let balance = rpc_number(&balance)?;
        let expected = BigUint::from_bytes_be(&amount);
        if balance < expected {
            return Err(ApiError(
                StatusCode::UNPROCESSABLE_ENTITY,
                "The wallet does not have enough of the pay token.".into(),
            ));
        }
        let formatted = units(&balance.to_string(), decimals).ok_or_else(unverifiable)?;
        if rpc_number(&allowance)? < expected {
            // Construct an exact approval from the validated deposit. Ignore provider approval calldata.
            (
                Action::Approve,
                formatted,
                json!({
                    "from":payer, "to":token, "value":"0x0",
                     "data":format!("0x{}", hex::encode(approval_data(&address_bytes(depository).map_err(|_| unverifiable())?, &amount))),
                }),
            )
        } else {
            (Action::Deposit, formatted, call)
        }
    };
    let (nonce, price, gas) = tokio::try_join!(
        rpc.call("eth_getTransactionCount", json!([payer, "pending"])),
        rpc.call("eth_gasPrice", json!([])),
        rpc.call("eth_estimateGas", json!([transaction])),
    )?;
    let nonce = rpc_number(&nonce)?;
    let gas_price = rpc_number(&price)?;
    let gas_limit = rpc_number(&gas)? * BigUint::from(12u8) / BigUint::from(10u8);
    let fee = &gas_price * &gas_limit;
    let required = if native {
        &fee + BigUint::from_bytes_be(&amount)
    } else {
        fee.clone()
    };
    if gas_limit > BigUint::from(1_000_000u64)
        || gas_limit < BigUint::from(21_000u64)
        || fee.bits() == 0
        || fee.bits() > 256
        || native_balance < required
    {
        return Err(ApiError(StatusCode::UNPROCESSABLE_ENTITY,
            "The wallet does not cover the reviewed amount and network gas, or the gas estimate is out of range.".into()));
    }
    let expires_at = order.deadline.min(at + 45);
    if expires_at <= crate::now() {
        return Err(ApiError(
            StatusCode::CONFLICT,
            "The Relay review expired. Get a fresh quote.".into(),
        ));
    }
    Ok(Json(Plan {
        request_id,
        request,
        action,
        chain_id,
        from: payer,
        token: terms.input.address,
        depository,
        order_id,
        nonce: nonce.to_str_radix(16),
        gas_price: gas_price.to_str_radix(16),
        gas_limit: gas_limit.to_str_radix(16),
        fee_atomic: fee.to_string(),
        amount_atomic,
        token_decimals,
        fee_decimals,
        expires_at,
        minimum_receive: minimum,
        receive_amount: terms.receive_amount,
        pay_balance,
        input_network: source.name.clone(),
        output_network: destination.name,
        fee: format_amount(&fee, &source)?,
        fee_symbol: source_currency.symbol.clone(),
    }))
}

fn quote_error(error: execution::types::Error) -> ApiError {
    ApiError(error.status, error.message)
}

fn address_word(address: &str) -> Result<[u8; 32], ApiError> {
    let bytes = address
        .strip_prefix("0x")
        .filter(|value| value.len() == 40)
        .and_then(|value| hex::decode(value).ok())
        .ok_or_else(unverifiable)?;
    let mut word = [0u8; 32];
    word[12..].copy_from_slice(&bytes);
    Ok(word)
}

fn encode_call(signature: &str, words: &[[u8; 32]]) -> String {
    let mut bytes = Keccak256::digest(signature.as_bytes())[..4].to_vec();
    for word in words {
        bytes.extend_from_slice(word);
    }
    format!("0x{}", hex::encode(bytes))
}

fn valid_hash(hash: &str) -> bool {
    hash.strip_prefix("0x")
        .is_some_and(|hash| hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn validate_deposit(
    quote: &Value,
    source: &Chain,
    payer: &str,
    depository: &str,
    token: &Token,
    amount: &[u8; 32],
    order_id: &str,
) -> Result<Value, ApiError> {
    let protocol = &quote["protocol"]["v2"];
    let pay = &protocol["paymentDetails"];
    if !protocol["orderId"]
        .as_str()
        .is_some_and(|provided| provided.eq_ignore_ascii_case(order_id))
        || !pay["depository"]
            .as_str()
            .is_some_and(|provided| provided.eq_ignore_ascii_case(depository))
        || pay["chainId"] != protocol_chain(&source.id)?
        || !pay["currency"]
            .as_str()
            .is_some_and(|provided| provided.eq_ignore_ascii_case(&token.address))
        || pay["amount"]
            .as_str()
            .and_then(|value| order::uint_string(value).ok())
            .as_ref()
            != Some(amount)
    {
        return Err(unverifiable());
    }

    let mut deposit = None;
    let steps = quote["steps"].as_array().ok_or_else(unverifiable)?;
    let order: [u8; 32] = hex::decode(order_id.strip_prefix("0x").ok_or_else(unverifiable)?)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or_else(unverifiable)?;
    let native = token.address.eq_ignore_ascii_case(NATIVE_EVM_TOKEN);
    let payer_address = address_bytes(payer).map_err(|_| unverifiable())?;
    let token_address = if native {
        None
    } else {
        Some(address_bytes(&token.address).map_err(|_| unverifiable())?)
    };
    let deposit_data = format!(
        "0x{}",
        hex::encode(deposit_data(
            &payer_address,
            token_address.as_ref(),
            amount,
            &order
        ))
    );
    for step in steps {
        if step["kind"] != "transaction" || step["depositAddress"].is_object() {
            return Err(unverifiable());
        }
        let data = &step["data"];
        match step["id"].as_str() {
            Some("approve") if !native => {}
            Some("deposit") if deposit.is_none() => deposit = Some(data),
            _ => return Err(unverifiable()),
        }
    }
    let deposit = deposit.ok_or_else(unverifiable)?;
    let value = if native { *amount } else { [0; 32] };
    if deposit["chainId"]
        .as_u64()
        .map(|id| id.to_string())
        .as_deref()
        != Some(&source.provider_id)
        || !deposit["to"]
            .as_str()
            .is_some_and(|address| same_address("evm", address, depository))
        || !deposit["from"]
            .as_str()
            .is_some_and(|address| same_address("evm", address, payer))
        || !deposit["data"]
            .as_str()
            .is_some_and(|data| data.eq_ignore_ascii_case(&deposit_data))
        || deposit["value"]
            .as_str()
            .and_then(|value| order::uint_string(value).ok())
            != Some(value)
    {
        return Err(unverifiable());
    }
    Ok(json!({"from":payer,"to":depository,"data":deposit_data,
        "value":format!("0x{}",BigUint::from_bytes_be(&value).to_str_radix(16))}))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StatusRequest {
    request_id: String,
    chain: String,
    transaction_id: String,
    last_valid_block_height: Option<u64>,
}

pub(crate) async fn status(
    State(state): State<AppState>,
    Query(request): Query<StatusRequest>,
) -> Result<Json<Value>, ApiError> {
    if !valid_hash(&request.request_id) {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Invalid Relay request ID.".into(),
        ));
    }
    let source = chain_for(&request.chain)?;
    let Json(receipt) = wallet::status(Query(wallet::StatusRequest {
        chain: request.chain,
        transaction_id: request.transaction_id.clone(),
        last_valid_block_height: request.last_valid_block_height,
    }))
    .await?;
    if receipt["status"] != "confirmed" {
        return Ok(Json(receipt));
    }

    let mut status = url("https://api.relay.link/intents/status/v3");
    status
        .query_pairs_mut()
        .append_pair("requestId", &request.request_id);
    let report = state
        .execution
        .request(Provider::Relay, Method::GET, status, None, true)
        .await
        .map_err(quote_error)?;
    Ok(Json(
        json!({"status": settled_status(&report, &source, &request.transaction_id)}),
    ))
}

fn settled_status(report: &Value, source: &Chain, hash: &str) -> &'static str {
    let source_matches = report["originChainId"]
        .as_u64()
        .map(|chain| chain.to_string())
        == Some(source.provider_id.clone())
        && report["inTxHashes"].as_array().is_some_and(|hashes| {
            hashes.iter().any(|entry| {
                entry
                    .as_str()
                    .is_some_and(|entry| same_address(&source.vm, entry, hash))
            })
        });
    if !source_matches {
        return "pending";
    }
    match report["status"].as_str() {
        Some("success")
            if report["txHashes"].as_array().is_some_and(|hashes| {
                hashes
                    .iter()
                    .any(|entry| entry.as_str().is_some_and(|entry| !entry.is_empty()))
            }) =>
        {
            "confirmed"
        }
        Some("refund") => "failed",
        _ => "pending",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: [&str; 3] = [
        include_str!("fixtures/evm-native-cross.json"),
        include_str!("fixtures/evm-token-cross.json"),
        include_str!("fixtures/evm-native-same.json"),
    ];

    fn fixture_input(quote: &Value) -> (Chain, Token, String, [u8; 32]) {
        let details = &quote["protocol"]["v2"]["paymentDetails"];
        let origin = if details["chainId"] == "ethereum" {
            "eip155:1"
        } else {
            "eip155:8453"
        };
        let chain = chain_for(origin).unwrap();
        let token = Token {
            chain: origin.into(),
            address: details["currency"].as_str().unwrap().to_owned(),
            symbol: "Fixture".into(),
            decimals: Some(18),
        };
        let payer = quote["steps"][0]["data"]["from"]
            .as_str()
            .unwrap()
            .to_owned();
        (
            chain,
            token,
            payer,
            order::uint_string(details["amount"].as_str().unwrap()).unwrap(),
        )
    }

    #[test]
    fn authentic_preview_commits_to_the_exact_native_and_erc20_deposits() {
        for fixture in FIXTURES {
            let quote: Value = serde_json::from_str(fixture).unwrap();
            let (chain, token, payer, amount) = fixture_input(&quote);
            let protocol = &quote["protocol"]["v2"];
            let encoded = &protocol["orderData"];
            let input = &encoded["inputs"][0]["payment"];
            let output = &encoded["output"];
            let payment = &output["payments"][0];
            let ctx = order::OrderContext {
                origin: protocol_chain(&chain.id).unwrap(),
                destination: output["chainId"].as_str().unwrap(),
                input: &token.address,
                output: payment["currency"].as_str().unwrap(),
                payer: &payer,
                recipient: payment["recipient"].as_str().unwrap(),
                amount: input["amount"].as_str().unwrap(),
                minimum_receive: payment["minimumAmount"].as_str().unwrap(),
                now: 1_790_000_000,
            };
            let order = order::validate(encoded, &ctx).unwrap();
            let order_id = format!("0x{}", hex::encode(order.id));
            assert_eq!(protocol["orderId"], order_id);
            let depository = depository(chain.provider_id.parse().unwrap()).unwrap();
            validate_deposit(
                &quote, &chain, &payer, depository, &token, &amount, &order_id,
            )
            .unwrap();

            let mut altered = quote.clone();
            let last = altered["steps"].as_array_mut().unwrap().last_mut().unwrap();
            last["data"]["to"] = json!("0x1111111111111111111111111111111111111111");
            assert!(validate_deposit(
                &altered, &chain, &payer, depository, &token, &amount, &order_id
            )
            .is_err());
            let mut altered = encoded.clone();
            altered["output"]["payments"][0]["recipient"] =
                json!("0x1111111111111111111111111111111111111111");
            assert!(order::validate(&altered, &ctx).is_err());
            let mut altered = encoded.clone();
            altered["inputs"][0]["refunds"][0]["recipient"] =
                json!("0x1111111111111111111111111111111111111111");
            assert!(order::validate(&altered, &ctx).is_err());
        }
    }

    #[test]
    fn destination_confirmation_is_bound_to_the_submitted_origin() {
        let origin = chain_for("eip155:1").unwrap();
        let tx = format!("0x{}", "11".repeat(32));
        let dst = format!("0x{}", "12".repeat(32));
        let mut report =
            json!({"status":"success","originChainId":1,"inTxHashes":[tx],"txHashes":[dst]});
        assert_eq!(settled_status(&report, &origin, &tx), "confirmed");
        assert_eq!(settled_status(&report, &origin, &dst), "pending");
        report["status"] = json!("failure");
        assert_eq!(settled_status(&report, &origin, &tx), "pending");
        report["status"] = json!("refund");
        assert_eq!(settled_status(&report, &origin, &tx), "failed");
    }
}
