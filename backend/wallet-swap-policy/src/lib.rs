use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use solana_message::Address;
use solana_signature::Signature;
pub use solana_transaction::versioned::VersionedTransaction;

pub mod relay_solana;
pub mod trigger;
use std::{
    str::FromStr,
    time::{SystemTime, UNIX_EPOCH},
};

pub type Result<T> = std::result::Result<T, &'static str>;

pub const SOL: &str = "So11111111111111111111111111111111111111112";
pub const SYSTEM: &str = "11111111111111111111111111111111";
pub const TOKEN: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
pub const TOKEN_2022: &str = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
const JUPITER: &str = "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4";
const COMPUTE_BUDGET: &str = "ComputeBudget111111111111111111111111111111";
const ASSOCIATED_TOKEN: &str = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
const ROUTE_V2: [u8; 8] = [187, 100, 250, 204, 49, 196, 175, 20];
const SHARED_ROUTE_V2: [u8; 8] = [209, 152, 83, 147, 124, 254, 216, 233];

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Terms {
    pub wallet: String,
    pub input_mint: String,
    pub output_mint: String,
    pub in_amount: String,
    pub minimum_out: String,
    pub slippage_bps: u16,
    pub max_network_cost: String,
    pub expires_at: u64,
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn decode(encoded: &str) -> Result<VersionedTransaction> {
    if encoded.len() > 1644 {
        return Err("Jupiter returned an oversized transaction.");
    }
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|_| "Invalid transaction encoding.")?;
    if bytes.len() > 1232 {
        return Err("Jupiter returned an oversized transaction.");
    }
    let transaction: VersionedTransaction =
        bincode::deserialize(&bytes).map_err(|_| "Jupiter returned an unsupported transaction.")?;
    transaction
        .sanitize()
        .map_err(|_| "Jupiter returned an invalid transaction.")?;
    if bincode::serialize(&transaction).map_err(|_| "Could not encode transaction.")? != bytes {
        return Err("Transaction encoding is not canonical.");
    }
    Ok(transaction)
}

pub fn encode(transaction: &VersionedTransaction) -> Result<String> {
    bincode::serialize(transaction)
        .map(|bytes| STANDARD.encode(bytes))
        .map_err(|_| "Could not encode transaction.")
}

/// Validate the immutable route and wallet signer before private key use. The data service
/// independently verifies the resolved accounts and simulated effects, then binds the
/// signed message to this exact validated transaction before submission.
pub fn review(transaction: &VersionedTransaction, terms: &Terms) -> Result<()> {
    let keys = transaction.message.static_account_keys();
    let wallet = Address::from_str(&terms.wallet).map_err(|_| "Invalid trade wallet.")?;
    let input = Address::from_str(&terms.input_mint).map_err(|_| "Invalid input mint.")?;
    let output = Address::from_str(&terms.output_mint).map_err(|_| "Invalid output mint.")?;
    let input_amount = terms
        .in_amount
        .parse::<u64>()
        .map_err(|_| "Invalid trade amount.")?;
    let minimum = terms
        .minimum_out
        .parse::<u64>()
        .map_err(|_| "Invalid trade minimum.")?;
    let network = terms
        .max_network_cost
        .parse::<u64>()
        .map_err(|_| "Invalid network cost.")?;
    if transaction.signatures != [Signature::default()]
        || keys.first() != Some(&wallet)
        || transaction.message.header().num_required_signatures != 1
        || transaction.message.header().num_readonly_signed_accounts != 0
        || input == output
        || input_amount == 0
        || minimum == 0
        || network > 50_000_000
        || !(1..=500).contains(&terms.slippage_bps)
        || terms.expires_at <= now()
        || terms.expires_at > now() + 60
    {
        return Err("The transaction does not match the reviewed wallet or order.");
    }

    let mut swap_count = 0;
    for instruction in transaction.message.instructions() {
        let program = keys
            .get(usize::from(instruction.program_id_index))
            .ok_or("Unsupported program reference.")?
            .to_string();
        let data = instruction.data.as_slice();
        match program.as_str() {
            JUPITER => {
                swap_count += 1;
                let (offset, signer, input_index, output_index) = if data.starts_with(&ROUTE_V2) {
                    (8, 0, 3, 4)
                } else if data.starts_with(&SHARED_ROUTE_V2) {
                    (9, 1, 6, 7)
                } else {
                    return Err("This Jupiter route format is unavailable for trading.");
                };
                let account = |index| instruction.accounts.get(index).copied();
                if account(signer) != Some(0) {
                    return Err("The trade is not authorized by the selected wallet.");
                }
                for (index, mint) in [(input_index, input), (output_index, output)] {
                    let index = usize::from(account(index).ok_or("Missing route mint.")?);
                    if keys.get(index).is_some_and(|key| *key != mint) {
                        return Err("The Jupiter route uses a different token.");
                    }
                }
                let data = data
                    .get(offset..offset + 22)
                    .ok_or("Invalid Jupiter route.")?;
                let encoded_input = u64::from_le_bytes(data[0..8].try_into().unwrap());
                let quoted_out = u64::from_le_bytes(data[8..16].try_into().unwrap());
                let slippage = u16::from_le_bytes(data[16..18].try_into().unwrap());
                let fee = u16::from_le_bytes(data[18..20].try_into().unwrap());
                // The full route is bound by simulation, including realized fees. The on-chain
                // slippage guard itself must enforce at least the reviewed minimum.
                let guarded = u128::from(quoted_out)
                    * u128::from(10_000u16.saturating_sub(slippage))
                    / 10_000;
                if encoded_input != input_amount
                    || slippage > terms.slippage_bps
                    || guarded < u128::from(minimum)
                    || fee > 100
                {
                    return Err("Jupiter's on-chain amounts differ from the trade review.");
                }
            }
            COMPUTE_BUDGET if matches!(data, [2, _, _, _, _] | [3, _, _, _, _, _, _, _, _]) => {}
            ASSOCIATED_TOKEN if data.is_empty() || data == [0] || data == [1] => {}
            // Wrap/unwrap SOL only. Token transfers belong inside the validated Jupiter
            // instruction. No authority, delegate, freeze or extension operations.
            TOKEN if matches!(data, [9] | [17]) => {}
            SYSTEM if data.len() == 12 && data[..4] == [2, 0, 0, 0] => {}
            _ => return Err("The trade contains an unsupported transaction instruction."),
        }
    }
    if swap_count != 1 {
        return Err("A trade must contain exactly one Jupiter route.");
    }
    Ok(())
}

pub fn validate_signed(
    planned: &VersionedTransaction,
    signed: &VersionedTransaction,
    transaction_id: &str,
) -> Result<()> {
    let [signature] = signed.signatures.as_slice() else {
        return Err("Unexpected trade signers.");
    };
    let signer = planned
        .message
        .static_account_keys()
        .first()
        .ok_or("Missing wallet signer.")?;
    if signed.message != planned.message
        || signature.to_string() != transaction_id
        || !signature.verify(signer.as_ref(), &signed.message.serialize())
    {
        return Err("The signature does not authorize the reviewed trade.");
    }
    Ok(())
}
