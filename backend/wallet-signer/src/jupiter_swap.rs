use super::{solana_address, transfer, Family, Request, Result, SolanaKey};
use ed25519_dalek::Signer;
use serde::Deserialize;
use solana_signature::Signature;
use trig_wallet_swap_policy as policy;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Plan {
    transaction: String,
    terms: policy::Terms,
}

pub(super) fn sign(value: &serde_json::Value, request: &Request) -> Result<transfer::Signed> {
    let plan: Plan =
        serde_json::from_value(value.clone()).map_err(|_| "A reviewed swap is required.")?;
    let mut transaction = policy::decode(&plan.transaction)?;
    policy::review(&transaction, &plan.terms)?;
    let seed = transfer::private_key(request, Family::Solana)?;
    let seed: &[u8; 32] = seed
        .as_slice()
        .try_into()
        .map_err(|_| "Invalid Solana wallet.")?;
    let key = SolanaKey::from_bytes(seed);
    if solana_address(&key) != plan.terms.wallet {
        return Err("The selected wallet does not match the trade.");
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
    use solana_message::{
        compiled_instruction::CompiledInstruction, legacy::Message, Address, MessageHeader,
        VersionedMessage,
    };
    use std::str::FromStr;

    const USDC: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    const JUPITER: &str = "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4";

    #[test]
    fn signs_only_the_reviewed_jupiter_message_and_account() {
        let wallet = solana_address(&SolanaKey::from_bytes(&[7; 32]));
        let keys = [wallet.as_str(), policy::SOL, USDC, JUPITER]
            .map(|key| Address::from_str(key).unwrap())
            .to_vec();
        let mut instruction = vec![187, 100, 250, 204, 49, 196, 175, 20];
        instruction.extend_from_slice(&1_000_000_u64.to_le_bytes());
        instruction.extend_from_slice(&1_001_u64.to_le_bytes());
        instruction.extend_from_slice(&50_u16.to_le_bytes());
        instruction.extend_from_slice(&[0; 4]);
        let mut plan = policy::VersionedTransaction {
            signatures: vec![Signature::default()],
            message: VersionedMessage::Legacy(Message {
                header: MessageHeader {
                    num_required_signatures: 1,
                    num_readonly_signed_accounts: 0,
                    num_readonly_unsigned_accounts: 3,
                },
                account_keys: keys,
                recent_blockhash: Default::default(),
                instructions: vec![CompiledInstruction {
                    program_id_index: 3,
                    accounts: vec![0, 0, 0, 1, 2],
                    data: instruction,
                }],
            }),
        };
        let request = Request {
            operation: "signJupiterSwap".into(),
            family: Some(Family::Solana),
            secret: Some(hex::encode([7; 32])),
            passphrase: None,
            account_index: None,
            transfer: None,
            trade: None,
        };
        let mut payload = json!({
            "terms": {
                "wallet": wallet, "inputMint": policy::SOL, "outputMint": USDC,
                "inAmount":"1000000", "minimumOut":"995", "slippageBps":50,
                "maxNetworkCost":"5000", "expiresAt":policy::now()+30
            },
            "transaction": policy::encode(&plan).unwrap()
        });
        let result = sign(&payload, &request).unwrap();
        let signed = policy::decode(&result.signed).unwrap();
        policy::validate_signed(&plan, &signed, &result.transaction_id).unwrap();
        let VersionedMessage::Legacy(ref mut message) = plan.message else {
            unreachable!()
        };
        message.instructions[0].data[8] ^= 1;
        assert!(policy::validate_signed(&plan, &signed, &result.transaction_id).is_err());
        payload["transaction"] = json!(policy::encode(&plan).unwrap());
        assert!(sign(&payload, &request).is_err());
    }
}
