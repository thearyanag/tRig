use super::{
    associated_address, solana_key, Result, ASSOCIATED_TOKEN_PROGRAM, MAX_TRANSFER_MESSAGE_BYTES,
    SPL_TOKEN_PROGRAM, SYSTEM_PROGRAM,
};
use serde::{Deserialize, Serialize};
use solana_hash::Hash;
use solana_instruction::{AccountMeta, Instruction};
use solana_message::{Message, VersionedMessage};
use solana_pubkey::Pubkey;
use std::str::FromStr;

// PDA under the Flash program, derived with the single seed b"flash_orders".
pub const DELEGATE: &str = "3jBWeQrnfEhw5LY53hwcoYKQJsrTUbtLbmGrNYCr1Fiq";
pub const WRAPPED_SOL: &str = "So11111111111111111111111111111111111111112";

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Setup {
    pub funder: String,
    pub input_mint: String,
    pub output_mint: String,
    pub amount: String,
    pub decimals: u8,
    pub blockhash: String,
    pub create_input: bool,
    pub create_output: bool,
    pub delegate: bool,
    pub wrap: bool,
}

fn create_account(owner: Pubkey, mint: Pubkey, ata: Pubkey, token: Pubkey) -> Result<Instruction> {
    Ok(Instruction {
        program_id: solana_key(ASSOCIATED_TOKEN_PROGRAM)?,
        accounts: vec![
            AccountMeta::new(owner, true),
            AccountMeta::new(ata, false),
            AccountMeta::new_readonly(owner, false),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new_readonly(solana_key(SYSTEM_PROGRAM)?, false),
            AccountMeta::new_readonly(token, false),
        ],
        data: vec![1], // CreateIdempotent
    })
}

impl Setup {
    pub fn amount_units(&self) -> Result<u64> {
        let units = self
            .amount
            .parse::<u64>()
            .map_err(|_| "Invalid Flash setup amount.")?;
        if units == 0 || units.to_string() != self.amount {
            return Err("Invalid Flash setup amount.");
        }
        Ok(units)
    }

    pub fn message(&self) -> Result<Vec<u8>> {
        let amount = self.amount_units()?;
        let owner = solana_key(&self.funder)?;
        let input_mint = solana_key(&self.input_mint)?;
        let output_mint = solana_key(&self.output_mint)?;
        if input_mint == output_mint
            || self.create_input && !self.wrap
            || self.wrap && (!self.delegate || self.input_mint != WRAPPED_SOL || self.decimals != 9)
            || !(self.create_input || self.create_output || self.delegate)
        {
            return Err("Invalid Flash Solana setup.");
        }
        let token = solana_key(SPL_TOKEN_PROGRAM)?;
        let input = associated_address(&owner, &input_mint, &token)?;
        let output = associated_address(&owner, &output_mint, &token)?;
        let blockhash =
            Hash::from_str(&self.blockhash).map_err(|_| "Invalid Flash setup blockhash.")?;
        let mut instructions = Vec::new();
        if self.create_input {
            instructions.push(create_account(owner, input_mint, input, token)?);
        }
        if self.create_output {
            instructions.push(create_account(owner, output_mint, output, token)?);
        }
        if self.wrap {
            instructions.push(solana_system_interface::instruction::transfer(
                &owner, &input, amount,
            ));
            instructions.push(Instruction {
                program_id: token,
                accounts: vec![AccountMeta::new(input, false)],
                data: vec![17], // SyncNative
            });
        }
        if self.delegate {
            let mut data = vec![13]; // ApproveChecked
            data.extend(amount.to_le_bytes());
            data.push(self.decimals);
            instructions.push(Instruction {
                program_id: token,
                accounts: vec![
                    AccountMeta::new(input, false),
                    AccountMeta::new_readonly(input_mint, false),
                    AccountMeta::new_readonly(solana_key(DELEGATE)?, false),
                    AccountMeta::new_readonly(owner, true),
                ],
                data,
            });
        }
        let message = VersionedMessage::Legacy(Message::new_with_blockhash(
            &instructions,
            Some(&owner),
            &blockhash,
        ));
        let bytes = message.serialize();
        if bytes.len() > MAX_TRANSFER_MESSAGE_BYTES {
            return Err("Flash setup exceeds the Solana message size.");
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> Setup {
        Setup {
            funder: "FVen3X669xLzsi6N2V91DoiyzHzg1uAgqiT8jZ9nS96Z".into(),
            input_mint: WRAPPED_SOL.into(),
            output_mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".into(),
            blockhash: Hash::new_from_array([2; 32]).to_string(),
            amount: "1000000".into(),
            decimals: 9,
            create_input: true,
            create_output: true,
            delegate: true,
            wrap: true,
        }
    }

    #[test]
    fn setup_builds_only_wallet_owned_atas_wrapping_and_pinned_exact_delegation() {
        let plan = setup();
        let wire = plan.message().unwrap();
        let owner = solana_key(&plan.funder).unwrap();
        let token = solana_key(SPL_TOKEN_PROGRAM).unwrap();
        let mint = solana_key(WRAPPED_SOL).unwrap();
        let input = associated_address(&owner, &mint, &token).unwrap();
        let output_mint = solana_key(&plan.output_mint).unwrap();
        let output = associated_address(&owner, &output_mint, &token).unwrap();
        let transfer = solana_system_interface::instruction::transfer(&owner, &input, 1_000_000);
        assert!(wire.windows(32).any(|bytes| bytes == input.as_ref()));
        assert!(wire.windows(32).any(|bytes| bytes == output.as_ref()));
        assert!(wire
            .windows(32)
            .any(|bytes| bytes == solana_key(DELEGATE).unwrap().as_ref()));
        assert!(wire
            .windows(transfer.data.len())
            .any(|bytes| bytes == transfer.data));
        assert!(wire
            .windows(10)
            .any(|bytes| bytes == [13, 64, 66, 15, 0, 0, 0, 0, 0, 9]));
        let mut rejected = plan;
        std::mem::swap(&mut rejected.input_mint, &mut rejected.output_mint);
        assert!(rejected.message().is_err());
    }
}
