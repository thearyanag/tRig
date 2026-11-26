use bip32::{DerivationPath, XPrv};
use bip39::{Language, Mnemonic};
use ed25519_dalek::SigningKey as SolanaKey;
use ed25519_dalek_bip32::{DerivationPath as SolanaPath, ExtendedSigningKey};
use k256::ecdsa::SigningKey as EvmKey;
use serde::{Deserialize, Serialize};
use sha3::{Digest, Keccak256};
use std::io::{self, Read, Write};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

#[allow(dead_code)] // Shared with the backend, which also uses the review metadata and delegate pin.
mod flash_intent;
mod flash_order;
mod jupiter_swap;
mod jupiter_trigger;
mod relay_solana;
mod relay_trade;
mod transfer;

type Result<T> = std::result::Result<T, &'static str>;

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Family {
    Solana,
    Evm,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    operation: String,
    secret: Option<String>,
    passphrase: Option<String>,
    #[zeroize(skip)]
    family: Option<Family>,
    #[zeroize(skip)]
    account_index: Option<u32>,
    #[zeroize(skip)]
    transfer: Option<transfer::Plan>,
    #[zeroize(skip)]
    trade: Option<serde_json::Value>,
}

#[derive(Serialize)]
struct Account {
    family: Family,
    address: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    accounts: Vec<Account>,
    #[serde(skip_serializing_if = "Option::is_none")]
    recovery_phrase: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transaction: Option<transfer::Signed>,
}

impl Drop for Response {
    fn drop(&mut self) {
        self.recovery_phrase.zeroize();
    }
}

fn evm_address(key: &EvmKey) -> String {
    let point = key.verifying_key().to_encoded_point(false);
    let digest = Keccak256::digest(&point.as_bytes()[1..]);
    let lower = hex::encode(&digest[12..]);
    let checksum = Keccak256::digest(lower.as_bytes());
    let mut result = String::from("0x");
    for (index, char) in lower.chars().enumerate() {
        let nibble = if index % 2 == 0 {
            checksum[index / 2] >> 4
        } else {
            checksum[index / 2] & 15
        };
        result.push(if nibble >= 8 {
            char.to_ascii_uppercase()
        } else {
            char
        });
    }
    result
}

fn solana_address(key: &SolanaKey) -> String {
    bs58::encode(key.verifying_key().to_bytes()).into_string()
}

fn phrase_accounts(mnemonic: &Mnemonic, passphrase: &str, index: u32) -> Result<Vec<Account>> {
    if index >= (1 << 31) || passphrase.len() > 512 {
        return Err("Invalid recovery options.");
    }
    let seed = Zeroizing::new(mnemonic.to_seed(passphrase));
    let evm_path: DerivationPath = format!("m/44'/60'/0'/0/{index}")
        .parse()
        .map_err(|_| "Invalid account index.")?;
    let sol_path: SolanaPath = format!("m/44'/501'/{index}'/0'")
        .parse()
        .map_err(|_| "Invalid account index.")?;
    let evm = XPrv::derive_from_path(seed.as_slice(), &evm_path)
        .map_err(|_| "Couldn’t derive the EVM account.")?;
    let sol = ExtendedSigningKey::from_seed(seed.as_slice())
        .and_then(|key| key.derive(&sol_path))
        .map_err(|_| "Couldn’t derive the Solana account.")?;
    Ok(vec![
        Account {
            family: Family::Solana,
            address: solana_address(&sol.signing_key),
        },
        Account {
            family: Family::Evm,
            address: evm_address(evm.private_key()),
        },
    ])
}

fn key_bytes(family: Family, input: &str) -> Result<Zeroizing<Vec<u8>>> {
    let input = input.trim();
    let decoded = if family == Family::Solana && input.starts_with('[') {
        serde_json::from_str::<Vec<u8>>(input).map_err(|_| "Enter a valid Solana private key.")?
    } else if family == Family::Evm
        || input.starts_with("0x")
        || (input.len() == 64 && input.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        hex::decode(input.strip_prefix("0x").unwrap_or(input))
            .map_err(|_| "Enter a valid hexadecimal private key.")?
    } else {
        bs58::decode(input)
            .into_vec()
            .map_err(|_| "Enter a valid Solana private key.")?
    };
    let mut bytes = Zeroizing::new(decoded);
    if family == Family::Solana && bytes.len() == 64 {
        let seed = <&[u8; 32]>::try_from(&bytes[..32]).map_err(|_| "Invalid Solana key length.")?;
        let key = SolanaKey::from_bytes(seed);
        if key.verifying_key().as_bytes() != &bytes[32..] {
            return Err("The Solana key and public address do not match.");
        }
        bytes[32..].zeroize();
        bytes.truncate(32);
    }
    if bytes.len() != 32 {
        return Err("The private key has the wrong length.");
    }
    Ok(bytes)
}

fn private_account(family: Family, input: &str) -> Result<Account> {
    let bytes = key_bytes(family, input)?;
    let address = match family {
        Family::Solana => {
            let seed = <&[u8; 32]>::try_from(bytes.as_slice())
                .map_err(|_| "Invalid Solana key length.")?;
            solana_address(&SolanaKey::from_bytes(seed))
        }
        Family::Evm => {
            let key = EvmKey::from_slice(bytes.as_slice())
                .map_err(|_| "Enter a valid EVM private key.")?;
            evm_address(&key)
        }
    };
    Ok(Account { family, address })
}

fn handle(request: Request) -> Result<Response> {
    match request.operation.as_str() {
        "generate" => {
            let phrase = Mnemonic::generate_in(Language::English, 12)
                .map_err(|_| "Couldn’t generate a recovery phrase.")?;
            let accounts = phrase_accounts(&phrase, "", 0)?;
            Ok(Response {
                accounts,
                recovery_phrase: Some(phrase.to_string()),
                transaction: None,
            })
        }
        "inspectPhrase" => {
            let secret = request
                .secret
                .as_deref()
                .ok_or("Enter a recovery phrase.")?;
            let words = Zeroizing::new(secret.split_whitespace().collect::<Vec<_>>().join(" "));
            let phrase = Mnemonic::parse_in(Language::English, words.as_str())
                .map_err(|_| "Check the recovery phrase and the order of the words.")?;
            let accounts = phrase_accounts(
                &phrase,
                request.passphrase.as_deref().unwrap_or(""),
                request.account_index.unwrap_or(0),
            )?;
            Ok(Response {
                accounts,
                recovery_phrase: None,
                transaction: None,
            })
        }
        "inspectKey" => {
            let family = request.family.ok_or("Choose Solana or EVM.")?;
            let secret = request.secret.as_deref().ok_or("Enter a private key.")?;
            Ok(Response {
                accounts: vec![private_account(family, secret)?],
                recovery_phrase: None,
                transaction: None,
            })
        }
        "signTransfer" => {
            let plan = request
                .transfer
                .as_ref()
                .ok_or("A reviewed transfer is required.")?;
            let transaction = transfer::sign(plan, &request)?;
            Ok(Response {
                accounts: vec![],
                recovery_phrase: None,
                transaction: Some(transaction),
            })
        }
        "signJupiterSwap" | "signRelaySolana" | "signRelayEVM" | "signFlashOrder" | "signFlashCancel"
        | "signFlashApproval" | "signFlashSolanaSetup" | "signJupiterTriggerAuth"
        | "signJupiterTriggerCancel" | "signJupiterTriggerTransfer" => {
            let plan = request.trade.as_ref().ok_or("A reviewed trade is required.")?;
            let transaction = match request.operation.as_str() {
                "signJupiterSwap" => jupiter_swap::sign(plan, &request),
                "signJupiterTriggerAuth" => jupiter_trigger::sign_auth(plan, &request),
                "signJupiterTriggerCancel" => jupiter_trigger::sign_cancel(plan, &request),
                "signJupiterTriggerTransfer" => jupiter_trigger::sign_transfer(plan, &request),
                "signRelaySolana" => relay_solana::sign(plan, &request),
                "signRelayEVM" => relay_trade::sign(plan, &request),
                "signFlashOrder" => flash_order::sign_order(plan, &request),
                "signFlashApproval" => flash_order::sign_approval(plan, &request),
                "signFlashSolanaSetup" => flash_order::sign_solana_setup(plan, &request),
                _ => flash_order::sign_cancel(plan, &request),
            }?;
            Ok(Response {
                accounts: vec![],
                recovery_phrase: None,
                transaction: Some(transaction),
            })
        }
        _ => Err("Unknown wallet operation."),
    }
}

fn main() -> io::Result<()> {
    let mut data = Zeroizing::new(Vec::new());
    io::stdin().lock().take(16_385).read_to_end(&mut data)?;
    let result = if data.len() <= 16_384 {
        serde_json::from_slice::<Request>(&data)
            .map_err(|_| "Couldn’t read wallet request.")
            .and_then(handle)
    } else {
        Err("Wallet input is too large.")
    };
    data.zeroize();
    let mut output = io::stdout().lock();
    match result {
        Ok(response) => serde_json::to_writer(&mut output, &response)?,
        Err(error) => serde_json::to_writer(&mut output, &serde_json::json!({"error": error}))?,
    }
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_returns_the_recovery_phrase_field_used_by_the_mac_app() {
        let request = serde_json::from_str(r#"{"operation":"generate"}"#).unwrap();
        let response = serde_json::to_value(handle(request).unwrap()).unwrap();
        assert_eq!(
            response["recoveryPhrase"]
                .as_str()
                .map(|phrase| phrase.split_whitespace().count()),
            Some(12)
        );
        assert!(response.get("recovery_phrase").is_none());
        assert_eq!(response["accounts"].as_array().map(Vec::len), Some(2));
    }

    #[test]
    fn recovery_restores_known_solana_and_evm_accounts() {
        let phrase = Mnemonic::parse("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap();
        let accounts = phrase_accounts(&phrase, "", 0).unwrap();
        assert_eq!(
            accounts[0].address,
            "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"
        );
        assert_eq!(
            accounts[1].address,
            "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
        );
        assert_ne!(
            phrase_accounts(&phrase, "", 1).unwrap()[0].address,
            accounts[0].address
        );
    }

    #[test]
    fn rejects_mismatched_solana_keypairs_and_invalid_evm_keys() {
        let seed = [7u8; 32];
        let key = SolanaKey::from_bytes(&seed);
        let mut pair = key.to_keypair_bytes();
        let text = bs58::encode(pair).into_string();
        let account = private_account(Family::Solana, &text).unwrap();
        assert_eq!(account.address, solana_address(&key));
        pair[63] ^= 1;
        assert!(private_account(Family::Solana, &bs58::encode(pair).into_string()).is_err());
        assert!(private_account(Family::Evm, &"00".repeat(32)).is_err());
    }
}
