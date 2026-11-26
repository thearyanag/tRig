use super::*;

const PAGE_SIZE: usize = 20;
const MAX_OFFSET: usize = 10_000;
const MAX_CACHED_ORDERS: usize = 128;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OrdersQuery {
    wallet: String,
    #[serde(default)]
    offset: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CancelRequest {
    wallet: String,
    order_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CancelProof {
    wallet: String,
    order_id: String,
    signature: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Order {
    id: String,
    order_type: String,
    order_state: String,
    raw_state: Option<String>,
    input_mint: String,
    output_mint: String,
    initial_input_amount: String,
    remaining_input_amount: String,
    output_amount: Option<String>,
    trigger_condition: Option<String>,
    trigger_price_usd: Option<String>,
    tp_price_usd: Option<String>,
    sl_price_usd: Option<String>,
    expires_at: Option<u64>,
    updated_at: Option<u64>,
    input_decimals: Option<u8>,
    can_cancel: bool,
    #[serde(skip)]
    vault: Option<String>,
    #[serde(skip)]
    deposit_signature: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OrderPage {
    orders: Vec<Order>,
    next_offset: Option<usize>,
}

pub(super) fn order_id(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}
fn order_unavailable() -> ApiError {
    invalid("Refresh Orders and select an open, expired, or pending withdrawal order.")
}
fn decimal_field(value: &Value) -> Option<String> {
    let text = value
        .as_str()
        .map(str::to_owned)
        .or_else(|| value.as_number().map(ToString::to_string))?;
    (text.len() <= 36
        && text
            .parse::<f64>()
            .is_ok_and(|price| price.is_finite() && price > 0.0))
    .then_some(text)
}

fn read_order(value: &Value, wallet: &str) -> Option<Order> {
    if value["userPubkey"] != wallet {
        return None;
    }
    let id = value["id"].as_str().filter(|id| order_id(id))?;
    let order_type = value["orderType"]
        .as_str()
        .filter(|kind| matches!(*kind, "single" | "oco" | "otoco"))?;
    let order_state = value["orderState"].as_str().filter(|state| {
        matches!(
            *state,
            "pending"
                | "open"
                | "executing"
                | "filled"
                | "pending_withdraw"
                | "cancelled"
                | "expired"
                | "failed"
        )
    })?;
    let raw_state = value["rawState"].as_str().filter(|state| identifier(state));
    let input_mint = value["inputMint"].as_str().filter(|mint| pubkey(mint))?;
    let output_mint = value["outputMint"]
        .as_str()
        .filter(|mint| pubkey(mint) && *mint != input_mint)?;
    let initial = value["initialInputAmount"].as_str().and_then(atomic)?;
    let remaining = value["remainingInputAmount"]
        .as_str()
        .and_then(atomic)
        .filter(|amount| *amount <= initial)?;
    let can_cancel = order_type == "single"
        && remaining > 0
        && matches!(order_state, "open" | "expired" | "pending_withdraw");
    let deposit_signature = value["events"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|event| event["type"] == "deposit")
        .find_map(|event| event["txSignature"].as_str().filter(|sig| signature(sig)))
        .map(str::to_owned);
    Some(Order {
        id: id.into(),
        order_type: order_type.into(),
        order_state: order_state.into(),
        raw_state: raw_state.map(str::to_owned),
        input_mint: input_mint.into(),
        output_mint: output_mint.into(),
        initial_input_amount: initial.to_string(),
        remaining_input_amount: remaining.to_string(),
        output_amount: value["outputAmount"]
            .as_str()
            .and_then(atomic)
            .map(|amount| amount.to_string()),
        trigger_condition: value["triggerCondition"]
            .as_str()
            .filter(|condition| matches!(*condition, "above" | "below"))
            .map(str::to_owned),
        trigger_price_usd: decimal_field(&value["triggerPriceUsd"]),
        tp_price_usd: decimal_field(&value["tpPriceUsd"]),
        sl_price_usd: decimal_field(&value["slPriceUsd"]),
        expires_at: value["expiresAt"].as_u64(),
        updated_at: value["updatedAt"].as_u64(),
        input_decimals: value["inputDecimals"]
            .as_u64()
            .and_then(|value| u8::try_from(value).ok()),
        can_cancel,
        vault: value["privyWalletPubkey"]
            .as_str()
            .filter(|vault| pubkey(vault))
            .map(str::to_owned),
        deposit_signature,
    })
}

fn read_history(value: &Value, wallet: &str, offset: usize) -> Result<OrderPage> {
    let records = value["orders"]
        .as_array()
        .filter(|records| records.len() <= PAGE_SIZE)
        .ok_or_else(bad_upstream)?;
    if records.iter().any(|record| record["userPubkey"] != wallet) {
        return Err(bad_upstream());
    }
    let next_offset = offset + records.len();
    let total = value["pagination"]["total"]
        .as_u64()
        .and_then(|total| usize::try_from(total).ok());
    let next_offset = (next_offset > offset
        && next_offset <= MAX_OFFSET
        && total.map_or(records.len() == PAGE_SIZE, |total| next_offset < total))
    .then_some(next_offset);
    Ok(OrderPage {
        orders: records
            .iter()
            .filter_map(|order| read_order(order, wallet))
            .collect(),
        next_offset,
    })
}

impl Service {
    async fn history(
        &self,
        key: Option<&str>,
        state: &mut WalletState,
        wallet: &str,
        offset: usize,
        mint: Option<&str>,
    ) -> Result<OrderPage> {
        let mut path =
            format!("orders/history?limit={PAGE_SIZE}&offset={offset}&sort=updated_at&dir=desc");
        if let Some(mint) = mint {
            // mint is a validated base58 address from the authenticated order history.
            path.push_str("&mint=");
            path.push_str(mint);
        }
        let value = self
            .authenticated(key, state, Method::GET, &path, None)
            .await?;
        let page = read_history(&value, wallet, offset)?;
        for order in &page.orders {
            if let Some(signature) = &order.deposit_signature {
                self.reconcile_deposit(wallet, signature, &order.id)?;
            }
            if state.orders.len() >= MAX_CACHED_ORDERS {
                let oldest = state
                    .orders
                    .values()
                    .min_by_key(|old| old.updated_at)
                    .map(|old| old.id.clone());
                if let Some(oldest) = oldest {
                    state.orders.remove(&oldest);
                }
            }
            state.orders.insert(order.id.clone(), order.clone());
        }
        Ok(page)
    }

    fn order_token_account(&self, wallet: &str, order_id: &str) -> Result<Option<String>> {
        let db = self.db.lock().map_err(|_| local_error())?;
        db.query_row(
            "SELECT order_token_account FROM jupiter_trigger_deposits WHERE wallet = ? AND order_id = ?",
            params![wallet, order_id], |row| row.get(0),
        ).optional().map_err(|_| local_error())
    }

    fn withdrawal_for_order(
        &self,
        wallet: &str,
        order: &str,
    ) -> Result<Option<(Review, Option<String>)>> {
        let db = self.db.lock().map_err(|_| local_error())?;
        let saved = db.query_row(
            "SELECT review, submitted_signature FROM jupiter_trigger_withdrawals WHERE wallet = ? AND order_id = ?",
            params![wallet, order], |row| Ok((row.get::<_, String>(0)?, row.get(1)?)),
        ).optional().map_err(|_| local_error())?;
        saved
            .map(|(review, signature)| {
                serde_json::from_str(&review)
                    .map(|review| (review, signature))
                    .map_err(|_| local_error())
            })
            .transpose()
    }

    fn save_withdrawal(
        &self,
        wallet: &str,
        order: &str,
        review: &Review,
        signature: Option<&str>,
    ) -> Result<()> {
        let body = serde_json::to_string(review).map_err(|_| local_error())?;
        let db = self.db.lock().map_err(|_| local_error())?;
        db.execute(
            "INSERT INTO jupiter_trigger_withdrawals(wallet, order_id, plan_id, review, submitted_signature)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(wallet, order_id) DO UPDATE SET plan_id = excluded.plan_id, review = excluded.review,
              submitted_signature = excluded.submitted_signature",
            params![wallet, order, review.plan_id, body, signature],
        ).map_err(|_| local_error())?;
        Ok(())
    }

    fn withdrawal_for_plan(
        &self,
        wallet: &str,
        plan_id: &str,
    ) -> Result<Option<(String, Review, Option<String>)>> {
        let db = self.db.lock().map_err(|_| local_error())?;
        let saved = db.query_row(
            "SELECT order_id, review, submitted_signature FROM jupiter_trigger_withdrawals WHERE wallet = ? AND plan_id = ?",
            params![wallet, plan_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get(2)?)),
        ).optional().map_err(|_| local_error())?;
        saved
            .map(|(order, review, signature)| {
                serde_json::from_str(&review)
                    .map(|review| (order, review, signature))
                    .map_err(|_| local_error())
            })
            .transpose()
    }

    fn forget_withdrawal(&self, wallet: &str, order: &str) -> Result<()> {
        self.db
            .lock()
            .map_err(|_| local_error())?
            .execute(
                "DELETE FROM jupiter_trigger_withdrawals WHERE wallet = ? AND order_id = ?",
                params![wallet, order],
            )
            .map_err(|_| local_error())?;
        Ok(())
    }
}

pub(crate) async fn orders(
    State(state): State<AppState>,
    Query(input): Query<OrdersQuery>,
) -> Result<Json<OrderPage>> {
    if input.offset > MAX_OFFSET {
        return Err(invalid("Invalid Jupiter order history page."));
    }
    let key = api_key(&state);
    let service = &state.jupiter_trigger;
    let wallet = service.wallet(&input.wallet, false).await?;
    let mut wallet = wallet.lock().await;
    service
        .history(key, &mut wallet, &input.wallet, input.offset, None)
        .await
        .map(Json)
}

pub(crate) async fn cancel_challenge(
    State(state): State<AppState>,
    Json(input): Json<CancelRequest>,
) -> Result<Json<CancelConsent>> {
    let wallet = state.jupiter_trigger.wallet(&input.wallet, false).await?;
    let mut wallet = wallet.lock().await;
    if wallet.tokens.is_none() {
        return Err(need_auth());
    }
    if !wallet
        .orders
        .get(&input.order_id)
        .is_some_and(|order| order.can_cancel)
    {
        return Err(order_unavailable());
    }
    let now = crate::now();
    let plan = CancelConsent {
        wallet: input.wallet,
        order_id: input.order_id,
        expires_at: now + 90,
        nonce: nonce()?,
    };
    plan.message_at(now).map_err(invalid)?;
    wallet.cancellation = Some(plan.clone());
    Ok(Json(plan))
}

fn withdrawal_source(transaction: &str) -> Result<(String, bool)> {
    let decoded = trig_wallet_swap_policy::decode(transaction).map_err(invalid)?;
    let keys = decoded.message.static_account_keys();
    let token_instructions = decoded.message.instructions().iter().filter(|instruction| {
        keys.get(usize::from(instruction.program_id_index))
            .is_some_and(|program| program.to_string() == trig_wallet_swap_policy::TOKEN)
    });
    let mut transfers = token_instructions
        .clone()
        .filter(|instruction| matches!(instruction.data.first(), Some(3 | 12)));
    let (source, direct_close) = if let Some(transfer) = transfers.next() {
        if transfers.next().is_some() {
            return Err(bad_upstream());
        }
        (transfer, false)
    } else {
        let mut closes = token_instructions.filter(|instruction| instruction.data == [9]);
        let close = closes.next().ok_or_else(bad_upstream)?;
        if closes.next().is_some() {
            return Err(bad_upstream());
        }
        (close, true)
    };
    let source = source
        .accounts
        .first()
        .and_then(|index| keys.get(usize::from(*index)))
        .ok_or_else(bad_upstream)?;
    Ok((source.to_string(), direct_close))
}

async fn verify_source(
    rpc: &Rpc,
    address: &str,
    vault: &str,
    mint: &str,
    amount: &str,
    direct_close: bool,
) -> Result<()> {
    let value = rpc
        .call(
            "getAccountInfo",
            json!([address, {"encoding":"jsonParsed", "commitment":"confirmed"}]),
        )
        .await?;
    let account = &value["value"];
    let details = &account["data"]["parsed"]["info"];
    if account["owner"] != trig_wallet_swap_policy::TOKEN
        || details["mint"] != mint
        || details["owner"] != vault
        || details["state"] != "initialized"
        || details["tokenAmount"]["amount"]
            .as_str()
            .and_then(atomic)
            .zip(atomic(amount))
            .is_none_or(|(balance, amount)| balance < amount || direct_close && balance != amount)
    {
        return Err(invalid(
            "The withdrawal account does not match the reviewed Jupiter vault and balance.",
        ));
    }
    Ok(())
}

async fn refresh_order(
    service: &Service,
    key: Option<&str>,
    wallet: &mut WalletState,
    address: &str,
    order: &Order,
) -> Result<Order> {
    let mut offset = 0;
    for _ in 0..5 {
        let page = service
            .history(key, wallet, address, offset, Some(&order.input_mint))
            .await?;
        if let Some(fresh) = page
            .orders
            .into_iter()
            .find(|candidate| candidate.id == order.id)
        {
            if fresh.input_mint != order.input_mint
                || fresh.output_mint != order.output_mint
                || !fresh.can_cancel
            {
                return Err(order_unavailable());
            }
            return Ok(fresh);
        }
        if let Some(next) = page.next_offset {
            offset = next;
        } else {
            break;
        }
    }
    Err(order_unavailable())
}

async fn submitted_withdrawal_pending(
    rpc: &Rpc,
    review: &Review,
    signature: Option<&str>,
) -> Result<bool> {
    let Some(signature) = signature else {
        return Ok(false);
    };
    let last_valid_height = review.last_valid_block_height.ok_or_else(local_error)?;
    Ok(transaction_failure(rpc, signature, last_valid_height)
        .await?
        .is_none())
}

pub(crate) async fn cancel_prepare(
    State(state): State<AppState>,
    Json(input): Json<CancelProof>,
) -> Result<Json<Value>> {
    let key = api_key(&state);
    let service = &state.jupiter_trigger;
    let wallet = service.wallet(&input.wallet, false).await?;
    let mut wallet = wallet.lock().await;
    let consent = wallet
        .cancellation
        .as_ref()
        .filter(|review| review.order_id == input.order_id)
        .ok_or_else(|| invalid("Confirm cancellation for this exact order."))?;
    let message = consent.message_at(crate::now()).map_err(invalid)?;
    trigger::verify_message(&consent.wallet, message.as_ref(), &input.signature)
        .map_err(invalid)?;
    wallet.cancellation = None;
    let order = wallet
        .orders
        .get(&input.order_id)
        .filter(|order| order.can_cancel)
        .cloned()
        .ok_or_else(order_unavailable)?;
    let order = refresh_order(service, key, &mut wallet, &input.wallet, &order).await?;
    let vault = service
        .vault(key, &mut wallet, &input.wallet, false)
        .await?;
    if order
        .vault
        .as_ref()
        .is_some_and(|address| address != &vault)
    {
        return Err(bad_upstream());
    }
    let rpc = solana_rpc().await?;
    if let Some((review, submitted)) = service.withdrawal_for_order(&input.wallet, &order.id)? {
        if submitted_withdrawal_pending(&rpc, &review, submitted.as_deref()).await? {
            return Err(ApiError(StatusCode::CONFLICT,
                "A withdrawal was already submitted. Check Orders and Activity before trying again.".into()));
        }
    }
    let (decimals, _) = mint_pair_precision(&rpc, &order.input_mint, &order.output_mint).await?;
    let response = service
        .authenticated(
            key,
            &mut wallet,
            Method::POST,
            &format!("orders/price/cancel/{}", order.id),
            None,
        )
        .await?;
    if response["id"] != order.id {
        return Err(bad_upstream());
    }
    let plan_id = response["requestId"]
        .as_str()
        .filter(|id| identifier(id))
        .ok_or_else(bad_upstream)?;
    let transaction = response["transaction"].as_str().ok_or_else(bad_upstream)?;
    let (source, direct_close) = withdrawal_source(transaction)?;
    if service
        .order_token_account(&input.wallet, &order.id)?
        .is_some_and(|account| account != source)
    {
        return Err(invalid(
            "Jupiter returned a different token account from the original deposit.",
        ));
    }
    verify_source(
        &rpc,
        &source,
        &vault,
        &order.input_mint,
        &order.remaining_input_amount,
        direct_close,
    )
    .await?;
    let now = crate::now();
    let mut review = Review {
        plan_id: plan_id.into(),
        signing_plan: TransferPlan {
            wallet: input.wallet.clone(),
            vault,
            mint: order.input_mint,
            order_token_account: source,
            amount: order.remaining_input_amount,
            decimals,
            transaction: transaction.into(),
            expires_at: now + REVIEW_TTL,
            direction: TransferDirection::Withdrawal,
            fee_lamports: 0,
            rent_lamports: 0,
        },
        fee_lamports: "0".into(),
        rent_lamports: "0".into(),
        mint_decimals: decimals,
        order_expires_at: None,
        last_valid_block_height: response["lastValidBlockHeight"].as_u64().filter(|h| *h > 0),
    };
    build_review(&rpc, &mut review).await?;
    service.save_withdrawal(&input.wallet, &order.id, &review, None)?;
    Ok(Json(
        serde_json::to_value(review).map_err(|_| local_error())?,
    ))
}

pub(crate) async fn cancel_submit(
    State(state): State<AppState>,
    Json(input): Json<SubmitRequest>,
) -> Result<Json<Receipt>> {
    if !identifier(&input.plan_id) || !signature(&input.transaction_id) {
        return Err(invalid("Invalid Jupiter Trigger withdrawal."));
    }
    let key = api_key(&state);
    let service = &state.jupiter_trigger;
    let wallet = service.wallet(&input.wallet, false).await?;
    let mut wallet = wallet.lock().await;
    let (order, review, submitted) = service
        .withdrawal_for_plan(&input.wallet, &input.plan_id)?
        .ok_or_else(|| invalid("Review a fresh Jupiter Trigger withdrawal before signing."))?;
    trigger::validate_transfer_signed(
        &review.signing_plan,
        &input.signed,
        &input.transaction_id,
        crate::now(),
    )
    .map_err(invalid)?;
    if submitted
        .as_ref()
        .is_some_and(|previous| previous != &input.transaction_id)
    {
        return Err(invalid(
            "This withdrawal was already submitted. Check Orders and Activity.",
        ));
    }
    service.save_withdrawal(&input.wallet, &order, &review, Some(&input.transaction_id))?;
    let value = service
        .authenticated(
            key,
            &mut wallet,
            Method::POST,
            &format!("orders/price/confirm-cancel/{order}"),
            Some(&json!({"signedTransaction":input.signed, "cancelRequestId":input.plan_id})),
        )
        .await?;
    let receipt = receipt(&value, Some(&order), &input.transaction_id, true)?;
    service.forget_withdrawal(&input.wallet, &order)?;
    Ok(Json(receipt))
}

#[cfg(test)]
mod tests {
    use super::*;

    const WALLET: &str = "FVen3X669xLzsi6N2V91DoiyzHzg1uAgqiT8jZ9nS96Z";
    const OTHER: &str = "So11111111111111111111111111111111111111112";
    const ID: &str = "eaf80f62-45b6-4fec-86d7-1d1a76d6519e";

    fn fixture(state: &str) -> Value {
        json!({
            "id":ID, "orderType":"single", "orderState":state, "rawState":"ready_to_cancel",
            "userPubkey":WALLET, "privyWalletPubkey":OTHER,
            "inputMint":OTHER, "initialInputAmount":"1000000000",
            "remainingInputAmount":"1000000",
            "outputMint":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
            "triggerCondition":"above", "triggerPriceUsd":170.125, "expiresAt":1795700000000u64
        })
    }

    #[test]
    fn trigger_history_rejects_mismatched_wallets_and_impossible_amounts() {
        let mut value = fixture("open");
        assert!(read_order(&value, WALLET).unwrap().can_cancel);
        assert!(read_order(&value, OTHER).is_none());
        let orders = read_history(
            &json!({"orders":[value], "pagination":{"total":2}}),
            WALLET,
            0,
        )
        .unwrap();
        assert_eq!(orders.next_offset, Some(1));
        assert_eq!(
            orders.orders[0].trigger_price_usd.as_deref(),
            Some("170.125")
        );
        assert!(read_history(&json!({"orders":[value]}), OTHER, 0).is_err());
        value["remainingInputAmount"] = json!("1000000001");
        assert!(read_order(&value, WALLET).is_none());
    }

    #[test]
    fn trigger_open_expired_and_mid_cancel_orders_allow_funded_withdrawal() {
        for state in ["open", "expired", "pending_withdraw"] {
            assert!(read_order(&fixture(state), WALLET).unwrap().can_cancel);
        }
        for state in ["executing", "filled", "cancelled"] {
            assert!(!read_order(&fixture(state), WALLET).unwrap().can_cancel);
        }
        let mut drained = fixture("expired");
        drained["remainingInputAmount"] = json!("0");
        assert!(!read_order(&drained, WALLET).unwrap().can_cancel);
    }

    #[test]
    fn trigger_withdrawal_recovery_is_durable_and_wallet_scoped() {
        let path = std::env::temp_dir().join(format!(
            "trig-jupiter-withdrawal-{}.sqlite",
            nonce().unwrap()
        ));
        let result = std::panic::catch_unwind(|| {
            let mut review = Review {
                plan_id: "withdrawal-one".into(),
                signing_plan: TransferPlan {
                    wallet: WALLET.into(),
                    vault: OTHER.into(),
                    mint: OTHER.into(),
                    order_token_account: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
                    amount: "1000000".into(),
                    decimals: 9,
                    transaction: "test-only-wire".into(),
                    expires_at: 100,
                    direction: TransferDirection::Withdrawal,
                    fee_lamports: 5000,
                    rent_lamports: 0,
                },
                fee_lamports: "5000".into(),
                rent_lamports: "0".into(),
                mint_decimals: 9,
                order_expires_at: None,
                last_valid_block_height: Some(200),
            };
            Service::open(&path)
                .unwrap()
                .save_withdrawal(WALLET, ID, &review, Some("original-signature"))
                .unwrap();
            let store = Service::open(&path).unwrap();
            assert!(store
                .withdrawal_for_plan(OTHER, &review.plan_id)
                .unwrap()
                .is_none());
            let (id, previous, signed) = store
                .withdrawal_for_plan(WALLET, &review.plan_id)
                .unwrap()
                .unwrap();
            assert_eq!(id, ID);
            assert_eq!(previous.last_valid_block_height, Some(200));
            assert_eq!(signed.as_deref(), Some("original-signature"));
            let old = review.plan_id.clone();
            review.plan_id = "withdrawal-two".into();
            store.save_withdrawal(WALLET, ID, &review, None).unwrap();
            assert!(store.withdrawal_for_plan(WALLET, &old).unwrap().is_none());
            assert!(store
                .withdrawal_for_order(WALLET, ID)
                .unwrap()
                .unwrap()
                .1
                .is_none());
        });
        let _ = std::fs::remove_file(path);
        if let Err(panic) = result {
            std::panic::resume_unwind(panic);
        }
    }
}
