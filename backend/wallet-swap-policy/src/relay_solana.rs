use super::{now, Result, VersionedTransaction, ASSOCIATED_TOKEN, SYSTEM, TOKEN};
use serde::{Deserialize, Serialize};
use solana_message::{AccountMeta, Address, Hash, Instruction, Message, VersionedMessage};
use solana_signature::Signature;

// Relay v2 production depository and its two program-derived accounts on Solana.
// https://github.com/relayprotocol/relay-settlement/tree/main/contracts/depository-svm
pub const PROGRAM: &str = "99vQwtBwYtrqqD9YSXbdum3KBdxPAVxYTaQ3cfnJSrN2";
const STATE: &str = "Dodg2HifwU8rmaVVyMyUZDGTRbqAJTyVYxXPwcbNpBKc";
pub const VAULT: &str = "7uTT8Xi5RWXzy7h9XL244GRgEycDYDhLjr3ZyNdXi8pZ";
const DEPOSIT_NATIVE: [u8; 8] = [0x0d, 0x9e, 0x0d, 0xdf, 0x5f, 0xd5, 0x1c, 0x06];
const DEPOSIT_TOKEN: [u8; 8] = [0x0b, 0x9c, 0x60, 0xda, 0x27, 0xa3, 0xb4, 0x13];

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Terms {
    pub wallet: String,
    pub input_mint: String,
    // A decimal string preserves the full u64 across JSON consumers.
    pub input_atomic: String,
    pub order_id: [u8; 32],
    pub expires_at: u64,
}

fn address(value: &str) -> Result<Address> {
    value.parse().map_err(|_| "Invalid Solana deposit account.")
}

pub fn instruction(terms: &Terms) -> Result<Instruction> {
    let amount: u64 = terms
        .input_atomic
        .parse()
        .map_err(|_| "Invalid Relay amount.")?;
    if amount == 0 || terms.order_id == [0; 32] {
        return Err("Invalid Relay deposit terms.");
    }
    let owner = address(&terms.wallet)?;
    let vault = address(VAULT)?;
    let native = terms.input_mint == SYSTEM;
    let mut accounts = vec![
        AccountMeta::new_readonly(address(STATE)?, false),
        AccountMeta::new(owner, true),
        AccountMeta::new_readonly(owner, false),
    ];
    if native {
        accounts.push(AccountMeta::new(vault, false));
    } else {
        let mint = address(&terms.input_mint)?;
        let associated = |wallet| -> Result<Address> {
            address(&trig_wallet_transfers::spl_recipient_address(
                wallet,
                &terms.input_mint,
            )?)
        };
        accounts.extend([
            AccountMeta::new_readonly(vault, false),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new(associated(terms.wallet.as_str())?, false),
            AccountMeta::new(associated(VAULT)?, false),
            AccountMeta::new_readonly(address(TOKEN)?, false),
            AccountMeta::new_readonly(address(ASSOCIATED_TOKEN)?, false),
        ]);
    }
    accounts.push(AccountMeta::new_readonly(address(SYSTEM)?, false));
    let mut data = Vec::with_capacity(48);
    data.extend_from_slice(if native {
        &DEPOSIT_NATIVE
    } else {
        &DEPOSIT_TOKEN
    });
    data.extend_from_slice(&amount.to_le_bytes());
    data.extend_from_slice(&terms.order_id);
    Ok(Instruction {
        program_id: address(PROGRAM)?,
        accounts,
        data,
    })
}

pub fn transaction(terms: &Terms, blockhash: &str) -> Result<VersionedTransaction> {
    let blockhash: Hash = blockhash.parse().map_err(|_| "Invalid Solana blockhash.")?;
    if blockhash == Hash::default() {
        return Err("Invalid Solana blockhash.");
    }
    let owner = address(&terms.wallet)?;
    Ok(VersionedTransaction {
        signatures: vec![Signature::default()],
        message: VersionedMessage::Legacy(Message::new_with_blockhash(
            &[instruction(terms)?],
            Some(&owner),
            &blockhash,
        )),
    })
}

/// Require the exact locally reconstructed message. This rules out additional
/// instructions, priority fees, address tables, and other signers.
pub fn review(planned: &VersionedTransaction, terms: &Terms, at: u64) -> Result<()> {
    if terms.expires_at <= at || terms.expires_at.saturating_sub(at) > 75 {
        return Err("Review a fresh Relay deposit.");
    }
    let expected = transaction(terms, &planned.message.recent_blockhash().to_string())?;
    if expected != *planned {
        return Err("The transaction does not match the reviewed Relay deposit.");
    }
    Ok(())
}

pub fn review_now(planned: &VersionedTransaction, terms: &Terms) -> Result<()> {
    review(planned, terms, now())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_the_exact_unsigned_deposit_message() {
        let mut terms = Terms {
            wallet: crate::SOL.into(),
            input_mint: SYSTEM.into(),
            input_atomic: "100000000".into(),
            order_id: [42; 32],
            expires_at: 130,
        };
        let planned = transaction(&terms, &Hash::new_from_array([9; 32]).to_string()).unwrap();
        assert!(review(&planned, &terms, 100).is_ok());
        assert!(review(&planned, &terms, 130).is_err());
        terms.input_atomic = "100000001".into();
        assert!(review(&planned, &terms, 100).is_err());
        terms.input_atomic = "100000000".into();
        terms.order_id[0] ^= 1;
        assert!(review(&planned, &terms, 100).is_err());
    }
}
