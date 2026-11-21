use super::types::Provider;
use std::{collections::HashMap, path::Path};

/// No Debug/Serialize implementation: credentials never enter API responses or logs.
#[derive(Default)]
pub struct Config {
    jupiter: Option<String>,
    relay: Option<String>,
    flash: Option<String>,
}
impl Config {
    pub fn load(path: Option<&Path>) -> std::io::Result<Self> {
        let values = if let Some(p) = path {
            match std::fs::read_to_string(p) {
                Ok(s) => parse(&s),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
                Err(e) => return Err(e),
            }
        } else {
            HashMap::new()
        };
        let get = |name: &str| {
            std::env::var(name)
                .ok()
                .filter(|v| !v.is_empty())
                .or_else(|| values.get(name).cloned())
                .filter(|v| !v.is_empty())
        };
        let config = Self {
            jupiter: get("JUPITER_API_KEY"),
            relay: get("RELAY_API_KEY"),
            flash: get("FLASH_API_KEY"),
        };
        if [Provider::Jupiter, Provider::Relay, Provider::Flash]
            .iter()
            .any(|p| {
                config
                    .key(*p)
                    .is_some_and(|s| s.len() > 512 || !s.bytes().all(|b| b.is_ascii_graphic()))
            })
        {
            return Err(std::io::Error::other(
                "Provider configuration contains an invalid API key",
            ));
        }
        Ok(config)
    }
    pub fn key(&self, p: Provider) -> Option<&str> {
        match p {
            Provider::Jupiter => self.jupiter.as_deref(),
            Provider::Relay => self.relay.as_deref(),
            Provider::Flash => self.flash.as_deref(),
        }
    }
    pub fn ready(&self, p: Provider) -> bool {
        p == Provider::Jupiter || self.key(p).is_some()
    }
    #[cfg(test)]
    pub fn test() -> Self {
        Self {
            jupiter: None,
            relay: Some("test-key".into()),
            flash: Some("test-key".into()),
        }
    }
}
fn parse(text: &str) -> HashMap<String, String> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.starts_with('#') {
                return None;
            }
            let (key, value) = line.split_once('=')?;
            let key = key.trim();
            if !["JUPITER_API_KEY", "RELAY_API_KEY", "FLASH_API_KEY"].contains(&key) {
                return None;
            }
            let value = value.trim();
            let value = if value.len() >= 2
                && ((value.starts_with('"') && value.ends_with('"'))
                    || (value.starts_with('\'') && value.ends_with('\'')))
            {
                &value[1..value.len() - 1]
            } else {
                value
            };
            Some((key.into(), value.into()))
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn config_is_literal_and_only_known_keys_are_loaded() {
        let x=parse("RELAY_API_KEY='literal$not-expanded'\nSECRET=ignored\nFLASH_API_KEY=\"test\"\n# JUPITER_API_KEY=ignored");
        assert_eq!(x.len(), 2);
        assert_eq!(x["RELAY_API_KEY"], "literal$not-expanded");
    }
}
