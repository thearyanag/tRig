use super::{evm_address, EvmKey, Family, Request, Result};
use crate::transfer::{hex_integer, private_key, reviewed_atomic, sign_legacy_evm, Signed};
use num_bigint::BigUint;
use serde::Deserialize;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};
use trig_wallet_transfers::{
    evm_address as address_bytes,
    relay::{approval_data, deposit_data, depository, NATIVE_EVM_TOKEN},
};

const INVALID: &str = "The reviewed Relay transaction could not be verified.";

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Action {
    Approve,
    Deposit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuoteInput {
    chain: String,
    address: String,
}

#[derive(Deserialize)]
struct Context {
    sender: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuoteRequest {
    input: QuoteInput,
    context: Context,
    amount: String,
    order_type: String,
    provider: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Plan {
    request: QuoteRequest,
    action: Action,
    chain_id: u64,
    from: String,
    token: String,
    depository: String,
    order_id: String,
    nonce: String,
    gas_price: String,
    gas_limit: String,
    fee_atomic: String,
    amount_atomic: String,
    token_decimals: u8,
    fee: String,
    fee_decimals: u8,
    expires_at: u64,
}

pub(super) fn sign(plan: &Value, request: &Request) -> Result<Signed> {
    let plan: Plan = serde_json::from_value(plan.clone()).map_err(|_| INVALID)?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| INVALID)?
        .as_secs();
    let secret = private_key(request, Family::Evm)?;
    let key = EvmKey::from_slice(secret.as_slice()).map_err(|_| "Invalid wallet.")?;
    let fields = validate(&plan, &key, now)?;
    sign_legacy_evm(plan.chain_id, fields, &key)
}

fn validate(plan: &Plan, key: &EvmKey, now: u64) -> Result<[Vec<u8>; 6]> {
    if plan.expires_at <= now
        || plan.expires_at > now + 45
        || plan.request.input.chain != format!("eip155:{}", plan.chain_id)
        || !plan.request.input.address.eq_ignore_ascii_case(&plan.token)
        || !plan.request.context.sender.eq_ignore_ascii_case(&plan.from)
        || !evm_address(key).eq_ignore_ascii_case(&plan.from)
        || plan.request.order_type != "market"
        || plan
            .request
            .provider
            .as_deref()
            .is_some_and(|provider| provider != "relay")
        || !depository(plan.chain_id)
            .is_some_and(|address| address.eq_ignore_ascii_case(&plan.depository))
        || plan.token_decimals > 38
        || plan.fee_decimals > 38
    {
        return Err(INVALID);
    }

    let amount = reviewed_atomic(&plan.request.amount, plan.token_decimals)?;
    if amount.bits() == 0 || amount.to_string() != plan.amount_atomic {
        return Err(INVALID);
    }
    let amount = amount.to_bytes_be();
    let mut amount_word = [0u8; 32];
    amount_word[32 - amount.len()..].copy_from_slice(&amount);
    let spender = address_bytes(&plan.depository)?;
    let payer = address_bytes(&plan.from)?;
    let token = if plan.token.eq_ignore_ascii_case(NATIVE_EVM_TOKEN) {
        if plan.token_decimals != plan.fee_decimals {
            return Err(INVALID);
        }
        None
    } else {
        Some(address_bytes(&plan.token)?)
    };
    let order = hex::decode(plan.order_id.strip_prefix("0x").ok_or(INVALID)?)
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .filter(|bytes| *bytes != [0; 32])
        .ok_or(INVALID)?;
    let gas_price = hex_integer(&plan.gas_price)?;
    let gas_limit = hex_integer(&plan.gas_limit)?;
    let limit = BigUint::from_bytes_be(&gas_limit);
    let fee = BigUint::from_bytes_be(&gas_price) * &limit;
    if limit < BigUint::from(21_000u32)
        || limit > BigUint::from(1_000_000u32)
        || fee.bits() == 0
        || fee.to_string() != plan.fee_atomic
        || fee != reviewed_atomic(&plan.fee, plan.fee_decimals)?
    {
        return Err(INVALID);
    }

    let (to, value, data) = match plan.action {
        Action::Approve => (
            token.ok_or(INVALID)?,
            Vec::new(),
            approval_data(&spender, &amount_word),
        ),
        Action::Deposit => (
            spender,
            if token.is_none() { amount } else { Vec::new() },
            deposit_data(&payer, token.as_ref(), &amount_word, &order),
        ),
    };
    Ok([
        hex_integer(&plan.nonce)?,
        gas_price,
        gas_limit,
        to.to_vec(),
        value,
        data,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn signs_only_the_exact_allowance_or_reviewed_deposit() {
        let key = EvmKey::from_slice(&[0x46; 32]).unwrap();
        let payer = evm_address(&key);
        let contract = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913";
        let spender = depository(8453).unwrap();
        let mut reviewed = json!({
            "action":"approve","chainId":8453,"from":payer,"token":contract,
            "depository":spender,"orderId":format!("0x{}", "01".repeat(32)),
            "nonce":"2","gasPrice":"1","gasLimit":"10000","feeAtomic":"65536",
            "fee":"0.000000000000065536","feeDecimals":18,
            "amountAtomic":"1250000","tokenDecimals":6,"expiresAt":100,
            "request":{"input":{"chain":"eip155:8453","address":contract},"provider":"relay",
                "context":{"sender":payer},"amount":"1.25","orderType":"market"},
        });
        let decode = |value: &Value| serde_json::from_value::<Plan>(value.clone()).unwrap();
        let fields = validate(&decode(&reviewed), &key, 90).unwrap();
        assert_eq!(fields[3], address_bytes(contract).unwrap());
        assert_eq!(fields[4], Vec::<u8>::new());
        assert_eq!(&fields[5][..4], &[0x09, 0x5e, 0xa7, 0xb3]);
        assert_eq!(&fields[5][16..36], &address_bytes(spender).unwrap());
        assert_eq!(
            BigUint::from_bytes_be(&fields[5][36..]),
            BigUint::from(1_250_000u64)
        );
        let signed = sign_legacy_evm(8453, fields, &key).unwrap();
        assert!(signed.transaction_id.starts_with("0x"));

        reviewed["action"] = json!("deposit");
        let fields = validate(&decode(&reviewed), &key, 90).unwrap();
        assert_eq!(fields[3], address_bytes(spender).unwrap());
        assert_eq!(&fields[5][..4], &[0xe8, 0x01, 0x79, 0x52]);
        assert_eq!(&fields[5][fields[5].len() - 32..], &[1u8; 32]);
        assert!(validate(&decode(&reviewed), &key, 100).is_err());

        reviewed["amountAtomic"] = json!("1250001");
        assert!(validate(&decode(&reviewed), &key, 90).is_err());
        reviewed["amountAtomic"] = json!("1250000");
        reviewed["depository"] = json!("0x1111111111111111111111111111111111111111");
        assert!(validate(&decode(&reviewed), &key, 90).is_err());
    }
}
