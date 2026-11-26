use crate::{
    chain_registry,
    execution::{
        self,
        amounts::{atomic, units},
        providers::{normalize_relay, relay_body},
        types::{Chain, Error as QuoteError, OrderType, Provider, Quote, QuoteRequest},
    },
    relay_trade::{
        order::{self, OrderContext},
        protocol_chain,
    },
    wallet::{atomic_balance, Rpc},
    ApiError, AppState,
};
use axum::{extract::State, http::StatusCode, Json};
use base64::{engine::general_purpose::STANDARD, Engine};
use bigdecimal::num_bigint::BigUint;
use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use tokio::sync::Mutex;
use trig_wallet_swap_policy::{
    self as policy,
    relay_solana::{self, Terms},
};

const MAX_BASE_FEE_LAMPORTS: u64 = 10_000;
const PLAN_SECONDS: u64 = 45;
const MAX_PLANS: usize = 32;
type Result<T> = std::result::Result<T, ApiError>;

#[derive(Default)]
pub(crate) struct Plans(Mutex<HashMap<String, Plan>>);

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    request_id: String,
    transaction: String,
    terms: Terms,
    origin_fee: String,
    recipient: String,
    destination: String,
    last_valid_block_height: u64,
    quote: Quote,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Prepare {
    quote: QuoteRequest,
    minimum_receive: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Submit {
    request_id: String,
    signed: String,
    transaction_id: String,
}

fn invalid(message: impl Into<String>) -> ApiError {
    ApiError(StatusCode::UNPROCESSABLE_ENTITY, message.into())
}

fn quote_error(error: QuoteError) -> ApiError {
    ApiError(error.status, error.message)
}

fn origin() -> Chain {
    chain_registry::get("solana")
        .expect("bundled Solana registry")
        .relay_chain()
}

fn valid_request_id(value: &str) -> bool {
    value.strip_prefix("0x").is_some_and(|id| {
        id.len() == 64 && id.bytes().all(|character| character.is_ascii_hexdigit())
    })
}

pub async fn prepare(
    State(state): State<AppState>,
    Json(input): Json<Prepare>,
) -> Result<Json<Plan>> {
    let mut request = input.quote;
    if request.input.chain != "solana"
        || request.output.chain == "solana"
        || request.order_type != OrderType::Market
        || request
            .provider
            .is_some_and(|provider| provider != Provider::Relay)
    {
        return Err(invalid("Select a Solana-to-EVM Relay market route."));
    }
    request.provider = Some(Provider::Relay);
    let from = origin();
    let destination = chain_registry::get(&request.output.chain)
        .filter(|entry| entry.vm_type == "evm")
        .ok_or_else(|| invalid("The destination network is unavailable."))?;
    let to = destination.relay_chain();
    execution::validate_route(&request, Provider::Relay, &from, &to).map_err(quote_error)?;
    let wallet = request
        .context
        .sender
        .as_deref()
        .ok_or_else(|| invalid("Choose a funding wallet."))?;
    let recipient = request
        .context
        .recipient
        .as_deref()
        .ok_or_else(|| invalid("Enter a destination address."))?;
    if recipient.eq_ignore_ascii_case("0x0000000000000000000000000000000000000000") {
        return Err(invalid("Enter a nonzero destination address."));
    }
    let (spend, receive) = tokio::try_join!(
        state
            .execution
            .token(Provider::Relay, &from, &request.input.address),
        state
            .execution
            .token(Provider::Relay, &to, &request.output.address)
    )
    .map_err(quote_error)?;
    let spend_decimals = spend.precision(Provider::Relay).map_err(quote_error)?;
    let receive_decimals = receive.precision(Provider::Relay).map_err(quote_error)?;
    let amount = atomic(&request.amount, spend_decimals).map_err(quote_error)?;
    let floor = atomic(&input.minimum_receive, receive_decimals).map_err(quote_error)?;
    let body = relay_body(&request, &from, &to, &spend).map_err(quote_error)?;
    let raw = state
        .execution
        .request(
            Provider::Relay,
            Method::POST,
            "https://api.relay.link/quote/v3"
                .parse()
                .expect("fixed Relay URL"),
            Some(body),
            true,
        )
        .await
        .map_err(quote_error)?;
    let at = crate::now();
    let quote =
        normalize_relay(&raw, &request, &from, &to, spend, receive, at).map_err(quote_error)?;
    let minimum = raw["details"]["currencyOut"]["minimumAmount"]
        .as_str()
        .ok_or_else(|| invalid("Relay did not provide a minimum receive amount."))?;
    let requested_floor = floor
        .parse::<BigUint>()
        .map_err(|_| invalid("Invalid quote floor."))?;
    if minimum
        .parse::<BigUint>()
        .map_err(|_| invalid("Invalid Relay minimum."))?
        < requested_floor
    {
        return Err(invalid(
            "The Relay rate moved below the previous minimum. Refresh the quote.",
        ));
    }
    let protocol = &raw["protocol"]["v2"];
    let order = order::validate(
        &protocol["orderData"],
        &OrderContext {
            origin: "solana",
            destination: protocol_chain(&to.id)?,
            input: &request.input.address,
            output: &request.output.address,
            payer: wallet,
            recipient,
            amount: &amount,
            minimum_receive: minimum,
            now: at,
        },
    )
    .map_err(invalid)?;
    let payment = &protocol["paymentDetails"];
    if protocol["orderId"]
        .as_str()
        .and_then(|id| hex::decode(id.strip_prefix("0x")?).ok())
        .as_deref()
        != Some(&order.id)
        || payment["chainId"] != "solana"
        || payment["depository"] != relay_solana::PROGRAM
        || payment["currency"] != request.input.address
        || payment["amount"] != amount
    {
        return Err(invalid("Relay did not commit to the requested deposit."));
    }
    let request_id = quote
        .provider_quote_id
        .clone()
        .filter(|id| valid_request_id(id))
        .ok_or_else(|| invalid("Invalid Relay request ID."))?;
    let terms = Terms {
        wallet: wallet.to_owned(),
        input_mint: request.input.address,
        input_atomic: amount,
        order_id: order.id,
        expires_at: order.deadline.min(at + PLAN_SECONDS),
    };
    validate_step(&raw["steps"], &terms)?;

    let rpc = Rpc::for_chain(&from).await?;
    let latest = rpc
        .call("getLatestBlockhash", json!([{"commitment":"confirmed"}]))
        .await?;
    let block = &latest["value"];
    let blockhash = block["blockhash"]
        .as_str()
        .ok_or_else(|| invalid("Missing Solana blockhash."))?;
    let last_valid_block_height = block["lastValidBlockHeight"]
        .as_u64()
        .filter(|value| *value > 0)
        .ok_or_else(|| invalid("Missing Solana block height."))?;
    let transaction = relay_solana::transaction(&terms, blockhash).map_err(invalid)?;
    let fee = rpc
        .call(
            "getFeeForMessage",
            json!([
                STANDARD.encode(transaction.message.serialize()), {"commitment":"confirmed"}
            ]),
        )
        .await?["value"]
        .as_u64()
        .filter(|value| (1..=MAX_BASE_FEE_LAMPORTS).contains(value))
        .ok_or_else(|| invalid("Could not verify the Solana fee for this deposit."))?;
    check_balances(&rpc, &from, &terms, fee, spend_decimals).await?;
    relay_solana::review_now(&transaction, &terms).map_err(invalid)?;
    let plan = Plan {
        request_id,
        transaction: policy::encode(&transaction).map_err(invalid)?,
        terms,
        origin_fee: units(&fee.to_string(), 9).expect("lamports are exact"),
        recipient: recipient.to_owned(),
        destination: to.name,
        last_valid_block_height,
        quote,
    };
    let mut plans = state.relay_solana_trade.0.lock().await;
    plans.retain(|_, plan| plan.terms.expires_at > crate::now());
    if plans.len() >= MAX_PLANS || plans.contains_key(&plan.request_id) {
        return Err(ApiError(
            StatusCode::TOO_MANY_REQUESTS,
            "Wait for an earlier review to expire.".into(),
        ));
    }
    plans.insert(plan.request_id.clone(), plan.clone());
    Ok(Json(plan))
}

fn validate_step(steps: &Value, terms: &Terms) -> Result<()> {
    let expected = relay_solana::instruction(terms).map_err(invalid)?;
    let [step] = steps.as_array().map(Vec::as_slice).unwrap_or_default() else {
        return Err(invalid("Relay requires additional actions for this route."));
    };
    let [instruction] = step["data"]["instructions"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
    else {
        return Err(invalid(
            "Relay did not provide a single deposit instruction.",
        ));
    };
    let keys_match = instruction["keys"].as_array().is_some_and(|keys| {
        keys.len() == expected.accounts.len()
            && keys.iter().zip(&expected.accounts).all(|(key, account)| {
                key["pubkey"] == account.pubkey.to_string()
                    && key["isSigner"] == account.is_signer
                    && key["isWritable"] == account.is_writable
            })
    });
    if step["id"] != "deposit"
        || step["kind"] != "transaction"
        || step["status"] != "incomplete"
        || !step["depositAddress"].is_null()
        || !keys_match
        || instruction["programId"] != relay_solana::PROGRAM
        || instruction["data"] != hex::encode(expected.data)
    {
        return Err(invalid(
            "Relay’s deposit instruction differs from the reviewed payment.",
        ));
    }
    Ok(())
}

async fn source_token_account(rpc: &Rpc, terms: &Terms) -> Result<Value> {
    let source = trig_wallet_transfers::spl_recipient_address(&terms.wallet, &terms.input_mint)
        .map_err(invalid)?;
    let vault =
        trig_wallet_transfers::spl_recipient_address(relay_solana::VAULT, &terms.input_mint)
            .map_err(invalid)?;
    let value = rpc
        .call(
            "getMultipleAccounts",
            json!([
                [source, vault], {"encoding":"jsonParsed","commitment":"confirmed"}
            ]),
        )
        .await?;
    let Some([source, vault]) = value["value"].as_array().map(Vec::as_slice) else {
        return Err(invalid("Could not verify the Relay token accounts."));
    };
    for (account, authority) in [
        (source, terms.wallet.as_str()),
        (vault, relay_solana::VAULT),
    ] {
        let info = &account["data"]["parsed"]["info"];
        if account["owner"] != policy::TOKEN
            || account["data"]["parsed"]["type"] != "account"
            || info["mint"] != terms.input_mint
            || info["owner"] != authority
            || info["state"] != "initialized"
        {
            return Err(invalid(
                "Both canonical SPL token accounts must be initialized for this Relay route.",
            ));
        }
    }
    Ok(source.clone())
}

async fn check_balances(
    rpc: &Rpc,
    chain: &Chain,
    terms: &Terms,
    fee: u64,
    decimals: u8,
) -> Result<()> {
    let amount = terms
        .input_atomic
        .parse::<u64>()
        .map_err(|_| invalid("Invalid deposit amount."))?;
    let required_sol = if terms.input_mint == policy::SYSTEM {
        amount
            .checked_add(fee)
            .ok_or_else(|| invalid("Invalid deposit amount."))?
    } else {
        let source = source_token_account(rpc, terms).await?;
        let balance = &source["data"]["parsed"]["info"]["tokenAmount"];
        if balance["decimals"].as_u64() != Some(u64::from(decimals))
            || balance["amount"]
                .as_str()
                .and_then(|value| value.parse::<u64>().ok())
                .is_none_or(|balance| balance < amount)
        {
            return Err(invalid(
                "The funding wallet’s associated token account has insufficient balance.",
            ));
        }
        fee
    };
    if atomic_balance(rpc, chain, &terms.wallet).await? < BigUint::from(required_sol) {
        return Err(invalid(
            "The funding wallet needs more SOL for this deposit and its network fee.",
        ));
    }
    Ok(())
}

pub async fn submit(
    State(state): State<AppState>,
    Json(request): Json<Submit>,
) -> Result<Json<Value>> {
    if !valid_request_id(&request.request_id) {
        return Err(invalid("Invalid Relay request ID."));
    }
    let mut plans = state.relay_solana_trade.0.lock().await;
    let plan = plans
        .get(&request.request_id)
        .ok_or_else(|| invalid("Review a new Relay deposit."))?;
    let planned = policy::decode(&plan.transaction).map_err(invalid)?;
    relay_solana::review_now(&planned, &plan.terms).map_err(invalid)?;
    let signed = policy::decode(&request.signed).map_err(invalid)?;
    policy::validate_signed(&planned, &signed, &request.transaction_id).map_err(invalid)?;
    let plan = plans.remove(&request.request_id).expect("verified plan");
    drop(plans);

    let rpc = Rpc::for_chain(&origin()).await?;
    if plan.terms.input_mint != policy::SYSTEM {
        source_token_account(&rpc, &plan.terms).await?;
    }
    relay_solana::review_now(&planned, &plan.terms).map_err(invalid)?;
    let signature = rpc.call("sendTransaction", json!([
        request.signed, {"encoding":"base64", "preflightCommitment":"confirmed","maxRetries":2}
    ])).await?;
    if signature != request.transaction_id {
        return Err(ApiError(
            StatusCode::BAD_GATEWAY,
            "The network returned an unexpected deposit signature.".into(),
        ));
    }
    Ok(Json(json!({"status":"pending"})))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_live_v3_spl_deposit_instruction_shape() {
        let terms = Terms {
            wallet: policy::SOL.into(),
            input_mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
            input_atomic: "2000000".into(),
            order_id: hex::decode(
                "1e654c4fe887be632cf6a267b4b07cd9b0bbc3e171637b18cd12b2490e8d9773",
            )
            .unwrap()
            .try_into()
            .unwrap(),
            expires_at: 1796301955,
        };
        let step = json!([{
            "id":"deposit", "kind":"transaction", "status":"incomplete",
            "data": {"instructions": [{
                "keys": [
                    {"pubkey":"Dodg2HifwU8rmaVVyMyUZDGTRbqAJTyVYxXPwcbNpBKc","isSigner":false,"isWritable":false},
                    {"pubkey":policy::SOL,"isSigner":true,"isWritable":true},
                    {"pubkey":policy::SOL,"isSigner":false,"isWritable":false},
                    {"pubkey":relay_solana::VAULT,"isSigner":false,"isWritable":false},
                    {"pubkey":terms.input_mint,"isSigner":false,"isWritable":false},
                    {"pubkey":"DHe62eeQVEnNK7vg5xUpDkJm7tuqHadjhvmPRFBG9UPo","isSigner":false,"isWritable":true},
                    {"pubkey":"4nvJ5zWdVspxJiNZzB127U6amPH98SFFkBx2JZrAduia","isSigner":false,"isWritable":true},
                    {"pubkey":policy::TOKEN,"isSigner":false,"isWritable":false},
                    {"pubkey":"ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL","isSigner":false,"isWritable":false},
                    {"pubkey":policy::SYSTEM,"isSigner":false,"isWritable":false}
                ],
                "programId": relay_solana::PROGRAM,
                "data": "0b9c60da27a3b41380841e00000000001e654c4fe887be632cf6a267b4b07cd9b0bbc3e171637b18cd12b2490e8d9773"
            }], "addressLookupTableAddresses":["Hm9fUgcn7qwDaiNTFiGh6pNtVATgnaRcmK6Bbx6EMZfP"]},
            "depositAddress": null
        }]);
        assert!(validate_step(&step, &terms).is_ok());
        let mut tampered = step;
        tampered[0]["data"]["instructions"][0]["keys"][6]["pubkey"] = json!(policy::SOL);
        assert!(validate_step(&tampered, &terms).is_err());
    }
}
