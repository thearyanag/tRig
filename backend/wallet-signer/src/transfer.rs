use super::{evm_address, key_bytes, solana_address, EvmKey, Family, Request, Result, SolanaKey};
use base64::{engine::general_purpose::STANDARD, Engine};
use bip32::{DerivationPath, XPrv};
use bip39::{Language, Mnemonic};
use ed25519_dalek::Signer;
use ed25519_dalek_bip32::{DerivationPath as SolanaPath, ExtendedSigningKey};
use num_bigint::BigUint;
use rlp::RlpStream;
use serde::{Deserialize, Serialize};
use sha3::{Digest, Keccak256};
use solana_signature::Signature;
use solana_transaction::versioned::VersionedTransaction;
use trig_wallet_transfers::{
    erc20_transfer_data, evm_address as address_bytes, solana_message, SplTransfer,
};
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Plan {
    intent: Intent,
    amount_atomic: String,
    decimals: u8,
    fee: String,
    fee_decimals: u8,
    parameters: Parameters,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Intent {
    chain: String,
    from: String,
    to: String,
    amount: String,
    token_address: Option<String>,
}

#[derive(Deserialize)]
#[serde(
    tag = "family",
    rename_all = "lowercase",
    rename_all_fields = "camelCase"
)]
enum Parameters {
    Solana {
        blockhash: String,
        spl: Option<SplTransfer>,
    },
    Evm {
        chain_id: String,
        nonce: String,
        gas_price: String,
        gas_limit: String,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Signed {
    pub(super) signed: String,
    pub(super) transaction_id: String,
}

pub(super) fn private_key(request: &Request, family: Family) -> Result<Zeroizing<Vec<u8>>> {
    let secret = request.secret.as_deref().ok_or("The wallet is locked.")?;
    if let Some(imported) = request.family {
        if imported != family {
            return Err("The wallet cannot sign on this network.");
        }
        return key_bytes(family, secret);
    }
    let words = Zeroizing::new(secret.split_whitespace().collect::<Vec<_>>().join(" "));
    let phrase = Mnemonic::parse_in(Language::English, words.as_str())
        .map_err(|_| "Invalid wallet backup.")?;
    let seed = Zeroizing::new(phrase.to_seed(request.passphrase.as_deref().unwrap_or("")));
    let index = request.account_index.unwrap_or_default();
    if index >= (1 << 31) {
        return Err("Invalid wallet account.");
    }
    match family {
        Family::Solana => {
            let path: SolanaPath = format!("m/44'/501'/{index}'/0'")
                .parse()
                .map_err(|_| "Invalid account.")?;
            let key = ExtendedSigningKey::from_seed(seed.as_slice())
                .and_then(|key| key.derive(&path))
                .map_err(|_| "Couldn’t restore the wallet account.")?;
            Ok(Zeroizing::new(key.signing_key.to_bytes().to_vec()))
        }
        Family::Evm => {
            let path: DerivationPath = format!("m/44'/60'/0'/0/{index}")
                .parse()
                .map_err(|_| "Invalid account.")?;
            let key = XPrv::derive_from_path(seed.as_slice(), &path)
                .map_err(|_| "Couldn’t restore the wallet account.")?;
            Ok(Zeroizing::new(key.private_key().to_bytes().to_vec()))
        }
    }
}

pub(super) fn sign(plan: &Plan, request: &Request) -> Result<Signed> {
    if reviewed_atomic(&plan.intent.amount, plan.decimals)?.to_string() != plan.amount_atomic {
        return Err("The signed amount must match the reviewed amount.");
    }
    match &plan.parameters {
        Parameters::Solana { blockhash, spl } if plan.intent.chain == "solana" => {
            if plan.intent.token_address.is_some() != spl.is_some()
                || spl
                    .as_ref()
                    .is_some_and(|token| token.decimals != plan.decimals)
                || spl.is_none() && plan.decimals != 9
                || plan.fee_decimals != 9
            {
                return Err("The Solana token does not match the reviewed transfer.");
            }
            let key = private_key(request, Family::Solana)?;
            let seed = <&[u8; 32]>::try_from(key.as_slice()).map_err(|_| "Invalid wallet.")?;
            let key = SolanaKey::from_bytes(seed);
            if solana_address(&key) != plan.intent.from {
                return Err("The selected wallet does not match.");
            }
            sign_solana(plan, blockhash, spl.as_ref(), &key)
        }
        Parameters::Evm {
            chain_id,
            nonce,
            gas_price,
            gas_limit,
        } if plan.intent.chain.strip_prefix("eip155:") == Some(chain_id) => {
            if plan.intent.token_address.is_none() && plan.decimals != plan.fee_decimals {
                return Err("The native asset does not match the reviewed transfer.");
            }
            let key = private_key(request, Family::Evm)?;
            let key = EvmKey::from_slice(key.as_slice()).map_err(|_| "Invalid wallet.")?;
            if !evm_address(&key).eq_ignore_ascii_case(&plan.intent.from) {
                return Err("The selected wallet does not match.");
            }
            let chain = chain_id
                .parse::<u64>()
                .ok()
                .filter(|chain| *chain > 0)
                .ok_or("Invalid chain ID.")?;
            sign_evm(plan, chain, nonce, gas_price, gas_limit, &key)
        }
        _ => Err("The reviewed transfer does not match the selected network."),
    }
}

fn sign_solana(
    plan: &Plan,
    blockhash: &str,
    spl: Option<&SplTransfer>,
    key: &SolanaKey,
) -> Result<Signed> {
    let amount = plan
        .amount_atomic
        .parse::<u64>()
        .ok()
        .filter(|amount| *amount > 0)
        .ok_or("Invalid amount.")?;
    let message = solana_message(
        &plan.intent.from,
        &plan.intent.to,
        amount,
        blockhash,
        plan.intent.token_address.as_deref().zip(spl),
    )?;
    let signature = key.sign(&message.serialize()).to_bytes();
    let tx = VersionedTransaction {
        signatures: vec![Signature::from(signature)],
        message,
    };
    let data = bincode::serialize(&tx).map_err(|_| "Couldn’t encode the Solana transfer.")?;
    Ok(Signed {
        signed: STANDARD.encode(data),
        transaction_id: bs58::encode(signature).into_string(),
    })
}

pub(super) fn reviewed_atomic(value: &str, decimals: u8) -> Result<BigUint> {
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    let fraction = fraction.trim_end_matches('0');
    let decimals = usize::from(decimals);
    if whole.is_empty() && fraction.is_empty()
        || value.len() > 300
        || fraction.len() > decimals
        || !whole
            .bytes()
            .chain(fraction.bytes())
            .all(|byte| byte.is_ascii_digit())
    {
        return Err("Invalid reviewed amount or fee.");
    }
    let raw = format!("{whole}{fraction}{}", "0".repeat(decimals - fraction.len()));
    BigUint::parse_bytes(raw.as_bytes(), 10)
        .filter(|value| value.bits() <= 256)
        .ok_or("Invalid reviewed amount or fee.")
}

pub(super) fn hex_integer(value: &str) -> Result<Vec<u8>> {
    if value.is_empty() || value.len() > 64 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("Invalid network fee or transaction counter.");
    }
    let value = value.trim_start_matches('0');
    if value.len() % 2 == 1 {
        hex::decode(format!("0{value}"))
    } else {
        hex::decode(value)
    }
    .map_err(|_| "Invalid network fee or transaction counter.")
}

// Convert a decimal uint256 amount to its minimum-width big-endian representation.
fn decimal_integer(value: &str) -> Result<Vec<u8>> {
    if value.is_empty() || value.len() > 78 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err("Invalid amount.");
    }
    let amount = BigUint::parse_bytes(value.as_bytes(), 10).ok_or("Invalid amount.")?;
    if !(1..=256).contains(&amount.bits()) {
        return Err("Invalid amount.");
    }
    Ok(amount.to_bytes_be())
}

fn sign_evm(
    plan: &Plan,
    chain: u64,
    nonce: &str,
    gas_price: &str,
    gas_limit: &str,
    key: &EvmKey,
) -> Result<Signed> {
    let recipient = address_bytes(&plan.intent.to)?;
    if plan.intent.from.eq_ignore_ascii_case(&plan.intent.to) {
        return Err("Choose a valid recipient account.");
    }
    let amount = decimal_integer(&plan.amount_atomic)?;
    let (destination, value, data) = match plan.intent.token_address.as_deref() {
        Some(contract) => (
            address_bytes(contract)?,
            Vec::new(),
            erc20_transfer_data(&recipient, &amount)?.to_vec(),
        ),
        None => (recipient, amount, Vec::new()),
    };
    let gas_price = hex_integer(gas_price)?;
    let gas_limit = hex_integer(gas_limit)?;
    // EVM chain fee precision is separate from the reviewed token precision.
    let fee = BigUint::from_bytes_be(&gas_price) * BigUint::from_bytes_be(&gas_limit);
    if fee != reviewed_atomic(&plan.fee, plan.fee_decimals)? {
        return Err("The signed network fee must match the reviewed fee.");
    }
    let fields = [
        hex_integer(nonce)?,
        gas_price,
        gas_limit,
        destination.to_vec(),
        value,
        data,
    ];
    sign_legacy_evm(chain, fields, key)
}

pub(super) fn sign_legacy_evm(chain: u64, fields: [Vec<u8>; 6], key: &EvmKey) -> Result<Signed> {
    let mut preimage = RlpStream::new_list(9);
    for field in &fields {
        preimage.append(&field.as_slice());
    }
    preimage.append(&chain).append(&0u8).append(&0u8);
    let hash = Keccak256::digest(preimage.out());
    let (signature, recovery) = key
        .sign_prehash_recoverable(&hash)
        .map_err(|_| "Couldn’t sign this transfer.")?;
    if recovery.to_byte() > 1 {
        return Err("Couldn’t sign this transfer.");
    }
    let v = chain
        .checked_mul(2)
        .and_then(|value| value.checked_add(35 + u64::from(recovery.to_byte())))
        .ok_or("Invalid chain ID.")?;
    let signature = signature.to_bytes();
    let mut tx = RlpStream::new_list(9);
    for field in &fields {
        tx.append(&field.as_slice());
    }
    tx.append(&v);
    for scalar in signature.chunks_exact(32) {
        let offset = scalar
            .iter()
            .position(|byte| *byte != 0)
            .ok_or("Invalid signature.")?;
        tx.append(&&scalar[offset..]);
    }
    let data = tx.out();
    Ok(Signed {
        signed: format!("0x{}", hex::encode(&data)),
        transaction_id: format!("0x{}", hex::encode(Keccak256::digest(&data))),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use solana_hash::Hash;
    use solana_message::{compiled_instruction::CompiledInstruction, VersionedMessage};
    use trig_wallet_transfers::{SplTokenProgram, TOKEN_2022_PROGRAM};

    #[test]
    fn legacy_evm_transfer_matches_the_eip155_reference() {
        let private = "46".repeat(32);
        let key = EvmKey::from_slice(&[0x46; 32]).unwrap();
        let from = evm_address(&key);
        let mut request: Request = serde_json::from_value(serde_json::json!({
            "operation": "signTransfer", "family": "evm", "secret": private,
            "transfer": {
                "intent": {"chain":"eip155:1","from":from,"to":"0x3535353535353535353535353535353535353535","amount":"1"},
                "amountAtomic":"1000000000000000000",
                "decimals":18,"fee":"0.00042","feeDecimals":18,
                "parameters":{"family":"evm","chainId":"1","nonce":"9","gasPrice":"4a817c800","gasLimit":"5208"}
            }
        })).unwrap();
        let signed = sign(request.transfer.as_ref().unwrap(), &request).unwrap();
        let expected = concat!("0xf86c098504a817c800825208943535353535353535353535353535353535353535",
            "880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276",
            "a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83");
        assert_eq!(signed.signed, expected);
        request.family = Some(Family::Solana);
        assert!(sign(request.transfer.as_ref().unwrap(), &request).is_err());
    }

    #[test]
    fn erc20_signature_binds_the_reviewed_amount_and_fee() {
        let from = evm_address(&EvmKey::from_slice(&[0x46; 32]).unwrap());
        let mut request: Request = serde_json::from_value(serde_json::json!({
            "operation":"signTransfer", "family":"evm", "secret":"46".repeat(32),
            "transfer":{
                "intent":{"chain":"eip155:1","from":from,
                    "to":"0x3535353535353535353535353535353535353535","amount":".25",
                    "tokenAddress":"0x1212121212121212121212121212121212121212"},
                "amountAtomic":"250000",
                "decimals":6,"fee":"0.001","feeDecimals":18,
                "parameters":{"family":"evm","chainId":"1","nonce":"9",
                    "gasPrice":"4a817c800","gasLimit":"c350"}
            }
        }))
        .unwrap();
        let signed = sign(request.transfer.as_ref().unwrap(), &request).unwrap();
        let bytes = hex::decode(&signed.signed[2..]).unwrap();
        let transaction = rlp::Rlp::new(&bytes);
        assert_eq!(transaction.at(3).unwrap().data().unwrap(), [0x12; 20]);
        assert!(transaction.at(4).unwrap().data().unwrap().is_empty());
        let payload = transaction.at(5).unwrap().data().unwrap();
        assert_eq!(&payload[..4], &[0xa9, 0x05, 0x9c, 0xbb]);
        assert_eq!(&payload[16..36], &[0x35; 20]);
        assert_eq!(
            BigUint::from_bytes_be(&payload[36..]),
            BigUint::from(250_000u32)
        );

        request.transfer.as_mut().unwrap().amount_atomic = "250001".into();
        assert!(sign(request.transfer.as_ref().unwrap(), &request).is_err());
        request.transfer.as_mut().unwrap().amount_atomic = "250000".into();
        request.transfer.as_mut().unwrap().fee = "0.0001".into();
        assert!(sign(request.transfer.as_ref().unwrap(), &request).is_err());
    }

    #[test]
    fn solana_transfer_signs_only_the_reviewed_system_instruction() {
        let key = SolanaKey::from_bytes(&[7; 32]);
        let from = solana_address(&key);
        let to = solana_address(&SolanaKey::from_bytes(&[9; 32]));
        let blockhash = Hash::new_from_array([3; 32]);
        let request: Request = serde_json::from_value(serde_json::json!({
            "operation":"signTransfer", "family":"solana", "secret":bs58::encode([7;32]).into_string(),
            "transfer":{
                "intent":{"chain":"solana","from":from,"to":to,"amount":"0.0000037"},
                "amountAtomic":"3700",
                "decimals":9,"fee":"0.000005","feeDecimals":9,
                "parameters":{"family":"solana","blockhash":blockhash.to_string()}
            }
        })).unwrap();
        let signed = sign(request.transfer.as_ref().unwrap(), &request).unwrap();
        let tx: VersionedTransaction =
            bincode::deserialize(&STANDARD.decode(signed.signed).unwrap()).unwrap();
        assert_eq!(tx.signatures.len(), 1);
        assert_eq!(tx.signatures[0].to_string(), signed.transaction_id);
        let signature = ed25519_dalek::Signature::from_bytes(tx.signatures[0].as_array());
        assert!(key
            .verifying_key()
            .verify_strict(&tx.message.serialize(), &signature)
            .is_ok());
        let VersionedMessage::Legacy(message) = tx.message else {
            panic!("unexpected message version");
        };
        assert_eq!(message.recent_blockhash, blockhash);
        assert_eq!(message.account_keys[0].to_string(), from);
        assert_eq!(message.account_keys[1].to_string(), to);
        let [CompiledInstruction { data, .. }] = message.instructions.as_slice() else {
            panic!("unexpected instructions");
        };
        assert_eq!(u64::from_le_bytes(data[4..].try_into().unwrap()), 3700);
    }

    #[test]
    fn spl_signer_creates_the_reviewed_recipient_account_and_checks_precision() {
        let from = solana_address(&SolanaKey::from_bytes(&[7; 32]));
        let to = solana_address(&SolanaKey::from_bytes(&[9; 32]));
        let source = solana_address(&SolanaKey::from_bytes(&[11; 32]));
        let mint = "So11111111111111111111111111111111111111112";
        let mut request: Request = serde_json::from_value(serde_json::json!({
            "operation":"signTransfer","family":"solana","secret":bs58::encode([7;32]).into_string(),
            "transfer":{
                "intent":{"chain":"solana","from":from,"to":to,"amount":"0.1125","tokenAddress":mint},
                "amountAtomic":"112500000",
                "decimals":9,"fee":"0.000005","feeDecimals":9,
                "parameters":{"family":"solana","blockhash":Hash::new_from_array([3;32]).to_string(),
                    "spl":{"program":"legacy","decimals":9,"sources":[{"address":source,"amount":112500000}],
                        "createRecipientAccount":true}}
            }
        })).unwrap();
        let signed = sign(request.transfer.as_ref().unwrap(), &request).unwrap();
        let tx: VersionedTransaction =
            bincode::deserialize(&STANDARD.decode(signed.signed).unwrap()).unwrap();
        let VersionedMessage::Legacy(message) = tx.message else {
            panic!("expected legacy message")
        };
        let [create, transfer] = message.instructions.as_slice() else {
            panic!("expected account creation and transfer");
        };
        let account = |instruction: &CompiledInstruction, index: usize| {
            message.account_keys[usize::from(instruction.accounts[index])].to_string()
        };
        let recipient = trig_wallet_transfers::spl_recipient_address(&to, mint).unwrap();
        assert_eq!(create.data, [1]);
        assert_eq!(account(create, 0), from);
        assert_eq!(account(create, 1), recipient);
        assert_eq!(account(create, 2), to);
        assert_eq!(account(transfer, 0), source);
        assert_eq!(account(transfer, 1), mint);
        assert_eq!(account(transfer, 2), recipient);
        assert_eq!(account(transfer, 3), from);
        assert_eq!(transfer.data[0], 12);
        assert_eq!(
            u64::from_le_bytes(transfer.data[1..9].try_into().unwrap()),
            112_500_000
        );
        assert_eq!(transfer.data[9], 9);

        let Parameters::Solana { spl: Some(spl), .. } =
            &mut request.transfer.as_mut().unwrap().parameters
        else {
            panic!("expected SPL transfer");
        };
        spl.program = SplTokenProgram::Token2022;
        let signed = sign(request.transfer.as_ref().unwrap(), &request).unwrap();
        let tx: VersionedTransaction =
            bincode::deserialize(&STANDARD.decode(signed.signed).unwrap()).unwrap();
        let VersionedMessage::Legacy(message) = tx.message else {
            panic!("expected legacy message")
        };
        let [create, transfer] = message.instructions.as_slice() else {
            panic!("expected account creation and transfer");
        };
        assert_eq!(
            message.account_keys[usize::from(create.accounts[5])].to_string(),
            TOKEN_2022_PROGRAM
        );
        assert_eq!(
            message.account_keys[usize::from(transfer.program_id_index)].to_string(),
            TOKEN_2022_PROGRAM
        );
        assert_ne!(
            message.account_keys[usize::from(transfer.accounts[2])].to_string(),
            recipient
        );
    }

    #[test]
    fn token2022_rent_simulation_carries_only_a_read_only_size_query() {
        let payer = solana_address(&SolanaKey::from_bytes(&[7; 32]));
        let mint = solana_address(&SolanaKey::from_bytes(&[9; 32]));
        let blockhash = Hash::new_from_array([3; 32]);
        let wire = trig_wallet_transfers::token2022_account_size_transaction(
            &payer,
            &mint,
            &blockhash.to_string(),
        )
        .unwrap();
        let tx: VersionedTransaction = bincode::deserialize(&wire).unwrap();
        assert_eq!(tx.signatures, [Signature::default()]);
        let VersionedMessage::Legacy(message) = tx.message else {
            panic!("expected legacy message")
        };
        let [instruction] = message.instructions.as_slice() else {
            panic!("expected size query")
        };
        assert_eq!(message.account_keys[0].to_string(), payer);
        assert_eq!(
            message.account_keys[usize::from(instruction.program_id_index)].to_string(),
            TOKEN_2022_PROGRAM
        );
        assert_eq!(
            message.account_keys[usize::from(instruction.accounts[0])].to_string(),
            mint
        );
        assert_eq!(instruction.data, [21, 7, 0]);
    }
}
