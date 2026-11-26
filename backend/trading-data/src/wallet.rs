use crate::{
    chain_registry,
    execution::{amounts, types::Chain},
    ApiError,
};
use axum::{extract::Query, http::StatusCode, Json};
use base64::{engine::general_purpose::STANDARD, Engine};
use bigdecimal::num_bigint::BigUint;
use reqwest::{Client, Url};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha3::{Digest, Keccak256};
use std::{net::IpAddr, time::Duration};
use trig_wallet_transfers::{
    erc20_transfer_data, evm_address, solana_associated_address, solana_message,
    spl_recipient_address, token2022_account_size_transaction, SplSource, SplTokenProgram,
    SplTransfer, TOKEN_2022_PROGRAM,
};

type Result<T> = std::result::Result<T, ApiError>;

fn unavailable(message: &str) -> ApiError {
    ApiError(StatusCode::BAD_GATEWAY, message.into())
}

fn bad(message: &str) -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, message.into())
}

pub(crate) fn chain_for(id: &str) -> Result<Chain> {
    chain_registry::get(id)
        .filter(|entry| !entry.disabled)
        .map(|entry| entry.relay_chain())
        .ok_or_else(|| bad("This wallet network is unavailable."))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Network {
    id: String,
    name: String,
    family: &'static str,
    symbol: String,
    decimals: u8,
}
pub async fn networks() -> Json<Vec<Network>> {
    Json(
        chain_registry::catalog()
            .chains
            .iter()
            .filter(|chain| !chain.disabled)
            .map(|chain| Network {
                family: if chain.vm_type == "evm" {
                    "evm"
                } else {
                    "solana"
                },
                id: chain.chain_id(),
                name: chain.display_name.clone(),
                symbol: chain.currency.symbol.clone(),
                decimals: chain.currency.decimals,
            })
            .collect(),
    )
}

fn public_ip(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => {
            let [a, b, _, _] = v4.octets();
            !v4.is_private()
                && !v4.is_loopback()
                && !v4.is_link_local()
                && !v4.is_broadcast()
                && !v4.is_multicast()
                && !v4.is_unspecified()
                && a != 0
                && a < 224
                && !(a == 100 && (64..=127).contains(&b))
                && !(a == 198 && (18..=19).contains(&b))
        }
        IpAddr::V6(v6) => v6.segments()[0] & 0xe000 == 0x2000,
    }
}

pub(crate) struct Rpc {
    endpoint: Url,
    client: Client,
}
impl Rpc {
    pub(crate) async fn for_chain(chain: &Chain) -> Result<Self> {
        let endpoint = chain
            .rpc_url
            .as_deref()
            .and_then(|url| Url::parse(url).ok())
            .filter(|url| {
                url.scheme() == "https"
                    && url.username().is_empty()
                    && url.password().is_none()
                    && url.port_or_known_default() == Some(443)
            })
            .ok_or_else(|| unavailable("This network has no supported RPC endpoint."))?;
        let Some(host) = endpoint
            .host_str()
            .filter(|host| host.contains('.') && host.parse::<IpAddr>().is_err())
        else {
            return Err(unavailable("This network has no supported RPC endpoint."));
        };
        let lookup =
            tokio::time::timeout(Duration::from_secs(4), tokio::net::lookup_host((host, 443)))
                .await
                .ok()
                .and_then(std::result::Result::ok)
                .ok_or_else(|| unavailable("Couldn’t connect to the wallet network."))?;
        let addresses: Vec<_> = lookup.filter(|address| public_ip(address.ip())).collect();
        if addresses.is_empty() {
            return Err(unavailable("Couldn’t connect to the wallet network."));
        }
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(12))
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .resolve_to_addrs(host, &addresses)
            .build()
            .map_err(|_| unavailable("Couldn’t connect to the wallet network."))?;
        Ok(Self { endpoint, client })
    }

    pub(crate) async fn call(&self, method: &str, params: Value) -> Result<Value> {
        let request = json!({"jsonrpc":"2.0","id":1,"method":method,"params":params});
        let mut response = self
            .client
            .post(self.endpoint.clone())
            .json(&request)
            .send()
            .await
            .and_then(|response| response.error_for_status())
            .map_err(|_| unavailable("The wallet network didn’t respond. Try again."))?;
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| unavailable("Couldn’t read the wallet network response."))?
        {
            if bytes.len() + chunk.len() > 256 * 1024 {
                return Err(unavailable(
                    "The wallet network returned an invalid response.",
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        let result: Value = serde_json::from_slice(&bytes)
            .map_err(|_| unavailable("The wallet network returned an invalid response."))?;
        if result.get("error").is_some() {
            return Err(unavailable("The wallet network rejected the request."));
        }
        result
            .get("result")
            .cloned()
            .ok_or_else(|| unavailable("The wallet network returned an invalid response."))
    }

    pub(crate) async fn verify_evm(&self, chain: &Chain) -> Result<()> {
        let actual = rpc_number(&self.call("eth_chainId", json!([])).await?)?;
        if actual.to_string() != chain.provider_id {
            return Err(unavailable(
                "The wallet RPC does not match the selected network.",
            ));
        }
        Ok(())
    }
}

pub(crate) fn rpc_number(value: &Value) -> Result<BigUint> {
    let digits = value
        .as_str()
        .and_then(|v| v.strip_prefix("0x"))
        .filter(|digits| !digits.is_empty() && digits.len() <= 64)
        .ok_or_else(|| unavailable("The wallet network returned an invalid amount."))?;
    BigUint::parse_bytes(digits.as_bytes(), 16)
        .ok_or_else(|| unavailable("The wallet network returned an invalid amount."))
}

pub(crate) fn format_amount(amount: &BigUint, chain: &Chain) -> Result<String> {
    chain
        .native_token
        .as_ref()
        .and_then(|value| value.decimals)
        .and_then(|decimals| amounts::units(&amount.to_string(), decimals))
        .ok_or_else(|| unavailable("This network’s native token information is unavailable."))
}

pub(crate) async fn atomic_balance(rpc: &Rpc, chain: &Chain, address: &str) -> Result<BigUint> {
    if chain.vm == "evm" {
        rpc_number(
            &rpc.call("eth_getBalance", json!([address, "latest"]))
                .await?,
        )
    } else {
        let result = rpc
            .call("getBalance", json!([address, {"commitment":"confirmed"}]))
            .await?;
        result["value"]
            .as_u64()
            .map(BigUint::from)
            .ok_or_else(|| unavailable("The wallet network returned an invalid balance."))
    }
}

#[derive(Deserialize)]
pub struct BalanceRequest {
    chain: String,
    address: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Balance {
    amount: String,
    as_of: u64,
}

pub async fn balance(Query(request): Query<BalanceRequest>) -> Result<Json<Balance>> {
    let chain = chain_for(&request.chain)?;
    if !amounts::address(&chain.vm, &request.address) {
        return Err(bad("Invalid wallet address."));
    }
    let rpc = Rpc::for_chain(&chain).await?;
    if chain.vm == "evm" {
        rpc.verify_evm(&chain).await?;
    }
    let amount = atomic_balance(&rpc, &chain, &request.address).await?;
    Ok(Json(Balance {
        amount: format_amount(&amount, &chain)?,
        as_of: crate::now(),
    }))
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Intent {
    chain: String,
    from: String,
    to: String,
    amount: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    token_address: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferPlan {
    intent: Intent,
    amount_atomic: String,
    decimals: u8,
    fee: String,
    fee_decimals: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    account_creation_fee: Option<String>,
    expires_at: u64,
    parameters: Parameters,
}

#[derive(Serialize)]
#[serde(
    tag = "family",
    rename_all = "lowercase",
    rename_all_fields = "camelCase"
)]
enum Parameters {
    Solana {
        blockhash: String,
        last_valid_block_height: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        spl: Option<SplTransfer>,
    },
    Evm {
        chain_id: String,
        nonce: String,
        gas_price: String,
        gas_limit: String,
    },
}

fn transfer_amount(intent: &Intent, decimals: u8) -> Result<String> {
    amounts::atomic(&intent.amount, decimals)
        .map_err(|_| bad("Enter a positive amount within this token’s decimal precision."))
}

fn uint256_word(result: &Value) -> Result<BigUint> {
    if result
        .as_str()
        .and_then(|value| value.strip_prefix("0x"))
        .map(str::len)
        != Some(64)
    {
        return Err(bad(
            "The token contract returned an invalid ERC-20 response.",
        ));
    }
    rpc_number(result)
}

async fn prepare_evm(
    rpc: &Rpc,
    chain: &Chain,
    intent: Intent,
    native_decimals: u8,
) -> Result<TransferPlan> {
    rpc.verify_evm(chain).await?;
    let token_address = intent.token_address.as_deref();
    let recipient = evm_address(&intent.to).map_err(bad)?;
    let decimals = if let Some(token) = token_address {
        evm_address(token).map_err(bad)?;
        let result = rpc
            .call(
                "eth_call",
                json!([{"to":token,"data":"0x313ce567"}, "latest"]),
            )
            .await?;
        u8::try_from(uint256_word(&result)?)
            .map_err(|_| bad("The token contract returned invalid decimal precision."))?
    } else {
        native_decimals
    };
    let amount_atomic = transfer_amount(&intent, decimals)?;
    let amount =
        BigUint::parse_bytes(amount_atomic.as_bytes(), 10).ok_or_else(|| bad("Invalid amount."))?;
    let transaction = if let Some(token) = token_address {
        let account = evm_address(&intent.from).map_err(bad)?;
        let data = erc20_transfer_data(&recipient, &amount.to_bytes_be()).map_err(bad)?;
        let transaction = json!({"from":intent.from,"to":token,"value":"0x0",
            "data": format!("0x{}", hex::encode(data))});
        let (balance, result) = tokio::try_join!(
            rpc.call(
                "eth_call",
                json!([{"to": token,
                "data": format!("0x70a08231{:0>64}", hex::encode(account))}, "latest"])
            ),
            rpc.call("eth_call", json!([transaction, "latest"])),
        )?;
        if uint256_word(&balance)? < amount {
            return Err(bad("The token balance does not cover this transfer."));
        }
        // Some widely used tokens predate the Boolean return convention.
        if result.as_str() != Some("0x") && uint256_word(&result)? != BigUint::from(1u8) {
            return Err(bad("The token contract rejected this transfer."));
        }
        transaction
    } else {
        json!({"from":intent.from,"to":intent.to,"value":format!("0x{amount:x}")})
    };
    let (nonce, gas_price, gas_limit, balance) = tokio::try_join!(
        rpc.call("eth_getTransactionCount", json!([intent.from, "pending"])),
        rpc.call("eth_gasPrice", json!([])),
        rpc.call("eth_estimateGas", json!([transaction])),
        atomic_balance(rpc, chain, &intent.from),
    )?;
    let nonce = rpc_number(&nonce)?;
    let gas_price = rpc_number(&gas_price)?;
    let gas_limit = rpc_number(&gas_limit)?;
    let fee = &gas_price * &gas_limit;
    let required_balance = if token_address.is_some() {
        fee.clone()
    } else {
        &amount + &fee
    };
    if balance < required_balance {
        return Err(bad(
            "The native balance does not cover this transfer and its network fee.",
        ));
    }
    Ok(TransferPlan {
        intent,
        amount_atomic,
        decimals,
        fee: format_amount(&fee, chain)?,
        fee_decimals: native_decimals,
        account_creation_fee: None,
        expires_at: crate::now() + 25,
        parameters: Parameters::Evm {
            chain_id: chain.provider_id.clone(),
            nonce: format!("{nonce:x}"),
            gas_price: format!("{gas_price:x}"),
            gas_limit: format!("{gas_limit:x}"),
        },
    })
}

fn only_token2022_extensions(account: &Value, base_space: u64, allowed: &[&str]) -> bool {
    let data = &account["data"];
    let info = &data["parsed"]["info"];
    match info.get("extensions").and_then(Value::as_array) {
        Some(extensions) if !extensions.is_empty() => extensions.iter().all(|extension| {
            extension["extension"]
                .as_str()
                .is_some_and(|name| allowed.contains(&name))
        }),
        _ => data["space"].as_u64() == Some(base_space),
    }
}

fn solana_account_matches(
    account: &Value,
    owner: &str,
    mint: &str,
    program: SplTokenProgram,
) -> bool {
    let data = &account["data"]["parsed"];
    let info = &data["info"];
    account["owner"].as_str() == Some(program.id())
        && data["type"].as_str() == Some("account")
        && info["owner"].as_str() == Some(owner)
        && info["mint"].as_str() == Some(mint)
        && info["state"].as_str() == Some("initialized")
        && (program == SplTokenProgram::Legacy
            || only_token2022_extensions(account, 165, &["immutableOwner"]))
}

fn spl_sources(
    accounts: &Value,
    owner: &str,
    mint: &str,
    decimals: u8,
    amount: u64,
    program: SplTokenProgram,
) -> Result<Vec<SplSource>> {
    let rows = accounts["value"]
        .as_array()
        .ok_or_else(|| unavailable("Couldn’t read the source token accounts."))?;
    let mut sources: Vec<_> = rows
        .iter()
        .filter_map(|row| {
            let account = &row["account"];
            if !solana_account_matches(account, owner, mint, program) {
                return None;
            }
            let token_amount = &account["data"]["parsed"]["info"]["tokenAmount"];
            let address = row["pubkey"].as_str()?;
            if token_amount["decimals"].as_u64() != Some(u64::from(decimals))
                || !amounts::address("solana", address)
            {
                return None;
            }
            let amount = token_amount["amount"].as_str()?.parse::<u64>().ok()?;
            (amount > 0).then_some(SplSource {
                address: address.into(),
                amount,
            })
        })
        .collect();
    sources.sort_unstable_by(|left, right| {
        right
            .amount
            .cmp(&left.amount)
            .then_with(|| left.address.cmp(&right.address))
    });
    let mut remaining = amount;
    let mut selected = Vec::new();
    for mut source in sources {
        source.amount = source.amount.min(remaining);
        remaining -= source.amount;
        selected.push(source);
        if remaining == 0 {
            return Ok(selected);
        }
    }
    Err(bad(
        "The available token accounts do not cover this transfer.",
    ))
}

async fn recipient_token_account_size(
    rpc: &Rpc,
    payer: &str,
    mint: &str,
    blockhash: &str,
    program: SplTokenProgram,
) -> Result<u64> {
    if program == SplTokenProgram::Legacy {
        return Ok(165);
    }
    let wire = token2022_account_size_transaction(payer, mint, blockhash).map_err(bad)?;
    let result = rpc
        .call(
            "simulateTransaction",
            json!([STANDARD.encode(wire), {
                "encoding":"base64","commitment":"confirmed","sigVerify":false
            }]),
        )
        .await?;
    let value = &result["value"];
    let returned = &value["returnData"];
    let size = returned["data"]
        .as_array()
        .and_then(|data| match data.as_slice() {
            [data, codec] if codec.as_str() == Some("base64") => {
                let bytes: [u8; 8] = STANDARD.decode(data.as_str()?).ok()?.try_into().ok()?;
                Some(u64::from_le_bytes(bytes))
            }
            _ => None,
        });
    if value.get("err") != Some(&Value::Null)
        || returned["programId"].as_str() != Some(TOKEN_2022_PROGRAM)
    {
        return Err(unavailable(
            "Couldn’t estimate the recipient token account deposit.",
        ));
    }
    size.filter(|size| (166..=10_485_760).contains(size))
        .ok_or_else(|| unavailable("Couldn’t estimate the recipient token account deposit."))
}

async fn prepare_spl(
    rpc: &Rpc,
    intent: &Intent,
    mint: &str,
    blockhash: &str,
) -> Result<(String, SplTransfer, u64)> {
    let legacy_destination = spl_recipient_address(&intent.to, mint).map_err(bad)?;
    let token2022_destination =
        solana_associated_address(&intent.to, mint, TOKEN_2022_PROGRAM).map_err(bad)?;
    let config = json!({"encoding":"jsonParsed","commitment":"confirmed"});
    let (destination_details, accounts) = tokio::try_join!(
        rpc.call(
            "getMultipleAccounts",
            json!([
                [mint, intent.to, legacy_destination, token2022_destination],
                config
            ])
        ),
        rpc.call(
            "getTokenAccountsByOwner",
            json!([intent.from, {"mint":mint}, config])
        ),
    )?;
    let Some([mint_info, recipient, legacy_account, token2022_account]) =
        destination_details["value"].as_array().map(Vec::as_slice)
    else {
        return Err(unavailable("Couldn’t verify the recipient token account."));
    };
    let data = &mint_info["data"]["parsed"];
    let program = mint_info["owner"]
        .as_str()
        .and_then(SplTokenProgram::from_id)
        .ok_or_else(|| bad("Choose a valid Solana token mint."))?;
    if data["type"].as_str() != Some("mint")
        || data["info"]["isInitialized"].as_bool() != Some(true)
    {
        return Err(bad("Choose an initialized Solana token mint."));
    }
    if program == SplTokenProgram::Token2022
        && !only_token2022_extensions(mint_info, 82, &["metadataPointer", "tokenMetadata"])
    {
        return Err(bad(
            "This Token-2022 mint has extensions that Send doesn’t support.",
        ));
    }
    let decimals = data["info"]["decimals"]
        .as_u64()
        .and_then(|value| u8::try_from(value).ok())
        .ok_or_else(|| unavailable("The network returned invalid token precision."))?;
    if recipient["owner"]
        .as_str()
        .and_then(SplTokenProgram::from_id)
        .is_some()
        || recipient["executable"].as_bool() == Some(true)
    {
        return Err(bad("Enter the recipient’s wallet address."));
    }
    let amount_atomic = transfer_amount(intent, decimals)?;
    let amount = amount_atomic
        .parse::<u64>()
        .map_err(|_| bad("The amount exceeds the Solana range."))?;
    let sources = spl_sources(&accounts, &intent.from, mint, decimals, amount, program)?;
    let destination_account = match program {
        SplTokenProgram::Legacy => legacy_account,
        SplTokenProgram::Token2022 => token2022_account,
    };
    let create_recipient_account = destination_account.is_null();
    let account_creation_fee = if create_recipient_account {
        let size =
            recipient_token_account_size(rpc, &intent.from, mint, blockhash, program).await?;
        rpc.call(
            "getMinimumBalanceForRentExemption",
            json!([size, {"commitment":"confirmed"}]),
        )
        .await?
        .as_u64()
        .ok_or_else(|| unavailable("Couldn’t estimate the recipient token account deposit."))?
    } else {
        if !solana_account_matches(destination_account, &intent.to, mint, program) {
            return Err(bad(
                "The recipient’s token account cannot accept this transfer.",
            ));
        }
        0
    };
    Ok((
        amount_atomic,
        SplTransfer {
            program,
            decimals,
            sources,
            create_recipient_account,
        },
        account_creation_fee,
    ))
}

async fn prepare_solana(
    rpc: &Rpc,
    chain: &Chain,
    intent: Intent,
    native_decimals: u8,
) -> Result<TransferPlan> {
    let (block, balance) = tokio::try_join!(
        rpc.call("getLatestBlockhash", json!([{"commitment":"confirmed"}])),
        atomic_balance(rpc, chain, &intent.from),
    )?;
    let blockhash = block["value"]["blockhash"]
        .as_str()
        .ok_or_else(|| unavailable("The wallet network did not return a valid blockhash."))?;
    let last_valid_block_height = block["value"]["lastValidBlockHeight"]
        .as_u64()
        .ok_or_else(|| unavailable("The wallet network did not return a valid block height."))?;
    let (amount_atomic, spl, account_creation_fee) =
        if let Some(mint) = intent.token_address.as_deref() {
            let (amount_atomic, spl, fee) = prepare_spl(rpc, &intent, mint, blockhash).await?;
            (amount_atomic, Some(spl), fee)
        } else {
            (transfer_amount(&intent, native_decimals)?, None, 0)
        };
    let amount = amount_atomic
        .parse::<u64>()
        .map_err(|_| bad("The amount exceeds the Solana range."))?;
    let message = solana_message(
        &intent.from,
        &intent.to,
        amount,
        blockhash,
        intent.token_address.as_deref().zip(spl.as_ref()),
    )
    .map_err(bad)?;
    let fee = rpc
        .call(
            "getFeeForMessage",
            json!([STANDARD.encode(message.serialize()), {"commitment":"confirmed"}]),
        )
        .await?["value"]
        .as_u64()
        .map(BigUint::from)
        .ok_or_else(|| unavailable("The wallet network could not estimate the fee."))?;
    let mut required_balance = &fee + BigUint::from(account_creation_fee);
    if spl.is_none() {
        required_balance += BigUint::from(amount);
    }
    if balance < required_balance {
        return Err(bad(
            "The SOL balance does not cover this transfer and its fees.",
        ));
    }
    Ok(TransferPlan {
        intent,
        amount_atomic,
        decimals: spl.as_ref().map_or(native_decimals, |token| token.decimals),
        fee: format_amount(&fee, chain)?,
        fee_decimals: native_decimals,
        account_creation_fee: (account_creation_fee > 0)
            .then(|| format_amount(&BigUint::from(account_creation_fee), chain))
            .transpose()?,
        expires_at: crate::now() + 25,
        parameters: Parameters::Solana {
            blockhash: blockhash.into(),
            last_valid_block_height,
            spl,
        },
    })
}

pub async fn prepare(Json(intent): Json<Intent>) -> Result<Json<TransferPlan>> {
    let chain = chain_for(&intent.chain)?;
    if !amounts::address(&chain.vm, &intent.from) || !amounts::address(&chain.vm, &intent.to) {
        return Err(bad(
            "Check the sender and recipient addresses for this network.",
        ));
    }
    if amounts::same_address(&chain.vm, &intent.from, &intent.to) {
        return Err(bad("Choose a different recipient."));
    }
    if intent
        .token_address
        .as_ref()
        .is_some_and(|token| !amounts::address(&chain.vm, token))
    {
        return Err(bad("Check the token address for this network."));
    }
    let decimals = chain
        .native_token
        .as_ref()
        .and_then(|token| token.decimals)
        .ok_or_else(|| unavailable("This network’s native token information is unavailable."))?;
    let rpc = Rpc::for_chain(&chain).await?;
    if chain.vm == "evm" {
        prepare_evm(&rpc, &chain, intent, decimals).await.map(Json)
    } else {
        prepare_solana(&rpc, &chain, intent, decimals)
            .await
            .map(Json)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Submission {
    chain: String,
    signed: String,
    transaction_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmissionReceipt {
    transaction_id: String,
}

fn valid_id(chain: &Chain, value: &str) -> bool {
    if chain.vm == "evm" {
        value.len() == 66
            && value.starts_with("0x")
            && value[2..].bytes().all(|b| b.is_ascii_hexdigit())
    } else {
        value.len() <= 88
            && bs58::decode(value)
                .into_vec()
                .is_ok_and(|value| value.len() == 64)
    }
}

fn signed_transaction_id(chain: &Chain, signed: &str) -> Option<String> {
    if chain.vm == "evm" {
        let bytes = hex::decode(signed.strip_prefix("0x")?).ok()?;
        return (!bytes.is_empty()).then(|| format!("0x{}", hex::encode(Keccak256::digest(bytes))));
    }
    let bytes = STANDARD.decode(signed).ok()?;
    // Within the 1,232-byte Solana packet, the compact signature count fits in
    // one byte. The first signature is the canonical transaction ID.
    let count = usize::from(*bytes.first()?);
    if count == 0 || bytes.len() > 1_232 || bytes.len() <= 1 + count * 64 {
        return None;
    }
    let signature = &bytes[1..65];
    (!signature.iter().all(|byte| *byte == 0)).then(|| bs58::encode(signature).into_string())
}

pub async fn submit(Json(input): Json<Submission>) -> Result<Json<SubmissionReceipt>> {
    let chain = chain_for(&input.chain)?;
    if !valid_id(&chain, &input.transaction_id)
        || input.signed.len() > 8192
        || input.signed.is_empty()
    {
        return Err(bad("Invalid signed transaction."));
    }
    if !signed_transaction_id(&chain, &input.signed)
        .is_some_and(|id| amounts::same_address(&chain.vm, &id, &input.transaction_id))
    {
        return Err(bad(
            "The signed transaction does not match its transaction ID.",
        ));
    }
    let rpc = Rpc::for_chain(&chain).await?;
    let response = if chain.vm == "evm" {
        rpc.verify_evm(&chain).await?;
        rpc.call("eth_sendRawTransaction", json!([input.signed]))
            .await?
    } else {
        rpc.call("sendTransaction", json!([input.signed, {"encoding":"base64","preflightCommitment":"confirmed","maxRetries":2}])).await?
    };
    let returned = response
        .as_str()
        .ok_or_else(|| unavailable("The network returned an invalid receipt."))?;
    if !amounts::same_address(&chain.vm, returned, &input.transaction_id) {
        return Err(unavailable(
            "The network returned a different transaction ID. Check Activity before retrying.",
        ));
    }
    Ok(Json(SubmissionReceipt {
        transaction_id: input.transaction_id,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusRequest {
    pub(crate) chain: String,
    pub(crate) transaction_id: String,
    pub(crate) last_valid_block_height: Option<u64>,
}

pub async fn status(Query(input): Query<StatusRequest>) -> Result<Json<Value>> {
    let chain = chain_for(&input.chain)?;
    if !valid_id(&chain, &input.transaction_id) {
        return Err(bad("Invalid transaction ID."));
    }
    let rpc = Rpc::for_chain(&chain).await?;
    let status = if chain.vm == "evm" {
        rpc.verify_evm(&chain).await?;
        let receipt = rpc
            .call("eth_getTransactionReceipt", json!([input.transaction_id]))
            .await?;
        match receipt["status"].as_str() {
            Some("0x1") => "confirmed",
            Some("0x0") => "failed",
            _ => "pending",
        }
    } else {
        let result = rpc
            .call(
                "getSignatureStatuses",
                json!([[input.transaction_id], {"searchTransactionHistory":true}]),
            )
            .await?;
        let entry = result["value"]
            .as_array()
            .filter(|values| values.len() == 1)
            .and_then(|values| values.first())
            .ok_or_else(|| {
                unavailable("The wallet network returned an invalid signature status.")
            })?;
        match entry["confirmationStatus"].as_str() {
            Some("confirmed" | "finalized") => {
                if entry["err"].is_null() {
                    "confirmed"
                } else {
                    "failed"
                }
            }
            _ if entry.is_null() => {
                let expired = if let Some(last_valid) = input.last_valid_block_height {
                    let height = rpc
                        .call("getBlockHeight", json!([{"commitment":"finalized"}]))
                        .await?
                        .as_u64()
                        .ok_or_else(|| {
                            unavailable("The wallet network returned an invalid block height.")
                        })?;
                    height > last_valid
                } else {
                    false
                };
                if expired {
                    "failed"
                } else {
                    "pending"
                }
            }
            _ => "pending",
        }
    };
    Ok(Json(json!({"status":status})))
}

#[cfg(test)]
mod transfer_tests {
    use super::*;

    #[test]
    fn spl_source_selection_uses_only_initialized_matching_accounts() {
        let mint = "So11111111111111111111111111111111111111112";
        let owner = bs58::encode([1; 32]).into_string();
        let account = |address: u8, state: &str, owner: &str, quantity: &str| {
            json!({
                "pubkey": bs58::encode([address; 32]).into_string(),
                "account": {
                    "owner": SplTokenProgram::Legacy.id(),
                    "data": {"parsed":{"type":"account","info":{
                        "owner":owner,"mint":mint,"state":state,
                        "tokenAmount":{"amount":quantity,"decimals":9}
                    }}}
                }
            })
        };
        let accounts = json!({"value":[
            account(2, "initialized", &owner, "21"),
            account(3, "initialized", &owner, "59"),
            account(4, "frozen", &owner, "100"),
            account(5, "initialized", mint, "100"),
        ]});
        let sources = spl_sources(&accounts, &owner, mint, 9, 75, SplTokenProgram::Legacy).unwrap();
        assert_eq!(sources.len(), 2);
        assert_eq!(sources[0].address, bs58::encode([3; 32]).into_string());
        assert_eq!(sources[0].amount, 59);
        assert_eq!(sources[1].address, bs58::encode([2; 32]).into_string());
        assert_eq!(sources[1].amount, 16);
        assert!(spl_sources(&accounts, &owner, mint, 9, 81, SplTokenProgram::Legacy).is_err());
    }

    #[test]
    fn token2022_extensions_that_change_transfer_semantics_are_rejected() {
        let mint = |space, extensions| {
            json!({
                "data":{"space":space,"parsed":{"info":{"extensions":extensions}}}
            })
        };
        let allowed = ["metadataPointer", "tokenMetadata"];
        assert!(only_token2022_extensions(
            &mint(82, json!([])),
            82,
            &allowed
        ));
        assert!(only_token2022_extensions(
            &mint(
                289,
                json!([{"extension":"metadataPointer"},{"extension":"tokenMetadata"}])
            ),
            82,
            &allowed,
        ));
        assert!(!only_token2022_extensions(
            &mint(200, json!([{"extension":"transferFeeConfig"}])),
            82,
            &allowed,
        ));
        assert!(!only_token2022_extensions(
            &mint(200, json!([{"extension":"transferHook"}])),
            82,
            &allowed,
        ));
        assert!(!only_token2022_extensions(
            &mint(200, Value::Null),
            82,
            &allowed
        ));
    }

    #[tokio::test]
    async fn mismatched_transaction_id_is_rejected_before_rpc() {
        let inputs = [
            Submission {
                chain: "eip155:1".into(),
                signed: "0x01".into(),
                transaction_id: format!("0x{}", "ff".repeat(32)),
            },
            Submission {
                chain: "solana".into(),
                signed: STANDARD.encode([&[1], &[7; 64][..], &[0; 70]].concat()),
                transaction_id: bs58::encode([8; 64]).into_string(),
            },
        ];
        for input in inputs {
            let error = submit(Json(input)).await.err().unwrap();
            assert_eq!(error.0, StatusCode::BAD_REQUEST);
            assert_eq!(
                error.1,
                "The signed transaction does not match its transaction ID."
            );
        }
    }
}
