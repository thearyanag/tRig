use crate::{
    execution::{
        self, amounts,
        service::url,
        types::{Error, OrderType, Provider, QuoteRequest, Result},
    },
    quotes::Side,
    wallet::{self, Rpc},
    AppState,
};
use axum::{extract::State, http::StatusCode, Json};
use bigdecimal::num_bigint::BigUint;
use chrono::{DateTime, Utc};
use reqwest::Method;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha3::{Digest, Keccak256};
use std::{collections::HashMap, path::Path, sync::Mutex};
use trig_wallet_transfers::{SplTokenProgram, SPL_TOKEN_PROGRAM};

#[path = "../../wallet-signer/src/flash_intent.rs"]
#[allow(dead_code)] // The signer uses the shared validation output to encode the EIP-712 digest.
mod intent;
#[path = "flash_solana_setup.rs"]
mod solana_setup;

const FLASH: &str = "https://flash.definitive.fi/v1";

struct Prepared {
    sign_plan: intent::OrderPlan,
    body: Value,
    intent_key: String,
    approval: Option<intent::ApprovalPlan>,
    solana_setup: Option<intent::SolanaSetupPlan>,
}

pub struct FlashPlacement {
    reviews: Mutex<HashMap<String, Prepared>>,
    db: Mutex<Connection>,
}

impl FlashPlacement {
    pub fn open(database: &Path) -> rusqlite::Result<Self> {
        let db = Connection::open(database)?;
        db.busy_timeout(std::time::Duration::from_secs(3))?;
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS flash_uncertain_submissions (
                intent_key TEXT PRIMARY KEY,
                deadline INTEGER NOT NULL
            )",
        )?;
        Ok(Self {
            reviews: Mutex::new(HashMap::new()),
            db: Mutex::new(db),
        })
    }

    fn check_clear(&self, key: &str, now: u64) -> Result<()> {
        let db = self.db.lock().map_err(|_| local_error())?;
        let blocked: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM flash_uncertain_submissions WHERE intent_key = ? AND deadline > ?)",
            params![key, now],
            |row| row.get(0),
        ).map_err(|_| local_error())?;
        if blocked {
            return Err(uncertain_submit());
        }
        Ok(())
    }

    fn mark_submitting(&self, key: &str, deadline: u64, now: u64) -> Result<()> {
        let db = self.db.lock().map_err(|_| local_error())?;
        db.execute(
            "DELETE FROM flash_uncertain_submissions WHERE deadline <= ?",
            [now],
        )
        .map_err(|_| local_error())?;
        let inserted = db.execute(
            "INSERT OR IGNORE INTO flash_uncertain_submissions(intent_key, deadline) VALUES (?, ?)",
            params![key, deadline],
        ).map_err(|_| local_error())?;
        if inserted != 1 {
            return Err(uncertain_submit());
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PrepareRequest {
    request: QuoteRequest,
    funder: String,
    take_profit: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    sign_plan: intent::OrderPlan,
    order_type: String,
    receive_amount: String,
    fee_usd: String,
    available_amount: String,
    spend_decimals: u8,
    approval: Option<ApprovalReview>,
    solana_setup: Option<intent::SolanaSetupPlan>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApprovalReview {
    plan: intent::ApprovalPlan,
    spender: &'static str,
    fee_native: String,
    fee_symbol: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SubmitRequest {
    plan_id: String,
    signature: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ApprovalSubmission {
    plan_id: String,
    signed: String,
    transaction_id: String,
}

fn local_error() -> Error {
    Error::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "flash_local_error",
        "The local Flash order store is unavailable.",
    )
}

fn uncertain_submit() -> Error {
    Error::new(
        StatusCode::CONFLICT,
        "flash_submission_unconfirmed",
        "An identical Flash order may have been submitted. Check Markets → Orders before trying again.",
    )
}

fn unsupported_setup() -> Error {
    Error::new(
        StatusCode::UNPROCESSABLE_ENTITY,
        "flash_allowance_required",
        "This token needs a Flash approval or setup step before the order can be placed.",
    )
}

fn is_erc20(address: &str) -> bool {
    intent::address(address)
        && !address.eq_ignore_ascii_case("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
}

fn big_uint(value: &Value) -> Option<BigUint> {
    let hex = value.as_str()?.strip_prefix("0x")?;
    if hex.is_empty() || hex.len() > 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    BigUint::parse_bytes(hex.as_bytes(), 16)
}

fn rpc_error() -> Error {
    Error::new(
        StatusCode::BAD_GATEWAY,
        "flash_wallet_rpc",
        "Couldn’t verify this Flash wallet transaction.",
    )
}

fn token_call(value: Value) -> Result<BigUint> {
    if value
        .as_str()
        .and_then(|text| text.strip_prefix("0x"))
        .map(str::len)
        != Some(64)
    {
        return Err(rpc_error());
    }
    big_uint(&value).ok_or_else(rpc_error)
}

fn allowance_data(owner: &str) -> String {
    format!(
        "0xdd62ed3e000000000000000000000000{}000000000000000000000000{}",
        &owner[2..],
        &intent::SETTLEMENT[2..]
    )
}

async fn spendable(rpc: &Rpc, token: &str, owner: &str) -> Result<(u8, BigUint, BigUint)> {
    let (decimals, balance, allowance) = tokio::try_join!(
        rpc.call("eth_call", json!([{"to":token,"data":"0x313ce567"},"latest"])),
        rpc.call("eth_call", json!([{"to":token,"data":format!("0x70a08231000000000000000000000000{}", &owner[2..])},"latest"])),
        rpc.call("eth_call", json!([{"to":token,"data":allowance_data(owner)},"latest"])),
    ).map_err(|_| rpc_error())?;
    let decimals = token_call(decimals)?
        .to_string()
        .parse::<u8>()
        .ok()
        .filter(|n| *n <= 38)
        .ok_or_else(rpc_error)?;
    Ok((decimals, token_call(balance)?, token_call(allowance)?))
}

fn requires_setup(response: &Value) -> bool {
    !response["wrap"].is_null()
        || !response["evm"]["approveTx"].is_null()
        || response["evm"]["permitTypedData"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
        || !response["setupTxs"].is_null()
            && !response["setupTxs"]
                .as_array()
                .is_some_and(|items| items.is_empty())
}

fn approval_calldata(amount: &BigUint) -> String {
    format!(
        "0x095ea7b3000000000000000000000000{}{:064x}",
        &intent::SETTLEMENT[2..],
        amount
    )
}

fn signed_approval_matches(raw: &[u8], plan: &intent::ApprovalPlan) -> Option<()> {
    let expected_amount = BigUint::parse_bytes(plan.amount.as_bytes(), 10)?;
    let calldata = approval_calldata(&expected_amount);
    let expected_data = hex::decode(calldata.strip_prefix("0x")?).ok()?;
    let expected_token = hex::decode(plan.token.strip_prefix("0x")?).ok()?;
    let tx = rlp::Rlp::new(raw);
    if !tx.is_list() || tx.payload_info().ok()?.total() != raw.len() || tx.item_count().ok()? != 9 {
        return None;
    }
    let fields = (0..9)
        .map(|index| tx.at(index).ok()?.data().ok())
        .collect::<Option<Vec<_>>>()?;
    for (index, hex_value) in [&plan.nonce, &plan.gas_price, &plan.gas_limit]
        .into_iter()
        .enumerate()
    {
        if BigUint::from_bytes_be(fields[index]) != BigUint::parse_bytes(hex_value.as_bytes(), 16)?
        {
            return None;
        }
    }
    if fields[3] != expected_token || !fields[4].is_empty() || fields[5] != expected_data {
        return None;
    }
    let v = &BigUint::from_bytes_be(fields[6]);
    let v_offset = BigUint::from(plan.chain_id.checked_mul(2)?.checked_add(35)?);
    let parity = if v == &v_offset {
        0
    } else if v == &(v_offset + 1u8) {
        1
    } else {
        return None;
    };
    let mut signature = [0; 64];
    for (index, scalar) in fields[7..9].iter().enumerate() {
        let size = 32usize.checked_sub(scalar.len())?;
        signature[(index * 32 + size)..(index + 1) * 32].copy_from_slice(scalar);
    }
    let signature = k256::ecdsa::Signature::from_slice(&signature).ok()?;
    let mut preimage = rlp::RlpStream::new_list(9);
    for field in &fields[..6] {
        preimage.append(field);
    }
    preimage.append(&plan.chain_id).append(&0u8).append(&0u8);
    let signer = k256::ecdsa::VerifyingKey::recover_from_prehash(
        &Keccak256::digest(preimage.out()),
        &signature,
        k256::ecdsa::RecoveryId::try_from(parity).ok()?,
    )
    .ok()?;
    let address = Keccak256::digest(&signer.to_encoded_point(false).as_bytes()[1..]);
    let address = format!("0x{}", hex::encode(&address[12..]));
    address.eq_ignore_ascii_case(&plan.funder).then_some(())
}

async fn prepare_approval(
    rpc: &Rpc,
    chain: &execution::types::Chain,
    order_plan: &intent::Plan,
    approval: &Value,
    amount: &BigUint,
) -> Result<ApprovalReview> {
    let calldata = approval_calldata(amount);
    if !approval["to"]
        .as_str()
        .is_some_and(|token| token.eq_ignore_ascii_case(&order_plan.from_token))
        || !approval["data"]
            .as_str()
            .is_some_and(|data| data.eq_ignore_ascii_case(&calldata))
        || !approval["value"].is_null()
            && !approval["value"]
                .as_str()
                .is_some_and(|value| matches!(value, "0" | "0x0"))
    {
        return Err(unsupported_setup());
    }
    let transaction =
        json!({"from":order_plan.funder,"to":order_plan.from_token,"value":"0x0","data":calldata});
    let (nonce, gas_price, gas_limit, balance, simulation) = tokio::try_join!(
        rpc.call(
            "eth_getTransactionCount",
            json!([&order_plan.funder, "pending"])
        ),
        rpc.call("eth_gasPrice", json!([])),
        rpc.call("eth_estimateGas", json!([&transaction])),
        wallet::atomic_balance(rpc, chain, &order_plan.funder),
        rpc.call("eth_call", json!([&transaction, "latest"])),
    )
    .map_err(|_| rpc_error())?;
    if simulation.as_str() != Some("0x") && token_call(simulation)? != BigUint::from(1u8) {
        return Err(unsupported_setup());
    }
    let nonce = big_uint(&nonce).ok_or_else(rpc_error)?;
    let gas_price = big_uint(&gas_price)
        .filter(|value| *value > BigUint::from(0u8))
        .ok_or_else(rpc_error)?;
    let gas_limit = big_uint(&gas_limit)
        .filter(|value| *value >= BigUint::from(21_000u64) && *value <= BigUint::from(300_000u64))
        .ok_or_else(rpc_error)?;
    let fee = &gas_price * &gas_limit;
    if fee > balance {
        return Err(Error::invalid(
            "The wallet’s native balance does not cover the Flash approval fee.",
        ));
    }
    let native = chain.native_token.as_ref().ok_or_else(rpc_error)?;
    let fee_native = amounts::units(&fee.to_string(), native.precision(Provider::Flash)?)
        .ok_or_else(rpc_error)?;
    let plan = intent::ApprovalPlan {
        plan_id: order_plan.plan_id.clone(),
        chain_id: order_plan.chain_id,
        funder: order_plan.funder.clone(),
        token: order_plan.from_token.clone(),
        amount: amount.to_string(),
        nonce: format!("{nonce:x}"),
        gas_price: format!("{gas_price:x}"),
        gas_limit: format!("{gas_limit:x}"),
        fee: fee.to_string(),
        expires_at: order_plan.expires_at,
    };
    plan.validate(crate::now()).map_err(Error::invalid)?;
    Ok(ApprovalReview {
        plan,
        spender: intent::SETTLEMENT,
        fee_native,
        fee_symbol: native.symbol.clone(),
    })
}

pub async fn prepare(
    State(state): State<AppState>,
    Json(input): Json<PrepareRequest>,
) -> Result<Json<Review>> {
    if input.request.input.chain == "solana" {
        return prepare_solana(&state, input).await.map(Json);
    }
    let PrepareRequest {
        mut request,
        funder,
        take_profit,
    } = input;
    let invalid = || Error::invalid("Choose a same-chain ERC-20 pair and an EVM funding wallet.");
    let chain_id = request
        .input
        .chain
        .strip_prefix("eip155:")
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|id| *id > 0)
        .ok_or_else(invalid)?;
    if request.input.chain != request.output.chain
        || request
            .input
            .address
            .eq_ignore_ascii_case(&request.output.address)
        || !is_erc20(&request.input.address)
        || !is_erc20(&request.output.address)
        || !intent::address(&funder)
        || request.side.is_none()
        || request.order_type == OrderType::Market
        || take_profit
            && (request.order_type != OrderType::Limit || request.side != Some(Side::Sell))
    {
        return Err(invalid());
    }
    request.provider = Some(Provider::Flash);
    request.context.sender = Some(funder.clone());
    request.context.recipient = None;
    let service = &state.execution;
    let chains = service.chain_set(Provider::Flash).await?;
    let chain = chains
        .chains
        .iter()
        .find(|chain| chain.id == request.input.chain)
        .ok_or_else(|| Error::invalid("Flash does not support this network."))?;
    execution::validate_route(&request, Provider::Flash, chain, chain)?;
    let order_type = if take_profit {
        "take-profit"
    } else if request.order_type == OrderType::Limit {
        "limit"
    } else {
        "stop-loss"
    };
    let mut body = execution::providers::flash_body(&request, chain, chain)?;
    if take_profit {
        body["triggers"] =
            json!([{ "notionalPrice": request.limit_price_usd, "triggerType": "upper" }]);
        body.as_object_mut()
            .ok_or_else(local_error)?
            .remove("limitNotionalPrice");
    }
    body["orderType"] = json!(order_type);
    body["evmUsePermit2"] = json!(false);
    let expiry = crate::now() + 86_400;
    let expiry_text = DateTime::<Utc>::from_timestamp(expiry as i64, 0)
        .ok_or_else(local_error)?
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    body["expireTime"] = json!(expiry_text);

    let trigger_price = request
        .limit_price_usd
        .as_deref()
        .or(request.trigger_price_usd.as_deref())
        .ok_or_else(|| Error::invalid("Enter a target price."))?;
    let price = amounts::decimal(trigger_price)?.normalized().to_string();
    let quantity = amounts::decimal(&request.amount)?.normalized().to_string();
    let intent_key = serde_json::to_string(&(
        chain_id,
        funder.to_ascii_lowercase(),
        request.input.address.to_ascii_lowercase(),
        request.output.address.to_ascii_lowercase(),
        order_type,
        request.side,
        quantity,
        price,
    ))
    .map_err(|_| local_error())?;
    state
        .flash_placement
        .check_clear(&intent_key, crate::now())?;

    let rpc_chain = wallet::chain_for(&request.input.chain).map_err(|_| rpc_error())?;
    let rpc = Rpc::for_chain(&rpc_chain).await.map_err(|_| rpc_error())?;
    rpc.verify_evm(&rpc_chain).await.map_err(|_| rpc_error())?;
    let (decimals, balance, allowance) = spendable(&rpc, &request.input.address, &funder).await?;
    let from_amount = amounts::atomic(&request.amount, decimals)?;
    let spend = BigUint::parse_bytes(from_amount.as_bytes(), 10).ok_or_else(local_error)?;
    if balance < spend {
        return Err(Error::invalid(
            "The wallet’s token balance does not cover this order.",
        ));
    }
    let approve_needed = allowance == BigUint::from(0u8);
    if approve_needed {
        body["forceMinimalAllowance"] = json!(true);
    } else if allowance < spend {
        return Err(Error::invalid(
            "This token already has a smaller Flash allowance. Existing allowances are preserved.",
        ));
    }
    let response = service
        .request(
            Provider::Flash,
            Method::POST,
            url(&format!("{FLASH}/quote")),
            Some(body.clone()),
            true,
        )
        .await?;

    let invalid_response = || Error::inconsistent(Provider::Flash);
    let field = |object: &Value, key: &str| -> Result<String> {
        object[key]
            .as_str()
            .filter(|text| !text.is_empty())
            .map(str::to_owned)
            .ok_or_else(invalid_response)
    };
    for field in ["targetAsset", "contraAsset"] {
        if !amounts::same_address(
            "evm",
            response[field].as_str().unwrap_or_default(),
            body[field].as_str().unwrap_or_default(),
        ) {
            return Err(invalid_response());
        }
    }
    if response["side"] != body["side"]
        || response["orderType"] != body["orderType"]
        || !amounts::same_amount(
            response["from"]["amount"].as_str().unwrap_or_default(),
            &request.amount,
        )
        || response["from"]["asset"]
            != if request.side == Some(Side::Buy) {
                "contra"
            } else {
                "target"
            }
        || response["to"]["asset"]
            != if request.side == Some(Side::Buy) {
                "target"
            } else {
                "contra"
            }
        || !response["svm"].is_null()
        || !response["bridgeQuoteId"].is_null()
    {
        return Err(invalid_response());
    }
    let sign_plan = intent::Plan {
        plan_id: field(&response, "quoteId")?,
        chain_id,
        funder,
        from_token: request.input.address,
        to_token: request.output.address,
        from_amount,
        order_deadline: expiry,
        expires_at: crate::now() + 60,
        typed_data: field(&response["evm"], "orderTypedData")?,
    };
    sign_plan
        .validate(crate::now())
        .map_err(|_| invalid_response())?;
    let approval = if approve_needed {
        if !response["wrap"].is_null()
            || response["evm"]["permitTypedData"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
            || response["setupTxs"]
                .as_array()
                .is_some_and(|actions| actions.len() > 1)
        {
            return Err(unsupported_setup());
        }
        Some(
            prepare_approval(
                &rpc,
                &rpc_chain,
                &sign_plan,
                &response["evm"]["approveTx"],
                &spend,
            )
            .await?,
        )
    } else {
        if requires_setup(&response) {
            return Err(unsupported_setup());
        }
        None
    };
    let receive_amount =
        amounts::positive(&response["to"]["amount"]).ok_or_else(invalid_response)?;
    let fee_usd = amounts::nonnegative(&response["fees"]["estimatedFeeNotional"])
        .ok_or_else(invalid_response)?;
    let available_amount =
        amounts::units(&balance.to_string(), decimals).ok_or_else(invalid_response)?;

    let fields = body.as_object_mut().ok_or_else(local_error)?;
    fields.remove("expireTime");
    fields.remove("evmUsePermit2");
    fields.remove("forceMinimalAllowance");
    fields.insert("evmOrderTypedData".into(), json!(&sign_plan.typed_data));
    fields.insert("quoteId".into(), json!(&sign_plan.plan_id));
    let plan_id = sign_plan.plan_id.clone();
    let sign_plan = intent::OrderPlan::Evm(sign_plan);
    cache_review(
        &state,
        plan_id,
        Prepared {
            sign_plan: sign_plan.clone(),
            body,
            intent_key,
            approval: approval.as_ref().map(|value| value.plan.clone()),
            solana_setup: None,
        },
    )?;
    Ok(Json(Review {
        sign_plan,
        order_type: order_type.into(),
        receive_amount,
        fee_usd,
        available_amount,
        spend_decimals: decimals,
        approval,
        solana_setup: None,
    }))
}

fn cache_review(state: &AppState, plan_id: String, plan: Prepared) -> Result<()> {
    let mut reviews = state
        .flash_placement
        .reviews
        .lock()
        .map_err(|_| local_error())?;
    reviews.retain(|_, value| value.sign_plan.expires_at() > crate::now());
    if reviews.len() >= 32 {
        return Err(Error::invalid(
            "Too many Flash reviews are open. Wait for earlier quotes to expire.",
        ));
    }
    if !crate::flash_orders::canonical_order_id(&plan_id) || reviews.contains_key(&plan_id) {
        return Err(Error::inconsistent(Provider::Flash));
    }
    reviews.insert(plan_id, plan);
    Ok(())
}

fn solana_setup_required() -> Error {
    Error::new(
        StatusCode::UNPROCESSABLE_ENTITY,
        "flash_solana_setup_required",
        "Flash could not verify a supported setup for this Solana pair.",
    )
}

fn empty_actions(value: &Value) -> bool {
    value.is_null() || value.as_array().is_some_and(|items| items.is_empty())
}

async fn solana_accounts(rpc: &Rpc, addresses: [&str; 2]) -> Result<[Value; 2]> {
    let result = rpc
        .call(
            "getMultipleAccounts",
            json!([addresses, {"encoding":"jsonParsed","commitment":"confirmed"}]),
        )
        .await
        .map_err(|_| rpc_error())?;
    result["value"]
        .as_array()
        .filter(|values| values.len() == 2)
        .map(|values| [values[0].clone(), values[1].clone()])
        .ok_or_else(rpc_error)
}

fn token_account<'a>(
    account: &'a Value,
    funder: &str,
    mint: &str,
    program: &str,
) -> Result<&'a Value> {
    let parsed = &account["data"]["parsed"];
    let info = &parsed["info"];
    if account["owner"] != program
        || parsed["type"] != "account"
        || info["owner"] != funder
        || info["mint"] != mint
        || info["state"] != "initialized"
        || mint == trig_wallet_transfers::flash::WRAPPED_SOL
            && !info["closeAuthority"].is_null()
            && info["closeAuthority"] != funder
    {
        return Err(solana_setup_required());
    }
    Ok(info)
}

async fn prepare_solana(state: &AppState, input: PrepareRequest) -> Result<Review> {
    let PrepareRequest {
        mut request,
        funder,
        take_profit,
    } = input;
    let service = &state.execution;
    let group = service.config.flash_solana_group().ok_or_else(|| {
        Error::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "flash_solana_unconfigured",
            "Solana order placement needs the verified Flash trading group on this Mac.",
        )
    })?;
    if request.output.chain != "solana"
        || request.input.address == request.output.address
        || !amounts::address("svm", &funder)
        || request.side.is_none()
        || request.order_type == OrderType::Market
        || take_profit
            && (request.order_type != OrderType::Limit || request.side != Some(Side::Sell))
    {
        return Err(Error::invalid(
            "Choose a same-chain SPL token pair and a Solana funding wallet.",
        ));
    }
    request.provider = Some(Provider::Flash);
    request.context.sender = Some(funder.clone());
    request.context.recipient = None;
    let chains = service.chain_set(Provider::Flash).await?;
    let chain = chains
        .chains
        .iter()
        .find(|chain| chain.id == "solana")
        .ok_or_else(|| Error::invalid("Flash does not currently support Solana."))?;
    execution::validate_route(&request, Provider::Flash, chain, chain)?;
    let order_type = if take_profit {
        "take-profit"
    } else if request.order_type == OrderType::Limit {
        "limit"
    } else {
        "stop-loss"
    };
    let trigger_price = request
        .limit_price_usd
        .as_deref()
        .or(request.trigger_price_usd.as_deref())
        .ok_or_else(|| Error::invalid("Enter a target price."))?;
    let intent_key = serde_json::to_string(&(
        "solana",
        &funder,
        &request.input.address,
        &request.output.address,
        order_type,
        request.side,
        amounts::decimal(&request.amount)?.normalized().to_string(),
        amounts::decimal(trigger_price)?.normalized().to_string(),
    ))
    .map_err(|_| local_error())?;
    state
        .flash_placement
        .check_clear(&intent_key, crate::now())?;
    let expiry = crate::now() + 86_400;
    let mut body = execution::providers::flash_body(&request, chain, chain)?;
    if take_profit {
        body["triggers"] = json!([{ "notionalPrice": trigger_price, "triggerType": "upper" }]);
        body.as_object_mut()
            .ok_or_else(local_error)?
            .remove("limitNotionalPrice");
    }
    body["orderType"] = json!(order_type);
    body["expireTime"] = json!(DateTime::<Utc>::from_timestamp(expiry as i64, 0)
        .ok_or_else(local_error)?
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
    let rpc_chain = wallet::chain_for("solana").map_err(|_| rpc_error())?;
    let rpc = Rpc::for_chain(&rpc_chain).await.map_err(|_| rpc_error())?;
    let mints = solana_accounts(&rpc, [&request.input.address, &request.output.address]).await?;
    let programs = mints
        .iter()
        .map(|mint| {
            SplTokenProgram::from_id(mint["owner"].as_str().unwrap_or_default())
                .filter(|_| mint["data"]["parsed"]["type"] == "mint")
                .map(SplTokenProgram::id)
                .ok_or_else(solana_setup_required)
        })
        .collect::<Result<Vec<_>>>()?;
    let decimals = mints[0]["data"]["parsed"]["info"]["decimals"]
        .as_u64()
        .and_then(|value| u8::try_from(value).ok())
        .ok_or_else(rpc_error)?;
    let funding = solana_setup::Funding::load(
        &rpc,
        &funder,
        &request.input.address,
        &request.output.address,
        [programs[0], programs[1]],
    )
    .await?;
    let spend = amounts::atomic(&request.amount, decimals)?
        .parse::<u64>()
        .map_err(|_| Error::invalid("The amount exceeds Solana’s token range."))?;
    let actions = funding.needed(&request.input.address, spend)?;
    if actions.needed() && programs.iter().any(|program| *program != SPL_TOKEN_PROGRAM) {
        return Err(Error::invalid(
            "First-time Flash setup supports classic SPL tokens.",
        ));
    }
    if actions.delegate {
        body["forceMinimalAllowance"] = json!(true);
    }
    if actions.wrap {
        body["svmUseNativeSOL"] = json!(true);
    }
    let response = service
        .request(
            Provider::Flash,
            Method::POST,
            url(&format!("{FLASH}/quote")),
            Some(body.clone()),
            true,
        )
        .await?;
    let svm = &response["svm"];
    if !response["evm"].is_null()
        || !actions.needed()
            && (!empty_actions(&response["setupTxs"]) || !empty_actions(&svm["ataSetupIxs"]))
    {
        return Err(solana_setup_required());
    }
    funding.validate_quote(&response, &actions, &funder, spend)?;
    let invalid = || Error::inconsistent(Provider::Flash);
    let terms = ["targetAsset", "contraAsset", "side", "orderType"];
    if terms.iter().any(|field| response[*field] != body[*field])
        || !response["bridgeQuoteId"].is_null()
        || !amounts::same_amount(
            response["from"]["amount"].as_str().unwrap_or_default(),
            &request.amount,
        )
        || svm["deadline"]
            .as_str()
            .and_then(|value| value.parse::<u64>().ok())
            != Some(expiry)
    {
        return Err(invalid());
    }
    let signed = intent::SolanaPlan {
        plan_id: response["quoteId"]
            .as_str()
            .ok_or_else(invalid)?
            .to_string(),
        funder,
        from_token: request.input.address,
        to_token: request.output.address,
        from_amount: spend.to_string(),
        order_deadline: expiry,
        expires_at: crate::now() + if actions.needed() { 25 } else { 60 },
        order_message: svm["orderMessage"]
            .as_str()
            .ok_or_else(invalid)?
            .to_string(),
        nonce: svm["nonce"].as_str().ok_or_else(invalid)?.to_string(),
        trading_group: group.to_string(),
        input_program: programs[0].into(),
        output_program: programs[1].into(),
    };
    signed.validate(crate::now()).map_err(|_| invalid())?;
    let mut balance = funding.amount();
    let setup = if actions.needed() {
        let wrap = actions.wrap;
        let (setup, native_balance) =
            solana_setup::prepare(&rpc, &signed, actions, decimals).await?;
        if wrap {
            balance = native_balance;
        }
        Some(setup)
    } else {
        None
    };
    let fields = body.as_object_mut().ok_or_else(local_error)?;
    for field in ["expireTime", "forceMinimalAllowance", "svmUseNativeSOL"] {
        fields.remove(field);
    }
    body["quoteId"] = json!(&signed.plan_id);
    body["svmNonce"] = json!(&signed.nonce);
    body["svmDeadline"] = json!(signed.order_deadline.to_string());
    let plan_id = signed.plan_id.clone();
    let sign_plan = intent::OrderPlan::Solana(signed);
    let receive_amount = amounts::positive(&response["to"]["amount"]).ok_or_else(invalid)?;
    let fee_usd =
        amounts::nonnegative(&response["fees"]["estimatedFeeNotional"]).ok_or_else(invalid)?;
    let available_amount = amounts::units(&balance.to_string(), decimals).ok_or_else(invalid)?;
    cache_review(
        state,
        plan_id,
        Prepared {
            sign_plan: sign_plan.clone(),
            body,
            intent_key,
            approval: None,
            solana_setup: setup.clone(),
        },
    )?;
    Ok(Review {
        sign_plan,
        order_type: order_type.into(),
        receive_amount,
        fee_usd,
        available_amount,
        spend_decimals: decimals,
        approval: None,
        solana_setup: setup,
    })
}

pub async fn submit(
    State(state): State<AppState>,
    Json(input): Json<SubmitRequest>,
) -> Result<Json<Value>> {
    if !crate::flash_orders::canonical_order_id(&input.plan_id) || input.signature.len() > 132 {
        return Err(Error::invalid("Invalid signed Flash order."));
    }
    let now = crate::now();
    let store = &state.flash_placement;
    let mut plan = store
        .reviews
        .lock()
        .map_err(|_| local_error())?
        .remove(&input.plan_id)
        .filter(|plan| {
            plan.sign_plan.expires_at() > now
                && plan.approval.is_none()
                && plan.solana_setup.is_none()
        })
        .ok_or_else(|| Error::invalid("Review a fresh Flash order before submitting."))?;
    let signature_valid = match &plan.sign_plan {
        intent::OrderPlan::Evm(_) => input.signature.strip_prefix("0x").is_some_and(|value| {
            value.len() == 130 && value.bytes().all(|b| b.is_ascii_hexdigit())
        }),
        intent::OrderPlan::Solana(_) => bs58::decode(&input.signature)
            .into_vec()
            .is_ok_and(|bytes| bytes.len() == 64),
    };
    if !signature_valid {
        return Err(Error::invalid("Invalid signed Flash order."));
    }
    plan.sign_plan.validate(now).map_err(Error::invalid)?;
    store.mark_submitting(&plan.intent_key, plan.sign_plan.order_deadline(), now)?;
    plan.body["userSignature"] = json!(input.signature);
    let response = state
        .execution
        .request(
            Provider::Flash,
            Method::POST,
            url(&format!("{FLASH}/order")),
            Some(plan.body),
            true,
        )
        .await
        .map_err(|_| uncertain_submit())?;
    let order_id = response["orderId"]
        .as_str()
        .filter(|id| crate::flash_orders::canonical_order_id(id))
        .ok_or_else(uncertain_submit)?;
    // The provider acknowledged this order. A local cleanup failure cannot undo it.
    if let Ok(db) = store.db.lock() {
        let _ = db.execute(
            "DELETE FROM flash_uncertain_submissions WHERE intent_key = ?",
            [&plan.intent_key],
        );
    }
    Ok(Json(json!({"orderId": order_id})))
}

pub async fn approve(
    State(state): State<AppState>,
    Json(input): Json<ApprovalSubmission>,
) -> Result<Json<Value>> {
    if !crate::flash_orders::canonical_order_id(&input.plan_id)
        || input.signed.len() > 4096
        || !input.signed.starts_with("0x")
    {
        return Err(Error::invalid("Invalid signed Flash approval."));
    }
    let raw = hex::decode(&input.signed[2..])
        .map_err(|_| Error::invalid("Invalid signed Flash approval."))?;
    let transaction_id = format!("0x{}", hex::encode(Keccak256::digest(&raw)));
    if transaction_id != input.transaction_id {
        return Err(Error::invalid(
            "This approval signature does not match its transaction ID.",
        ));
    }
    let plan = state
        .flash_placement
        .reviews
        .lock()
        .map_err(|_| local_error())?
        .remove(&input.plan_id)
        .and_then(|plan| plan.approval)
        .ok_or_else(|| Error::invalid("Review a fresh Flash order before approving."))?;
    plan.validate(crate::now()).map_err(Error::invalid)?;
    if signed_approval_matches(&raw, &plan).is_none() {
        return Err(Error::invalid(
            "This signed transaction differs from the reviewed Flash approval.",
        ));
    }
    let chain = wallet::chain_for(&format!("eip155:{}", plan.chain_id)).map_err(|_| rpc_error())?;
    let rpc = Rpc::for_chain(&chain).await.map_err(|_| rpc_error())?;
    rpc.verify_evm(&chain).await.map_err(|_| rpc_error())?;
    let (allowance, nonce) = tokio::try_join!(
        rpc.call(
            "eth_call",
            json!([{"to":plan.token, "data":allowance_data(&plan.funder)}, "pending"])
        ),
        rpc.call("eth_getTransactionCount", json!([plan.funder, "pending"])),
    )
    .map_err(|_| rpc_error())?;
    if token_call(allowance)? != BigUint::from(0u8)
        || big_uint(&nonce)
            .map(|value| format!("{value:x}"))
            .as_deref()
            != Some(&plan.nonce)
    {
        return Err(Error::invalid(
            "The wallet’s allowance or pending transactions changed. Review a fresh approval.",
        ));
    }
    plan.validate(crate::now()).map_err(Error::invalid)?;
    let result = rpc
        .call("eth_sendRawTransaction", json!([input.signed]))
        .await
        .map_err(|_| rpc_error())?;
    if !result
        .as_str()
        .is_some_and(|id| id.eq_ignore_ascii_case(&transaction_id))
    {
        return Err(rpc_error());
    }
    Ok(Json(json!({"transactionId": transaction_id})))
}

pub async fn setup_solana(
    State(state): State<AppState>,
    Json(input): Json<ApprovalSubmission>,
) -> Result<Json<Value>> {
    if !crate::flash_orders::canonical_order_id(&input.plan_id)
        || input.signed.len() > 1644
        || !(64..=88).contains(&input.transaction_id.len())
    {
        return Err(Error::invalid("Invalid signed Flash setup."));
    }
    let plan = state
        .flash_placement
        .reviews
        .lock()
        .map_err(|_| local_error())?
        .remove(&input.plan_id)
        .and_then(|plan| plan.solana_setup)
        .ok_or_else(|| Error::invalid("Review a fresh Flash setup before submitting."))?;
    let chain = wallet::chain_for("solana").map_err(|_| rpc_error())?;
    let rpc = Rpc::for_chain(&chain).await.map_err(|_| rpc_error())?;
    solana_setup::submit(&rpc, plan, &input.signed, &input.transaction_id).await?;
    Ok(Json(json!({"transactionId": input.transaction_id})))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flash_submission_claim_is_durable_and_expires_at_the_signed_deadline() {
        let store = FlashPlacement::open(Path::new(":memory:")).unwrap();
        assert!(store.check_clear("fingerprint", 10).is_ok());
        assert!(store.mark_submitting("fingerprint", 20, 10).is_ok());
        assert!(store.mark_submitting("fingerprint", 20, 11).is_err());
        assert!(store.check_clear("fingerprint", 19).is_err());
        assert!(store.check_clear("fingerprint", 20).is_ok());
        assert!(store.mark_submitting("fingerprint", 30, 20).is_ok());
    }

    #[test]
    fn flash_requires_an_existing_allowance_instead_of_executing_setup_payloads() {
        assert!(requires_setup(&json!({"evm":{"approveTx":{"to":"token"}}})));
        assert!(requires_setup(&json!({"evm":{"permitTypedData":"permit"}})));
        assert!(requires_setup(&json!({"setupTxs":["abc"]})));
        assert!(requires_setup(&json!({"wrap":{}})));
        assert!(!requires_setup(
            &json!({"evm":{"approveTx":null,"permitTypedData":""},"setupTxs":null,"wrap":null})
        ));
    }

    #[test]
    fn flash_approval_submission_rejects_changed_amount_and_signer() {
        let signer = k256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap();
        let address =
            Keccak256::digest(&signer.verifying_key().to_encoded_point(false).as_bytes()[1..]);
        let mut plan = intent::ApprovalPlan {
            plan_id: "deadbeef-1234-abcd-9876-000000000001".into(),
            chain_id: 8453,
            funder: format!("0x{}", hex::encode(&address[12..])),
            token: "0x4200000000000000000000000000000000000006".into(),
            amount: "5000000000000000".into(),
            nonce: "0".into(),
            gas_price: "1".into(),
            gas_limit: "c350".into(),
            fee: "50000".into(),
            expires_at: 60,
        };
        let address = hex::decode(&plan.token[2..]).unwrap();
        let data = approval_calldata(&BigUint::parse_bytes(plan.amount.as_bytes(), 10).unwrap());
        let data = hex::decode(&data[2..]).unwrap();
        let mut tx = rlp::RlpStream::new_list(9);
        tx.append(&0u8)
            .append(&1u8)
            .append(&50000u64)
            .append(&address)
            .append(&0u8)
            .append(&data)
            .append(&plan.chain_id)
            .append(&0u8)
            .append(&0u8);
        let (signature, parity) = signer
            .sign_digest_recoverable(Keccak256::new_with_prefix(tx.out()))
            .unwrap();
        let signature = signature.to_bytes();
        let mut tx = rlp::RlpStream::new_list(9);
        tx.append(&0u8)
            .append(&1u8)
            .append(&50000u64)
            .append(&address)
            .append(&0u8)
            .append(&data)
            .append(&(plan.chain_id * 2 + 35 + u64::from(parity.to_byte())));
        for scalar in [&signature[..32], &signature[32..]] {
            let offset = scalar.iter().position(|byte| *byte != 0).unwrap();
            tx.append(&&scalar[offset..]);
        }
        let wire = tx.out();
        assert!(signed_approval_matches(&wire, &plan).is_some());
        plan.amount = "5000000000000001".into();
        assert!(signed_approval_matches(&wire, &plan).is_none());
        plan.amount = "5000000000000000".into();
        plan.funder = "0x000000000000000000000000000000000000dead".into();
        assert!(signed_approval_matches(&wire, &plan).is_none());
    }
}
