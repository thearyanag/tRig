// Relay Settlement SDK order hashing, limited to EVM and Solana.
// https://github.com/relayprotocol/relay-settlement/blob/main/packages/sdk/src/order/index.ts
use bigdecimal::num_bigint::BigUint;
use serde_json::Value;
use sha3::{Digest, Keccak256};

type Result<T> = std::result::Result<T, &'static str>;
type Word = [u8; 32];
const INVALID: &str = "Relay returned unverifiable order terms.";

pub(crate) struct OrderContext<'a> {
    pub origin: &'a str,
    pub destination: &'a str,
    pub input: &'a str,
    pub output: &'a str,
    pub payer: &'a str,
    pub recipient: &'a str,
    pub amount: &'a str,
    pub minimum_receive: &'a str,
    pub now: u64,
}

pub(crate) struct ValidatedOrder {
    pub id: Word,
    pub deadline: u64,
}

pub(crate) fn validate(value: &Value, context: &OrderContext<'_>) -> Result<ValidatedOrder> {
    let version = string(&value["version"])?;
    let (input, refunds, output, deadline, recipient, currency, minimum, calls) = match version {
        "v1" => {
            let input = one(&value["inputs"])?;
            let output = &value["output"];
            let payment = one(&output["payments"])?;
            (
                &input["payment"],
                &input["refunds"],
                output,
                &output["deadline"],
                &payment["recipient"],
                &payment["currency"],
                &payment["minimumAmount"],
                &output["calls"],
            )
        }
        "v2" => {
            let output = &value["output"];
            let fill = &output["fill"];
            (
                &value["input"],
                &value["refunds"],
                output,
                &value["deadline"],
                &fill["recipient"],
                &fill["currency"],
                &fill["minimumAmount"],
                &fill["calls"],
            )
        }
        _ => return Err(INVALID),
    };
    let deadline = deadline.as_u64().ok_or(INVALID)?;
    if deadline <= context.now
        || input["chainId"] != context.origin
        || output["chainId"] != context.destination
        || uint(&input["amount"])? != uint_string(context.amount)?
        || uint_string(context.minimum_receive)? == [0; 32]
        || uint(minimum)? != uint_string(context.minimum_receive)?
        || !same_address(&input["currency"], context.input, context.origin)
        || !same_address(recipient, context.recipient, context.destination)
        || !same_address(currency, context.output, context.destination)
        || !array(calls)?.is_empty()
        || array(refunds)?.is_empty()
    {
        return Err(INVALID);
    }
    for refund in array(refunds)? {
        let to_source = refund["chainId"] == context.origin
            && same_address(&refund["recipient"], context.payer, context.origin)
            && same_address(&refund["currency"], context.input, context.origin);
        let to_destination = refund["chainId"] == context.destination
            && same_address(&refund["recipient"], context.recipient, context.destination)
            && same_address(&refund["currency"], context.output, context.destination);
        if !to_source && !to_destination {
            return Err(INVALID);
        }
    }
    let id = order_id(value, "solana")?;
    Ok(ValidatedOrder { id, deadline })
}

pub(crate) fn order_id(value: &Value, svm_chain: &str) -> Result<Word> {
    let string_hash = |field: &Value| string(field).map(|value| hash(value.as_bytes()));
    let raw_hash = |field: &Value| raw(field).map(|value| hash(&value));
    let addr = |field: &Value, chain: &Value| {
        address(field, string(chain)? == svm_chain).map(|bytes| hash(&bytes))
    };
    let solver_address = |field: &Value| {
        let mut result = [0; 32];
        result[12..].copy_from_slice(&address(field, false)?);
        Ok::<_, &'static str>(result)
    };
    let fees = array_hash(&value["fees"], |fee| {
        Ok(struct_hash(
            FEE,
            &[
                string_hash(&fee["recipientChainId"])?,
                addr(&fee["recipient"], &fee["recipientChainId"])?,
                string_hash(&fee["currencyChainId"])?,
                addr(&fee["currency"], &fee["currencyChainId"])?,
                uint(&fee["amount"])?,
            ],
        ))
    })?;
    let salt = uint(&value["salt"])?;
    let version = string_hash(&value["version"])?;
    let output = &value["output"];
    let output_chain = &output["chainId"];
    match string(&value["version"])? {
        "v1" => {
            let inputs = array_hash(&value["inputs"], |input| {
                let payment = &input["payment"];
                let chain = &payment["chainId"];
                let payment_hash = struct_hash(
                    PAYMENT,
                    &[
                        string_hash(chain)?,
                        addr(&payment["currency"], chain)?,
                        uint(&payment["amount"])?,
                        uint(&payment["weight"])?,
                    ],
                );
                let refunds = array_hash(&input["refunds"], |refund| {
                    let chain = &refund["chainId"];
                    Ok(struct_hash(
                        REFUND,
                        &[
                            string_hash(chain)?,
                            addr(&refund["recipient"], chain)?,
                            addr(&refund["currency"], chain)?,
                            uint(&refund["minimumAmount"])?,
                            uint32(&refund["deadline"])?,
                            raw_hash(&refund["extraData"])?,
                        ],
                    ))
                })?;
                Ok(struct_hash(
                    &[INPUT, PAYMENT, REFUND].concat(),
                    &[payment_hash, refunds],
                ))
            })?;
            let payments = array_hash(&output["payments"], |payment| {
                Ok(struct_hash(
                    OUTPUT_PAYMENT,
                    &[
                        addr(&payment["recipient"], output_chain)?,
                        addr(&payment["currency"], output_chain)?,
                        uint(&payment["minimumAmount"])?,
                        uint(&payment["expectedAmount"])?,
                    ],
                ))
            })?;
            let output = struct_hash(
                &[OUTPUT, OUTPUT_PAYMENT].concat(),
                &[
                    string_hash(output_chain)?,
                    payments,
                    uint32(&output["deadline"])?,
                    array_hash(&output["calls"], raw_hash)?,
                    raw_hash(&output["extraData"])?,
                ],
            );
            let kind = [ORDER, FEE, INPUT, PAYMENT, REFUND, OUTPUT, OUTPUT_PAYMENT].concat();
            Ok(struct_hash(
                &kind,
                &[
                    version,
                    string_hash(&value["solverChainId"])?,
                    solver_address(&value["solver"])?,
                    salt,
                    inputs,
                    output,
                    fees,
                ],
            ))
        }
        "v2" => {
            let input = &value["input"];
            let input_chain = &input["chainId"];
            let input = struct_hash(
                V2_INPUT,
                &[
                    string_hash(input_chain)?,
                    addr(&input["currency"], input_chain)?,
                    uint(&input["amount"])?,
                ],
            );
            let refunds = array_hash(&value["refunds"], |refund| {
                let chain = &refund["chainId"];
                Ok(struct_hash(
                    V2_REFUND,
                    &[
                        string_hash(chain)?,
                        addr(&refund["currency"], chain)?,
                        uint(&refund["minimumAmount"])?,
                        addr(&refund["recipient"], chain)?,
                    ],
                ))
            })?;
            let withdraw = &output["withdraw"];
            let withdraw = struct_hash(
                V2_WITHDRAW,
                &[
                    addr(&withdraw["currency"], output_chain)?,
                    uint(&withdraw["minimumAmount"])?,
                ],
            );
            let fill = &output["fill"];
            let fill = struct_hash(
                V2_FILL,
                &[
                    addr(&fill["currency"], output_chain)?,
                    uint(&fill["minimumAmount"])?,
                    addr(&fill["recipient"], output_chain)?,
                    array_hash(&fill["calls"], raw_hash)?,
                ],
            );
            let output = struct_hash(
                &[V2_OUTPUT, V2_FILL, V2_WITHDRAW].concat(),
                &[string_hash(output_chain)?, withdraw, fill],
            );
            let kind = [
                V2_ORDER,
                FEE,
                V2_FILL,
                V2_INPUT,
                V2_OUTPUT,
                V2_REFUND,
                V2_WITHDRAW,
            ]
            .concat();
            Ok(struct_hash(
                &kind,
                &[
                    version,
                    string_hash(&value["relayerChainId"])?,
                    solver_address(&value["relayer"])?,
                    salt,
                    uint32(&value["deadline"])?,
                    input,
                    refunds,
                    output,
                    fees,
                ],
            ))
        }
        _ => Err(INVALID),
    }
}

const ORDER: &str = "Order(string version,string solverChainId,address solver,uint256 salt,Input[] inputs,Output output,Fee[] fees)";
const FEE: &str = "Fee(string recipientChainId,bytes recipient,string currencyChainId,bytes currency,uint256 amount)";
const INPUT: &str = "Input(InputPayment payment,InputRefund[] refunds)";
const PAYMENT: &str = "InputPayment(string chainId,bytes currency,uint256 amount,uint256 weight)";
const REFUND: &str = "InputRefund(string chainId,bytes recipient,bytes currency,uint256 minimumAmount,uint32 deadline,bytes extraData)";
const OUTPUT: &str =
    "Output(string chainId,OutputPayment[] payments,uint32 deadline,bytes[] calls,bytes extraData)";
const OUTPUT_PAYMENT: &str =
    "OutputPayment(bytes recipient,bytes currency,uint256 minimumAmount,uint256 expectedAmount)";
const V2_ORDER: &str = "Order(string version,string relayerChainId,address relayer,uint256 salt,uint32 deadline,Input input,Refund[] refunds,Output output,Fee[] fees)";
const V2_INPUT: &str = "Input(string chainId,bytes currency,uint256 amount)";
const V2_REFUND: &str =
    "Refund(string chainId,bytes currency,uint256 minimumAmount,bytes recipient)";
const V2_OUTPUT: &str = "Output(string chainId,Withdraw withdraw,Fill fill)";
const V2_FILL: &str = "Fill(bytes currency,uint256 minimumAmount,bytes recipient,bytes[] calls)";
const V2_WITHDRAW: &str = "Withdraw(bytes currency,uint256 minimumAmount)";

fn hash(bytes: &[u8]) -> Word {
    Keccak256::digest(bytes).into()
}
fn struct_hash(kind: &str, words: &[Word]) -> Word {
    let mut hasher = Keccak256::new();
    hasher.update(hash(kind.as_bytes()));
    for word in words {
        hasher.update(word);
    }
    hasher.finalize().into()
}
fn array_hash(value: &Value, item: impl Fn(&Value) -> Result<Word>) -> Result<Word> {
    let mut hasher = Keccak256::new();
    for row in array(value)? {
        hasher.update(item(row)?);
    }
    Ok(hasher.finalize().into())
}
fn array(value: &Value) -> Result<&[Value]> {
    value
        .as_array()
        .filter(|items| items.len() <= 12)
        .map(Vec::as_slice)
        .ok_or(INVALID)
}
fn one(value: &Value) -> Result<&Value> {
    match array(value)? {
        [item] => Ok(item),
        _ => Err(INVALID),
    }
}
fn string(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|text| text.len() <= 4096)
        .ok_or(INVALID)
}
fn raw(value: &Value) -> Result<Vec<u8>> {
    let text = string(value)?.strip_prefix("0x").ok_or(INVALID)?;
    hex::decode(text).map_err(|_| INVALID)
}
fn address(value: &Value, svm: bool) -> Result<Vec<u8>> {
    let bytes = if svm {
        bs58::decode(string(value)?)
            .into_vec()
            .map_err(|_| INVALID)?
    } else {
        raw(value)?
    };
    (bytes.len() == if svm { 32 } else { 20 })
        .then_some(bytes)
        .ok_or(INVALID)
}
fn same_address(value: &Value, expected: &str, chain: &str) -> bool {
    if chain == "solana" {
        value.as_str() == Some(expected)
    } else {
        value
            .as_str()
            .is_some_and(|value| value.eq_ignore_ascii_case(expected))
    }
}
fn uint(value: &Value) -> Result<Word> {
    uint_string(string(value)?)
}
fn uint32(value: &Value) -> Result<Word> {
    let integer = u32::try_from(value.as_u64().ok_or(INVALID)?).map_err(|_| INVALID)?;
    let mut word = [0; 32];
    word[28..].copy_from_slice(&integer.to_be_bytes());
    Ok(word)
}
pub(super) fn uint_string(value: &str) -> Result<Word> {
    let (number, radix) = match value.strip_prefix("0x") {
        Some(number) => (number, 16),
        None => (value, 10),
    };
    if number.is_empty()
        || number.len() > 78
        || !number.bytes().all(|byte| {
            if radix == 10 {
                byte.is_ascii_digit()
            } else {
                byte.is_ascii_hexdigit()
            }
        })
    {
        return Err(INVALID);
    }
    let bytes = BigUint::parse_bytes(number.as_bytes(), radix)
        .ok_or(INVALID)?
        .to_bytes_be();
    if bytes.len() > 32 {
        return Err(INVALID);
    }
    let mut word = [0; 32];
    word[32 - bytes.len()..].copy_from_slice(&bytes);
    Ok(word)
}
