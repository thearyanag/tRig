use super::{
    evm_address, flash_intent as intent, solana_address, transfer, EvmKey, Family, Request, Result,
    SolanaKey,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::Signer;
use num_bigint::BigUint;
use serde::Deserialize;
use sha3::{Digest, Keccak256};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct CancelPlan {
    order_id: String,
    funder: String,
    family: Family,
}

fn canonical_order_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')
            }
        })
}

fn cancel_message(id: &str) -> String {
    format!("Definitive Flash v1 — Cancel Order\nOrder: {id}")
}

fn personal_signing_digest(message: &str) -> Keccak256 {
    let mut digest = Keccak256::new();
    digest.update(format!("\x19Ethereum Signed Message:\n{}", message.len()).as_bytes());
    digest.update(message.as_bytes());
    digest
}

fn sign_cancel_evm(plan: &CancelPlan, key: &EvmKey) -> Result<String> {
    if !evm_address(key).eq_ignore_ascii_case(&plan.funder) {
        return Err("The selected wallet did not fund this Flash order.");
    }
    let message = cancel_message(&plan.order_id);
    let (signature, recovery_id) = key
        .sign_digest_recoverable(personal_signing_digest(&message))
        .map_err(|_| "Couldn’t sign this Flash cancellation.")?;
    let mut bytes = signature.to_bytes().to_vec();
    bytes.push(recovery_id.to_byte() + 27);
    Ok(format!("0x{}", hex::encode(bytes)))
}

fn sign_cancel_solana(plan: &CancelPlan, key: &SolanaKey) -> Result<String> {
    if solana_address(key) != plan.funder {
        return Err("The selected wallet did not fund this Flash order.");
    }
    let message = cancel_message(&plan.order_id);
    Ok(bs58::encode(key.sign(message.as_bytes()).to_bytes()).into_string())
}

pub(super) fn sign_cancel(
    trade: &serde_json::Value,
    request: &Request,
) -> Result<transfer::Signed> {
    let plan: CancelPlan =
        serde_json::from_value(trade.clone()).map_err(|_| "Invalid Flash cancellation.")?;
    if !canonical_order_id(&plan.order_id) {
        return Err("Invalid Flash order ID.");
    }
    let key = transfer::private_key(request, plan.family)?;
    let signed = match plan.family {
        Family::Evm => {
            let key = EvmKey::from_slice(&key).map_err(|_| "Invalid EVM wallet.")?;
            sign_cancel_evm(&plan, &key)?
        }
        Family::Solana => {
            let seed =
                <&[u8; 32]>::try_from(key.as_slice()).map_err(|_| "Invalid Solana wallet.")?;
            sign_cancel_solana(&plan, &SolanaKey::from_bytes(seed))?
        }
    };
    Ok(transfer::Signed {
        signed,
        transaction_id: plan.order_id.clone(),
    })
}

fn word(bytes: &[u8]) -> Result<[u8; 32]> {
    let offset = 32usize
        .checked_sub(bytes.len())
        .ok_or("Invalid Flash authorization size.")?;
    let mut result = [0; 32];
    result[offset..].copy_from_slice(bytes);
    Ok(result)
}

fn address_word(value: &str) -> Result<[u8; 32]> {
    let address = value.strip_prefix("0x").ok_or("Invalid Flash address.")?;
    word(&hex::decode(address).map_err(|_| "Invalid Flash address.")?)
}

fn integer_word(value: &str) -> Result<[u8; 32]> {
    let integer = BigUint::parse_bytes(value.as_bytes(), 10).ok_or("Invalid Flash amount.")?;
    word(&integer.to_bytes_be())
}

fn order_digest(plan: &intent::Plan, message: &intent::Message) -> Result<Keccak256> {
    let mut domain = Keccak256::new();
    domain.update(Keccak256::digest(intent::DOMAIN_TYPE.as_bytes()));
    domain.update(Keccak256::digest(b"DefinitiveFlashAllowance"));
    domain.update(Keccak256::digest(b"1"));
    domain.update(word(&plan.chain_id.to_be_bytes())?);
    domain.update(address_word(intent::SETTLEMENT)?);

    let mut order = Keccak256::new();
    order.update(Keccak256::digest(intent::ORDER_TYPE.as_bytes()));
    for address in [
        &message.swapper,
        &message.vault,
        &message.recipient,
        &message.from_token,
        &message.to_token,
    ] {
        order.update(address_word(address)?);
    }
    for value in [&message.from_amount, &message.salt, &message.deadline] {
        order.update(integer_word(value)?);
    }
    let mut digest = Keccak256::new();
    digest.update([0x19, 0x01]);
    digest.update(domain.finalize());
    digest.update(order.finalize());
    Ok(digest)
}

pub(super) fn sign_order(trade: &serde_json::Value, request: &Request) -> Result<transfer::Signed> {
    let plan: intent::OrderPlan =
        serde_json::from_value(trade.clone()).map_err(|_| "Invalid Flash order review.")?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Wallet clock unavailable.")?
        .as_secs();
    let plan = match plan {
        intent::OrderPlan::Evm(plan) => plan,
        intent::OrderPlan::Solana(plan) => {
            plan.validate(now)?;
            let key = transfer::private_key(request, Family::Solana)?;
            let seed =
                <&[u8; 32]>::try_from(key.as_slice()).map_err(|_| "Invalid Solana wallet.")?;
            let key = SolanaKey::from_bytes(seed);
            if solana_address(&key) != plan.funder {
                return Err("The selected wallet does not match the Flash order.");
            }
            let signed =
                bs58::encode(key.sign(plan.order_message.as_bytes()).to_bytes()).into_string();
            return Ok(transfer::Signed {
                signed,
                transaction_id: plan.plan_id,
            });
        }
    };
    let message = plan.validate(now)?;
    let key = transfer::private_key(request, Family::Evm)?;
    let key = EvmKey::from_slice(&key).map_err(|_| "Invalid EVM wallet.")?;
    if !evm_address(&key).eq_ignore_ascii_case(&plan.funder) {
        return Err("The selected wallet does not match the Flash order.");
    }
    let (signature, recovery) = key
        .sign_digest_recoverable(order_digest(&plan, &message)?)
        .map_err(|_| "Couldn’t sign this Flash order.")?;
    let mut bytes = signature.to_bytes().to_vec();
    bytes.push(recovery.to_byte() + 27);
    Ok(transfer::Signed {
        signed: format!("0x{}", hex::encode(bytes)),
        transaction_id: plan.plan_id,
    })
}

pub(super) fn sign_approval(
    trade: &serde_json::Value,
    request: &Request,
) -> Result<transfer::Signed> {
    let plan: intent::ApprovalPlan =
        serde_json::from_value(trade.clone()).map_err(|_| "Invalid Flash approval review.")?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Wallet clock unavailable.")?
        .as_secs();
    plan.validate(now)?;
    let raw_key = transfer::private_key(request, Family::Evm)?;
    let key = EvmKey::from_slice(&raw_key).map_err(|_| "Invalid EVM wallet.")?;
    if !evm_address(&key).eq_ignore_ascii_case(&plan.funder) {
        return Err("The selected wallet does not match this approval.");
    }
    let nonce = transfer::hex_integer(&plan.nonce)?;
    let gas_price = transfer::hex_integer(&plan.gas_price)?;
    let gas_limit = transfer::hex_integer(&plan.gas_limit)?;
    if BigUint::from_bytes_be(&gas_limit) > BigUint::from(300_000u64)
        || (BigUint::from_bytes_be(&gas_price) * BigUint::from_bytes_be(&gas_limit)).to_string()
            != plan.fee
    {
        return Err("The reviewed Flash approval fee has changed.");
    }
    let token = hex::decode(&plan.token[2..]).map_err(|_| "Invalid Flash approval token.")?;
    let mut calldata = vec![0x09, 0x5e, 0xa7, 0xb3];
    calldata.extend_from_slice(&address_word(intent::SETTLEMENT)?);
    calldata.extend_from_slice(&integer_word(&plan.amount)?);
    transfer::sign_legacy_evm(
        plan.chain_id,
        [nonce, gas_price, gas_limit, token, Vec::new(), calldata],
        &key,
    )
}

pub(super) fn sign_solana_setup(
    trade: &serde_json::Value,
    request: &Request,
) -> Result<transfer::Signed> {
    let plan: intent::SolanaSetupPlan =
        serde_json::from_value(trade.clone()).map_err(|_| "Invalid Solana Flash setup review.")?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "Wallet clock unavailable.")?
        .as_secs();
    let message = plan.message(now)?;
    let key = transfer::private_key(request, Family::Solana)?;
    let seed = <&[u8; 32]>::try_from(key.as_slice()).map_err(|_| "Invalid Solana wallet.")?;
    let key = SolanaKey::from_bytes(seed);
    if solana_address(&key) != plan.setup.funder {
        return Err("The selected wallet does not match this Flash setup.");
    }
    let signature = key.sign(&message).to_bytes();
    let mut wire = vec![1];
    wire.extend(signature);
    wire.extend(message);
    Ok(transfer::Signed {
        signed: STANDARD.encode(wire),
        transaction_id: bs58::encode(signature).into_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};

    const ORDER: &str = "deadbeef-1234-abcd-9876-000000000001";

    #[test]
    fn flash_solana_setup_signs_the_locally_built_message_and_binds_funding_wallet() {
        let seed = [6; 32];
        let key = SolanaKey::from_bytes(&seed);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let mut plan = intent::SolanaSetupPlan {
            plan_id: ORDER.into(),
            setup: trig_wallet_transfers::flash::Setup {
                funder: solana_address(&key),
                input_mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
                output_mint: trig_wallet_transfers::flash::WRAPPED_SOL.into(),
                amount: "1000000".into(),
                decimals: 6,
                blockhash: solana_hash::Hash::new_from_array([1; 32]).to_string(),
                create_input: false,
                create_output: true,
                delegate: true,
                wrap: false,
            },
            expires_at: now + 30,
            last_valid_block_height: 999,
            fee_lamports: 5000,
            rent_lamports: 2039280,
        };
        let request: Request = serde_json::from_value(serde_json::json!({
            "operation": "signFlashSolanaSetup",
            "secret": bs58::encode(seed).into_string(),
            "family": "solana",
        }))
        .unwrap();
        let prepared = serde_json::to_value(&plan).unwrap();
        let signed = sign_solana_setup(&prepared, &request).unwrap();
        let wire = STANDARD.decode(&signed.signed).unwrap();
        assert_eq!(wire[0], 1);
        assert_eq!(&wire[65..], plan.message(now).unwrap());
        let signature = ed25519_dalek::Signature::from_slice(&wire[1..65]).unwrap();
        assert_eq!(
            signed.transaction_id,
            bs58::encode(signature.to_bytes()).into_string()
        );
        key.verifying_key()
            .verify_strict(&wire[65..], &signature)
            .unwrap();
        plan.setup.funder = trig_wallet_transfers::flash::DELEGATE.into();
        assert!(sign_solana_setup(&serde_json::to_value(&plan).unwrap(), &request).is_err());
    }

    #[test]
    fn flash_solana_authorization_binds_wallet_accounts_and_trading_group() {
        let token_program = trig_wallet_transfers::SPL_TOKEN_PROGRAM;
        let mut plan = intent::SolanaPlan {
            plan_id: ORDER.into(),
            funder: "FVen3X669xLzsi6N2V91DoiyzHzg1uAgqiT8jZ9nS96Z".into(),
            from_token: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
            to_token: "So11111111111111111111111111111111111111112".into(),
            from_amount: "1000000".into(),
            order_deadline: 1_810_000_000,
            expires_at: 1_809_999_060,
            order_message: "DFS|m=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v|t=1000000|h=R25S5dSmtup8DExgP6SfXy".into(),
            nonce: "133".into(),
            trading_group: "C9cmcgqgaD1P1wGjyHpc1SLsHCiD8VHJCKyGciPrGyDe".into(),
            input_program: token_program.into(),
            output_program: token_program.into(),
        };
        let now = 1_809_999_000;
        assert!(plan.validate(now).is_ok());
        plan.trading_group = plan.funder.clone();
        assert!(plan.validate(now).is_err());
    }

    #[test]
    fn flash_evm_authorization_matches_live_quote_and_viem_digest() {
        let funder = "0x000000000000000000000000000000000000dEaD";
        let from_token = "0x4200000000000000000000000000000000000006";
        let to_token = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
        let order_deadline = 1_795_783_358;
        let now = order_deadline - 86_400;
        let mut typed_data = serde_json::json!({
            "types": {
                "EIP712Domain": [
                    {"name":"name","type":"string"}, {"name":"version","type":"string"},
                    {"name":"chainId","type":"uint256"}, {"name":"verifyingContract","type":"address"}
                ],
                "FlashOrder": [
                    {"name":"swapper","type":"address"}, {"name":"vault","type":"address"},
                    {"name":"recipient","type":"address"}, {"name":"fromToken","type":"address"},
                    {"name":"toToken","type":"address"}, {"name":"fromAmount","type":"uint256"},
                    {"name":"salt","type":"uint256"}, {"name":"deadline","type":"uint256"}
                ]
            },
            "primaryType": "FlashOrder",
            "domain": {
                "name":"DefinitiveFlashAllowance","version":"1","chainId":"8453",
                "verifyingContract":intent::SETTLEMENT
            },
            "message": {
                "swapper":funder,"vault":"0x1074393effFCf1A15e306cD3931F48eDA9ABcd55","recipient":funder,
                "fromToken":from_token,"toToken":to_token,"fromAmount":"200000000000000000",
                "salt":"2170864418246688112684110381099107688079","deadline":order_deadline.to_string()
            }
        });
        let mut plan = intent::Plan {
            plan_id: ORDER.into(),
            chain_id: 8453,
            funder: funder.into(),
            from_token: from_token.into(),
            to_token: to_token.into(),
            from_amount: "200000000000000000".into(),
            order_deadline,
            expires_at: now + 60,
            typed_data: typed_data.to_string(),
        };
        let message = plan.validate(now).unwrap();
        let digest = order_digest(&plan, &message).unwrap().finalize();
        assert_eq!(
            hex::encode(digest),
            "b808954762dbdd71cc302c6873d8e79dab0335a20cec81a34f45591e3fae4c8e"
        );
        assert!(plan.validate(plan.expires_at).is_err());
        typed_data["message"]["recipient"] = serde_json::json!(to_token);
        plan.typed_data = typed_data.to_string();
        assert!(plan.validate(now).is_err());
    }

    #[test]
    fn flash_cancellation_evm_signs_the_canonical_eip191_message() {
        let key = EvmKey::from_slice(&[7; 32]).unwrap();
        let plan = CancelPlan {
            order_id: ORDER.into(),
            family: Family::Evm,
            funder: evm_address(&key),
        };
        let signature = sign_cancel_evm(&plan, &key).unwrap();
        let raw = hex::decode(signature.strip_prefix("0x").unwrap()).unwrap();
        let recovered = VerifyingKey::recover_from_digest(
            personal_signing_digest(&format!(
                "Definitive Flash v1 — Cancel Order\nOrder: {ORDER}"
            )),
            &Signature::from_slice(&raw[..64]).unwrap(),
            RecoveryId::try_from(raw[64] - 27).unwrap(),
        )
        .unwrap();
        assert_eq!(&recovered, key.verifying_key());
        assert!(sign_cancel_evm(
            &CancelPlan {
                funder: "other".into(),
                ..plan
            },
            &key
        )
        .is_err());
    }

    #[test]
    fn flash_cancellation_solana_signs_only_the_canonical_message() {
        let key = SolanaKey::from_bytes(&[8; 32]);
        let plan = CancelPlan {
            order_id: ORDER.into(),
            family: Family::Solana,
            funder: solana_address(&key),
        };
        let signature = sign_cancel_solana(&plan, &key).unwrap();
        let raw = bs58::decode(signature).into_vec().unwrap();
        let signature = ed25519_dalek::Signature::from_slice(&raw).unwrap();
        assert!(key
            .verifying_key()
            .verify_strict(cancel_message(ORDER).as_bytes(), &signature)
            .is_ok());
        assert!(key
            .verifying_key()
            .verify_strict(b"unrelated", &signature)
            .is_err());
        assert!(!canonical_order_id("invalid"));
    }
}
