use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use trig_wallet_transfers::{solana_associated_address, SplTokenProgram};

pub const SETTLEMENT: &str = "0x5d00000873b6BF41539e6f5365B0Ff7d3c368f78";
pub const SOLANA_PROGRAM: &str = "FLaSHxRVv6G1NCJ2SFGPvQqKUPszuDjaTkBMFCSzEqpJ";
pub const DOMAIN_TYPE: &str =
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
pub const ORDER_TYPE: &str =
    "FlashOrder(address swapper,address vault,address recipient,address fromToken,address toToken,uint256 fromAmount,uint256 salt,uint256 deadline)";

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Plan {
    pub plan_id: String,
    pub chain_id: u64,
    pub funder: String,
    pub from_token: String,
    pub to_token: String,
    pub from_amount: String,
    pub order_deadline: u64,
    pub expires_at: u64,
    pub typed_data: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub enum OrderPlan {
    Evm(Plan),
    Solana(SolanaPlan),
}

impl OrderPlan {
    pub fn validate(&self, now: u64) -> Result<(), &'static str> {
        match self {
            Self::Evm(plan) => plan.validate(now).map(|_| ()),
            Self::Solana(plan) => plan.validate(now),
        }
    }

    pub fn expires_at(&self) -> u64 {
        match self {
            Self::Evm(plan) => plan.expires_at,
            Self::Solana(plan) => plan.expires_at,
        }
    }

    pub fn order_deadline(&self) -> u64 {
        match self {
            Self::Evm(plan) => plan.order_deadline,
            Self::Solana(plan) => plan.order_deadline,
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SolanaPlan {
    pub plan_id: String,
    pub funder: String,
    pub from_token: String,
    pub to_token: String,
    pub from_amount: String,
    pub order_deadline: u64,
    pub expires_at: u64,
    pub order_message: String,
    pub nonce: String,
    pub trading_group: String,
    pub input_program: String,
    pub output_program: String,
}

fn pubkey(address: &str) -> Result<[u8; 32], &'static str> {
    if address.len() > 44 {
        return Err("Invalid Solana Flash public key.");
    }
    bs58::decode(address)
        .into_vec()
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or("Invalid Solana Flash public key.")
}

impl SolanaPlan {
    pub fn validate(&self, now: u64) -> Result<(), &'static str> {
        let amount = self
            .from_amount
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or("Invalid Solana Flash amount.")?;
        let nonce = self
            .nonce
            .parse::<u64>()
            .map_err(|_| "Invalid Flash order nonce.")?;
        if self.plan_id.len() != 36
            || self.order_message.len() > 128
            || self.from_amount != amount.to_string()
            || self.nonce != nonce.to_string()
            || self.expires_at <= now
            || self.expires_at > now.saturating_add(120)
            || self.order_deadline <= self.expires_at
            || self.order_deadline > now.saturating_add(86_400)
            || self.from_token == self.to_token
            || SplTokenProgram::from_id(&self.input_program).is_none()
            || SplTokenProgram::from_id(&self.output_program).is_none()
        {
            return Err("Invalid or expired Solana Flash order review.");
        }
        let input = solana_associated_address(&self.funder, &self.from_token, &self.input_program)?;
        let output = solana_associated_address(&self.funder, &self.to_token, &self.output_program)?;
        let mut hash = Sha256::new();
        hash.update(b"DFS_ORDER_V1");
        hash.update(pubkey(&output)?);
        hash.update(nonce.to_le_bytes());
        hash.update(self.order_deadline.to_le_bytes());
        hash.update(pubkey(&input)?);
        hash.update(pubkey(SOLANA_PROGRAM)?);
        hash.update(pubkey(&self.trading_group)?);
        let digest = bs58::encode(&hash.finalize()[..16]).into_string();
        let message = format!("DFS|m={}|t={amount}|h={digest}", self.from_token);
        if self.order_message != message {
            return Err("The Solana Flash commitment differs from the reviewed order.");
        }
        Ok(())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ApprovalPlan {
    pub plan_id: String,
    pub chain_id: u64,
    pub funder: String,
    pub token: String,
    pub amount: String,
    pub nonce: String,
    pub gas_price: String,
    pub gas_limit: String,
    pub fee: String,
    pub expires_at: u64,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SolanaSetupPlan {
    pub plan_id: String,
    pub setup: trig_wallet_transfers::flash::Setup,
    pub expires_at: u64,
    pub last_valid_block_height: u64,
    pub fee_lamports: u64,
    pub rent_lamports: u64,
}

impl SolanaSetupPlan {
    pub fn message(&self, now: u64) -> Result<Vec<u8>, &'static str> {
        if self.plan_id.len() != 36
            || self.expires_at <= now
            || self.expires_at > now.saturating_add(60)
            || self.last_valid_block_height == 0
            || self.fee_lamports == 0
            || (self.setup.create_input || self.setup.create_output) != (self.rent_lamports > 0)
        {
            return Err("Review a fresh Flash setup transaction.");
        }
        self.setup.message()
    }
}

impl ApprovalPlan {
    pub fn validate(&self, now: u64) -> Result<(), &'static str> {
        if self.plan_id.len() != 36
            || self.chain_id == 0
            || !address(&self.funder)
            || !address(&self.token)
            || !uint(&self.amount)
            || !uint(&self.fee)
            || self.expires_at <= now
            || self.expires_at > now.saturating_add(120)
        {
            return Err("Invalid or expired Flash approval review.");
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TypedOrder {
    types: Value,
    primary_type: String,
    domain: Domain,
    message: Message,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Domain {
    name: String,
    version: String,
    chain_id: String,
    verifying_contract: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Message {
    pub swapper: String,
    pub vault: String,
    pub recipient: String,
    pub from_token: String,
    pub to_token: String,
    pub from_amount: String,
    pub salt: String,
    pub deadline: String,
}

pub fn address(value: &str) -> bool {
    value.len() == 42
        && value.starts_with("0x")
        && value[2..].bytes().all(|b| b.is_ascii_hexdigit())
        && value[2..].bytes().any(|b| b != b'0')
}

fn uint(value: &str) -> bool {
    const MAX: &str =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    !value.is_empty()
        && value.bytes().all(|b| b.is_ascii_digit())
        && !value.starts_with('0')
        && (value.len() < MAX.len() || value.len() == MAX.len() && value <= MAX)
}

impl Plan {
    pub fn validate(&self, now: u64) -> Result<Message, &'static str> {
        if self.plan_id.is_empty()
            || self.plan_id.len() > 128
            || !self
                .plan_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
            || self.chain_id == 0
            || self.expires_at <= now
            || self.expires_at > now.saturating_add(120)
            || self.order_deadline <= self.expires_at
            || self.order_deadline > now.saturating_add(86_400)
            || self.typed_data.len() > 5000
            || ![&self.funder, &self.from_token, &self.to_token]
                .iter()
                .all(|v| address(v))
            || self.from_token.eq_ignore_ascii_case(&self.to_token)
            || !uint(&self.from_amount)
        {
            return Err("Invalid or expired Flash order review.");
        }
        let order: TypedOrder = serde_json::from_str(&self.typed_data)
            .map_err(|_| "Unrecognized Flash order authorization.")?;
        let expected_types = json!({
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
        });
        let message = order.message;
        if order.types != expected_types
            || order.primary_type != "FlashOrder"
            || order.domain.name != "DefinitiveFlashAllowance"
            || order.domain.version != "1"
            || order.domain.chain_id != self.chain_id.to_string()
            || !order
                .domain
                .verifying_contract
                .eq_ignore_ascii_case(SETTLEMENT)
            || !message.swapper.eq_ignore_ascii_case(&self.funder)
            || !message.recipient.eq_ignore_ascii_case(&self.funder)
            || !address(&message.vault)
            || !message.from_token.eq_ignore_ascii_case(&self.from_token)
            || !message.to_token.eq_ignore_ascii_case(&self.to_token)
            || message.from_amount != self.from_amount
            || !uint(&message.salt)
            || message.deadline != self.order_deadline.to_string()
        {
            return Err("The Flash authorization does not match this order.");
        }
        Ok(message)
    }
}
