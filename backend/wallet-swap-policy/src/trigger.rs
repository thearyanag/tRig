use super::{
    decode, Address, Result, Signature, VersionedTransaction, ASSOCIATED_TOKEN, COMPUTE_BUDGET,
    SOL, SYSTEM, TOKEN,
};
use serde::{Deserialize, Serialize};
use solana_system_interface::instruction::SystemInstruction;
use std::{collections::HashSet, str::FromStr};

const MAX_NETWORK_LAMPORTS: u64 = 50_000_000;
const COMPUTE_UNIT_LIMIT: u32 = 1_400_000;
const SIGNATURE_FEE_LAMPORTS: u64 = 5_000;
const MAX_CHALLENGE_SECONDS: u64 = 305;
const MAX_CONSENT_SECONDS: u64 = 120;
const MAX_REVIEW_SECONDS: u64 = 90;
const MEMO: &str = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr";
const MEMO_LEGACY: &str = "Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo";
const RENT: &str = "SysvarRent111111111111111111111111111111111";

fn address(value: &str) -> Result<Address> {
    if !(32..=44).contains(&value.len()) {
        return Err("Invalid Jupiter Trigger account.");
    }
    value
        .parse()
        .map_err(|_| "Invalid Jupiter Trigger account.")
}

pub fn canonical_order_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(position, byte)| {
            if matches!(position, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')
            }
        })
}

pub fn challenge_expires_at(wallet: &str, challenge: &str, now: u64) -> Result<u64> {
    address(wallet)?;
    let invalid = "Jupiter returned an invalid or expired wallet login challenge.";
    let prefix = format!(
        "Sign this message to authenticate with Jupiter that you are the owner of {wallet}.\n\n"
    );
    let data = challenge.strip_prefix(&prefix).ok_or(invalid)?;
    let data = data.strip_prefix(' ').unwrap_or(data);
    let (timestamp, nonce) = data
        .strip_prefix("This challenge expires at ")
        .ok_or(invalid)?
        .split_once(" with the nonce of ")
        .ok_or(invalid)?;
    if !timestamp.ends_with('Z')
        || timestamp.len() > 30
        || !canonical_order_id(nonce.strip_suffix('.').ok_or(invalid)?)
    {
        return Err(invalid);
    }
    let expires_at = chrono::DateTime::parse_from_rfc3339(timestamp)
        .ok()
        .and_then(|date| u64::try_from(date.timestamp()).ok())
        .ok_or(invalid)?;
    if expires_at <= now || expires_at > now.saturating_add(MAX_CHALLENGE_SECONDS) {
        return Err(invalid);
    }
    Ok(expires_at)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthPlan {
    pub wallet: String,
    pub challenge: String,
    pub expires_at: u64,
}

impl AuthPlan {
    pub fn message_at(&self, now: u64) -> Result<&str> {
        let expires_at = challenge_expires_at(&self.wallet, &self.challenge, now)?;
        if self.expires_at <= now || self.expires_at > expires_at {
            return Err("Review a fresh Jupiter login challenge.");
        }
        Ok(&self.challenge)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CancelConsent {
    pub wallet: String,
    pub order_id: String,
    pub expires_at: u64,
    pub nonce: String,
}

impl CancelConsent {
    pub fn message_at(&self, now: u64) -> Result<String> {
        address(&self.wallet)?;
        if !canonical_order_id(&self.order_id)
            || !(16..=64).contains(&self.nonce.len())
            || !self
                .nonce
                .bytes()
                .all(|b| b.is_ascii_hexdigit() || b == b'-')
            || !self.nonce.bytes().any(|b| b.is_ascii_hexdigit())
            || self.expires_at <= now
            || self.expires_at > now.saturating_add(MAX_CONSENT_SECONDS)
        {
            return Err("Review a fresh Jupiter order cancellation.");
        }
        Ok(format!(
            "tRig Jupiter Trigger v2 cancellation\nWallet: {}\nOrder: {}\nExpires: {}\nNonce: {}",
            self.wallet, self.order_id, self.expires_at, self.nonce
        ))
    }
}

pub fn verify_message(wallet: &str, message: &[u8], signature: &str) -> Result<()> {
    let wallet = address(wallet)?;
    let sig = Signature::from_str(signature).map_err(|_| "Invalid Jupiter Trigger signature.")?;
    if !sig.verify(wallet.as_ref(), message) {
        return Err("The signature does not belong to this Jupiter Trigger wallet.");
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TransferDirection {
    Deposit,
    Withdrawal,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TransferPlan {
    pub wallet: String,
    pub vault: String,
    pub mint: String,
    pub order_token_account: String,
    pub amount: String,
    pub decimals: u8,
    pub transaction: String,
    pub expires_at: u64,
    pub direction: TransferDirection,
    pub fee_lamports: u64,
    pub rent_lamports: u64,
}

pub struct ReviewedTransfer {
    pub transaction: VersionedTransaction,
    pub signer_index: usize,
    pub seeded_rent_lamports: u64,
    pub ata_creations: Vec<String>,
    minimum_fee_lamports: u64,
}

struct TransferAccounts {
    wallet: Address,
    vault: Address,
    mint: Address,
    order: Address,
    wallet_token: Address,
    vault_token: Address,
    token: Address,
    system: Address,
    rent: Address,
    native: bool,
}

impl TransferAccounts {
    fn new(plan: &TransferPlan) -> Result<Self> {
        let token = address(TOKEN)?;
        let system = address(SYSTEM)?;
        let wallet = address(&plan.wallet)?;
        let vault = address(&plan.vault)?;
        let mint = address(&plan.mint)?;
        let order = address(&plan.order_token_account)?;
        let wallet_token = address(&trig_wallet_transfers::spl_recipient_address(
            &plan.wallet,
            &plan.mint,
        )?)?;
        let vault_token = address(&trig_wallet_transfers::spl_recipient_address(
            &plan.vault,
            &plan.mint,
        )?)?;
        if wallet == vault
            || [wallet, vault, mint, wallet_token, token, system].contains(&order)
            || [token, system].contains(&wallet)
            || [token, system].contains(&vault)
        {
            return Err("The Jupiter wallet, vault, or order account is invalid.");
        }
        Ok(Self {
            wallet,
            vault,
            mint,
            order,
            wallet_token,
            vault_token,
            token,
            system,
            rent: address(RENT)?,
            native: plan.mint == SOL,
        })
    }
}

#[derive(Default)]
struct TransferEffects {
    compute_limit: Option<u32>,
    compute_price: Option<u64>,
    seeded_rent: Option<u64>,
    initialized_owner: Option<Address>,
    created_atas: Vec<Address>,
    wrapped: Option<Address>,
    did_sync: bool,
    token_transfer: bool,
    closed_order: bool,
    closed_wallet_token: bool,
}

impl TransferEffects {
    fn compute(&mut self, accounts: &[Address], data: &[u8]) -> Result<()> {
        if !accounts.is_empty() {
            return Err("Unexpected account in Jupiter fee instruction.");
        }
        match data {
            [2, limit @ ..] if limit.len() == 4 && self.compute_limit.is_none() => {
                let limit = u32::from_le_bytes(limit.try_into().unwrap());
                if !(1..=COMPUTE_UNIT_LIMIT).contains(&limit) {
                    return Err("The Jupiter compute limit exceeds the supported amount.");
                }
                self.compute_limit = Some(limit);
            }
            [3, price @ ..] if price.len() == 8 && self.compute_price.is_none() => {
                self.compute_price = Some(u64::from_le_bytes(price.try_into().unwrap()));
            }
            _ => return Err("Unsupported Jupiter fee instruction."),
        }
        Ok(())
    }

    fn minimum_fee(&self, signature_count: usize) -> Result<u64> {
        let price = self.compute_price.unwrap_or(0);
        let limit = if price == 0 {
            0
        } else {
            self.compute_limit
                .ok_or("The Jupiter priority fee has no explicit compute limit.")?
        };
        let priority = (u128::from(price) * u128::from(limit)).div_ceil(1_000_000);
        let fee = u128::from(SIGNATURE_FEE_LAMPORTS) * signature_count as u128 + priority;
        u64::try_from(fee).map_err(|_| "The Jupiter network fee is too high.")
    }

    fn associated_token(
        &mut self,
        ix: &[Address],
        data: &[u8],
        keys: &TransferAccounts,
    ) -> Result<()> {
        if !matches!(data, [] | [0] | [1]) {
            return Err("Unsupported associated token account instruction.");
        }
        let [payer, token_account, owner, mint, system, token, remaining @ ..] = ix else {
            return Err("Invalid Jupiter associated token account instruction.");
        };
        let owner_matches = (*owner == keys.wallet && *token_account == keys.wallet_token)
            || (*owner == keys.vault
                && *token_account == keys.vault_token
                && *token_account == keys.order);
        if *payer != keys.wallet
            || !owner_matches
            || *mint != keys.mint
            || *system != keys.system
            || *token != keys.token
            || !(remaining.is_empty() || remaining == [keys.rent])
            || self.created_atas.contains(token_account)
        {
            return Err("The Jupiter transaction would create an unexpected token account.");
        }
        self.created_atas.push(*token_account);
        Ok(())
    }

    fn system(
        &mut self,
        ix: &[Address],
        data: &[u8],
        amount: u64,
        keys: &TransferAccounts,
        vault_cosigner: bool,
    ) -> Result<()> {
        let instruction: SystemInstruction =
            bincode::deserialize(data).map_err(|_| "Invalid Jupiter system instruction.")?;
        if bincode::serialize(&instruction).ok().as_deref() != Some(data) {
            return Err("Noncanonical Jupiter system instruction.");
        }
        match instruction {
            SystemInstruction::CreateAccountWithSeed {
                base,
                seed,
                lamports,
                space,
                owner,
            } if self.seeded_rent.is_none()
                && owner == keys.token
                && (base == keys.wallet || vault_cosigner && base == keys.vault)
                && (ix == [keys.wallet, keys.order, base]
                    || base == keys.wallet && ix == [keys.wallet, keys.order])
                && space == 165
                && (1..=MAX_NETWORK_LAMPORTS).contains(&lamports) =>
            {
                if Address::create_with_seed(&base, &seed, &owner).ok() != Some(keys.order)
                    || self.created_atas.contains(&keys.order)
                    || keys.order == keys.vault_token
                {
                    return Err("The Jupiter order account was derived from unexpected inputs.");
                }
                self.seeded_rent = Some(lamports);
                Ok(())
            }
            SystemInstruction::Transfer { lamports }
                if keys.native
                    && lamports == amount
                    && self.wrapped.is_none()
                    && (ix == [keys.wallet, keys.wallet_token]
                        || ix == [keys.wallet, keys.order]
                            && self.initialized_owner == Some(keys.vault)) =>
            {
                self.wrapped = Some(ix[1]);
                Ok(())
            }
            _ => Err("The Jupiter transaction contains an unexpected SOL debit."),
        }
    }

    fn token(
        &mut self,
        ix: &[Address],
        data: &[u8],
        amount: u64,
        decimals: u8,
        direction: TransferDirection,
        keys: &TransferAccounts,
    ) -> Result<()> {
        let deposit = direction == TransferDirection::Deposit;
        match data {
            [1] if deposit => {
                let [order, mint, owner, rent] = ix else {
                    return Err("Invalid Jupiter token account initializer.");
                };
                if *rent != keys.rent {
                    return Err("Invalid Jupiter token account initializer.");
                }
                self.initialize(keys, *order, *mint, *owner)?;
            }
            [16 | 18, owner @ ..] if deposit && owner.len() == 32 => {
                let owner = Address::new_from_array(owner.try_into().unwrap());
                let (order, mint) = match (data[0], ix) {
                    (16, [order, mint, rent]) if *rent == keys.rent => (*order, *mint),
                    (18, [order, mint]) => (*order, *mint),
                    _ => return Err("Invalid Jupiter token account initializer."),
                };
                self.initialize(keys, order, mint, owner)?;
            }
            [6, 2, 1, new_owner @ ..]
                if deposit
                    && new_owner == keys.vault.as_ref()
                    && ix == [keys.order, keys.wallet]
                    && self.initialized_owner == Some(keys.wallet) =>
            {
                self.initialized_owner = Some(keys.vault);
            }
            [3, units @ ..] if units.len() == 8 => {
                self.transfer(ix, units, amount, false, direction, keys)?;
            }
            [12, units @ .., d] if units.len() == 8 && *d == decimals => {
                self.transfer(ix, units, amount, true, direction, keys)?;
            }
            [17] if deposit
                && keys.native
                && !self.did_sync
                && self.wrapped.is_some_and(|account| ix == [account]) =>
            {
                self.did_sync = true;
            }
            [9] if !deposit
                && ix == [keys.order, keys.wallet, keys.vault]
                && !self.closed_order
                && (keys.native || self.token_transfer) =>
            {
                self.closed_order = true;
            }
            [9] if keys.native
                && ix == [keys.wallet_token, keys.wallet, keys.wallet]
                && self.created_atas.contains(&keys.wallet_token)
                && self.token_transfer
                && !self.closed_wallet_token =>
            {
                self.closed_wallet_token = true;
            }
            _ => return Err("The Jupiter transaction contains an unexpected token instruction."),
        }
        Ok(())
    }

    fn initialize(
        &mut self,
        keys: &TransferAccounts,
        order: Address,
        mint: Address,
        owner: Address,
    ) -> Result<()> {
        if self.seeded_rent.is_none()
            || self.initialized_owner.is_some()
            || order != keys.order
            || mint != keys.mint
            || (owner != keys.vault && owner != keys.wallet)
        {
            return Err("The Jupiter transaction initializes an unexpected order account.");
        }
        self.initialized_owner = Some(owner);
        Ok(())
    }

    fn transfer(
        &mut self,
        ix: &[Address],
        units: &[u8],
        amount: u64,
        checked: bool,
        direction: TransferDirection,
        keys: &TransferAccounts,
    ) -> Result<()> {
        let expected = match direction {
            TransferDirection::Deposit => [keys.wallet_token, keys.order, keys.wallet],
            TransferDirection::Withdrawal => [keys.order, keys.wallet_token, keys.vault],
        };
        let exact_accounts = if checked {
            ix == [expected[0], keys.mint, expected[1], expected[2]]
        } else {
            ix == expected
        };
        if self.token_transfer
            || self.closed_order
            || self.closed_wallet_token
            || !exact_accounts
            || u64::from_le_bytes(units.try_into().unwrap()) != amount
            || self
                .wrapped
                .is_some_and(|account| account != keys.wallet_token || !self.did_sync)
        {
            return Err(
                "The Jupiter transfer does not match the reviewed token, accounts, or amount.",
            );
        }
        self.token_transfer = true;
        Ok(())
    }

    fn verify_principal(
        &self,
        keys: &TransferAccounts,
        direction: TransferDirection,
    ) -> Result<()> {
        match direction {
            TransferDirection::Deposit => {
                let controlled_order_account = if self.seeded_rent.is_some() {
                    self.initialized_owner == Some(keys.vault)
                } else {
                    keys.order == keys.vault_token
                };
                let received_deposit = match self.wrapped {
                    None => self.token_transfer,
                    Some(account) if account == keys.wallet_token => {
                        self.did_sync && self.token_transfer
                    }
                    Some(account) => account == keys.order && self.did_sync && !self.token_transfer,
                };
                if !controlled_order_account || !received_deposit {
                    return Err("The deposit does not fund the reviewed Jupiter vault and order.");
                }
            }
            TransferDirection::Withdrawal => {
                if !(self.token_transfer || keys.native && self.closed_order) {
                    return Err("The withdrawal does not return funds to the reviewed wallet.");
                }
            }
        }
        Ok(())
    }
}

impl TransferPlan {
    pub fn inspect_at(&self, now: u64) -> Result<ReviewedTransfer> {
        let keys = TransferAccounts::new(self)?;
        let amount = self
            .amount
            .parse::<u64>()
            .map_err(|_| "Invalid Jupiter Trigger amount.")?;
        if amount == 0
            || amount.to_string() != self.amount
            || self.expires_at <= now
            || self.expires_at > now.saturating_add(MAX_REVIEW_SECONDS)
            || keys.native && self.decimals != 9
        {
            return Err("Review a fresh Jupiter Trigger transfer.");
        }
        let transaction = decode(&self.transaction)?;
        let account_keys = transaction.message.static_account_keys();
        let header = transaction.message.header();
        let signer_count = usize::from(header.num_required_signatures);
        let wallet_signer = signer_count == 1 && account_keys.first() == Some(&keys.wallet);
        let vault_cosigner =
            signer_count == 2 && account_keys.get(..2) == Some(&[keys.wallet, keys.vault]);
        if !(wallet_signer || vault_cosigner)
            || self.direction == TransferDirection::Withdrawal && !vault_cosigner
            || header.num_readonly_signed_accounts >= header.num_required_signatures
            || transaction.signatures.len() != signer_count
            || transaction.signatures[0] != Signature::default()
            || transaction
                .message
                .address_table_lookups()
                .is_some_and(|tables| !tables.is_empty())
            || account_keys.iter().collect::<HashSet<_>>().len() != account_keys.len()
        {
            return Err(
                "The Jupiter transfer has an unexpected fee payer, signer, or lookup table.",
            );
        }
        let message = transaction.message.serialize();
        if vault_cosigner
            && transaction.signatures[1] != Signature::default()
            && !transaction.signatures[1].verify(keys.vault.as_ref(), &message)
        {
            return Err("The existing Jupiter vault signature is invalid.");
        }
        let mut effects = TransferEffects::default();
        for ix in transaction.message.instructions() {
            let program = account_keys
                .get(usize::from(ix.program_id_index))
                .ok_or("The Jupiter program account is missing.")?
                .to_string();
            let accounts = ix
                .accounts
                .iter()
                .map(|index| {
                    account_keys
                        .get(usize::from(*index))
                        .copied()
                        .ok_or("The Jupiter instruction account is missing.")
                })
                .collect::<Result<Vec<_>>>()?;
            let data = ix.data.as_slice();
            match program.as_str() {
                COMPUTE_BUDGET => effects.compute(&accounts, data)?,
                ASSOCIATED_TOKEN => {
                    if self.direction == TransferDirection::Withdrawal
                        && accounts.get(2) != Some(&keys.wallet)
                    {
                        return Err("The withdrawal creates a token account for another wallet.");
                    }
                    effects.associated_token(&accounts, data, &keys)?;
                }
                SYSTEM if self.direction == TransferDirection::Deposit => {
                    effects.system(&accounts, data, amount, &keys, vault_cosigner)?
                }
                TOKEN => effects.token(
                    &accounts,
                    data,
                    amount,
                    self.decimals,
                    self.direction,
                    &keys,
                )?,
                MEMO | MEMO_LEGACY
                    if data.len() <= 256
                        && std::str::from_utf8(data).is_ok()
                        && accounts
                            .iter()
                            .all(|a| *a == keys.wallet || vault_cosigner && *a == keys.vault) => {}
                _ => {
                    return Err("The Jupiter transfer contains an unsupported program instruction.")
                }
            }
        }
        effects.verify_principal(&keys, self.direction)?;
        let minimum_fee_lamports = effects.minimum_fee(signer_count)?;
        let seeded_rent_lamports = effects.seeded_rent.unwrap_or(0);
        if minimum_fee_lamports.saturating_add(seeded_rent_lamports) > MAX_NETWORK_LAMPORTS {
            return Err("The Jupiter transfer exceeds the supported network cost.");
        }
        Ok(ReviewedTransfer {
            transaction,
            signer_index: 0,
            seeded_rent_lamports,
            ata_creations: effects
                .created_atas
                .into_iter()
                .map(|a| a.to_string())
                .collect(),
            minimum_fee_lamports,
        })
    }

    pub fn review_at(&self, now: u64) -> Result<ReviewedTransfer> {
        let reviewed = self.inspect_at(now)?;
        if self.fee_lamports < reviewed.minimum_fee_lamports
            || self.rent_lamports < reviewed.seeded_rent_lamports
            || (reviewed.ata_creations.is_empty()
                && self.rent_lamports != reviewed.seeded_rent_lamports)
            || (!reviewed.ata_creations.is_empty()
                && self.rent_lamports == reviewed.seeded_rent_lamports)
            || (self.fee_lamports.saturating_add(self.rent_lamports) > MAX_NETWORK_LAMPORTS)
        {
            return Err("The Jupiter transfer exceeds the reviewed fee or rent.");
        }
        Ok(reviewed)
    }
}

pub fn validate_transfer_signed(
    plan: &TransferPlan,
    signed_base64: &str,
    tx_id: &str,
    now: u64,
) -> Result<()> {
    let reviewed = plan.review_at(now)?;
    let signed = decode(signed_base64)?;
    let wallet = address(&plan.wallet)?;
    let signature = signed
        .signatures
        .first()
        .ok_or("The Jupiter transfer has no wallet signature.")?;
    if signed.message != reviewed.transaction.message
        || signed.signatures.get(1..) != reviewed.transaction.signatures.get(1..)
        || signature.to_string() != tx_id
        || !signature.verify(wallet.as_ref(), &signed.message.serialize())
    {
        return Err("The signature does not authorize the reviewed Jupiter transfer.");
    }
    Ok(())
}
