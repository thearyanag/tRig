use crate::{
    execution::types::Provider,
    quotes,
    wallet::{chain_for, Rpc},
    ApiError, AppState,
};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use reqwest::{Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use tokio::sync::Mutex;
use trig_wallet_swap_policy::{
    self as policy, Terms, VersionedTransaction, SOL, SYSTEM, TOKEN, TOKEN_2022,
};

#[derive(Default)]
pub struct Plans(Mutex<HashMap<String, Prepared>>);

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Prepare {
    wallet: String,
    input_mint: String,
    output_mint: String,
    in_amount: String,
    slippage_bps: u16,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Prepared {
    terms: Terms,
    transaction: String,
    request_id: String,
    last_valid_block_height: u64,
    out_amount: String,
    fee_bps: u64,
    #[serde(skip)]
    submitted: bool,
}

fn reject(message: &str) -> ApiError {
    ApiError(StatusCode::UNPROCESSABLE_ENTITY, message.into())
}

fn malformed() -> ApiError {
    reject("Jupiter returned an inconsistent trade. Review a new quote.")
}

fn quantity(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| v.as_str()?.parse().ok())
}

fn pubkey(value: &str) -> bool {
    value.len() <= 44
        && bs58::decode(value)
            .into_vec()
            .is_ok_and(|bytes| bytes.len() == 32)
}

fn order_quantity(value: &Value, key: &str) -> Result<u64, ApiError> {
    quantity(&value[key]).ok_or_else(malformed)
}

fn provider_error(error: crate::execution::types::Error) -> ApiError {
    ApiError(error.status, error.message)
}

fn from_order(order: &Value, input: &Prepare, amount: u64) -> Result<Prepared, ApiError> {
    if order["taker"] != input.wallet
        || order["inputMint"] != input.input_mint
        || order["outputMint"] != input.output_mint
        || order["swapMode"] != "ExactIn"
        || order_quantity(order, "inAmount")? != amount
        || order_quantity(order, "slippageBps")? != u64::from(input.slippage_bps)
        || !matches!(order["router"].as_str(), Some("iris" | "metis"))
    {
        return Err(malformed());
    }
    let request_id = order["requestId"]
        .as_str()
        .filter(|id| {
            !id.is_empty()
                && id.len() <= 128
                && id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
        })
        .ok_or_else(malformed)?;
    let min = order_quantity(order, "otherAmountThreshold")?;
    let out = order_quantity(order, "outAmount")?;
    let fee_bps = order_quantity(order, "feeBps")?;
    let block_height = order_quantity(order, "lastValidBlockHeight")?;
    if min == 0 || min > out || fee_bps > 100 || block_height == 0 {
        return Err(malformed());
    }
    let fee = order_quantity(order, "signatureFeeLamports")?
        .checked_add(order_quantity(order, "prioritizationFeeLamports")?)
        .and_then(|sum| sum.checked_add(quantity(&order["rentFeeLamports"])?))
        .ok_or_else(malformed)?;
    if fee == 0 || fee > 50_000_000 {
        return Err(reject(
            "The Jupiter route exceeds the supported network cost.",
        ));
    }
    let transaction = order["transaction"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 1644)
        .ok_or_else(|| {
            reject(
                "Jupiter could not build a swap for this wallet. Check the balance and try again.",
            )
        })?;
    Ok(Prepared {
        terms: Terms {
            wallet: input.wallet.clone(),
            input_mint: input.input_mint.clone(),
            output_mint: input.output_mint.clone(),
            in_amount: amount.to_string(),
            minimum_out: min.to_string(),
            max_network_cost: fee.to_string(),
            slippage_bps: input.slippage_bps,
            expires_at: policy::now() + 45,
        },
        last_valid_block_height: block_height,
        transaction: transaction.into(),
        request_id: request_id.into(),
        out_amount: out.to_string(),
        fee_bps,
        submitted: false,
    })
}

pub async fn prepare(
    State(state): State<AppState>,
    Json(input): Json<Prepare>,
) -> Result<Json<Value>, ApiError> {
    let amount = input
        .in_amount
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| reject("Enter a positive swap amount."))?;
    if ![&input.wallet, &input.input_mint, &input.output_mint]
        .into_iter()
        .all(|p| pubkey(p))
        || input.input_mint == input.output_mint
        || input.input_mint != quotes::USDC && input.output_mint != quotes::USDC
        || !(1..=500).contains(&input.slippage_bps)
    {
        return Err(reject(
            "Select a Solana wallet and a supported pair against USDC.",
        ));
    }
    let mut url = Url::parse("https://api.jup.ag/swap/v2/order").unwrap();
    url.query_pairs_mut()
        .append_pair("inputMint", &input.input_mint)
        .append_pair("outputMint", &input.output_mint)
        .append_pair("amount", &input.in_amount)
        .append_pair("slippageBps", &input.slippage_bps.to_string())
        .append_pair("taker", &input.wallet)
        .append_pair("excludeRouters", "jupiterz,dflow,okx");
    let order = state
        .execution
        .request(Provider::Jupiter, Method::GET, url, None, true)
        .await
        .map_err(provider_error)?;
    let plan = from_order(&order, &input, amount)?;
    let unsigned = policy::decode(&plan.transaction).map_err(reject)?;
    policy::review(&unsigned, &plan.terms).map_err(reject)?;
    let rpc = Rpc::for_chain(&chain_for("solana")?).await?;
    let effects = verify_effects(&rpc, &unsigned, &plan).await?;
    if policy::now() + 5 >= plan.terms.expires_at {
        return Err(reject(
            "The swap expired during validation. Refresh the review.",
        ));
    }
    let mut plans = state.jupiter_swaps.0.lock().await;
    let now = policy::now();
    plans.retain(|_, entry| entry.terms.expires_at > now);
    if plans.len() >= 32 || plans.contains_key(&plan.request_id) {
        return Err(reject("Refresh the trade review in a moment."));
    }
    let mut response = serde_json::to_value(&plan).map_err(|_| malformed())?;
    response["inputBalance"] = json!(effects.input_balance.to_string());
    response["feeBalance"] = json!(effects.fee_balance.to_string());
    response["inputDecimals"] = json!(effects.input_decimals);
    response["outputDecimals"] = json!(effects.output_decimals);
    response["wrappedSolReturned"] = json!(effects.wrapped_sol_returned.to_string());
    plans.insert(plan.request_id.clone(), plan);
    Ok(Json(response))
}

async fn resolved_accounts(rpc: &Rpc, tx: &VersionedTransaction) -> Result<Vec<String>, ApiError> {
    let mut keys: Vec<_> = tx
        .message
        .static_account_keys()
        .iter()
        .map(ToString::to_string)
        .collect();
    let Some(lookups) = tx
        .message
        .address_table_lookups()
        .filter(|tables| !tables.is_empty())
    else {
        return Ok(keys);
    };
    let table_keys: Vec<_> = lookups
        .iter()
        .map(|lookup| lookup.account_key.to_string())
        .collect();
    let reply = rpc
        .call(
            "getMultipleAccounts",
            json!([table_keys, {"encoding":"base64","commitment":"confirmed"}]),
        )
        .await?;
    let tables = reply["value"]
        .as_array()
        .filter(|values| values.len() == lookups.len())
        .ok_or_else(malformed)?;
    let mut readonly = Vec::new();
    for (table, lookup) in tables.iter().zip(lookups) {
        const LOOKUP_PROGRAM: &str = "AddressLookupTab1e1111111111111111111111111";
        let data = account_data(table)?;
        if table["owner"] != LOOKUP_PROGRAM
            || data.len() < 56
            || data[..4] != [1, 0, 0, 0]
            || data[4..12] != [255; 8]
            || (data.len() - 56) % 32 != 0
        {
            return Err(reject("Jupiter used an unavailable Solana lookup table."));
        }
        let key = |index: &u8| {
            let start = 56 + usize::from(*index) * 32;
            data.get(start..start + 32)
                .map(|bytes| bs58::encode(bytes).into_string())
                .ok_or_else(malformed)
        };
        for index in &lookup.writable_indexes {
            keys.push(key(index)?);
        }
        for index in &lookup.readonly_indexes {
            readonly.push(key(index)?);
        }
    }
    keys.extend(readonly);
    Ok(keys)
}

fn account_data(account: &Value) -> Result<Vec<u8>, ApiError> {
    account["data"]
        .get(0)
        .and_then(Value::as_str)
        .and_then(|s| STANDARD.decode(s).ok())
        .ok_or_else(|| reject("Solana returned an invalid account snapshot."))
}

fn account_ref<'a>(keys: &'a [String], indices: &[u8], index: usize) -> Result<&'a str, ApiError> {
    indices
        .get(index)
        .and_then(|i| keys.get(usize::from(*i)))
        .map(String::as_str)
        .ok_or_else(malformed)
}

fn check_resolved_accounts(
    tx: &VersionedTransaction,
    keys: &[String],
    terms: &Terms,
) -> Result<(), ApiError> {
    let wsol = trig_wallet_transfers::spl_recipient_address(&terms.wallet, SOL).map_err(reject)?;
    let mut wrap_count = 0;
    for ix in tx.message.instructions() {
        let program = keys
            .get(usize::from(ix.program_id_index))
            .ok_or_else(malformed)?
            .as_str();
        let account = |index| account_ref(keys, &ix.accounts, index);
        match program {
            SYSTEM => {
                wrap_count += 1;
                let amount = u64::from_le_bytes(ix.data[4..12].try_into().unwrap());
                if terms.input_mint != SOL
                    || account(0)? != terms.wallet
                    || account(1)? != wsol
                    || amount != terms.in_amount.parse::<u64>().map_err(|_| malformed())?
                {
                    return Err(reject("Jupiter requested an unexpected SOL transfer."));
                }
            }
            TOKEN => {
                if terms.input_mint != SOL && terms.output_mint != SOL
                    || account(0)? != wsol
                    || ix.data == [9]
                        && (account(1)? != terms.wallet || account(2)? != terms.wallet)
                {
                    return Err(reject(
                        "Jupiter requested an unexpected token account change.",
                    ));
                }
            }
            "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL" => {
                let mint = account(3)?;
                let token_program = account(5)?;
                let expected = trig_wallet_transfers::solana_associated_address(
                    &terms.wallet,
                    mint,
                    token_program,
                )
                .map_err(reject)?;
                if account(0)? != terms.wallet
                    || account(2)? != terms.wallet
                    || account(1)? != expected
                    || account(4)? != SYSTEM
                    || !matches!(token_program, TOKEN | TOKEN_2022)
                {
                    return Err(reject(
                        "Jupiter requested an unexpected token account creation.",
                    ));
                }
            }
            "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4" => {
                let (source, destination, from, to, source_program, destination_program) =
                    if ix.data[0] == 187 {
                        (1, 2, 3, 4, 5, 6)
                    } else {
                        (2, 5, 6, 7, 8, 9)
                    };
                let owner_account = |mint: &str| {
                    trig_wallet_transfers::spl_recipient_address(&terms.wallet, mint)
                        .map_err(reject)
                };
                if account(from)? != terms.input_mint
                    || account(to)? != terms.output_mint
                    || account(source)? != owner_account(&terms.input_mint)?
                    || account(destination)? != owner_account(&terms.output_mint)?
                    || account(source_program)? != TOKEN
                    || account(destination_program)? != TOKEN
                    || source == 1 && ![account(destination)?, program].contains(&account(7)?)
                {
                    return Err(reject(
                        "The Jupiter route does not use the selected wallet's token accounts.",
                    ));
                }
            }
            _ => {}
        }
    }
    if terms.input_mint == SOL && wrap_count != 1 {
        return Err(reject(
            "Jupiter did not wrap the exact reviewed amount of SOL.",
        ));
    }
    Ok(())
}

struct VerifiedEffects {
    input_balance: u64,
    fee_balance: u64,
    input_decimals: u8,
    output_decimals: u8,
    wrapped_sol_returned: u64,
}

async fn verify_effects(
    rpc: &Rpc,
    tx: &VersionedTransaction,
    plan: &Prepared,
) -> Result<VerifiedEffects, ApiError> {
    let terms = &plan.terms;
    let keys = resolved_accounts(rpc, tx).await?;
    if keys.iter().collect::<HashSet<_>>().len() != keys.len() {
        return Err(malformed());
    }
    check_resolved_accounts(tx, &keys, terms)?;
    let writable: Vec<_> = keys
        .iter()
        .enumerate()
        .filter(|(i, _)| tx.message.is_maybe_writable(*i, None))
        .map(|(_, key)| key)
        .collect();
    if writable.first().map(|v| v.as_str()) != Some(terms.wallet.as_str()) || writable.len() > 64 {
        return Err(reject(
            "The Jupiter transaction exceeds the supported account scope.",
        ));
    }
    let before_keys: Vec<_> = writable
        .iter()
        .copied()
        .chain([&terms.input_mint, &terms.output_mint])
        .collect();
    let before = rpc
        .call(
            "getMultipleAccounts",
            json!([before_keys, {
                "encoding":"base64","commitment":"confirmed"
            }]),
        )
        .await?;
    let slot = before["context"]["slot"].as_u64().ok_or_else(malformed)?;
    let simulation = rpc
        .call(
            "simulateTransaction",
            json!([plan.transaction, {
                "encoding":"base64", "sigVerify":false, "replaceRecentBlockhash":false,
                "commitment":"confirmed", "minContextSlot":slot,
                "accounts":{"encoding":"base64","addresses":writable}
            }]),
        )
        .await?;
    let value = &simulation["value"];
    if value.get("err") != Some(&Value::Null) {
        return Err(reject(
            "The Jupiter transaction did not simulate successfully. Check balances and refresh.",
        ));
    }
    let fee = rpc
        .call(
            "getFeeForMessage",
            json!([STANDARD.encode(tx.message.serialize()), {"commitment":"confirmed"}]),
        )
        .await?;
    let fee = fee["value"]
        .as_u64()
        .filter(|fee| *fee > 0)
        .ok_or_else(|| {
            reject("Solana could not verify the transaction fee. Refresh the review.")
        })?;
    let before = before["value"]
        .as_array()
        .filter(|accounts| accounts.len() == before_keys.len())
        .ok_or_else(malformed)?;
    let after = value["accounts"]
        .as_array()
        .filter(|accounts| accounts.len() == writable.len())
        .ok_or_else(malformed)?;
    let (wallet_accounts, mints) = before.split_at(writable.len());
    let wsol = trig_wallet_transfers::spl_recipient_address(&terms.wallet, SOL).map_err(reject)?;
    let wsol_index = writable.iter().position(|address| **address == wsol);
    let (input_balance, fee_balance, wrapped_sol_returned) =
        validate_balances(wallet_accounts, after, terms, fee, wsol_index)?;
    Ok(VerifiedEffects {
        input_balance,
        fee_balance,
        input_decimals: mint_decimals(&mints[0])?,
        output_decimals: mint_decimals(&mints[1])?,
        wrapped_sol_returned,
    })
}

fn mint_decimals(account: &Value) -> Result<u8, ApiError> {
    let data = account_data(account)?;
    if account["owner"] != TOKEN || data.len() != 82 || data[45] != 1 {
        return Err(reject("The trade token uses an unsupported mint format."));
    }
    Ok(data[44])
}

struct TokenAccount {
    mint: String,
    amount: u64,
    program: String,
    authority: Vec<u8>,
}

fn wallet_token(account: &Value, wallet: &str) -> Result<Option<TokenAccount>, ApiError> {
    let Some(program @ (TOKEN | TOKEN_2022)) = account["owner"].as_str() else {
        return Ok(None);
    };
    let data = account_data(account)?;
    if data.len() < 165 || bs58::encode(&data[32..64]).into_string() != wallet {
        return Ok(None);
    }
    if program == TOKEN && data.len() != 165 {
        return Err(reject(
            "This wallet token account uses unsupported extensions.",
        ));
    }
    Ok(Some(TokenAccount {
        mint: bs58::encode(&data[..32]).into_string(),
        amount: u64::from_le_bytes(data[64..72].try_into().unwrap()),
        program: program.into(),
        authority: data[72..].to_vec(),
    }))
}

fn validate_balances(
    before: &[Value],
    after: &[Value],
    terms: &Terms,
    fee: u64,
    wsol_index: Option<usize>,
) -> Result<(u64, u64, u64), ApiError> {
    let bad_effect =
        || reject("The simulated swap changed wallet balances outside the reviewed terms.");
    let pre_sol = before
        .first()
        .filter(|v| v["owner"] == SYSTEM)
        .and_then(|v| v["lamports"].as_u64())
        .ok_or_else(bad_effect)?;
    let post_sol = after
        .first()
        .filter(|v| v["owner"] == SYSTEM)
        .and_then(|v| v["lamports"].as_u64())
        .ok_or_else(bad_effect)?;
    let input = terms.in_amount.parse::<u64>().map_err(|_| malformed())?;
    let minimum = terms.minimum_out.parse::<u64>().map_err(|_| malformed())?;
    let max_fee = terms
        .max_network_cost
        .parse::<u64>()
        .map_err(|_| malformed())?;
    let mut input_delta = 0i128;
    let mut out_delta = 0i128;
    let mut input_balance = 0u64;
    let mut wrapped_sol_returned = 0;
    for (index, (pre, post)) in before.iter().zip(after).enumerate().skip(1) {
        let a = wallet_token(pre, &terms.wallet)?;
        let b = wallet_token(post, &terms.wallet)?;
        if Some(index) == wsol_index
            && (terms.input_mint == SOL || terms.output_mint == SOL)
            && a.as_ref().is_some_and(|token| {
                token.mint == SOL
                    && token.program == TOKEN
                    && token.authority[0..4] == [0; 4]
                    && token.authority[57..61] == [0; 4]
            })
            && (post.is_null() || post["owner"] == SYSTEM && post["lamports"] == 0)
        {
            // Closing the wallet's wrapped SOL account returns its previous balance and rent.
            // Subtract the refund before measuring the trade's SOL delta.
            wrapped_sol_returned = pre["lamports"].as_u64().ok_or_else(bad_effect)?;
            continue;
        }
        if a.is_some() && b.is_none() || !pre.is_null() && a.is_none() && b.is_some() {
            return Err(bad_effect());
        }
        let Some(token) = b else { continue };
        if a.as_ref().is_some_and(|prev| {
            prev.mint != token.mint
                || prev.program != token.program
                || prev.authority != token.authority
        }) || a.is_none()
            && (token.authority[0..4] != [0; 4] || token.authority[57..61] != [0; 4])
        {
            return Err(bad_effect());
        }
        let previous = a.as_ref().map_or(0, |previous| previous.amount);
        let delta = i128::from(token.amount) - i128::from(previous);
        if token.mint == terms.input_mint && token.mint != SOL {
            input_delta += delta;
            input_balance = input_balance.checked_add(previous).ok_or_else(bad_effect)?;
        } else if token.mint == terms.output_mint && token.mint != SOL {
            out_delta += delta;
        } else if delta != 0 {
            return Err(bad_effect());
        }
    }
    let spent = i128::from(input);
    let sol_delta = i128::from(post_sol) - i128::from(pre_sol) - i128::from(wrapped_sol_returned);
    if fee > max_fee
        || sol_delta < -i128::from(max_fee) - if terms.input_mint == SOL { spent } else { 0 }
    {
        return Err(bad_effect());
    }
    let receive = if terms.output_mint == SOL {
        sol_delta + i128::from(fee)
    } else {
        out_delta
    };
    if receive < i128::from(minimum)
        || terms.input_mint != SOL && input_delta != -spent
        || terms.input_mint == SOL && sol_delta > -spent
    {
        return Err(bad_effect());
    }
    if terms.input_mint == SOL {
        input_balance = pre_sol;
    }
    Ok((input_balance, pre_sol, wrapped_sol_returned))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Submit {
    request_id: String,
    signed: String,
    transaction_id: String,
}

pub async fn submit(
    State(state): State<AppState>,
    Json(input): Json<Submit>,
) -> Result<Json<Value>, ApiError> {
    let plan = {
        let mut plans = state.jupiter_swaps.0.lock().await;
        let plan = plans
            .get_mut(&input.request_id)
            .filter(|plan| !plan.submitted && plan.terms.expires_at > policy::now())
            .ok_or_else(|| reject("The trade was already submitted or its review expired."))?;
        let unsigned = policy::decode(&plan.transaction).map_err(reject)?;
        let signed = policy::decode(&input.signed).map_err(reject)?;
        policy::validate_signed(&unsigned, &signed, &input.transaction_id).map_err(reject)?;
        plan.submitted = true;
        plan.clone()
    };
    // The signed transaction can be submitted only once; the wallet journal recovers
    // the outcome directly from Solana if Jupiter's response is lost or ambiguous.
    let result = state
        .execution
        .request(
            Provider::Jupiter,
            Method::POST,
            Url::parse("https://api.jup.ag/swap/v2/execute").unwrap(),
            Some(json!({
                "signedTransaction": input.signed, "requestId": input.request_id,
                "lastValidBlockHeight": plan.last_valid_block_height.to_string(),
            })),
            true,
        )
        .await
        .map_err(provider_error)?;
    let confirmed = result["signature"] == input.transaction_id
        && result["status"] == "Success"
        && result["code"] == 0
        && quantity(&result["totalInputAmount"])
            .zip(plan.terms.in_amount.parse().ok())
            .is_some_and(|(actual, max): (u64, u64)| actual <= max)
        && quantity(&result["totalOutputAmount"])
            .zip(plan.terms.minimum_out.parse().ok())
            .is_some_and(|(actual, min): (u64, u64)| actual >= min);
    Ok(Json(
        json!({"status": if confirmed { "confirmed" } else { "pending" }}),
    ))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Status {
    chain: String,
    #[serde(rename = "requestId")]
    _request_id: String,
    transaction_id: String,
    last_valid_block_height: Option<u64>,
}

pub async fn status(Query(input): Query<Status>) -> Result<Json<Value>, ApiError> {
    if input.chain != "solana"
        || input.transaction_id.len() > 88
        || bs58::decode(&input.transaction_id)
            .into_vec()
            .map_or(true, |b| b.len() != 64)
    {
        return Err(reject("Invalid Solana transaction."));
    }
    let rpc = Rpc::for_chain(&chain_for("solana")?).await?;
    let signatures = rpc
        .call(
            "getSignatureStatuses",
            json!([[input.transaction_id], {"searchTransactionHistory":true}]),
        )
        .await?;
    let value = signatures["value"].get(0).ok_or_else(malformed)?;
    let mut status = match value["confirmationStatus"].as_str() {
        Some("confirmed" | "finalized") if value["err"].is_null() => "confirmed",
        Some("confirmed" | "finalized") => "failed",
        _ => "pending",
    };
    if value.is_null() {
        if let Some(last) = input.last_valid_block_height {
            let height = rpc
                .call("getBlockHeight", json!([{"commitment":"finalized"}]))
                .await?;
            if height
                .as_u64()
                .is_some_and(|height| height > last.saturating_add(20))
            {
                status = "expired";
            }
        }
    }
    Ok(Json(json!({"status":status})))
}

#[cfg(test)]
mod tests {
    use super::*;

    const WALLET: &str = "So11111111111111111111111111111111111111112";

    fn token(mint: &str, amount: u64) -> Value {
        let mut bytes = vec![0u8; 165];
        bytes[..32].copy_from_slice(&bs58::decode(mint).into_vec().unwrap());
        bytes[32..64].copy_from_slice(&bs58::decode(WALLET).into_vec().unwrap());
        bytes[64..72].copy_from_slice(&amount.to_le_bytes());
        bytes[108] = 1; // Initialized token account.
        json!({"owner":TOKEN, "data":[STANDARD.encode(bytes),"base64"]})
    }

    fn sol(amount: u64) -> Value {
        json!({"owner":SYSTEM,"lamports":amount})
    }

    #[test]
    fn validates_exact_spend_minimum_receive_and_cost_without_authority_changes() {
        let terms = Terms {
            wallet: WALLET.into(),
            input_mint: quotes::USDC.into(),
            output_mint: SOL.into(),
            in_amount: "1000000".into(),
            minimum_out: "10000000".into(),
            max_network_cost: "5000".into(),
            slippage_bps: 50,
            expires_at: policy::now() + 30,
        };
        let before = vec![sol(9_000), token(quotes::USDC, 2_000_000)];
        let mut after = vec![sol(10_004_000), token(quotes::USDC, 1_000_000)];
        assert!(validate_balances(&before, &after, &terms, 5_000, None).is_ok());
        assert!(validate_balances(&before, &after, &terms, 5_001, None).is_err());
        after[0] = sol(10_003_999);
        assert!(validate_balances(&before, &after, &terms, 5_000, None).is_err());
        after[0] = sol(10_004_000);
        after[1] = token(quotes::USDC, 999_999);
        assert!(validate_balances(&before, &after, &terms, 5_000, None).is_err());
        after[1] = token(quotes::USDC, 1_000_000);
        let mut bytes = account_data(&after[1]).unwrap();
        bytes[72] = 1;
        after[1]["data"][0] = json!(STANDARD.encode(bytes));
        assert!(validate_balances(&before, &after, &terms, 5_000, None).is_err());
    }

    #[test]
    fn separating_returned_wrapped_sol_preserves_exact_spend() {
        let terms = Terms {
            wallet: WALLET.into(),
            input_mint: SOL.into(),
            output_mint: quotes::USDC.into(),
            in_amount: "10000000".into(),
            minimum_out: "650000".into(),
            max_network_cost: "5000".into(),
            slippage_bps: 50,
            expires_at: policy::now() + 30,
        };
        let mut wrapped = token(SOL, 1_000_000);
        wrapped["lamports"] = json!(3_039_280);
        let before = vec![sol(20_000_000), wrapped, token(quotes::USDC, 0)];
        let after = vec![sol(13_034_280), Value::Null, token(quotes::USDC, 700_000)];
        assert_eq!(
            validate_balances(&before, &after, &terms, 5_000, Some(1)).ok(),
            Some((20_000_000, 20_000_000, 3_039_280))
        );
        assert!(validate_balances(&before, &after, &terms, 5_000, None).is_err());
    }
}
