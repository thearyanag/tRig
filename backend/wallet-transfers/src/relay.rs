pub const NATIVE_EVM_TOKEN: &str = "0x0000000000000000000000000000000000000000";

// Relay's production /chains catalog and relay-settlement settlement-networks source.
pub fn depository(chain: u64) -> Option<&'static str> {
    match chain {
        25 | 5000 => Some("0x59916da825d2d2ec1bf878d71c88826f6633ecca"),
        1 | 10 | 56 | 130 | 137 | 143 | 146 | 196 | 999 | 4326 | 4663 | 5042 | 8453 | 9745
        | 42161 | 43114 | 57073 | 80094 | 99901 => {
            Some("0x4cd00e387622c35bddb9b4c962c136462338bc31")
        }
        _ => None,
    }
}

pub fn approval_data(spender: &[u8; 20], amount: &[u8; 32]) -> Vec<u8> {
    let mut data = vec![0x09, 0x5e, 0xa7, 0xb3]; // approve(address,uint256)
    data.extend(address_word(spender));
    data.extend(amount);
    data
}

pub fn deposit_data(
    payer: &[u8; 20],
    token: Option<&[u8; 20]>,
    amount: &[u8; 32],
    order: &[u8; 32],
) -> Vec<u8> {
    let mut data = match token {
        Some(_) => vec![0xe8, 0x01, 0x79, 0x52], // depositErc20(address,address,uint256,bytes32)
        None => vec![0x49, 0x29, 0x0c, 0x1c],    // depositNative(address,bytes32)
    };
    data.extend(address_word(payer));
    if let Some(token) = token {
        data.extend(address_word(token));
        data.extend(amount);
    }
    data.extend(order);
    data
}

fn address_word(address: &[u8; 20]) -> [u8; 32] {
    let mut word = [0; 32];
    word[12..].copy_from_slice(address);
    word
}
