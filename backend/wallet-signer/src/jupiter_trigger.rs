use super::{solana_address, transfer, Family, Request, Result, SolanaKey};
use ed25519_dalek::Signer;
use solana_signature::Signature;
use trig_wallet_swap_policy::{
    encode, now,
    trigger::{AuthPlan, CancelConsent, TransferPlan},
};

fn key_for(wallet: &str, request: &Request) -> Result<SolanaKey> {
    let seed = transfer::private_key(request, Family::Solana)?;
    let seed: &[u8; 32] = seed
        .as_slice()
        .try_into()
        .map_err(|_| "Invalid Solana wallet.")?;
    let key = SolanaKey::from_bytes(seed);
    if solana_address(&key) != wallet {
        return Err("The selected wallet does not match this Jupiter Trigger action.");
    }
    Ok(key)
}

fn sign_message(wallet: &str, message: &str, request: &Request) -> Result<transfer::Signed> {
    let signature = Signature::from(
        key_for(wallet, request)?
            .sign(message.as_bytes())
            .to_bytes(),
    )
    .to_string();
    Ok(transfer::Signed {
        signed: signature.clone(),
        transaction_id: signature,
    })
}

pub(super) fn sign_auth(value: &serde_json::Value, request: &Request) -> Result<transfer::Signed> {
    let plan: AuthPlan =
        serde_json::from_value(value.clone()).map_err(|_| "Invalid Jupiter login review.")?;
    sign_message(&plan.wallet, plan.message_at(now())?, request)
}

pub(super) fn sign_cancel(
    value: &serde_json::Value,
    request: &Request,
) -> Result<transfer::Signed> {
    let plan: CancelConsent = serde_json::from_value(value.clone())
        .map_err(|_| "Invalid Jupiter cancellation review.")?;
    sign_message(&plan.wallet, &plan.message_at(now())?, request)
}

pub(super) fn sign_transfer(
    value: &serde_json::Value,
    request: &Request,
) -> Result<transfer::Signed> {
    let plan: TransferPlan = serde_json::from_value(value.clone())
        .map_err(|_| "Invalid Jupiter Trigger transfer review.")?;
    let mut reviewed = plan.review_at(now())?;
    let key = key_for(&plan.wallet, request)?;
    let message = reviewed.transaction.message.serialize();
    let signature = Signature::from(key.sign(&message).to_bytes());
    reviewed.transaction.signatures[reviewed.signer_index] = signature;
    Ok(transfer::Signed {
        signed: encode(&reviewed.transaction)?,
        transaction_id: signature.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use solana_message::{
        compiled_instruction::CompiledInstruction, legacy::Message, Address, MessageHeader,
        VersionedMessage,
    };
    use solana_system_interface::instruction::SystemInstruction;
    use std::str::FromStr;
    use trig_wallet_swap_policy::{
        decode,
        trigger::{validate_transfer_signed, verify_message, TransferDirection},
        VersionedTransaction, SOL, SYSTEM, TOKEN,
    };

    const USDC: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    const ORDER_ID: &str = "01a21801-663f-7787-821e-772ddaebf927";
    const RENT: u64 = 2_039_280;

    fn test_request(key: u8) -> Request {
        Request {
            operation: String::new(),
            family: Some(Family::Solana),
            secret: Some(hex::encode([key; 32])),
            passphrase: None,
            account_index: None,
            transfer: None,
            trade: None,
        }
    }

    fn address(value: &str) -> Address {
        Address::from_str(value).unwrap()
    }

    fn seeded_deposit(wallet: &SolanaKey, vault: &SolanaKey) -> TransferPlan {
        let wallet = address(&solana_address(wallet));
        let vault = address(&solana_address(vault));
        let mint = address(SOL);
        let token = address(TOKEN);
        let order = Address::create_with_seed(&vault, "trigger-order-fixture", &token).unwrap();
        let setup = SystemInstruction::CreateAccountWithSeed {
            base: vault,
            seed: "trigger-order-fixture".to_owned(),
            lamports: RENT,
            space: 165,
            owner: token,
        };
        let transfer = SystemInstruction::Transfer {
            lamports: 200_000_000,
        };
        let instructions = vec![
            CompiledInstruction {
                program_id_index: 5,
                accounts: vec![0, 2, 1],
                data: bincode::serialize(&setup).unwrap(),
            },
            CompiledInstruction {
                program_id_index: 4,
                accounts: vec![2, 3],
                data: [vec![18], vault.as_ref().to_vec()].concat(),
            },
            CompiledInstruction {
                program_id_index: 5,
                accounts: vec![0, 2],
                data: bincode::serialize(&transfer).unwrap(),
            },
            CompiledInstruction {
                program_id_index: 4,
                accounts: vec![2],
                data: vec![17],
            },
        ];
        let transaction = VersionedTransaction {
            signatures: vec![Signature::default(); 2],
            message: VersionedMessage::Legacy(Message {
                header: MessageHeader {
                    num_required_signatures: 2,
                    num_readonly_signed_accounts: 1,
                    num_readonly_unsigned_accounts: 3,
                },
                account_keys: vec![wallet, vault, order, mint, token, address(SYSTEM)],
                recent_blockhash: Default::default(),
                instructions,
            }),
        };
        TransferPlan {
            wallet: wallet.to_string(),
            vault: vault.to_string(),
            order_token_account: order.to_string(),
            mint: SOL.to_owned(),
            amount: "200000000".to_owned(),
            decimals: 9,
            transaction: encode(&transaction).unwrap(),
            expires_at: now() + 30,
            direction: TransferDirection::Deposit,
            fee_lamports: 10_000,
            rent_lamports: RENT,
        }
    }

    #[test]
    fn trigger_login_and_cancel_use_distinct_wallet_bound_messages() {
        let wallet = solana_address(&SolanaKey::from_bytes(&[7; 32]));
        let expiry = now() + 120;
        let date = chrono::DateTime::from_timestamp(expiry as i64, 0).unwrap();
        let challenge = format!("Sign this message to authenticate with Jupiter that you are the owner of {wallet}.\n\nThis challenge expires at {} with the nonce of {ORDER_ID}.",
            date.to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
        let mut plan = AuthPlan {
            wallet: wallet.clone(),
            challenge,
            expires_at: expiry,
        };
        let request = test_request(7);
        let signed = sign_auth(&serde_json::to_value(&plan).unwrap(), &request).unwrap();
        verify_message(&wallet, plan.challenge.as_bytes(), &signed.signed).unwrap();
        assert!(sign_auth(&serde_json::to_value(&plan).unwrap(), &test_request(8)).is_err());
        assert!(plan.message_at(expiry).is_err());
        plan.challenge.push_str("\nGrant arbitrary authority");
        assert!(sign_auth(&serde_json::to_value(&plan).unwrap(), &request).is_err());

        let consent = CancelConsent {
            wallet: wallet.clone(),
            order_id: ORDER_ID.into(),
            expires_at: now() + 60,
            nonce: "ab12de3445ab9bc0".into(),
        };
        let signed_cancel =
            sign_cancel(&serde_json::to_value(&consent).unwrap(), &request).unwrap();
        verify_message(
            &wallet,
            consent.message_at(now()).unwrap().as_bytes(),
            &signed_cancel.signed,
        )
        .unwrap();
        assert!(verify_message(
            &wallet,
            consent.message_at(now()).unwrap().as_bytes(),
            &signed.signed
        )
        .is_err());
    }

    #[test]
    fn trigger_native_deposit_accepts_exact_seeded_vault_and_preserves_cosigner() {
        let wallet = SolanaKey::from_bytes(&[7; 32]);
        let vault = SolanaKey::from_bytes(&[8; 32]);
        let mut plan = seeded_deposit(&wallet, &vault);
        let mut transaction = decode(&plan.transaction).unwrap();
        transaction.signatures[1] =
            Signature::from(vault.sign(&transaction.message.serialize()).to_bytes());
        plan.transaction = encode(&transaction).unwrap();
        let request = test_request(7);
        let result = sign_transfer(&serde_json::to_value(&plan).unwrap(), &request).unwrap();
        validate_transfer_signed(&plan, &result.signed, &result.transaction_id, now()).unwrap();
        assert_eq!(
            decode(&result.signed).unwrap().signatures[1],
            transaction.signatures[1]
        );

        let mut tampered = plan.clone();
        tampered.amount = "200000001".to_owned();
        assert!(sign_transfer(&serde_json::to_value(&tampered).unwrap(), &request).is_err());
        tampered = plan.clone();
        tampered.rent_lamports = RENT - 1;
        assert!(sign_transfer(&serde_json::to_value(&tampered).unwrap(), &request).is_err());
        tampered = plan.clone();
        let VersionedMessage::Legacy(ref mut message) = transaction.message else {
            panic!()
        };
        message.instructions[1].data =
            [vec![18], wallet.verifying_key().to_bytes().to_vec()].concat();
        transaction.signatures[1] = Signature::default();
        tampered.transaction = encode(&transaction).unwrap();
        assert!(sign_transfer(&serde_json::to_value(&tampered).unwrap(), &request).is_err());
    }

    #[test]
    fn trigger_withdrawal_only_pays_the_funding_wallet_and_reviewed_amount() {
        let wallet = solana_address(&SolanaKey::from_bytes(&[7; 32]));
        let vault = solana_address(&SolanaKey::from_bytes(&[8; 32]));
        let order =
            Address::create_with_seed(&address(&vault), "withdraw-fixture", &address(TOKEN))
                .unwrap();
        let wallet_token = trig_wallet_transfers::spl_recipient_address(&wallet, USDC).unwrap();
        let mut transaction = VersionedTransaction {
            signatures: vec![Signature::default(); 2],
            message: VersionedMessage::Legacy(Message {
                header: MessageHeader {
                    num_required_signatures: 2,
                    num_readonly_signed_accounts: 1,
                    num_readonly_unsigned_accounts: 2,
                },
                account_keys: vec![
                    address(&wallet),
                    address(&vault),
                    order,
                    address(&wallet_token),
                    address(USDC),
                    address(TOKEN),
                ],
                recent_blockhash: Default::default(),
                instructions: vec![
                    CompiledInstruction {
                        program_id_index: 5,
                        accounts: vec![2, 4, 3, 1],
                        data: [vec![12], 20_000_000u64.to_le_bytes().to_vec(), vec![6]].concat(),
                    },
                    CompiledInstruction {
                        program_id_index: 5,
                        accounts: vec![2, 0, 1],
                        data: vec![9],
                    },
                ],
            }),
        };
        let mut plan = TransferPlan {
            wallet,
            vault,
            mint: USDC.into(),
            order_token_account: order.to_string(),
            amount: "20000000".into(),
            decimals: 6,
            transaction: encode(&transaction).unwrap(),
            expires_at: now() + 30,
            direction: TransferDirection::Withdrawal,
            fee_lamports: 10_000,
            rent_lamports: 0,
        };
        let request = test_request(7);
        let result = sign_transfer(&serde_json::to_value(&plan).unwrap(), &request).unwrap();
        validate_transfer_signed(&plan, &result.signed, &result.transaction_id, now()).unwrap();
        let VersionedMessage::Legacy(ref mut message) = transaction.message else {
            panic!()
        };
        message.instructions[1].accounts[1] = 1;
        plan.transaction = encode(&transaction).unwrap();
        assert!(sign_transfer(&serde_json::to_value(&plan).unwrap(), &request).is_err());
    }
}
