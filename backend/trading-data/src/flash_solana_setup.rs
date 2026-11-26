use super::{
    intent, rpc_error, solana_accounts, solana_setup_required, token_account, Error, Result, Rpc,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use trig_wallet_transfers::{
    flash::{Setup, DELEGATE, WRAPPED_SOL},
    solana_associated_address, SPL_TOKEN_PROGRAM,
};

pub(super) struct Funding {
    input: Value,
    output: Value,
    input_ata: String,
    amount: u64,
}

#[derive(PartialEq, Eq)]
pub(super) struct Actions {
    pub create_input: bool,
    pub create_output: bool,
    pub delegate: bool,
    pub wrap: bool,
}

impl Actions {
    pub(super) fn needed(&self) -> bool {
        self.create_input || self.create_output || self.delegate
    }
    fn created_accounts(&self) -> u64 {
        u64::from(self.create_input) + u64::from(self.create_output)
    }
    fn from_setup(setup: &Setup) -> Self {
        Self {
            create_input: setup.create_input,
            create_output: setup.create_output,
            delegate: setup.delegate,
            wrap: setup.wrap,
        }
    }
}

impl Funding {
    pub(super) async fn load(
        rpc: &Rpc,
        funder: &str,
        input: &str,
        output: &str,
        programs: [&str; 2],
    ) -> Result<Self> {
        let input_ata =
            solana_associated_address(funder, input, programs[0]).map_err(Error::invalid)?;
        let output_ata =
            solana_associated_address(funder, output, programs[1]).map_err(Error::invalid)?;
        let [input_account, output_account] =
            solana_accounts(rpc, [&input_ata, &output_ata]).await?;
        if !output_account.is_null() {
            token_account(&output_account, funder, output, programs[1])?;
        }
        let amount = if input_account.is_null() {
            0
        } else {
            token_account(&input_account, funder, input, programs[0])?["tokenAmount"]["amount"]
                .as_str()
                .and_then(|value| value.parse().ok())
                .ok_or_else(rpc_error)?
        };
        Ok(Self {
            input: input_account,
            output: output_account,
            input_ata,
            amount,
        })
    }

    pub(super) fn amount(&self) -> u64 {
        self.amount
    }

    pub(super) fn needed(&self, input_mint: &str, spend: u64) -> Result<Actions> {
        let account = &self.input["data"]["parsed"]["info"];
        let delegate = &account["delegate"];
        let wrap = input_mint == WRAPPED_SOL && self.amount == 0;
        if self.amount < spend && !wrap {
            return Err(Error::invalid(
                "The wallet’s token balance does not cover this order.",
            ));
        }
        if wrap && !self.input.is_null() {
            let rent = account["rentExemptReserve"]["amount"]
                .as_str()
                .and_then(|v| v.parse::<u64>().ok())
                .ok_or_else(solana_setup_required)?;
            if account["isNative"].as_bool() != Some(true)
                || self.input["lamports"].as_u64() != Some(rent)
            {
                return Err(solana_setup_required());
            }
        }
        // A setup cannot replace an existing authorization, including a smaller Flash delegation.
        let delegate = if delegate.is_null() {
            true
        } else if delegate == DELEGATE
            && !wrap
            && account["delegatedAmount"]["amount"]
                .as_str()
                .and_then(|value| value.parse::<u64>().ok())
                .is_some_and(|amount| amount >= spend)
        {
            false
        } else {
            return Err(Error::invalid(
                "This token already has a delegation that cannot be replaced here.",
            ));
        };
        Ok(Actions {
            create_input: self.input.is_null(),
            create_output: self.output.is_null(),
            delegate,
            wrap,
        })
    }

    pub(super) fn validate_quote(
        &self,
        response: &Value,
        actions: &Actions,
        funder: &str,
        spend: u64,
    ) -> Result<()> {
        let svm = &response["svm"];
        if !svm["sponsoredDelegateTx"].is_null()
            || (!response["wrap"].is_null()) != actions.wrap
            || (!svm["delegateIx"].is_null()) != actions.delegate
        {
            return Err(solana_setup_required());
        }
        if actions.delegate {
            let instruction = &svm["delegateIx"];
            let keys = instruction["accounts"]
                .as_array()
                .filter(|items| items.len() == 3)
                .ok_or_else(solana_setup_required)?;
            let expected = [self.input_ata.as_str(), DELEGATE, funder];
            let encoded = instruction["data"]
                .as_str()
                .filter(|text| text.len() <= 18)
                .ok_or_else(solana_setup_required)?;
            let bytes = bs58::decode(encoded)
                .into_vec()
                .map_err(|_| solana_setup_required())?;
            // Flash's SPL Approve must request the same amount. tRig upgrades it to
            // ApproveChecked with the resolved mint/decimals when building the actual message.
            if instruction["programId"] != SPL_TOKEN_PROGRAM
                || keys
                    .iter()
                    .zip(expected)
                    .any(|(key, address)| key["pubkey"] != address)
                || bytes.first() != Some(&4)
                || bytes.get(1..) != Some(&spend.to_le_bytes())
            {
                return Err(solana_setup_required());
            }
        }
        Ok(())
    }
}

async fn native_balance(rpc: &Rpc, funder: &str) -> Result<u64> {
    rpc.call("getBalance", json!([funder, {"commitment":"confirmed"}]))
        .await
        .map_err(|_| rpc_error())?["value"]
        .as_u64()
        .ok_or_else(rpc_error)
}

async fn cost(rpc: &Rpc, plan: &Setup, message: &[u8]) -> Result<(u64, u64, u64)> {
    let actions = Actions::from_setup(plan);
    let rent = async {
        if actions.created_accounts() == 0 {
            return Ok(0);
        }
        rpc.call(
            "getMinimumBalanceForRentExemption",
            json!([165, {"commitment":"confirmed"}]),
        )
        .await
        .map_err(|_| rpc_error())?
        .as_u64()
        .and_then(|lamports| lamports.checked_mul(actions.created_accounts()))
        .filter(|lamports| *lamports > 0)
        .ok_or_else(rpc_error)
    };
    let fee = async {
        rpc.call(
            "getFeeForMessage",
            json!([STANDARD.encode(message), {"commitment":"confirmed"}]),
        )
        .await
        .map_err(|_| rpc_error())?["value"]
            .as_u64()
            .filter(|lamports| *lamports > 0)
            .ok_or_else(rpc_error)
    };
    let (rent, fee, balance) = tokio::try_join!(rent, fee, native_balance(rpc, &plan.funder))?;
    let deposit = if actions.wrap {
        plan.amount_units().map_err(Error::invalid)?
    } else {
        0
    };
    if rent
        .checked_add(fee)
        .and_then(|lamports| lamports.checked_add(deposit))
        .is_none_or(|total| total > balance)
    {
        return Err(Error::invalid(
            "The SOL balance does not cover this setup, its fees, and any wrapping.",
        ));
    }
    Ok((rent, fee, balance))
}

pub(super) async fn prepare(
    rpc: &Rpc,
    order: &intent::SolanaPlan,
    actions: Actions,
    decimals: u8,
) -> Result<(intent::SolanaSetupPlan, u64)> {
    let latest = rpc
        .call("getLatestBlockhash", json!([{"commitment":"confirmed"}]))
        .await
        .map_err(|_| rpc_error())?;
    let info = &latest["value"];
    let setup = Setup {
        funder: order.funder.clone(),
        input_mint: order.from_token.clone(),
        output_mint: order.to_token.clone(),
        amount: order.from_amount.clone(),
        decimals,
        blockhash: info["blockhash"].as_str().ok_or_else(rpc_error)?.into(),
        create_input: actions.create_input,
        create_output: actions.create_output,
        delegate: actions.delegate,
        wrap: actions.wrap,
    };
    let message = setup.message().map_err(Error::invalid)?;
    let mut wire = vec![0; 65];
    wire[0] = 1; // A single placeholder signature for simulation only.
    wire.extend(&message);
    let simulation = rpc.call(
        "simulateTransaction",
        json!([STANDARD.encode(wire), {"encoding":"base64","commitment":"confirmed","sigVerify":false}]),
    ).await.map_err(|_| rpc_error())?;
    if simulation["value"].get("err") != Some(&Value::Null) {
        return Err(solana_setup_required());
    }
    let (rent_lamports, fee_lamports, balance) = cost(rpc, &setup, &message).await?;
    let plan = intent::SolanaSetupPlan {
        plan_id: order.plan_id.clone(),
        setup,
        expires_at: order.expires_at,
        last_valid_block_height: info["lastValidBlockHeight"]
            .as_u64()
            .ok_or_else(rpc_error)?,
        fee_lamports,
        rent_lamports,
    };
    Ok((plan, balance))
}

pub(super) async fn submit(
    rpc: &Rpc,
    plan: intent::SolanaSetupPlan,
    signed: &str,
    transaction_id: &str,
) -> Result<()> {
    let message = plan.message(crate::now()).map_err(Error::invalid)?;
    let wire = STANDARD
        .decode(signed)
        .map_err(|_| Error::invalid("Invalid signed Flash setup."))?;
    if wire.len() != 65 + message.len()
        || wire[0] != 1
        || wire[65..] != message
        || bs58::encode(&wire[1..65]).into_string() != transaction_id
    {
        return Err(Error::invalid(
            "The signed transaction differs from the reviewed Flash setup.",
        ));
    }
    let current = Funding::load(
        rpc,
        &plan.setup.funder,
        &plan.setup.input_mint,
        &plan.setup.output_mint,
        [SPL_TOKEN_PROGRAM, SPL_TOKEN_PROGRAM],
    )
    .await?;
    let amount = plan.setup.amount_units().map_err(Error::invalid)?;
    let expected = Actions::from_setup(&plan.setup);
    let current = current.needed(&plan.setup.input_mint, amount)?;
    let (rent, fee, _) = cost(rpc, &plan.setup, &message).await?;
    if current != expected
        || rent != plan.rent_lamports
        || fee != plan.fee_lamports
        || plan.expires_at <= crate::now()
    {
        return Err(Error::invalid(
            "The wallet or fee estimate changed. Review a fresh Flash setup.",
        ));
    }
    let result = rpc
        .call(
            "sendTransaction",
            json!([signed, {
                "encoding":"base64","preflightCommitment":"confirmed","maxRetries":0
            }]),
        )
        .await
        .map_err(|_| rpc_error())?;
    if result.as_str() != Some(transaction_id) {
        return Err(rpc_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPL_MINT: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    const OWNER: &str = "FVen3X669xLzsi6N2V91DoiyzHzg1uAgqiT8jZ9nS96Z";
    const SOURCE: &str = "HU2S9ByyqbnCD2SVfvr9qoLtDTtyTnMZoMaw1xpr6cTb";

    #[test]
    fn flash_solana_setup_preserves_existing_delegations() {
        let mut funding = Funding {
            input: json!({"data":{"parsed":{"info":{
                "delegate": DELEGATE, "delegatedAmount": {"amount":"100"}
            }}}}),
            output: Value::Null,
            input_ata: SOURCE.into(),
            amount: 1000,
        };
        let funded = funding.needed(SPL_MINT, 100).unwrap();
        assert!(funded.create_output);
        assert!(!funded.delegate);
        assert!(funding.needed(SPL_MINT, 101).is_err());
        funding.input["data"]["parsed"]["info"]["delegate"] = json!(OWNER);
        assert!(funding.needed(SPL_MINT, 1).is_err());
    }

    #[test]
    fn flash_solana_setup_accepts_only_exact_delegation_to_the_pinned_program() {
        let funding = Funding {
            input: json!({}),
            output: Value::Null,
            input_ata: SOURCE.into(),
            amount: 1000,
        };
        let actions = funding.needed(SPL_MINT, 100).unwrap();
        let mut data = vec![4];
        data.extend(100u64.to_le_bytes());
        let mut quote = json!({"svm":{"delegateIx":{
            "programId": SPL_TOKEN_PROGRAM,
            "accounts":[{"pubkey":SOURCE}, {"pubkey":DELEGATE}, {"pubkey":OWNER}],
            "data":bs58::encode(data).into_string(),
        }}});
        assert!(funding.validate_quote(&quote, &actions, OWNER, 100).is_ok());
        assert!(funding.validate_quote(&quote, &actions, OWNER, 50).is_err());
        quote["svm"]["delegateIx"]["accounts"][1]["pubkey"] = json!(OWNER);
        assert!(funding
            .validate_quote(&quote, &actions, OWNER, 100)
            .is_err());
    }
}
