use super::{solana_address, transfer, Family, Request, Result, SolanaKey};
use ed25519_dalek::Signer;
use serde::Deserialize;
use solana_signature::Signature;
use trig_wallet_swap_policy::{self as policy, relay_solana};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Plan {
    transaction: String,
    terms: relay_solana::Terms,
}

pub(super) fn sign(value: &serde_json::Value, request: &Request) -> Result<transfer::Signed> {
    let plan: Plan = serde_json::from_value(value.clone())
        .map_err(|_| "A reviewed Relay deposit is required.")?;
    let mut transaction = policy::decode(&plan.transaction)?;
    relay_solana::review_now(&transaction, &plan.terms)?;
    let seed = transfer::private_key(request, Family::Solana)?;
    let seed: &[u8; 32] = seed
        .as_slice()
        .try_into()
        .map_err(|_| "Invalid Solana wallet.")?;
    let key = SolanaKey::from_bytes(seed);
    if solana_address(&key) != plan.terms.wallet {
        return Err("The selected wallet does not match the Relay deposit.");
    }
    let signature = Signature::from(key.sign(&transaction.message.serialize()).to_bytes());
    transaction.signatures[0] = signature;
    Ok(transfer::Signed {
        signed: policy::encode(&transaction)?,
        transaction_id: signature.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn signs_the_canonical_deposit_with_the_reviewed_wallet() {
        let key = SolanaKey::from_bytes(&[11; 32]);
        let terms = relay_solana::Terms {
            wallet: solana_address(&key),
            input_mint: policy::SYSTEM.into(),
            input_atomic: "2000000".into(),
            order_id: [7; 32],
            expires_at: policy::now() + 30,
        };
        let hash = solana_hash::Hash::new_from_array([9; 32]).to_string();
        let planned = relay_solana::transaction(&terms, &hash).unwrap();
        let plan = json!({"transaction":policy::encode(&planned).unwrap(), "terms":terms});
        let request = serde_json::from_value(json!({
            "operation":"signRelaySolana", "secret":hex::encode(key.to_bytes()),
            "family":"solana",
        }))
        .unwrap();
        let signed = sign(&plan, &request).unwrap();
        let transaction = policy::decode(&signed.signed).unwrap();
        assert!(policy::validate_signed(&planned, &transaction, &signed.transaction_id).is_ok());

        let mut wrong = plan;
        wrong["terms"]["wallet"] = json!(policy::SOL);
        assert!(sign(&wrong, &request).is_err());
    }
}
