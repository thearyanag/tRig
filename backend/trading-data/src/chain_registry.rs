use crate::execution::types::{Chain, Token};
use serde::Deserialize;
use std::sync::OnceLock;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Registry {
    pub captured_at: u64,
    pub chains: Vec<Entry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Entry {
    pub id: u64,
    pub name: String,
    pub display_name: String,
    pub vm_type: String,
    pub disabled: bool,
    pub deposit_enabled: bool,
    pub http_rpc_url: String,
    pub explorer_url: Option<String>,
    pub gecko_network: String,
    pub currency: Currency,
}

#[derive(Deserialize)]
pub(crate) struct Currency {
    pub address: String,
    pub name: String,
    pub symbol: String,
    pub decimals: u8,
}

impl Entry {
    pub fn chain_id(&self) -> String {
        if self.name == "solana" {
            "solana".into()
        } else {
            format!("eip155:{}", self.id)
        }
    }

    pub fn relay_chain(&self) -> Chain {
        let id = self.chain_id();
        Chain {
            native_token: Some(Token {
                chain: id.clone(),
                address: self.currency.address.clone(),
                symbol: self.currency.symbol.clone(),
                decimals: Some(self.currency.decimals),
            }),
            id,
            name: self.display_name.clone(),
            vm: self.vm_type.clone(),
            provider_id: self.id.to_string(),
            enabled: !self.disabled,
            deposit_enabled: self.deposit_enabled,
            minimum_order_usd: None,
            rpc_url: Some(self.http_rpc_url.clone()),
        }
    }
}

pub(crate) fn catalog() -> &'static Registry {
    static REGISTRY: OnceLock<Registry> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        serde_json::from_str(include_str!("chain-registry.json")).expect("bundled chain registry")
    })
}

pub(crate) fn get(chain_id: &str) -> Option<&'static Entry> {
    let rows = &catalog().chains;
    if chain_id == "solana" {
        return rows.iter().find(|chain| chain.name == "solana");
    }
    let id = chain_id.strip_prefix("eip155:")?;
    if id.starts_with('0') || !id.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let id = id.parse::<u64>().ok()?;
    rows.iter()
        .find(|chain| chain.vm_type == "evm" && chain.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn registry_has_exactly_the_supported_networks() {
        let rows = &catalog().chains;
        assert_eq!(rows.len(), 22);
        assert_eq!(get("solana").unwrap().vm_type, "svm");
        let expected = [
            1, 10, 25, 56, 130, 137, 143, 146, 196, 999, 4326, 4663, 5000, 5042, 8453, 9745, 42161,
            43114, 57073, 80094, 99901,
        ];
        assert_eq!(
            rows.iter()
                .filter(|row| row.vm_type == "evm")
                .map(|row| row.id)
                .collect::<HashSet<_>>(),
            HashSet::from(expected),
        );
        assert!(rows
            .iter()
            .all(|row| !row.disabled && !row.gecko_network.is_empty()));
        assert!(get("eip155:1329").is_none());
    }
}
