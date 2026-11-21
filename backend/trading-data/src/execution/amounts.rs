use super::types::*;
use bigdecimal::{BigDecimal, Zero};
use std::str::FromStr;

pub fn decimal(s: &str) -> Result<BigDecimal> {
    if s.is_empty() || s.len() > 300 || s.trim() != s {
        return Err(Error::invalid("Enter a positive decimal amount."));
    }
    let mut parts = s.split('.');
    let whole = parts.next().unwrap_or("");
    let fraction = parts.next().unwrap_or("");
    if parts.next().is_some()
        || whole.is_empty() && fraction.is_empty()
        || !whole
            .bytes()
            .chain(fraction.bytes())
            .all(|b| b.is_ascii_digit())
    {
        return Err(Error::invalid("Use digits and a decimal point."));
    }
    let n = BigDecimal::from_str(s).map_err(|_| Error::invalid("Invalid decimal amount."))?;
    if n <= BigDecimal::zero() {
        return Err(Error::invalid("Enter a positive amount."));
    }
    Ok(n)
}
pub fn number(value: &serde_json::Value) -> Option<String> {
    let text = value
        .as_str()
        .map(str::to_owned)
        .or_else(|| value.as_number().map(ToString::to_string))?;
    crate::portfolio::number(&serde_json::Value::String(text)).map(|n| crate::portfolio::text(&n))
}
pub fn nonnegative(value: &serde_json::Value) -> Option<String> {
    let s = number(value)?;
    (BigDecimal::from_str(&s).ok()? >= BigDecimal::zero()).then_some(s)
}
pub fn positive(value: &serde_json::Value) -> Option<String> {
    let s = number(value)?;
    (BigDecimal::from_str(&s).ok()? > BigDecimal::zero()).then_some(s)
}
pub fn atomic(s: &str, decimals: u8) -> Result<String> {
    decimal(s)?;
    let (whole, frac) = s.split_once('.').unwrap_or((s, ""));
    let frac = frac.trim_end_matches('0');
    if frac.len() > usize::from(decimals) {
        return Err(Error::invalid(
            "Amount exceeds this token's decimal precision.",
        ));
    }
    let raw = format!(
        "{whole}{frac}{}",
        "0".repeat(usize::from(decimals) - frac.len())
    )
    .trim_start_matches('0')
    .to_string();
    const MAX: &str =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    if raw.len() > MAX.len() || raw.len() == MAX.len() && raw.as_str() > MAX {
        return Err(Error::invalid("Amount exceeds the supported token range."));
    }
    Ok(raw)
}
pub fn units(raw: &str, decimals: u8) -> Option<String> {
    if raw.is_empty() || raw.len() > 78 || !raw.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let raw = raw.trim_start_matches('0');
    let raw = if raw.is_empty() { "0" } else { raw };
    if decimals == 0 {
        return Some(raw.into());
    }
    let padded = format!("{:0>width$}", raw, width = usize::from(decimals) + 1);
    let split = padded.len() - usize::from(decimals);
    Some(
        format!("{}.{}", &padded[..split], &padded[split..])
            .trim_end_matches('0')
            .trim_end_matches('.')
            .into(),
    )
}
pub fn same_amount(a: &str, b: &str) -> bool {
    crate::portfolio::number(&serde_json::Value::String(a.into()))
        .zip(crate::portfolio::number(&serde_json::Value::String(
            b.into(),
        )))
        .is_some_and(|(x, y)| x == y)
}
pub fn canonical_address(vm: &str, address: &str) -> String {
    if vm == "evm" {
        address.to_ascii_lowercase()
    } else {
        address.to_owned()
    }
}
pub fn same_address(vm: &str, a: &str, b: &str) -> bool {
    if vm == "evm" {
        a.eq_ignore_ascii_case(b)
    } else {
        a == b
    }
}
pub fn address(vm: &str, s: &str) -> bool {
    match vm {
        "evm" => {
            s.len() == 42 && s.starts_with("0x") && s[2..].bytes().all(|c| c.is_ascii_hexdigit())
        }
        "svm" => crate::discovery::is_address(s),
        _ => !s.is_empty() && s.len() <= 256 && s.bytes().all(|c| c.is_ascii_graphic()),
    }
}
pub fn validate(r: &QuoteRequest) -> Result<()> {
    decimal(&r.amount)?;
    if r.order_type == OrderType::StopLoss && r.side == Some(crate::quotes::Side::Buy) {
        return Err(Error::invalid("Stop-loss estimates sell the input token."));
    }
    if !(1..=500).contains(&r.slippage_bps) {
        return Err(Error::invalid("Slippage must be between 1 and 500 bps."));
    }
    for t in [&r.input, &r.output] {
        if t.chain.is_empty()
            || t.chain.len() > 64
            || t.address.is_empty()
            || t.address.len() > 256
            || !t.address.bytes().all(|b| b.is_ascii_graphic())
        {
            return Err(Error::invalid("Choose a valid chain and token address."));
        }
    }
    if r.input == r.output {
        return Err(Error::invalid("Choose two different tokens or chains."));
    }
    match r.order_type {
        OrderType::Market => {
            if r.limit_price_usd.is_some() || r.trigger_price_usd.is_some() {
                return Err(Error::invalid(
                    "Market quotes do not take limit or trigger prices.",
                ));
            }
        }
        OrderType::Limit => {
            decimal(r.limit_price_usd.as_deref().ok_or_else(|| {
                Error::invalid("Enter a USD limit price for the receive token.")
            })?)?;
            if r.trigger_price_usd.is_some() {
                return Err(Error::invalid(
                    "A limit quote does not take a trigger price.",
                ));
            }
        }
        OrderType::StopLoss => {
            decimal(r.trigger_price_usd.as_deref().ok_or_else(|| {
                Error::invalid("Enter a USD stop price for the token being sold.")
            })?)?;
            if r.limit_price_usd.is_some() {
                return Err(Error::invalid(
                    "Stop-loss quotes currently use a market trigger.",
                ));
            }
        }
    }
    Ok(())
}
