pub mod flash;
pub mod relay;

use curve25519_dalek::edwards::CompressedEdwardsY;
use serde::{Deserialize, Serialize};
use solana_hash::Hash;
use solana_instruction::{AccountMeta, Instruction};
use solana_message::{Message, VersionedMessage};
use solana_pubkey::Pubkey;
use std::str::FromStr;

type Result<T> = std::result::Result<T, &'static str>;

pub const SPL_TOKEN_PROGRAM: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
pub const TOKEN_2022_PROGRAM: &str = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
const ASSOCIATED_TOKEN_PROGRAM: &str = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
const SYSTEM_PROGRAM: &str = "11111111111111111111111111111111";
// Solana's 1,232 byte wire limit minus one signature and its compact length.
const MAX_TRANSFER_MESSAGE_BYTES: usize = 1_232 - 65;

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SplTokenProgram {
    Legacy,
    Token2022,
}

impl SplTokenProgram {
    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            SPL_TOKEN_PROGRAM => Some(Self::Legacy),
            TOKEN_2022_PROGRAM => Some(Self::Token2022),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Legacy => SPL_TOKEN_PROGRAM,
            Self::Token2022 => TOKEN_2022_PROGRAM,
        }
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SplSource {
    pub address: String,
    pub amount: u64,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SplTransfer {
    pub program: SplTokenProgram,
    pub decimals: u8,
    pub sources: Vec<SplSource>,
    pub create_recipient_account: bool,
}

pub fn token2022_account_size_transaction(
    payer: &str,
    mint: &str,
    blockhash: &str,
) -> Result<Vec<u8>> {
    let instruction = Instruction {
        program_id: solana_key(TOKEN_2022_PROGRAM)?,
        accounts: vec![AccountMeta::new_readonly(solana_key(mint)?, false)],
        // GetAccountDataSize with the ImmutableOwner extension the ATA program adds.
        data: vec![21, 7, 0],
    };
    let message = VersionedMessage::Legacy(Message::new_with_blockhash(
        &[instruction],
        Some(&solana_key(payer)?),
        &Hash::from_str(blockhash).map_err(|_| "Invalid blockhash.")?,
    ));
    // The simulation wire format carries a single zeroed signature.
    let mut wire = vec![0; 65];
    wire[0] = 1;
    wire.extend(message.serialize());
    Ok(wire)
}

pub fn evm_address(value: &str) -> Result<[u8; 20]> {
    let value = value.strip_prefix("0x").ok_or("Invalid EVM address.")?;
    let mut bytes = [0; 20];
    hex::decode_to_slice(value, &mut bytes).map_err(|_| "Invalid EVM address.")?;
    if bytes == [0; 20] {
        return Err("Choose a valid EVM account or contract.");
    }
    Ok(bytes)
}

pub fn erc20_transfer_data(recipient: &[u8; 20], amount: &[u8]) -> Result<[u8; 68]> {
    if amount.is_empty() || amount.len() > 32 || amount.iter().all(|byte| *byte == 0) {
        return Err("Invalid ERC-20 transfer amount.");
    }
    let mut data = [0; 68];
    // ERC-20 transfer(address,uint256)
    data[..4].copy_from_slice(&[0xa9, 0x05, 0x9c, 0xbb]);
    data[16..36].copy_from_slice(recipient);
    data[68 - amount.len()..].copy_from_slice(amount);
    Ok(data)
}

fn solana_key(value: &str) -> Result<Pubkey> {
    value.parse().map_err(|_| "Invalid Solana address.")
}

fn associated_address(owner: &Pubkey, mint: &Pubkey, token_program: &Pubkey) -> Result<Pubkey> {
    let program = solana_key(ASSOCIATED_TOKEN_PROGRAM)?;
    let seeds = [owner.as_ref(), token_program.as_ref(), mint.as_ref()];
    // Search the same bump seeds as Solana's PDA derivation. The SDK hashes the
    // address, and dalek checks that the result lies off the Edwards curve.
    (1..=u8::MAX)
        .rev()
        .map(|bump| Pubkey::derive_address(&seeds, Some(bump), &program))
        .find(|address| {
            CompressedEdwardsY(*address.as_array())
                .decompress()
                .is_none()
        })
        .ok_or("Couldn’t derive the recipient token account.")
}

pub fn solana_associated_address(owner: &str, mint: &str, token_program: &str) -> Result<String> {
    associated_address(
        &solana_key(owner)?,
        &solana_key(mint)?,
        &solana_key(token_program)?,
    )
    .map(|key| key.to_string())
}

pub fn spl_recipient_address(owner: &str, mint: &str) -> Result<String> {
    associated_address(
        &solana_key(owner)?,
        &solana_key(mint)?,
        &solana_key(SPL_TOKEN_PROGRAM)?,
    )
    .map(|address| address.to_string())
}

fn spl_instructions(
    owner: Pubkey,
    recipient: Pubkey,
    mint: Pubkey,
    amount: u64,
    plan: &SplTransfer,
) -> Result<Vec<Instruction>> {
    let token = solana_key(plan.program.id())?;
    let destination = associated_address(&recipient, &mint, &token)?;
    if plan.sources.is_empty()
        || plan
            .sources
            .iter()
            .try_fold(0u64, |total, source| total.checked_add(source.amount))
            != Some(amount)
    {
        return Err("The token accounts don’t match the reviewed transfer amount.");
    }

    let mut instructions = Vec::new();
    if plan.create_recipient_account {
        instructions.push(Instruction {
            program_id: solana_key(ASSOCIATED_TOKEN_PROGRAM)?,
            accounts: vec![
                AccountMeta::new(owner, true),
                AccountMeta::new(destination, false),
                AccountMeta::new_readonly(recipient, false),
                AccountMeta::new_readonly(mint, false),
                AccountMeta::new_readonly(solana_key(SYSTEM_PROGRAM)?, false),
                AccountMeta::new_readonly(token, false),
            ],
            // Associated Token Account CreateIdempotent
            data: vec![1],
        });
    }

    let mut used_sources = std::collections::HashSet::new();
    for source in &plan.sources {
        let address = solana_key(&source.address)?;
        if source.amount == 0 || address == destination || !used_sources.insert(address) {
            return Err("Invalid source token account.");
        }
        // SPL Token TransferChecked, including the mint's precision.
        let mut data = vec![12];
        data.extend(source.amount.to_le_bytes());
        data.push(plan.decimals);
        instructions.push(Instruction {
            program_id: token,
            accounts: vec![
                AccountMeta::new(address, false),
                AccountMeta::new_readonly(mint, false),
                AccountMeta::new(destination, false),
                AccountMeta::new_readonly(owner, true),
            ],
            data,
        });
    }
    Ok(instructions)
}

pub fn solana_message(
    from: &str,
    to: &str,
    amount: u64,
    blockhash: &str,
    token: Option<(&str, &SplTransfer)>,
) -> Result<VersionedMessage> {
    let from = solana_key(from)?;
    let to = solana_key(to)?;
    let blockhash = Hash::from_str(blockhash).map_err(|_| "Invalid blockhash.")?;
    if from == to || amount == 0 {
        return Err("Choose a different recipient and a positive amount.");
    }
    let instructions = match token {
        Some((mint, plan)) => spl_instructions(from, to, solana_key(mint)?, amount, plan)?,
        None => vec![solana_system_interface::instruction::transfer(
            &from, &to, amount,
        )],
    };
    let message = VersionedMessage::Legacy(Message::new_with_blockhash(
        &instructions,
        Some(&from),
        &blockhash,
    ));
    if message.serialize().len() > MAX_TRANSFER_MESSAGE_BYTES {
        return Err("Send a smaller amount from fewer token accounts.");
    }
    Ok(message)
}
